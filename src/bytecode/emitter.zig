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
        allocator.free(self.block.ops);
        allocator.free(self.block.constants);
        allocator.free(self.block.exception_table);
        self.* = undefined;
    }
};

/// Lowers the arithmetic, branch, and bare-call subset. Unsupported syntax is
/// reported during compilation; it still executes through the AST walker.
pub const BytecodeEmitter = struct {
    allocator: Allocator,
    scope: codeblock.ScopeAnalysis,
    ops: std.ArrayListUnmanaged(codeblock.Op) = .empty,
    constants: std.ArrayListUnmanaged(codeblock.Constant) = .empty,
    next_register: u16,
    max_register: u16,

    pub fn emit(allocator: Allocator, function: *const zfunctions.FunctionNode) !CompiledCodeBlock {
        const scope = try codeblock.ScopeAnalyzer.analyze(allocator, function);
        var self = BytecodeEmitter{
            .allocator = allocator,
            .scope = scope,
            .next_register = scope.local_count,
            .max_register = scope.local_count,
        };
        defer self.scope.deinit(allocator);
        errdefer self.ops.deinit(allocator);
        errdefer self.constants.deinit(allocator);

        try self.emitBody(function.body);
        const ops = try self.ops.toOwnedSlice(allocator);
        errdefer allocator.free(ops);
        const constants = try self.constants.toOwnedSlice(allocator);
        errdefer allocator.free(constants);
        return .{ .block = .{
            .ops = ops,
            .constants = constants,
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
        var self = BytecodeEmitter{
            .allocator = allocator,
            .scope = scope,
            .next_register = scope.local_count,
            .max_register = scope.local_count,
        };
        defer self.scope.deinit(allocator);
        errdefer self.ops.deinit(allocator);
        errdefer self.constants.deinit(allocator);

        var last_register: ?u8 = null;
        for (statements) |statement| {
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
        } else {
            try self.emitOp(.{ .opcode = .return_undefined });
        }

        const ops = try self.ops.toOwnedSlice(allocator);
        errdefer allocator.free(ops);
        const constants = try self.constants.toOwnedSlice(allocator);
        errdefer allocator.free(constants);
        return .{ .block = .{
            .ops = ops,
            .constants = constants,
            .local_count = scope.local_count,
            .register_count = self.max_register,
            .param_count = 0,
            .capture_count = @intCast(scope.captured_locals.len),
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
            },
            .block => |block| {
                for (block.data.block) |statement| try self.emitStatement(statement);
                if (self.ops.items.len == 0 or self.ops.items[self.ops.items.len - 1].opcode != .return_value)
                    try self.emitOp(.{ .opcode = .return_undefined });
            },
        }
    }

    fn emitStatement(self: *BytecodeEmitter, statement: *const zstatements.Statement) anyerror!void {
        switch (statement.data) {
            .block => |items| for (items) |item| try self.emitStatement(item),
            .return_stmt => |value| {
                if (value) |expression| {
                    const register = try self.emitExpression(expression);
                    try self.emitOp(.{ .opcode = .return_value, .a = register });
                } else try self.emitOp(.{ .opcode = .return_undefined });
            },
            .expr_stmt => |expression| _ = try self.emitExpression(expression),
            .variable => |variable| try self.emitVariable(variable),
            .if_stmt => |item| try self.emitIf(item),
            .while_stmt => |item| try self.emitWhile(item),
            .for_stmt => |item| try self.emitFor(item.head, item.body),
            .function_declaration => |ptr| try self.emitFunctionDeclaration(ptr),
            .try_stmt => |item| try self.emitTry(item),
            .throw_stmt => |arg| try self.emitThrow(arg),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitStore(self: *BytecodeEmitter, name: []const u8, reg: u8) !void {
        if (self.scope.localSlot(name)) |slot| {
            if (!self.scope.capturesLocal(name)) {
                return self.emitOp(.{ .opcode = .store_local, .a = try small(slot), .b = reg });
            }
        }
        const constant = try self.addConstant(.{ .property_key = name });
        return self.emitOp(.{ .opcode = .store_global, .a = constant, .b = reg });
    }

    fn emitVariable(self: *BytecodeEmitter, variable: anytype) !void {
        for (variable.declarators) |declarator| {
            if (declarator.pattern.* != .identifier) return error.UnsupportedSyntax;
            const name = declarator.pattern.identifier.name;
            const val_reg = if (declarator.init) |init|
                try self.emitExpression(init)
            else
                try self.emitSimple(.load_undefined);
            try self.emitStore(name, val_reg);
        }
    }

    fn emitIf(self: *BytecodeEmitter, item: anytype) anyerror!void {
        const condition = try self.emitExpression(item.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        try self.emitStatement(item.consequent);
        if (item.alternate) |alternate| {
            const end_jump = try self.emitJump(.jump, 0);
            try self.patchJump(false_jump, self.ops.items.len);
            try self.emitStatement(alternate);
            try self.patchJump(end_jump, self.ops.items.len);
        } else try self.patchJump(false_jump, self.ops.items.len);
    }

    fn emitWhile(self: *BytecodeEmitter, item: anytype) anyerror!void {
        const start = self.ops.items.len;
        const condition = try self.emitExpression(item.test_expr);
        const end_jump = try self.emitJump(.jump_if_false, condition);
        try self.emitStatement(item.body);
        const back = try self.emitJump(.jump, 0);
        try self.patchJump(back, start);
        try self.patchJump(end_jump, self.ops.items.len);
    }

    fn emitFor(self: *BytecodeEmitter, head: zstatements.ForHead, body: *const zstatements.Statement) anyerror!void {
        switch (head) {
            .c_style => |c_style| {
                if (c_style.init) |init| switch (init) {
                    .decl => |variable| try self.emitVariable(variable),
                    .expr => |expression| _ = try self.emitExpression(expression),
                };
                const start = self.ops.items.len;
                var end_jump: ?usize = null;
                if (c_style.test_expr) |test_expr| {
                    const condition = try self.emitExpression(test_expr);
                    end_jump = try self.emitJump(.jump_if_false, condition);
                }
                try self.emitStatement(body);
                if (c_style.update) |update| _ = try self.emitExpression(update);
                const back = try self.emitJump(.jump, 0);
                try self.patchJump(back, start);
                if (end_jump) |jump| try self.patchJump(jump, self.ops.items.len);
            },
            .for_of => |item| try self.emitForOf(item, body),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitForOf(self: *BytecodeEmitter, item: anytype, body: *const zstatements.Statement) anyerror!void {
        if (item.is_await) return error.UnsupportedSyntax;
        const name: []const u8 = switch (item.binding) {
            .declared => |d| if (d.pattern.* == .identifier) d.pattern.identifier.name else return error.UnsupportedSyntax,
            .existing => |n| n.name,
            else => return error.UnsupportedSyntax,
        };
        const iter_obj_reg = try self.emitExpression(item.iterable);
        const iter_reg = try self.allocRegister();
        try self.emitOp(.{ .opcode = .iter_init, .a = iter_reg, .b = iter_obj_reg });
        const loop_start = self.ops.items.len;
        const val_reg = try self.allocRegister();
        const done_reg = try self.allocRegister();
        try self.emitOp(.{ .opcode = .iter_next, .a = val_reg, .b = done_reg, .c = iter_reg });
        const exit_jump = try self.emitJump(.jump_if_true, done_reg);
        try self.emitStore(name, val_reg);
        try self.emitStatement(body);
        const back_jump = try self.emitJump(.jump, 0);
        try self.patchJump(back_jump, loop_start);
        try self.patchJump(exit_jump, self.ops.items.len);
        try self.emitOp(.{ .opcode = .iter_end, .a = iter_reg });
    }

    fn emitFunctionDeclaration(self: *BytecodeEmitter, ptr: anytype) anyerror!void {
        const function = zfunctions.asFunctionNode(ptr);
        const name = switch (function.kind) {
            .function_decl => |d| d.name,
            else => return error.UnsupportedSyntax,
        };
        const const_idx = try self.addConstant(.{ .function_node = function });
        const fn_reg = try self.allocRegister();
        try self.emitOp(.{ .opcode = .make_closure, .a = fn_reg, .b = const_idx });
        try self.emitStore(name, fn_reg);
    }

    fn emitFunctionLike(self: *BytecodeEmitter, ptr: anytype) anyerror!u8 {
        const function = zfunctions.asFunctionNode(ptr);
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
        try self.emitStatement(item.block);
        try self.emitOp(.{ .opcode = .end_catch });
        const end_jump = try self.emitJump(.jump, 0);
        try self.patchJump(setup_jump, self.ops.items.len);
        if (handler.param) |param| {
            if (param.* != .identifier) return error.UnsupportedSyntax;
            try self.emitStore(param.identifier.name, err_reg);
        }
        try self.emitStatement(handler.body);
        try self.patchJump(end_jump, self.ops.items.len);
    }

    fn emitThrow(self: *BytecodeEmitter, arg: *const zparser.Node) anyerror!void {
        const val = try self.emitExpression(arg);
        try self.emitOp(.{ .opcode = .throw_value, .a = val });
    }

    fn emitExpression(self: *BytecodeEmitter, expression: *const zparser.Node) anyerror!u8 {
        switch (expression.data) {
            .number_literal => |number| return self.emitConstant(.{ .number = number }),
            .string_literal => |string| return self.emitConstant(.{ .string = string }),
            .boolean_literal => |boolean| return self.emitConstant(.{ .boolean = boolean }),
            .null_literal => return self.emitSimple(.load_null),
            .identifier => |name| return self.emitIdentifier(name),
            .paren => |inner| return self.emitExpression(inner),
            .unary => |unary| return self.emitUnary(unary),
            .binary => |binary| return self.emitBinary(binary),
            .assignment => |assignment| {
                if (assignment.op == .assign) {
                    if (assignment.target.data == .identifier) {
                        const name = assignment.target.data.identifier;
                        const value = try self.emitExpression(assignment.value);
                        try self.emitStore(name, value);
                        return value;
                    } else if (assignment.target.data == .member) {
                        const m = assignment.target.data.member;
                        if (m.optional) return error.UnsupportedSyntax;
                        const obj_reg = try self.emitExpression(m.object);
                        if (!m.computed) {
                            if (m.property.data != .identifier) return error.UnsupportedSyntax;
                            const key_const = try self.addConstant(.{ .property_key = m.property.data.identifier });
                            const val_reg = try self.emitExpression(assignment.value);
                            try self.emitOp(.{ .opcode = .set_prop, .a = obj_reg, .b = key_const, .c = val_reg });
                            return val_reg;
                        } else {
                            const key_reg = try self.emitExpression(m.property);
                            const val_reg = try self.emitExpression(assignment.value);
                            try self.emitOp(.{ .opcode = .set_elem, .a = obj_reg, .b = key_reg, .c = val_reg });
                            return val_reg;
                        }
                    } else {
                        return error.UnsupportedSyntax;
                    }
                } else if (assignment.op == .add or assignment.op == .sub or assignment.op == .mul or assignment.op == .div or assignment.op == .mod) {
                    if (assignment.target.data == .identifier) {
                        const name = assignment.target.data.identifier;
                        const old_val = try self.emitIdentifier(name);
                        const right_val = try self.emitExpression(assignment.value);
                        const res_reg = try self.allocRegister();
                        const opcode: codeblock.Opcode = switch (assignment.op) {
                            .add => .add,
                            .sub => .sub_num,
                            .mul => .mul_num,
                            .div => .div_num,
                            .mod => .mod_num,
                            else => unreachable,
                        };
                        try self.emitOp(.{ .opcode = opcode, .a = res_reg, .b = old_val, .c = right_val });
                        try self.emitStore(name, res_reg);
                        return res_reg;
                    } else return error.UnsupportedSyntax;
                } else return error.UnsupportedSyntax;
            },
            .conditional => |conditional| return self.emitConditional(conditional),
            .call => |call| return self.emitCall(call),
            .object_literal => |items| return self.emitObjectLiteral(items),
            .array_literal => |items| return self.emitArrayLiteral(items),
            .member => |member| return self.emitMember(member),
            .function_like => |ptr| return self.emitFunctionLike(ptr),
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitIdentifier(self: *BytecodeEmitter, name: []const u8) !u8 {
        const destination = try self.allocRegister();
        if (self.scope.localSlot(name)) |slot| {
            if (self.scope.capturesLocal(name)) {
                const constant = try self.addConstant(.{ .property_key = name });
                try self.emitOp(.{ .opcode = .load_global, .a = destination, .b = constant });
            } else {
                try self.emitOp(.{ .opcode = .load_local, .a = destination, .b = try small(slot) });
            }
        } else {
            const constant = try self.addConstant(.{ .property_key = name });
            try self.emitOp(.{ .opcode = .load_global, .a = destination, .b = constant });
        }
        return destination;
    }

    fn emitUnary(self: *BytecodeEmitter, unary: anytype) anyerror!u8 {
        switch (unary.op) {
            .minus => {
                const operand = try self.emitExpression(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .neg, .a = destination, .b = operand });
                return destination;
            },
            .not => {
                const operand = try self.emitExpression(unary.operand);
                const destination = try self.allocRegister();
                try self.emitOp(.{ .opcode = .not, .a = destination, .b = operand });
                return destination;
            },
            .post_inc, .post_dec, .pre_inc, .pre_dec => {
                if (unary.operand.data != .identifier) return error.UnsupportedSyntax;
                const name = unary.operand.data.identifier;
                const old_reg = try self.emitIdentifier(name);
                const one_reg = try self.emitConstant(.{ .number = 1.0 });
                const new_reg = try self.allocRegister();
                const opcode: codeblock.Opcode = if (unary.op == .post_inc or unary.op == .pre_inc) .add_num else .sub_num;
                try self.emitOp(.{ .opcode = opcode, .a = new_reg, .b = old_reg, .c = one_reg });
                try self.emitStore(name, new_reg);
                return if (unary.op == .post_inc or unary.op == .post_dec) old_reg else new_reg;
            },
            else => return error.UnsupportedSyntax,
        }
    }

    fn emitBinary(self: *BytecodeEmitter, binary: anytype) anyerror!u8 {
        const opcode: codeblock.Opcode = switch (binary.op) {
            .add => .add,
            .sub => .sub_num,
            .mul => .mul_num,
            .div => .div_num,
            .mod => .mod_num,
            .lt => .lt_num,
            .gt => .gt_num,
            .le => .le_num,
            .ge => .ge_num,
            .eq, .eqeqeq => .eq,
            .ne, .noteqeq => .ne,
            else => return error.UnsupportedSyntax,
        };
        const left = try self.emitExpression(binary.left);
        const right = try self.emitExpression(binary.right);
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = opcode, .a = destination, .b = left, .c = right });
        return destination;
    }

    fn emitConditional(self: *BytecodeEmitter, conditional: anytype) anyerror!u8 {
        const destination = try self.allocRegister();
        const condition = try self.emitExpression(conditional.test_expr);
        const false_jump = try self.emitJump(.jump_if_false, condition);
        const consequent = try self.emitExpression(conditional.consequent);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = consequent });
        const end_jump = try self.emitJump(.jump, 0);
        try self.patchJump(false_jump, self.ops.items.len);
        const alternate = try self.emitExpression(conditional.alternate);
        try self.emitOp(.{ .opcode = .move, .a = destination, .b = alternate });
        try self.patchJump(end_jump, self.ops.items.len);
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
            .move,
            .neg,
            .not,
            .add,
            .sub_num,
            .mul_num,
            .div_num,
            .mod_num,
            .lt_num,
            .gt_num,
            .le_num,
            .ge_num,
            .eq,
            .ne,
            .call,
            .new_object,
            .new_array,
            .get_prop,
            .get_elem,
            .make_closure,
            .iter_init,
            .iter_next,
            => true,
            else => false,
        };
    }

    fn emitCall(self: *BytecodeEmitter, call: anytype) anyerror!u8 {
        if (call.optional) return error.UnsupportedSyntax;
        const callee = try self.emitExpression(call.callee);
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
            } else if (self.ops.items.len > 0 and self.ops.items[self.ops.items.len - 1].a == value and isRegisterDefOpcode(self.ops.items[self.ops.items.len - 1].opcode)) {
                self.ops.items[self.ops.items.len - 1].a = target_slot;
            } else {
                try self.emitOp(.{ .opcode = .move, .a = target_slot, .b = value });
            }
        }
        const destination = try self.allocRegister();
        try self.emitOp(.{ .opcode = .call, .a = destination, .b = callee, .c = arg_count });
        return destination;
    }

    fn emitObjectLiteral(self: *BytecodeEmitter, items: anytype) anyerror!u8 {
        const dst = try self.allocRegister();
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
                    const val_reg = try self.emitExpression(prop.value);
                    const key_const = try self.addConstant(.{ .property_key = key_name });
                    try self.emitOp(.{ .opcode = .set_prop, .a = dst, .b = key_const, .c = val_reg });
                },
            }
        }
        return dst;
    }

    fn emitArrayLiteral(self: *BytecodeEmitter, items: anytype) anyerror!u8 {
        if (items.len > std.math.maxInt(u8)) return error.UnsupportedSyntax;
        const dst = try self.allocRegister();
        const len: u8 = @intCast(items.len);
        try self.emitOp(.{ .opcode = .new_array, .a = dst, .b = len });
        for (items, 0..) |maybe_item, index| {
            const item = maybe_item orelse return error.UnsupportedSyntax;
            if (item.data == .spread) return error.UnsupportedSyntax;
            const val_reg = try self.emitExpression(item);
            const idx_reg = try self.emitConstant(.{ .number = @floatFromInt(index) });
            try self.emitOp(.{ .opcode = .set_elem, .a = dst, .b = idx_reg, .c = val_reg });
        }
        return dst;
    }

    fn emitMember(self: *BytecodeEmitter, member: anytype) anyerror!u8 {
        if (member.optional) return error.UnsupportedSyntax;
        const obj_reg = try self.emitExpression(member.object);
        const dst = try self.allocRegister();
        if (!member.computed) {
            if (member.property.data != .identifier) return error.UnsupportedSyntax;
            const key_const = try self.addConstant(.{ .property_key = member.property.data.identifier });
            try self.emitOp(.{ .opcode = .get_prop, .a = dst, .b = obj_reg, .c = key_const });
        } else {
            const key_reg = try self.emitExpression(member.property);
            try self.emitOp(.{ .opcode = .get_elem, .a = dst, .b = obj_reg, .c = key_reg });
        }
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

    fn allocRegister(self: *BytecodeEmitter) !u8 {
        const register = try small(self.next_register);
        self.next_register += 1;
        self.max_register = @max(self.max_register, self.next_register);
        return register;
    }

    fn emitOp(self: *BytecodeEmitter, op: codeblock.Op) !void {
        try self.ops.append(self.allocator, op);
    }
};

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
            .neg, .not => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .add, .sub_num, .mul_num, .div_num, .mod_num, .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .jump => try output.print(allocator, " {d}", .{jumpTarget(op)}),
            .jump_if_true, .jump_if_false => try output.print(allocator, " r{d}, {d}", .{ op.a, jumpTarget(op) }),
            .call => try output.print(allocator, " r{d}, r{d}, {d}", .{ op.a, op.b, op.c }),
            .move => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .new_object => try output.print(allocator, " r{d}", .{op.a}),
            .new_array => try output.print(allocator, " r{d}, {d}", .{ op.a, op.b }),
            .get_prop => try output.print(allocator, " r{d}, r{d}, #{d}", .{ op.a, op.b, op.c }),
            .set_prop => try output.print(allocator, " r{d}, #{d}, r{d}", .{ op.a, op.b, op.c }),
            .get_elem => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .set_elem => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .make_closure => try output.print(allocator, " r{d}, #{d}", .{ op.a, op.b }),
            .iter_init => try output.print(allocator, " r{d}, r{d}", .{ op.a, op.b }),
            .iter_next => try output.print(allocator, " r{d}, r{d}, r{d}", .{ op.a, op.b, op.c }),
            .iter_end => try output.print(allocator, " r{d}", .{op.a}),
            .setup_catch => try output.print(allocator, " r{d}, {d}", .{ op.a, jumpTarget(op) }),
            .end_catch => {},
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
        "0000 load_local r2, @0\n" ++
            "0001 load_local r3, @1\n" ++
            "0002 add r4, r2, r3\n" ++
            "0003 return_value r4\n",
        text,
    );
}
