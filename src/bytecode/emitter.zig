//! AST-to-bytecode emission for the initial control-flow and call subset.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zfunctions = @import("zfunctions");
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const codeblock = @import("codeblock.zig");

pub const CompiledCodeBlock = struct {
    block: codeblock.CodeBlock,

    pub fn deinit(self: *CompiledCodeBlock, allocator: Allocator) void {
        self.block.deinitJit(allocator);
        allocator.free(self.block.ops);
        allocator.free(self.block.constants);
        allocator.free(self.block.exception_table);
        for (self.block.captured_names) |name| {
            allocator.free(name);
        }
        allocator.free(self.block.captured_names);
        allocator.free(self.block.captured_is_lexical);
        @import("vm.zig").clearPropIC();
        for (self.block.call_target_cache) |*c| {
            if (c.callee) |v| {
                var val = v;
                val.deinit();
            }
        }
        allocator.free(self.block.call_target_cache);
        self.* = undefined;
    }
};

/// Lowers the arithmetic, branch, and bare-call subset. Unsupported syntax is
/// reported during compilation; it still executes through the AST walker.
pub const BytecodeEmitter = struct {
    const LoopCtx = struct {
        breaks: std.ArrayListUnmanaged(usize) = .empty,
        continues: std.ArrayListUnmanaged(usize) = .empty,
        try_depth: u16,
    };

    const EmitterBinding = struct {
        name: []const u8,
        slot: u16,
        kind: codeblock.LocalKind,
        depth: u16,
        captured: bool,
        initialized: bool,
    };

    allocator: Allocator,
    scope: codeblock.ScopeAnalysis,
    ops: std.ArrayListUnmanaged(codeblock.Op) = .empty,
    constants: std.ArrayListUnmanaged(codeblock.Constant) = .empty,
    free_registers: std.ArrayListUnmanaged(u8) = .empty,
    call_sites: std.ArrayListUnmanaged(codeblock.CallSiteCache) = .empty,
    bindings: std.ArrayListUnmanaged(EmitterBinding) = .empty,
    next_register: u16,
    max_register: u16,
    scope_depth: u16 = 0,
    is_script: bool = false,
    try_depth: u16 = 0,
    current_loop: ?*LoopCtx = null,

    pub fn emit(allocator: Allocator, function: *const zfunctions.FunctionNode) !CompiledCodeBlock {
        if (function.is_generator or function.is_async) return error.UnsupportedSyntax;
        if (function.params.rest != null) return error.UnsupportedSyntax;
        for (function.params.items) |param| {
            if (param.default != null) return error.UnsupportedSyntax;
            if (param.pattern.* != .identifier) return error.UnsupportedSyntax;
        }
        const scope = try codeblock.ScopeAnalyzer.analyze(allocator, function);
        if (scope.flags.has_super) {
            var mut_scope = scope;
            mut_scope.deinit(allocator);
            return error.UnsupportedSyntax;
        }
        var self = BytecodeEmitter{
            .allocator = allocator,
            .scope = scope,
            .next_register = scope.local_count,
            .max_register = scope.local_count,
        };
        defer self.scope.deinit(allocator);
        defer self.free_registers.deinit(allocator);
        defer self.call_sites.deinit(allocator);
        defer self.bindings.deinit(allocator);
        for (function.params.items) |param| {
            if (self.scope.capturesLocal(param.pattern.identifier.name)) return error.UnsupportedSyntax;
        }
        errdefer self.ops.deinit(allocator);
        errdefer self.constants.deinit(allocator);

        try self.initRootBindings();
        if (function.body == .block and function.body.block.data == .block) {
            try self.prebindBlockLexicals(function.body.block.data.block);
        }

        try self.emitBody(function.body);
        try self.fuseCmpJumps();
        const ops = try self.ops.toOwnedSlice(allocator);
        errdefer allocator.free(ops);
        const constants = try self.constants.toOwnedSlice(allocator);
        errdefer allocator.free(constants);
        const call_target_cache = try self.call_sites.toOwnedSlice(allocator);
        errdefer allocator.free(call_target_cache);
        const captured_names = try allocator.alloc([]const u8, scope.captured_locals.len);
        errdefer allocator.free(captured_names);
        const captured_is_lexical = try allocator.alloc(bool, scope.captured_locals.len);
        errdefer allocator.free(captured_is_lexical);
        var duped_count: usize = 0;
        errdefer for (captured_names[0..duped_count]) |n| allocator.free(n);
        for (scope.captured_locals, 0..) |n, i| {
            captured_names[i] = try allocator.dupe(u8, n);
            duped_count += 1;
            const kind = self.rootBindingKind(n);
            captured_is_lexical[i] = (kind == .let or kind == .@"const");
        }
        return .{ .block = .{
            .ops = ops,
            .constants = constants,
            .call_target_cache = call_target_cache,
            .captured_names = captured_names,
            .captured_is_lexical = captured_is_lexical,
            .local_count = scope.local_count,
            .register_count = self.max_register,
            .param_count = scope.param_count,
            .capture_count = @intCast(scope.captured_locals.len),
            .flags = scope.flags,
            .name = functionName(function),
        } };
    }

    pub fn emitScript(allocator: Allocator, statements: anytype) !CompiledCodeBlock {
        const scope = try codeblock.ScopeAnalyzer.analyzeStatements(allocator, statements);
        if (scope.flags.has_super) {
            var mut_scope = scope;
            mut_scope.deinit(allocator);
            return error.UnsupportedSyntax;
        }
        var self = BytecodeEmitter{
            .allocator = allocator,
            .scope = scope,
            .next_register = scope.local_count,
            .max_register = scope.local_count,
            .is_script = true,
        };
        defer self.scope.deinit(allocator);
        defer self.free_registers.deinit(allocator);
        defer self.call_sites.deinit(allocator);
        defer self.bindings.deinit(allocator);
        errdefer self.ops.deinit(allocator);
        errdefer self.constants.deinit(allocator);

        try self.initRootBindings();
        try self.prebindBlockLexicals(statements);

        var last_register: ?u8 = null;
        for (statements) |statement| {
            if (last_register) |prev| self.freeRegister(prev);
            switch (statement.data) {
                .expr_stmt => |expr| {
                    last_register = try self.emitExpression(expr);
                },
                else => {
                    try self.emitStatement(statement);
                    last_register = null;
                },
            }
        }
        if (last_register) |reg| {
            try self.emitOp(.{ .opcode = .return_value, .a = reg });
            self.freeRegister(reg);
        } else {
            try self.emitOp(.{ .opcode = .return_undefined });
        }

        try self.fuseCmpJumps();
        const ops = try self.ops.toOwnedSlice(allocator);
        errdefer allocator.free(ops);
        const constants = try self.constants.toOwnedSlice(allocator);
        errdefer allocator.free(constants);
        const call_target_cache = try self.call_sites.toOwnedSlice(allocator);
        errdefer allocator.free(call_target_cache);
        return .{ .block = .{
            .ops = ops,
            .constants = constants,
            .call_target_cache = call_target_cache,
            .captured_names = &.{},
            .local_count = scope.local_count,
            .register_count = self.max_register,
            .param_count = 0,
            .capture_count = 0,
            .flags = scope.flags,
            .name = null,
        } };
    }

    fn functionName(function: *const zfunctions.FunctionNode) ?[]const u8 {
        return switch (function.kind) {
            .function_decl => |kind| kind.name,
            .function_expr => |kind| kind.name,
            .method => |kind| kind.name,
            .arrow => null,
        };
    }

    fn emitBody(self: *BytecodeEmitter, body: zfunctions.FunctionBody) !void {
        switch (body) {
            .expression => |expression| {
                const value = try self.emitExpression(expression);
                try self.emitOp(.{ .opcode = .return_value, .a = value });
                self.freeRegister(value);
            },
            .block => |block| {
                for (block.data.block) |statement| {
                    if (statement.data == .function_declaration) {
                        try self.emitStatement(statement);
                    }
                }
                for (block.data.block) |statement| {
                    if (statement.data == .function_declaration) continue;
                    try self.emitStatement(statement);
                }
                try self.emitOp(.{ .opcode = .return_undefined });
            },
        }
    }

    fn initRootBindings(self: *BytecodeEmitter) !void {
        for (self.scope.locals) |local| {
            switch (local.kind) {
                .parameter, .@"var", .function => {
                    try self.bindings.append(self.allocator, .{
                        .name = local.name,
                        .slot = local.slot,
                        .kind = local.kind,
                        .depth = 0,
                        .captured = self.scope.capturesLocal(local.name),
                        .initialized = true,
                    });
                },
                else => {},
            }
        }
    }

    fn rootBindingKind(self: *const BytecodeEmitter, name: []const u8) ?codeblock.LocalKind {
        for (self.bindings.items) |b| {
            if (b.depth == 0 and std.mem.eql(u8, b.name, name)) return b.kind;
        }
        return self.scope.localKind(name);
    }

    fn prebindVariableLexical(self: *BytecodeEmitter, variable: anytype) !void {
        const lkind: codeblock.LocalKind = if (variable.kind == .@"const") .@"const" else .let;
        for (variable.declarators) |declarator| {
            if (declarator.pattern.* != .identifier) return error.UnsupportedSyntax;
            const slot = self.scope.patternSlot(declarator.pattern) orelse return error.UnsupportedSyntax;
            const name = declarator.pattern.identifier.name;
            try self.bindings.append(self.allocator, .{
                .name = name,
                .slot = slot,
                .kind = lkind,
                .depth = self.scope_depth,
                .captured = (self.scope_depth == 0 and self.scope.capturesLocal(name)),
                .initialized = false,
            });
        }
    }

    fn prebindBlockLexicals(self: *BytecodeEmitter, stmts: anytype) anyerror!void {
        for (stmts) |stmt| {
            switch (stmt.data) {
                .variable => |variable| {
                    if (variable.kind != .@"var") {
                        try self.prebindVariableLexical(variable);
                    }
                },
                .class_declaration => return error.UnsupportedSyntax,
                .function_declaration => {
                    if (self.scope_depth > 0) return error.UnsupportedSyntax;
                },
                else => {},
            }
        }
    }

    fn resolveBinding(self: *const BytecodeEmitter, name: []const u8) ?EmitterBinding {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            const b = self.bindings.items[i];
            if (std.mem.eql(u8, b.name, name)) return b;
        }
        return null;
    }

    fn findBindingIndexBySlot(self: *const BytecodeEmitter, slot: u16) ?usize {
        var i = self.bindings.items.len;
        while (i > 0) {
            i -= 1;
            if (self.bindings.items[i].slot == slot) return i;
        }
        return null;
    }

    fn emitConstAssignTypeError(self: *BytecodeEmitter) !void {
        try self.emitOp(.{ .opcode = .throw_value, .a = 0, .b = 1 });
    }

    fn emitStatement(self: *BytecodeEmitter, statement: *const zstatements.Statement) anyerror!void {
        switch (statement.data) {
            .block => |items| {
                const mark = self.bindings.items.len;
                self.scope_depth += 1;
                defer {
                    self.bindings.items.len = mark;
                    self.scope_depth -= 1;
                }
                try self.prebindBlockLexicals(items);
                for (items) |item| try self.emitStatement(item);
            },
            .return_stmt => |value| {
                if (value) |expression| {
                    const register = try self.emitReadOperand(expression);
                    try self.emitOp(.{ .opcode = .return_value, .a = register });
                    self.freeRegister(register);
                } else try self.emitOp(.{ .opcode = .return_undefined });
            },
            .expr_stmt => |expression| {
                try self.emitEffectExpression(expression);
            },
            .variable => |variable| try self.emitVariable(variable),
            .if_stmt => |item| try self.emitIf(item),
            .while_stmt => |item| try self.emitWhile(item),
            .do_while => |item| try self.emitDoWhile(item),
            .for_stmt => |item| try self.emitFor(item.head, item.body),
            .function_declaration => |ptr| try self.emitFunctionDeclaration(ptr),
            .try_stmt => |item| try self.emitTry(item),
            .throw_stmt => |arg| try self.emitThrow(arg),
            .empty => {},
            .break_stmt => |label| {
                if (self.is_script or label != null) return error.UnsupportedSyntax;
                const lctx = self.current_loop orelse return error.UnsupportedSyntax;
                if (lctx.try_depth != self.try_depth) return error.UnsupportedSyntax;
                const j = try self.emitJump(.jump, 0);
                try lctx.breaks.append(self.allocator, j);
            },
            .continue_stmt => |label| {
                if (self.is_script or label != null) return error.UnsupportedSyntax;
                const lctx = self.current_loop orelse return error.UnsupportedSyntax;
                if (lctx.try_depth != self.try_depth) return error.UnsupportedSyntax;
                const j = try self.emitJump(.jump, 0);
                try lctx.continues.append(self.allocator, j);
            },
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitStore(self: *BytecodeEmitter, name: []const u8, reg: u8) !void {
        if (std.mem.eql(u8, name, "arguments") and self.resolveBinding("arguments") == null) {
            return error.UnsupportedSyntax;
        }
        if (self.resolveBinding(name)) |b| {
            if (!b.initialized) return error.UnsupportedSyntax;
            if (b.kind == .@"const") return self.emitConstAssignTypeError();
            if (!b.captured) {
                return self.emitOp(.{ .opcode = .store_local, .a = try small(b.slot), .b = reg });
            }
        }
        const constant = try self.addConstant(.{ .property_key = name });
        return self.emitOp(.{ .opcode = .store_global, .a = constant, .b = reg, .c = 0 });
    }

    fn emitVariable(self: *BytecodeEmitter, variable: anytype) !void {
        for (variable.declarators) |declarator| {
            if (declarator.pattern.* != .identifier) return error.UnsupportedSyntax;
            const name = declarator.pattern.identifier.name;
            const slot = self.scope.patternSlot(declarator.pattern) orelse return error.UnsupportedSyntax;
            if (variable.kind == .@"var") {
                if (declarator.init == null) continue;
                const init = declarator.init.?;
                if (!self.scope.capturesLocal(name)) {
                    const local_slot = try small(slot);
                    try self.emitExprInto(init, local_slot, name);
                } else {
                    const val_reg = try self.emitExpression(init);
                    const constant = try self.addConstant(.{ .property_key = name });
                    try self.emitOp(.{ .opcode = .store_global, .a = constant, .b = val_reg, .c = 0 });
                    self.freeRegister(val_reg);
                }
                continue;
            }
            const b_idx = self.findBindingIndexBySlot(slot) orelse return error.UnsupportedSyntax;
            const is_captured = self.bindings.items[b_idx].captured;
            if (!is_captured) {
                const local_slot = try small(slot);
                if (declarator.init) |init| {
                    try self.emitExprInto(init, local_slot, name);
                } else {
                    try self.emitOp(.{ .opcode = .load_undefined, .a = local_slot });
                }
                self.bindings.items[b_idx].initialized = true;
            } else {
                const val_reg = if (declarator.init) |init|
                    try self.emitExpression(init)
                else
                    try self.emitSimple(.load_undefined);
                self.bindings.items[b_idx].initialized = true;
                const init_mode: u8 = if (variable.kind == .@"const") 2 else 1;
                const constant = try self.addConstant(.{ .property_key = name });
                try self.emitOp(.{ .opcode = .store_global, .a = constant, .b = val_reg, .c = init_mode });
                self.freeRegister(val_reg);
            }
        }
    }

    fn emitExprInto(self: *BytecodeEmitter, expression: *const zparser.Node, target_slot: u8, target_name: []const u8) anyerror!void {
        const cur = unwrapParen(expression);
        if (cur.data == .object_literal and !exprReferencesIdent(cur, target_name)) {
            try self.emitObjectLiteralInto(cur.data.object_literal, target_slot);
            return;
        }
        if (cur.data == .array_literal and !exprReferencesIdent(cur, target_name)) {
            try self.emitArrayLiteralInto(cur.data.array_literal, target_slot);
            return;
        }
        const val_reg = try self.emitExpression(cur);
        if (val_reg == target_slot) return;
        if (isSingleDefExpr(cur) and val_reg >= self.scope.local_count and self.ops.items.len > 0 and self.ops.items[self.ops.items.len - 1].a == val_reg and isRegisterDefOpcode(self.ops.items[self.ops.items.len - 1].opcode)) {
            self.ops.items[self.ops.items.len - 1].a = target_slot;
            self.freeRegister(val_reg);
            return;
        }
        try self.emitOp(.{ .opcode = .store_local, .a = target_slot, .b = val_reg });
        self.freeRegister(val_reg);
    }

    fn emitIf(self: *BytecodeEmitter, item: anytype) anyerror!void {
        const condition = try self.emitExpression(item.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        self.freeRegister(condition);
        try self.emitStatement(item.consequent);
        if (item.alternate) |alternate| {
            const end_jump = try self.emitJump(.jump, 0);
            try self.patchJump(false_jump, self.ops.items.len);
            try self.emitStatement(alternate);
            try self.patchJump(end_jump, self.ops.items.len);
        } else try self.patchJump(false_jump, self.ops.items.len);
    }

    fn emitWhile(self: *BytecodeEmitter, item: anytype) anyerror!void {
        var lctx = LoopCtx{ .try_depth = self.try_depth };
        const prev_loop = self.current_loop;
        self.current_loop = &lctx;
        defer {
            self.current_loop = prev_loop;
            lctx.breaks.deinit(self.allocator);
            lctx.continues.deinit(self.allocator);
        }
        const start = self.ops.items.len;
        const condition = try self.emitExpression(item.test_expr);
        const end_jump = try self.emitJump(.jump_if_false, condition);
        self.freeRegister(condition);
        try self.emitStatement(item.body);
        for (lctx.continues.items) |cj| try self.patchJump(cj, start);
        const back = try self.emitJump(.jump, 0);
        try self.patchJump(back, start);
        const after = self.ops.items.len;
        try self.patchJump(end_jump, after);
        for (lctx.breaks.items) |bj| try self.patchJump(bj, after);
    }

    fn emitDoWhile(self: *BytecodeEmitter, item: anytype) anyerror!void {
        var lctx = LoopCtx{ .try_depth = self.try_depth };
        const prev_loop = self.current_loop;
        self.current_loop = &lctx;
        defer {
            self.current_loop = prev_loop;
            lctx.breaks.deinit(self.allocator);
            lctx.continues.deinit(self.allocator);
        }
        const start = self.ops.items.len;
        try self.emitStatement(item.body);
        const cond_pc = self.ops.items.len;
        for (lctx.continues.items) |cj| try self.patchJump(cj, cond_pc);
        const condition = try self.emitExpression(item.test_expr);
        const back = try self.emitJump(.jump_if_true, condition);
        self.freeRegister(condition);
        try self.patchJump(back, start);
        const after = self.ops.items.len;
        for (lctx.breaks.items) |bj| try self.patchJump(bj, after);
    }

    fn emitFor(self: *BytecodeEmitter, head: zstatements.ForHead, body: *const zstatements.Statement) anyerror!void {
        switch (head) {
            .c_style => |c_style| {
                const has_lex_init = if (c_style.init) |init| (init == .decl and init.decl.kind != .@"var") else false;
                const lex_mark = self.bindings.items.len;
                if (has_lex_init) self.scope_depth += 1;
                defer if (has_lex_init) {
                    self.bindings.items.len = lex_mark;
                    self.scope_depth -= 1;
                };
                if (has_lex_init) {
                    try self.prebindVariableLexical(c_style.init.?.decl);
                }
                if (c_style.init) |init| switch (init) {
                    .decl => |variable| try self.emitVariable(variable),
                    .expr => |expression| {
                        const reg = try self.emitExpression(expression);
                        self.freeRegister(reg);
                    },
                };
                var lctx = LoopCtx{ .try_depth = self.try_depth };
                const prev_loop = self.current_loop;
                self.current_loop = &lctx;
                defer {
                    self.current_loop = prev_loop;
                    lctx.breaks.deinit(self.allocator);
                    lctx.continues.deinit(self.allocator);
                }
                const start = self.ops.items.len;
                var end_jump: ?usize = null;
                if (c_style.test_expr) |test_expr| {
                    const condition = try self.emitExpression(test_expr);
                    end_jump = try self.emitJump(.jump_if_false, condition);
                    self.freeRegister(condition);
                }
                try self.emitStatement(body);
                const update_pc = self.ops.items.len;
                for (lctx.continues.items) |cj| try self.patchJump(cj, update_pc);
                if (c_style.update) |update| {
                    try self.emitEffectExpression(update);
                }
                const back = try self.emitJump(.jump, 0);
                try self.patchJump(back, start);
                const after = self.ops.items.len;
                if (end_jump) |jump| try self.patchJump(jump, after);
                for (lctx.breaks.items) |bj| try self.patchJump(bj, after);
            },
            .for_of => |item| try self.emitForOf(item, body),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitForOf(self: *BytecodeEmitter, item: anytype, body: *const zstatements.Statement) anyerror!void {
        _ = self;
        _ = item;
        _ = body;
        return error.UnsupportedSyntax;
    }

    fn emitFunctionDeclaration(self: *BytecodeEmitter, ptr: anytype) anyerror!void {
        const function = zfunctions.asFunctionNode(ptr);
        if (function.is_generator or function.is_async) return error.UnsupportedSyntax;
        const name = switch (function.kind) {
            .function_decl => |d| d.name,
            else => return error.UnsupportedSyntax,
        };
        const const_idx = try self.addConstant(.{ .function_node = function });
        const fn_reg = try self.allocRegister();
        try self.emitOp(.{ .opcode = .make_closure, .a = fn_reg, .b = const_idx });
        try self.emitStore(name, fn_reg);
        self.freeRegister(fn_reg);
    }

    fn emitFunctionLike(self: *BytecodeEmitter, ptr: anytype) anyerror!u8 {
        const function = zfunctions.asFunctionNode(ptr);
        if (function.is_generator or function.is_async) return error.UnsupportedSyntax;
        const const_idx = try self.addConstant(.{ .function_node = function });
        const fn_reg = try self.allocRegister();
        try self.emitOp(.{ .opcode = .make_closure, .a = fn_reg, .b = const_idx });
        return fn_reg;
    }

    fn emitTry(self: *BytecodeEmitter, item: anytype) anyerror!void {
        if (item.finalizer != null) return error.UnsupportedSyntax;
        const handler = item.handler orelse return error.UnsupportedSyntax;
        const err_reg = try self.allocRegister();
        const setup_jump = try self.emitJump(.setup_catch, err_reg);
        {
            self.try_depth += 1;
            defer self.try_depth -= 1;
            try self.emitStatement(item.block);
        }
        try self.emitOp(.{ .opcode = .end_catch });
        const end_jump = try self.emitJump(.jump, 0);
        try self.patchJump(setup_jump, self.ops.items.len);
        const catch_mark = self.bindings.items.len;
        self.scope_depth += 1;
        defer {
            self.bindings.items.len = catch_mark;
            self.scope_depth -= 1;
        }
        if (handler.param) |param| {
            if (param.* != .identifier) return error.UnsupportedSyntax;
            const p_slot = self.scope.patternSlot(param) orelse return error.UnsupportedSyntax;
            const p_name = param.identifier.name;
            try self.bindings.append(self.allocator, .{
                .name = p_name,
                .slot = p_slot,
                .kind = .catch_binding,
                .depth = self.scope_depth,
                .captured = false,
                .initialized = true,
            });
            try self.emitStore(p_name, err_reg);
        }
        self.freeRegister(err_reg);
        if (handler.body.data == .block) {
            try self.prebindBlockLexicals(handler.body.data.block);
            for (handler.body.data.block) |stmt_item| try self.emitStatement(stmt_item);
        } else {
            try self.emitStatement(handler.body);
        }
        try self.patchJump(end_jump, self.ops.items.len);
    }

    fn emitThrow(self: *BytecodeEmitter, arg: *const zparser.Node) anyerror!void {
        const val = try self.emitExpression(arg);
        try self.emitOp(.{ .opcode = .throw_value, .a = val });
        self.freeRegister(val);
    }

    fn emitExpression(self: *BytecodeEmitter, expression: *const zparser.Node) anyerror!u8 {
        switch (expression.data) {
            .number_literal => |number| return self.emitConstant(.{ .number = number }),
            .string_literal => |string| return self.emitConstant(.{ .string = string }),
            .boolean_literal => |boolean| return self.emitConstant(.{ .boolean = boolean }),
            .null_literal => return self.emitSimple(.load_null),
            .identifier => |name| return self.emitIdentifier(name),
            .paren => |inner| return self.emitExpression(inner),
            .sequence => |items| {
                if (items.len == 0) return self.emitSimple(.load_undefined);
                for (items[0 .. items.len - 1]) |item| {
                    const reg = try self.emitExpression(item);
                    self.freeRegister(reg);
                }
                return self.emitExpression(items[items.len - 1]);
            },
            .unary => |unary| return self.emitUnary(unary),
            .binary => |binary| return self.emitBinary(binary),
            .assignment => |assignment| {
                const target_unwrapped = unwrapParen(assignment.target);
                if (assignment.op == .assign) {
                    if (target_unwrapped.data == .identifier) {
                        const name = target_unwrapped.data.identifier;
                        if (std.mem.eql(u8, name, "arguments") and self.resolveBinding("arguments") == null) {
                            return error.UnsupportedSyntax;
                        }
                        if (self.resolveBinding(name)) |b| {
                            if (!b.initialized) return error.UnsupportedSyntax;
                        } else if (unwrapParen(assignment.value).data == .assignment) {
                            return error.UnsupportedSyntax;
                        }
                        const value = try self.emitExpression(assignment.value);
                        try self.emitStore(name, value);
                        return value;
                    } else if (target_unwrapped.data == .member) {
                        const m = target_unwrapped.data.member;
                        if (m.optional) return error.UnsupportedSyntax;
                        const rhs_mutates = exprMayMutateLocal(assignment.value);
                        if (!m.computed) {
                            if (m.property.data != .identifier) return error.UnsupportedSyntax;
                            if (m.property.data.identifier.len > 0 and m.property.data.identifier[0] == '#') return error.UnsupportedSyntax;
                            var obj_reg = if (!rhs_mutates)
                                try self.emitReadOperand(m.object)
                            else
                                try self.emitExpression(m.object);
                            if (rhs_mutates and obj_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = obj_reg });
                                obj_reg = tmp;
                            }
                            const key_const = try self.addConstant(.{ .property_key = m.property.data.identifier });
                            const val_reg = try self.emitExpression(assignment.value);
                            try self.emitOp(.{ .opcode = .set_prop, .a = obj_reg, .b = key_const, .c = val_reg });
                            self.freeRegister(obj_reg);
                            return val_reg;
                        } else {
                            const prop_mutates = exprMayMutateLocal(m.property);
                            var obj_reg = if (!prop_mutates and !rhs_mutates)
                                try self.emitReadOperand(m.object)
                            else
                                try self.emitExpression(m.object);
                            if ((prop_mutates or rhs_mutates) and obj_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = obj_reg });
                                obj_reg = tmp;
                            }
                            var key_reg = if (!rhs_mutates)
                                try self.emitReadOperand(m.property)
                            else
                                try self.emitExpression(m.property);
                            if (rhs_mutates and key_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = key_reg });
                                key_reg = tmp;
                            }
                            const val_reg = try self.emitExpression(assignment.value);
                            try self.emitOp(.{ .opcode = .set_elem, .a = obj_reg, .b = key_reg, .c = val_reg });
                            self.freeRegister(key_reg);
                            self.freeRegister(obj_reg);
                            return val_reg;
                        }
                    } else {
                        return error.UnsupportedSyntax;
                    }
                } else if (switch (assignment.op) {
                    .add, .sub, .mul, .div, .mod, .pow, .bitand, .bitor, .bitxor, .shl, .shr, .ushr => true,
                    else => false,
                }) {
                    const opcode: codeblock.Opcode = switch (assignment.op) {
                        .add => .add,
                        .sub => .sub_num,
                        .mul => .mul_num,
                        .div => .div_num,
                        .mod => .mod_num,
                        .pow => .pow_num,
                        .bitand => .and_bits,
                        .bitor => .or_bits,
                        .bitxor => .xor_bits,
                        .shl => .shl,
                        .shr => .shr,
                        .ushr => .ushr,
                        else => unreachable,
                    };
                    if (target_unwrapped.data == .identifier) {
                        const name = target_unwrapped.data.identifier;
                        if (self.resolveBinding(name)) |b| {
                            if (!b.initialized) return error.UnsupportedSyntax;
                            if (b.kind == .@"const") {
                                const old_val = try self.emitIdentifier(name);
                                const right_val = try self.emitReadOperand(assignment.value);
                                const res_reg = try self.allocRegister();
                                try self.emitOp(.{ .opcode = opcode, .a = res_reg, .b = old_val, .c = right_val });
                                self.freeRegister(right_val);
                                self.freeRegister(old_val);
                                try self.emitConstAssignTypeError();
                                return res_reg;
                            }
                        }
                        if (self.getLocalSlot(target_unwrapped)) |local_slot| {
                            if (!exprMayMutateLocal(assignment.value)) {
                                const right_val = try self.emitReadOperand(assignment.value);
                                try self.emitOp(.{ .opcode = opcode, .a = local_slot, .b = local_slot, .c = right_val });
                                self.freeRegister(right_val);
                                return local_slot;
                            }
                        }
                        const old_val = try self.emitIdentifier(name);
                        const right_val = try self.emitReadOperand(assignment.value);
                        const res_reg = try self.allocRegister();
                        try self.emitOp(.{ .opcode = opcode, .a = res_reg, .b = old_val, .c = right_val });
                        self.freeRegister(right_val);
                        self.freeRegister(old_val);
                        try self.emitStore(name, res_reg);
                        return res_reg;
                    } else if (target_unwrapped.data == .member) {
                        const m = target_unwrapped.data.member;
                        if (m.optional or m.object.data == .super_expr) return error.UnsupportedSyntax;
                        if (!m.computed) {
                            if (m.property.data != .identifier) return error.UnsupportedSyntax;
                            const prop_name = m.property.data.identifier;
                            if (prop_name.len > 0 and prop_name[0] == '#') return error.UnsupportedSyntax;
                            const res_reg = try self.allocRegister();
                            var obj_reg = try self.emitExpression(m.object);
                            if (obj_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = obj_reg });
                                obj_reg = tmp;
                            }
                            const key_const = try self.addConstant(.{ .property_key = prop_name });
                            const cur_reg = try self.allocRegister();
                            try self.emitOp(.{ .opcode = .get_prop, .a = cur_reg, .b = obj_reg, .c = key_const });
                            const rhs_reg = try self.emitReadOperand(assignment.value);
                            try self.emitOp(.{ .opcode = opcode, .a = res_reg, .b = cur_reg, .c = rhs_reg });
                            self.freeRegister(rhs_reg);
                            self.freeRegister(cur_reg);
                            try self.emitOp(.{ .opcode = .set_prop, .a = obj_reg, .b = key_const, .c = res_reg });
                            self.freeRegister(obj_reg);
                            return res_reg;
                        } else {
                            const res_reg = try self.allocRegister();
                            var obj_reg = try self.emitExpression(m.object);
                            if (obj_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = obj_reg });
                                obj_reg = tmp;
                            }
                            var key_reg = try self.emitExpression(m.property);
                            if (key_reg < self.scope.local_count) {
                                const tmp = try self.allocRegister();
                                try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = key_reg });
                                key_reg = tmp;
                            }
                            try self.emitOp(.{ .opcode = .to_prop_key, .a = key_reg, .b = obj_reg });
                            const cur_reg = try self.allocRegister();
                            try self.emitOp(.{ .opcode = .get_elem, .a = cur_reg, .b = obj_reg, .c = key_reg });
                            const rhs_reg = try self.emitReadOperand(assignment.value);
                            try self.emitOp(.{ .opcode = opcode, .a = res_reg, .b = cur_reg, .c = rhs_reg });
                            self.freeRegister(rhs_reg);
                            self.freeRegister(cur_reg);
                            try self.emitOp(.{ .opcode = .set_elem, .a = obj_reg, .b = key_reg, .c = res_reg });
                            self.freeRegister(key_reg);
                            self.freeRegister(obj_reg);
                            return res_reg;
                        }
                    } else return error.UnsupportedSyntax;
                } else return error.UnsupportedSyntax;
            },
            .conditional => |conditional| return self.emitConditional(conditional),
            .logical => |logical| return self.emitLogical(logical),
            .call => |call| return self.emitCall(call),
            .new_expr => |ne| return self.emitNewExpr(ne),
            .object_literal => |items| return self.emitObjectLiteral(items),
            .array_literal => |items| return self.emitArrayLiteral(items),
            .member => |member| return self.emitMember(member),
            .this_expr => return self.emitSimple(.load_this),
            .function_like => |ptr| return self.emitFunctionLike(ptr),
            .yield_expr, .await_expr => return error.UnsupportedSyntax,
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitIdentifier(self: *BytecodeEmitter, name: []const u8) !u8 {
        if (std.mem.eql(u8, name, "arguments") and self.resolveBinding("arguments") == null) {
            return error.UnsupportedSyntax;
        }
        if (self.resolveBinding(name)) |b| {
            if (!b.initialized) return error.UnsupportedSyntax;
            const destination = try self.allocRegister();
            if (b.captured) {
                const constant = try self.addConstant(.{ .property_key = name });
                try self.emitOp(.{ .opcode = .load_global, .a = destination, .b = constant });
            } else {
                try self.emitOp(.{ .opcode = .load_local, .a = destination, .b = try small(b.slot) });
            }
            return destination;
        }
        const destination = try self.allocRegister();
        const constant = try self.addConstant(.{ .property_key = name });
        try self.emitOp(.{ .opcode = .load_global, .a = destination, .b = constant });
        return destination;
    }

    fn emitEffectExpression(self: *BytecodeEmitter, expression: *const zparser.Node) anyerror!void {
        const cur = unwrapParen(expression);
        if (cur.data == .unary) {
            const unary = cur.data.unary;
            if (unary.op == .post_inc or unary.op == .post_dec or unary.op == .pre_inc or unary.op == .pre_dec) {
                if (self.getLocalSlot(unary.operand)) |local_slot| {
                    const unwrap = unwrapParen(unary.operand);
                    const is_const = if (unwrap.data == .identifier)
                        (if (self.resolveBinding(unwrap.data.identifier)) |b| b.kind == .@"const" else false)
                    else
                        false;
                    if (!is_const) {
                        const one_idx = try self.addConstant(.{ .number = 1.0 });
                        const is_inc = (unary.op == .post_inc or unary.op == .pre_inc);
                        const super_op: codeblock.Opcode = if (is_inc) .add_local_const else .sub_local_const;
                        try self.emitOp(.{ .opcode = super_op, .a = local_slot, .b = local_slot, .c = one_idx });
                        return;
                    }
                }
            }
        }
        const reg = try self.emitExpression(expression);
        self.freeRegister(reg);
    }

    fn emitReadOperand(self: *BytecodeEmitter, node: *const zparser.Node) anyerror!u8 {
        if (self.getLocalSlot(node)) |slot| return slot;
        return self.emitExpression(node);
    }

    fn emitUnary(self: *BytecodeEmitter, unary: anytype) anyerror!u8 {
        switch (unary.op) {
            .minus => {
                const operand = try self.emitReadOperand(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .neg, .a = destination, .b = operand });
                self.freeRegister(operand);
                return destination;
            },
            .not => {
                const operand = try self.emitReadOperand(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .not, .a = destination, .b = operand });
                self.freeRegister(operand);
                return destination;
            },
            .bitnot => {
                const operand = try self.emitReadOperand(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .not_bits, .a = destination, .b = operand });
                self.freeRegister(operand);
                return destination;
            },
            .void_op => {
                const operand = try self.emitExpression(unary.operand);
                try self.emitOp(.{ .opcode = .load_undefined, .a = operand });
                return operand;
            },
            .typeof => {
                const unwrap = unwrapParen(unary.operand);
                if (unwrap.data == .identifier) {
                    const name = unwrap.data.identifier;
                    if (self.resolveBinding(name)) |b| {
                        if (!b.initialized) return error.UnsupportedSyntax;
                    } else {
                        if (std.mem.eql(u8, name, "arguments")) return error.UnsupportedSyntax;
                        const name_const = try self.addConstant(.{ .property_key = name });
                        const destination = try self.allocRegister();
                        try self.emitOp(.{ .opcode = .typeof_global, .a = destination, .b = name_const });
                        return destination;
                    }
                }
                const operand = try self.emitReadOperand(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .typeof, .a = destination, .b = operand });
                self.freeRegister(operand);
                return destination;
            },
            .post_inc, .post_dec, .pre_inc, .pre_dec => {
                const op_unwrap = unwrapParen(unary.operand);
                if (op_unwrap.data != .identifier) return error.UnsupportedSyntax;
                const name = op_unwrap.data.identifier;
                const is_inc = (unary.op == .post_inc or unary.op == .pre_inc);
                const is_post = (unary.op == .post_inc or unary.op == .post_dec);
                if (self.resolveBinding(name)) |b| {
                    if (!b.initialized) return error.UnsupportedSyntax;
                    if (b.kind == .@"const") {
                        const old_reg = try self.emitIdentifier(name);
                        const one_reg = try self.emitConstant(.{ .number = 1.0 });
                        const new_reg = try self.allocRegister();
                        const opcode: codeblock.Opcode = if (is_inc) .add_num else .sub_num;
                        try self.emitOp(.{ .opcode = opcode, .a = new_reg, .b = old_reg, .c = one_reg });
                        self.freeRegister(one_reg);
                        self.freeRegister(old_reg);
                        try self.emitConstAssignTypeError();
                        return new_reg;
                    }
                }
                if (self.getLocalSlot(op_unwrap)) |local_slot| {
                    const one_idx = try self.addConstant(.{ .number = 1.0 });
                    const super_op: codeblock.Opcode = if (is_inc) .add_local_const else .sub_local_const;
                    const dst = try self.allocRegister();
                    if (is_post) {
                        try self.emitOp(.{ .opcode = .load_local, .a = dst, .b = local_slot });
                        try self.emitOp(.{ .opcode = super_op, .a = local_slot, .b = local_slot, .c = one_idx });
                    } else {
                        try self.emitOp(.{ .opcode = super_op, .a = local_slot, .b = local_slot, .c = one_idx });
                        try self.emitOp(.{ .opcode = .load_local, .a = dst, .b = local_slot });
                    }
                    return dst;
                }
                const old_reg = try self.emitIdentifier(name);
                const one_reg = try self.emitConstant(.{ .number = 1.0 });
                const new_reg = try self.allocRegister();
                const opcode: codeblock.Opcode = if (is_inc) .add_num else .sub_num;
                try self.emitOp(.{ .opcode = opcode, .a = new_reg, .b = old_reg, .c = one_reg });
                try self.emitStore(name, new_reg);
                self.freeRegister(one_reg);
                const ret = if (is_post) old_reg else new_reg;
                self.freeRegister(if (ret == old_reg) new_reg else old_reg);
                return ret;
            },
            else => return error.UnsupportedSyntax,
        }
    }

    fn getLocalSlot(self: *BytecodeEmitter, node: *const zparser.Node) ?u8 {
        const unwrap = unwrapParen(node);
        if (unwrap.data == .identifier) {
            const name = unwrap.data.identifier;
            if (self.resolveBinding(name)) |b| {
                if (!b.initialized or b.captured) return null;
                return small(b.slot) catch null;
            }
        }
        return null;
    }

    fn emitBinary(self: *BytecodeEmitter, binary: anytype) anyerror!u8 {
        if (self.getLocalSlot(binary.left)) |local_slot| {
            if (asConstant(binary.right)) |const_val| {
                const super_opcode: ?codeblock.Opcode = switch (binary.op) {
                    .add => .add_local_const,
                    .sub => .sub_local_const,
                    .lt => .lt_local_const,
                    .gt => .gt_local_const,
                    .le => .le_local_const,
                    .ge => .ge_local_const,
                    .eqeqeq => .eq_local_const,
                    else => null,
                };
                if (super_opcode) |opc| {
                    const const_idx = try self.addConstant(const_val);
                    const destination = try self.allocRegister();
                    try self.emitOp(.{ .opcode = opc, .a = destination, .b = local_slot, .c = const_idx });
                    return destination;
                }
            }
        } else if (self.getLocalSlot(binary.right)) |local_slot| {
            if (binary.op == .eqeqeq) {
                if (asConstant(binary.left)) |const_val| {
                    const const_idx = try self.addConstant(const_val);
                    const destination = try self.allocRegister();
                    try self.emitOp(.{ .opcode = .eq_local_const, .a = destination, .b = local_slot, .c = const_idx });
                    return destination;
                }
            }
        } else if (binary.op == .add or binary.op == .sub) {
            if (asConstant(binary.right)) |const_val| {
                if (const_val == .number) {
                    const left = try self.emitReadOperand(binary.left);
                    const const_idx = try self.addConstant(const_val);
                    const destination = try self.allocRegister();
                    const opc: codeblock.Opcode = if (binary.op == .add) .add_local_const else .sub_local_const;
                    try self.emitOp(.{ .opcode = opc, .a = destination, .b = left, .c = const_idx });
                    self.freeRegister(left);
                    return destination;
                }
            }
        }

        const opcode: codeblock.Opcode = switch (binary.op) {
            .add => .add,
            .sub => .sub_num,
            .mul => .mul_num,
            .div => .div_num,
            .mod => .mod_num,
            .pow => .pow_num,
            .lt => .lt_num,
            .gt => .gt_num,
            .le => .le_num,
            .ge => .ge_num,
            .eq => .loose_eq,
            .ne => .loose_ne,
            .eqeqeq => .eq,
            .noteqeq => .ne,
            .bitand => .and_bits,
            .bitor => .or_bits,
            .bitxor => .xor_bits,
            .shl => .shl,
            .shr => .shr,
            .ushr => .ushr,
            else => return error.UnsupportedSyntax,
        };
        const rhs_mutates = exprMayMutateLocal(binary.right);
        var left = if (!rhs_mutates)
            try self.emitReadOperand(binary.left)
        else
            try self.emitExpression(binary.left);
        if (rhs_mutates and left < self.scope.local_count) {
            const tmp = try self.allocRegister();
            try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = left });
            left = tmp;
        }
        const right = try self.emitReadOperand(binary.right);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = opcode, .a = destination, .b = left, .c = right });
        self.freeRegister(right);
        self.freeRegister(left);
        return destination;
    }

    fn emitConditional(self: *BytecodeEmitter, conditional: anytype) anyerror!u8 {
        const destination = try self.allocRegister();
        const condition = try self.emitExpression(conditional.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        self.freeRegister(condition);
        const consequent = try self.emitExpression(conditional.consequent);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = consequent });
        self.freeRegister(consequent);
        const end_jump = try self.emitJump(.jump, 0);
        try self.patchJump(false_jump, self.ops.items.len);
        const alternate = try self.emitExpression(conditional.alternate);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = alternate });
        self.freeRegister(alternate);
        try self.patchJump(end_jump, self.ops.items.len);
        return destination;
    }

    fn emitLogical(self: *BytecodeEmitter, logical: anytype) anyerror!u8 {
        const destination = try self.allocRegister();
        const left = try self.emitExpression(logical.left);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = left });
        self.freeRegister(left);

        const jump_opcode: codeblock.Opcode = switch (logical.op) {
            .and_op => .jump_if_false,
            .or_op => .jump_if_true,
            .nullish => .jump_if_not_nullish,
        };
        const jump = try self.emitJump(jump_opcode, destination);

        const right = try self.emitExpression(logical.right);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = right });
        self.freeRegister(right);

        try self.patchJump(jump, self.ops.items.len);
        return destination;
    }

    fn isRegisterDefOpcode(opcode: codeblock.Opcode) bool {
        return switch (opcode) {
            .load_const,
            .load_local,
            .load_global,
            .load_undefined,
            .load_null,
            .load_true,
            .load_false,
            .load_this,
            .move,
            .neg,
            .not,
            .not_bits,
            .typeof,
            .add,
            .sub_num,
            .mul_num,
            .div_num,
            .mod_num,
            .pow_num,
            .lt_num,
            .gt_num,
            .le_num,
            .ge_num,
            .eq,
            .ne,
            .loose_eq,
            .loose_ne,
            .typeof_global,
            .and_bits,
            .or_bits,
            .xor_bits,
            .shl,
            .shr,
            .ushr,
            .call,
            .call_global,
            .new_value,
            .new_object,
            .new_array,
            .get_prop,
            .get_elem,
            .make_closure,
            .iter_init,
            .iter_next,
            .add_local_const,
            .sub_local_const,
            .lt_local_const,
            .gt_local_const,
            .le_local_const,
            .ge_local_const,
            .eq_local_const,
            .get_elem_const,
            => true,
            else => false,
        };
    }

    fn emitCall(self: *BytecodeEmitter, call: anytype) anyerror!u8 {
        if (call.optional) return error.UnsupportedSyntax;
        var this_reg: ?u8 = null;
        const unwrapped = unwrapParen(call.callee);
        if (unwrapped.data == .identifier and std.mem.eql(u8, unwrapped.data.identifier, "eval")) {
            return error.UnsupportedSyntax;
        }
        var global_call_name: ?[]const u8 = null;
        const callee = if (unwrapped.data == .member) blk: {
            const m = unwrapped.data.member;
            if (m.optional) return error.UnsupportedSyntax;
            const obj_reg = try self.emitExpression(m.object);
            this_reg = obj_reg;
            const dst = try self.allocRegister();
            if (!m.computed) {
                if (m.property.data != .identifier) return error.UnsupportedSyntax;
                const key_const = try self.addConstant(.{ .property_key = m.property.data.identifier });
                try self.emitOp(.{ .opcode = .get_prop, .a = dst, .b = obj_reg, .c = key_const });
            } else if (asIntegerIndex(m.property)) |num| {
                if (self.constants.items.len < std.math.maxInt(u8)) {
                    const const_idx = try self.addConstant(.{ .number = num });
                    try self.emitOp(.{ .opcode = .get_elem_const, .a = dst, .b = obj_reg, .c = const_idx });
                } else {
                    const key_reg = try self.emitExpression(m.property);
                    try self.emitOp(.{ .opcode = .get_elem, .a = dst, .b = obj_reg, .c = key_reg });
                    self.freeRegister(key_reg);
                }
            } else {
                const key_reg = try self.emitExpression(m.property);
                try self.emitOp(.{ .opcode = .get_elem, .a = dst, .b = obj_reg, .c = key_reg });
                self.freeRegister(key_reg);
            }
            break :blk dst;
        } else if (unwrapped.data == .identifier) blk: {
            const name = unwrapped.data.identifier;
            if (self.resolveBinding(name)) |b| {
                if (!b.initialized) return error.UnsupportedSyntax;
                if (b.captured) {
                    global_call_name = name;
                    break :blk try self.allocRegister();
                }
                break :blk try self.emitExpression(call.callee);
            }
            if (std.mem.eql(u8, name, "arguments")) return error.UnsupportedSyntax;
            global_call_name = name;
            break :blk try self.allocRegister();
        } else try self.emitExpression(call.callee);
        if (self.next_register != @as(u16, callee) + 1) return error.UnsupportedSyntax;
        const argument_slots: u16 = std.math.cast(u16, call.args.len) orelse return error.TooManyRegisters;
        const arg_count = try small(argument_slots);
        const arg_base = self.next_register;
        self.next_register += argument_slots;
        self.max_register = @max(self.max_register, self.next_register);
        for (call.args, 0..) |argument, index| {
            if (argument.data == .spread) return error.UnsupportedSyntax;
            const target_slot = try small(arg_base + @as(u16, @intCast(index)));
            const value = try self.emitExpression(argument);
            if (value == target_slot) {
                // Already in target slot
            } else if (isSingleDefExpr(argument) and value >= self.scope.local_count and self.ops.items.len > 0 and self.ops.items[self.ops.items.len - 1].a == value and isRegisterDefOpcode(self.ops.items[self.ops.items.len - 1].opcode)) {
                self.ops.items[self.ops.items.len - 1].a = target_slot;
                self.freeRegister(value);
            } else {
                try self.emitOp(.{ .opcode = .move, .a = target_slot, .b = value });
                self.freeRegister(value);
            }
        }
        for (0..argument_slots) |i| self.freeRegister(@intCast(arg_base + argument_slots - 1 - i));
        const destination = callee;
        const slot = std.math.cast(u8, self.call_sites.items.len) orelse return error.UnsupportedSyntax;
        try self.call_sites.append(self.allocator, .{ .arg_count = arg_count, .this_reg = this_reg, .global_name = global_call_name });
        const call_op: codeblock.Opcode = if (global_call_name != null) .call_global else .call;
        try self.emitOp(.{ .opcode = call_op, .a = destination, .b = callee, .c = slot });
        if (this_reg) |r| self.freeRegister(r);
        return destination;
    }

    fn emitNewExpr(self: *BytecodeEmitter, ne: anytype) anyerror!u8 {
        const args_slice = ne.args orelse &.{};
        const argument_slots: u16 = std.math.cast(u16, args_slice.len) orelse return error.TooManyRegisters;
        const arg_count = try small(argument_slots);
        const callee_val = try self.emitReadOperand(ne.callee);
        const base_slot = self.next_register;
        const callee_slot = try small(base_slot);
        self.next_register = base_slot + 1 + argument_slots;
        self.max_register = @max(self.max_register, self.next_register);
        if (callee_val != callee_slot) {
            try self.emitOp(.{ .opcode = .move, .a = callee_slot, .b = callee_val });
        }
        for (args_slice, 0..) |argument, index| {
            if (argument.data == .spread) return error.UnsupportedSyntax;
            const target_slot = try small(base_slot + 1 + @as(u16, @intCast(index)));
            const value = try self.emitExpression(argument);
            if (value == target_slot) {
                // Already in target slot
            } else if (isSingleDefExpr(argument) and value >= self.scope.local_count and self.ops.items.len > 0 and self.ops.items[self.ops.items.len - 1].a == value and isRegisterDefOpcode(self.ops.items[self.ops.items.len - 1].opcode)) {
                self.ops.items[self.ops.items.len - 1].a = target_slot;
                self.freeRegister(value);
            } else {
                try self.emitOp(.{ .opcode = .move, .a = target_slot, .b = value });
                self.freeRegister(value);
            }
        }
        for (0..argument_slots) |i| self.freeRegister(@intCast(base_slot + 1 + argument_slots - 1 - i));
        self.freeRegister(callee_val);
        try self.emitOp(.{ .opcode = .new_value, .a = callee_slot, .b = callee_slot, .c = arg_count });
        return callee_slot;
    }

    fn emitObjectLiteral(self: *BytecodeEmitter, items: anytype) anyerror!u8 {
        const dst = try self.allocRegister();
        try self.emitObjectLiteralInto(items, dst);
        return dst;
    }

    fn emitObjectLiteralInto(self: *BytecodeEmitter, items: anytype, dst: u8) anyerror!void {
        try self.emitOp(.{ .opcode = .new_object, .a = dst });
        for (items) |item| {
            switch (item) {
                .spread => return error.UnsupportedSyntax,
                .property => |prop| {
                    if (prop.computed or prop.kind != .init) return error.UnsupportedSyntax;
                    const key_name = switch (prop.key.data) {
                        .identifier => |name| name,
                        .string_literal => |s| s,
                        else => return error.UnsupportedSyntax,
                    };
                    if (std.mem.eql(u8, key_name, "__proto__")) return error.UnsupportedSyntax;
                    const val_reg = try self.emitReadOperand(prop.value);
                    const key_const = try self.addConstant(.{ .property_key = key_name });
                    try self.emitOp(.{ .opcode = .set_prop, .a = dst, .b = key_const, .c = val_reg });
                    self.freeRegister(val_reg);
                },
            }
        }
    }

    fn emitArrayLiteral(self: *BytecodeEmitter, items: anytype) anyerror!u8 {
        if (items.len > std.math.maxInt(u8)) return error.UnsupportedSyntax;
        const dst = try self.allocRegister();
        try self.emitArrayLiteralInto(items, dst);
        return dst;
    }

    fn emitArrayLiteralInto(self: *BytecodeEmitter, items: anytype, dst: u8) anyerror!void {
        if (items.len > std.math.maxInt(u8)) return error.UnsupportedSyntax;
        const len: u8 = @intCast(items.len);
        try self.emitOp(.{ .opcode = .new_array, .a = dst, .b = len });
        for (items, 0..) |maybe_item, index| {
            const item = maybe_item orelse return error.UnsupportedSyntax;
            if (item.data == .spread) return error.UnsupportedSyntax;
            const val_reg = try self.emitReadOperand(item);
            if (index <= std.math.maxInt(u8)) {
                try self.emitOp(.{ .opcode = .set_elem_const, .a = dst, .b = @intCast(index), .c = val_reg });
            } else {
                const idx_reg = try self.emitConstant(.{ .number = @floatFromInt(index) });
                try self.emitOp(.{ .opcode = .set_elem, .a = dst, .b = idx_reg, .c = val_reg });
                self.freeRegister(idx_reg);
            }
            self.freeRegister(val_reg);
        }
    }

    fn emitMember(self: *BytecodeEmitter, member: anytype) anyerror!u8 {
        if (member.optional) return error.UnsupportedSyntax;
        const prop_safe = !member.computed or asIntegerIndex(member.property) != null or !exprMayMutateLocal(member.property);
        var obj_reg = if (prop_safe)
            try self.emitReadOperand(member.object)
        else
            try self.emitExpression(member.object);
        if (!prop_safe and obj_reg < self.scope.local_count) {
            const tmp = try self.allocRegister();
            try self.emitOp(.{ .opcode = .load_local, .a = tmp, .b = obj_reg });
            obj_reg = tmp;
        }
        const dst = try self.allocRegister();
        if (!member.computed) {
            if (member.property.data != .identifier) return error.UnsupportedSyntax;
            const prop_name = member.property.data.identifier;
            if (prop_name.len > 0 and prop_name[0] == '#') return error.UnsupportedSyntax;
            const key_const = try self.addConstant(.{ .property_key = prop_name });
            try self.emitOp(.{ .opcode = .get_prop, .a = dst, .b = obj_reg, .c = key_const });
        } else if (asIntegerIndex(member.property)) |num| {
            if (self.constants.items.len < std.math.maxInt(u8)) {
                const const_idx = try self.addConstant(.{ .number = num });
                try self.emitOp(.{ .opcode = .get_elem_const, .a = dst, .b = obj_reg, .c = const_idx });
            } else {
                const key_reg = try self.emitReadOperand(member.property);
                try self.emitOp(.{ .opcode = .get_elem, .a = dst, .b = obj_reg, .c = key_reg });
                self.freeRegister(key_reg);
            }
        } else {
            const key_reg = try self.emitReadOperand(member.property);
            try self.emitOp(.{ .opcode = .get_elem, .a = dst, .b = obj_reg, .c = key_reg });
            self.freeRegister(key_reg);
        }
        self.freeRegister(obj_reg);
        return dst;
    }

    fn emitSimple(self: *BytecodeEmitter, opcode: codeblock.Opcode) !u8 {
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = opcode, .a = destination });
        return destination;
    }

    fn emitConstant(self: *BytecodeEmitter, constant: codeblock.Constant) !u8 {
        const index = try self.addConstant(constant);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = .load_const, .a = destination, .b = index });
        return destination;
    }

    fn addConstant(self: *BytecodeEmitter, constant: codeblock.Constant) !u8 {
        if (self.constants.items.len > std.math.maxInt(u8)) return error.TooManyConstants;
        const index: u8 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, constant);
        return index;
    }

    fn emitJump(self: *BytecodeEmitter, opcode: codeblock.Opcode, condition: u8) !usize {
        try self.emitOp(.{ .opcode = opcode, .a = condition });
        return self.ops.items.len - 1;
    }

    fn patchJump(self: *BytecodeEmitter, instruction: usize, target: usize) !void {
        if (target > std.math.maxInt(u16)) return error.TooManyInstructions;
        self.ops.items[instruction].b = @intCast(target >> 8);
        self.ops.items[instruction].c = @intCast(target);
    }

    fn fusedCmpOpcode(op: codeblock.Opcode) ?codeblock.Opcode {
        return switch (op) {
            .eq_local_const => .jeq_local_const_false,
            .lt_local_const => .jlt_local_const_false,
            .le_local_const => .jle_local_const_false,
            .gt_local_const => .jgt_local_const_false,
            .ge_local_const => .jge_local_const_false,
            else => null,
        };
    }

    fn isJumpWithTarget(op: codeblock.Opcode) bool {
        return switch (op) {
            .jump, .jump_if_true, .jump_if_false, .jump_if_not_nullish, .setup_catch => true,
            else => false,
        };
    }

    fn fuseCmpJumps(self: *BytecodeEmitter) !void {
        const len = self.ops.items.len;
        if (len < 2) return;

        const is_target = try self.allocator.alloc(bool, len + 1);
        defer self.allocator.free(is_target);
        @memset(is_target, false);
        for (self.ops.items) |op| {
            if (isJumpWithTarget(op.opcode)) {
                const t = jumpTarget(op);
                if (t <= len) is_target[t] = true;
            }
        }

        const pc_map = try self.allocator.alloc(u16, len + 1);
        defer self.allocator.free(pc_map);

        var new_len: u16 = 0;
        var i: usize = 0;
        while (i < len) {
            pc_map[i] = new_len;
            if (i + 1 < len and !is_target[i + 1] and self.ops.items[i + 1].opcode == .jump_if_false and self.ops.items[i + 1].a == self.ops.items[i].a and fusedCmpOpcode(self.ops.items[i].opcode) != null) {
                const target = jumpTarget(self.ops.items[i + 1]);
                if (target > i + 1 and target - i <= 255) {
                    pc_map[i + 1] = new_len + 1;
                    new_len += 1;
                    i += 2;
                    continue;
                }
            }
            new_len += 1;
            i += 1;
        }
        pc_map[len] = new_len;
        if (new_len == len) return;

        var r: usize = 0;
        var w: usize = 0;
        while (r < len) {
            if (r + 1 < len and !is_target[r + 1] and self.ops.items[r + 1].opcode == .jump_if_false and self.ops.items[r + 1].a == self.ops.items[r].a) {
                if (fusedCmpOpcode(self.ops.items[r].opcode)) |fused_op| {
                    const target = jumpTarget(self.ops.items[r + 1]);
                    if (target > r + 1 and target - r <= 255) {
                        const new_target = pc_map[target];
                        const old_op = self.ops.items[r];
                        self.ops.items[w] = .{
                            .opcode = fused_op,
                            .a = old_op.b,
                            .b = old_op.c,
                            .c = @intCast(new_target - w),
                        };
                        w += 1;
                        r += 2;
                        continue;
                    }
                }
            }
            var op = self.ops.items[r];
            if (isJumpWithTarget(op.opcode)) {
                const new_target = pc_map[jumpTarget(op)];
                op.b = @intCast(new_target >> 8);
                op.c = @intCast(new_target & 0xFF);
            }
            self.ops.items[w] = op;
            w += 1;
            r += 1;
        }
        self.ops.items.len = w;
    }

    fn allocRegister(self: *BytecodeEmitter) !u8 {
        if (self.free_registers.items.len > 0) {
            var min_idx: usize = 0;
            for (self.free_registers.items[1..], 1..) |reg, i| {
                if (reg < self.free_registers.items[min_idx]) min_idx = i;
            }
            return self.free_registers.swapRemove(min_idx);
        }
        const register = try small(self.next_register);
        self.next_register += 1;
        self.max_register = @max(self.max_register, self.next_register);
        return register;
    }

    fn freeRegister(self: *BytecodeEmitter, reg: u8) void {
        if (reg < self.scope.local_count) return;
        for (self.free_registers.items) |r| {
            if (r == reg) return;
        }
        self.free_registers.append(self.allocator, reg) catch return;
        while (self.next_register > self.scope.local_count) {
            const top: u8 = @intCast(self.next_register - 1);
            const idx = for (self.free_registers.items, 0..) |r, i| {
                if (r == top) break i;
            } else break;
            _ = self.free_registers.swapRemove(idx);
            self.next_register -= 1;
        }
    }

    fn emitOp(self: *BytecodeEmitter, op: codeblock.Op) !void {
        try self.ops.append(self.allocator, op);
    }
};

fn exprMayMutateLocal(node: *const zparser.Node) bool {
    const cur = unwrapParen(node);
    return switch (cur.data) {
        .number_literal, .string_literal, .boolean_literal, .null_literal, .identifier, .this_expr, .function_like => false,
        .assignment, .yield_expr, .await_expr => true,
        .unary => |u| switch (u.op) {
            .post_inc, .post_dec, .pre_inc, .pre_dec => true,
            else => exprMayMutateLocal(u.operand),
        },
        .binary => |b| exprMayMutateLocal(b.left) or exprMayMutateLocal(b.right),
        .logical => |l| exprMayMutateLocal(l.left) or exprMayMutateLocal(l.right),
        .conditional => |c| exprMayMutateLocal(c.test_expr) or exprMayMutateLocal(c.consequent) or exprMayMutateLocal(c.alternate),
        .member => |m| exprMayMutateLocal(m.object) or (m.computed and exprMayMutateLocal(m.property)),
        .sequence => |items| blk: {
            for (items) |it| if (exprMayMutateLocal(it)) break :blk true;
            break :blk false;
        },
        .array_literal => |items| blk: {
            for (items) |maybe_it| if (maybe_it) |it| if (exprMayMutateLocal(it)) break :blk true;
            break :blk false;
        },
        .object_literal => |items| blk: {
            for (items) |it| switch (it) {
                .spread => |s| if (exprMayMutateLocal(s)) break :blk true,
                .property => |p| if ((p.computed and exprMayMutateLocal(p.key)) or exprMayMutateLocal(p.value)) break :blk true,
            };
            break :blk false;
        },
        .call => |c| blk: {
            if (exprMayMutateLocal(c.callee)) break :blk true;
            for (c.args) |arg| if (exprMayMutateLocal(arg)) break :blk true;
            break :blk false;
        },
        else => true,
    };
}

fn isSingleDefExpr(node: *const zparser.Node) bool {
    const cur = unwrapParen(node);
    return switch (cur.data) {
        .number_literal,
        .string_literal,
        .boolean_literal,
        .null_literal,
        .this_expr,
        .function_like,
        .identifier,
        .binary,
        .member,
        .call,
        => true,
        .unary => |u| switch (u.op) {
            .minus, .not, .bitnot, .typeof => true,
            else => false,
        },
        else => false,
    };
}

fn exprReferencesIdent(node: *const zparser.Node, target_name: []const u8) bool {
    const cur = unwrapParen(node);
    return switch (cur.data) {
        .number_literal, .string_literal, .boolean_literal, .null_literal, .this_expr, .function_like => false,
        .identifier => |name| std.mem.eql(u8, name, target_name),
        .unary => |u| exprReferencesIdent(u.operand, target_name),
        .binary => |b| exprReferencesIdent(b.left, target_name) or exprReferencesIdent(b.right, target_name),
        .logical => |l| exprReferencesIdent(l.left, target_name) or exprReferencesIdent(l.right, target_name),
        .conditional => |c| exprReferencesIdent(c.test_expr, target_name) or exprReferencesIdent(c.consequent, target_name) or exprReferencesIdent(c.alternate, target_name),
        .member => |m| exprReferencesIdent(m.object, target_name) or (m.computed and exprReferencesIdent(m.property, target_name)),
        .assignment => |a| exprReferencesIdent(a.target, target_name) or exprReferencesIdent(a.value, target_name),
        .sequence => |items| blk: {
            for (items) |it| if (exprReferencesIdent(it, target_name)) break :blk true;
            break :blk false;
        },
        .array_literal => |items| blk: {
            for (items) |maybe_it| if (maybe_it) |it| if (exprReferencesIdent(it, target_name)) break :blk true;
            break :blk false;
        },
        .object_literal => |items| blk: {
            for (items) |it| switch (it) {
                .spread => |s| if (exprReferencesIdent(s, target_name)) break :blk true,
                .property => |p| if ((p.computed and exprReferencesIdent(p.key, target_name)) or exprReferencesIdent(p.value, target_name)) break :blk true,
            };
            break :blk false;
        },
        .call => |c| blk: {
            if (exprReferencesIdent(c.callee, target_name)) break :blk true;
            for (c.args) |arg| if (exprReferencesIdent(arg, target_name)) break :blk true;
            break :blk false;
        },
        else => true,
    };
}

fn unwrapParen(node: *const zparser.Node) *const zparser.Node {
    var cur = node;
    while (cur.data == .paren) {
        cur = cur.data.paren;
    }
    return cur;
}

fn asConstant(node: *const zparser.Node) ?codeblock.Constant {
    const unwrap = unwrapParen(node);
    return switch (unwrap.data) {
        .number_literal => |num| .{ .number = num },
        .string_literal => |str| .{ .string = str },
        .boolean_literal => |b| .{ .boolean = b },
        else => null,
    };
}

fn asIntegerIndex(node: *const zparser.Node) ?f64 {
    const unwrap = unwrapParen(node);
    if (unwrap.data == .number_literal) {
        const n = unwrap.data.number_literal;
        if (n >= 0 and n <= 255 and @as(f64, @floatFromInt(@as(usize, @intFromFloat(n)))) == n) {
            return n;
        }
    }
    return null;
}

fn small(value: u16) !u8 {
    if (value > std.math.maxInt(u8)) return error.TooManyRegisters;
    return @intCast(value);
}

pub fn disassemble(allocator: Allocator, block: *const codeblock.CodeBlock) ![]u8 {
    var output: std.ArrayListUnmanaged(u8) = .empty;
    errdefer output.deinit(allocator);
    for (block.ops, 0..) |op, index| {
        try output.print(allocator, "{d:0>4} {s}", .{ index, @tagName(op.opcode) });
        switch (op.opcode) {
            .load_const => try output.print(allocator, " r{d}, #{d}", .{ op.a, op.b }),
            .load_local, .load_global, .load_capture => try output.print(allocator, " r{d}, @{d}", .{ op.a, op.b }),
            .store_local, .store_global, .store_capture => try output.print(allocator, " @{d}, r{d}", .{ op.a, op.b }),
            .neg, .not, .not_bits, .typeof => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .typeof_global => try output.print(allocator, " r{d}, #{d}", .{ op.a, op.b }),
            .add, .sub_num, .mul_num, .div_num, .mod_num, .pow_num, .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne, .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .add_local_const, .sub_local_const, .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => try output.print(allocator, " r{d}, @{d}, #{d}", .{ op.a, op.b, op.c }),
            .jeq_local_const_false, .jlt_local_const_false, .jle_local_const_false, .jgt_local_const_false, .jge_local_const_false => try output.print(allocator, " @{d}, #{d}, +{d}", .{ op.a, op.b, op.c }),
            .jump => try output.print(allocator, " {d}", .{jumpTarget(op)}),
            .jump_if_true, .jump_if_false, .jump_if_not_nullish => try output.print(allocator, " r{d}, {d}", .{ op.a, jumpTarget(op) }),
            .call, .call_global => try output.print(allocator, " r{d}, r{d}, [cache:{d}]", .{ op.a, op.b, op.c }),
            .move => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .new_object => try output.print(allocator, " r{d}", .{op.a}),
            .new_array => try output.print(allocator, " r{d}, {d}", .{ op.a, op.b }),
            .get_prop => try output.print(allocator, " r{d}, r{d}, #{d}", .{ op.a, op.b, op.c }),
            .set_prop, .set_prop_transition => try output.print(allocator, " r{d}, #{d}, r{d}", .{ op.a, op.b, op.c }),
            .get_elem => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .get_elem_const => try output.print(allocator, " r{d}, r{d}, #{d}", .{ op.a, op.b, op.c }),
            .set_elem => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .set_elem_const => try output.print(allocator, " r{d}, #{d}, r{d}", .{ op.a, op.b, op.c }),
            .make_closure => try output.print(allocator, " r{d}, #{d}", .{ op.a, op.b }),
            .iter_init => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .iter_next => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .iter_end => try output.print(allocator, " r{d}", .{op.a}),
            .setup_catch => try output.print(allocator, " r{d}, {d}", .{ op.a, jumpTarget(op) }),
            .end_catch => {},
            .load_this => try output.print(allocator, " r{d}", .{op.a}),
            .throw_value => try output.print(allocator, " r{d}", .{op.a}),
            .return_value => try output.print(allocator, " r{d}", .{op.a}),
            else => {},
        }
        try output.append(allocator, '\n');
    }
    return output.toOwnedSlice(allocator);
}

pub fn jumpTarget(op: codeblock.Op) usize {
    return (@as(usize, op.b) << 8) | op.c;
}

test "emitter disassembles an add function" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function add(a, b) { return a + b; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var compiled = try BytecodeEmitter.emit(std.testing.allocator, function);
    defer compiled.deinit(std.testing.allocator);
    const text = try disassemble(std.testing.allocator, &compiled.block);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings(
        "0000 add r2, r0, r1\n" ++
            "0001 return_value r2\n" ++
            "0002 return_undefined\n",
        text,
    );
}
