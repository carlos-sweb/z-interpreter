//! Phase 2 foundations. This module has no execution path yet.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zfunctions = @import("zfunctions");
const zparser = @import("zparser");
const zstatements = @import("zstatements");

pub const Opcode = enum(u8) {
    nop,
    load_const,
    move,
    load_local,
    store_local,
    load_capture,
    store_capture,
    load_global,
    store_global,
    load_this,
    load_undefined,
    load_null,
    load_true,
    load_false,
    add_num,
    sub_num,
    mul_num,
    div_num,
    mod_num,
    lt_num,
    gt_num,
    le_num,
    ge_num,
    add,
    jump,
    jump_if_true,
    jump_if_false,
    call,
    call_method,
    new_value,
    get_prop,
    set_prop,
    make_closure,
    return_value,
    return_undefined,
    throw_value,
};

pub const Op = packed struct(u32) {
    opcode: Opcode,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
};

pub const Constant = union(enum) {
    number: f64,
    string: []const u8,
    boolean: bool,
    bigint: []const u8,
    property_key: []const u8,
};

pub const Flags = packed struct(u8) {
    is_arrow: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    needs_arguments: bool = false,
    lexical_this: bool = false,
    has_try: bool = false,
    _reserved: u2 = 0,
};

pub const ExceptionHandler = struct {
    start_pc: u32,
    end_pc: u32,
    target_pc: u32,
    kind: enum { @"catch", finally, catch_finally },
    catch_local: ?u16 = null,
};

/// Immutable representation emitted by a later compiler pass.
pub const CodeBlock = struct {
    ops: []const Op = &.{},
    constants: []const Constant = &.{},
    exception_table: []const ExceptionHandler = &.{},
    local_count: u16 = 0,
    register_count: u16 = 0,
    param_count: u16 = 0,
    capture_count: u16 = 0,
    flags: Flags = .{},
    name: ?[]const u8 = null,
};

pub const LocalKind = enum { parameter, @"var", let, @"const", function, class, catch_binding };

pub const Local = struct {
    name: []const u8,
    slot: u16,
    kind: LocalKind,
};

/// Metadata required by the future emitter. Captured locals are slots used by
/// nested closures; free names must be provided by an enclosing scope.
pub const ScopeAnalysis = struct {
    locals: []Local,
    captured_locals: []const []const u8,
    free_names: []const []const u8,
    local_count: u16,
    register_count: u16,
    param_count: u16,
    flags: Flags,

    pub fn deinit(self: *ScopeAnalysis, allocator: Allocator) void {
        allocator.free(self.locals);
        allocator.free(self.captured_locals);
        allocator.free(self.free_names);
        self.* = undefined;
    }

    pub fn localSlot(self: *const ScopeAnalysis, name: []const u8) ?u16 {
        for (self.locals) |local| if (std.mem.eql(u8, local.name, name)) return local.slot;
        return null;
    }

    pub fn capturesLocal(self: *const ScopeAnalysis, name: []const u8) bool {
        for (self.captured_locals) |captured| if (std.mem.eql(u8, captured, name)) return true;
        return false;
    }
};

/// Conservative function-scope analysis. It allocates unique slots for every
/// parameter and declaration. Precise block-scope TDZ placement is deferred
/// to bytecode emission, while nested-function free names already identify
/// closure captures.
pub const ScopeAnalyzer = struct {
    allocator: Allocator,
    locals: std.ArrayListUnmanaged(Local) = .empty,
    local_names: std.StringHashMapUnmanaged(void) = .empty,
    captured: std.ArrayListUnmanaged([]const u8) = .empty,
    captured_names: std.StringHashMapUnmanaged(void) = .empty,
    free: std.ArrayListUnmanaged([]const u8) = .empty,
    free_names: std.StringHashMapUnmanaged(void) = .empty,
    param_count: u16 = 0,

    pub fn analyze(allocator: Allocator, function: *const zfunctions.FunctionNode) !ScopeAnalysis {
        var self = ScopeAnalyzer{ .allocator = allocator };
        defer self.local_names.deinit(allocator);
        defer self.captured_names.deinit(allocator);
        defer self.free_names.deinit(allocator);
        errdefer self.locals.deinit(allocator);
        errdefer self.captured.deinit(allocator);
        errdefer self.free.deinit(allocator);

        for (function.params.items) |param| try self.addPattern(param.pattern, .parameter);
        self.param_count = @intCast(self.locals.items.len);
        if (function.params.rest) |rest| {
            try self.addPattern(rest, .parameter);
            self.param_count += 1;
        }
        try self.collectLocals(function.body);
        try self.scanBody(function.body);

        const locals = try self.locals.toOwnedSlice(allocator);
        errdefer allocator.free(locals);
        const captured = try self.captured.toOwnedSlice(allocator);
        errdefer allocator.free(captured);
        const free = try self.free.toOwnedSlice(allocator);
        errdefer allocator.free(free);
        const count: u16 = @intCast(locals.len);
        return .{
            .locals = locals,
            .captured_locals = captured,
            .free_names = free,
            .local_count = count,
            .register_count = count,
            .param_count = self.param_count,
            .flags = .{
                .is_arrow = function.kind == .arrow,
                .is_generator = function.is_generator,
                .is_async = function.is_async,
                .lexical_this = function.kind == .arrow,
            },
        };
    }

    fn addLocal(self: *ScopeAnalyzer, name: []const u8, kind: LocalKind) !void {
        if (self.local_names.contains(name)) return;
        const slot: u16 = @intCast(self.locals.items.len);
        try self.local_names.put(self.allocator, name, {});
        try self.locals.append(self.allocator, .{ .name = name, .slot = slot, .kind = kind });
    }

    fn addPattern(self: *ScopeAnalyzer, pattern: *const zstatements.BindingPattern, kind: LocalKind) !void {
        switch (pattern.*) {
            .identifier => |identifier| try self.addLocal(identifier.name, kind),
            .array => |array| {
                for (array.elements) |maybe_element| if (maybe_element) |element| try self.addPattern(element.pattern, kind);
                if (array.rest) |rest| try self.addPattern(rest, kind);
            },
            .object => |object| {
                for (object.properties) |property| try self.addPattern(property.value, kind);
                if (object.rest) |rest| try self.addLocal(rest.name, kind);
            },
        }
    }

    fn collectLocals(self: *ScopeAnalyzer, body: zfunctions.FunctionBody) !void {
        if (body == .block) try self.collectStatement(body.block);
    }

    fn kindFor(variable_kind: zstatements.VariableKind) LocalKind {
        return switch (variable_kind) {
            .@"var" => .@"var",
            .let => .let,
            .@"const" => .@"const",
        };
    }

    fn collectStatement(self: *ScopeAnalyzer, statement: *const zstatements.Statement) !void {
        switch (statement.data) {
            .block => |items| for (items) |item| try self.collectStatement(item),
            .variable => |variable| for (variable.declarators) |declarator| try self.addPattern(declarator.pattern, kindFor(variable.kind)),
            .function_declaration => |ptr| try self.addLocal(zfunctions.asFunctionNode(ptr).kind.function_decl.name, .function),
            .class_declaration => |ptr| if (zfunctions.asClassNode(ptr).name) |name| try self.addLocal(name, .class),
            .if_stmt => |item| {
                try self.collectStatement(item.consequent);
                if (item.alternate) |alternate| try self.collectStatement(alternate);
            },
            .while_stmt => |item| try self.collectStatement(item.body),
            .do_while => |item| try self.collectStatement(item.body),
            .for_stmt => |item| {
                switch (item.head) {
                    .c_style => |head| if (head.init) |init| if (init == .decl) for (init.decl.declarators) |declarator| try self.addPattern(declarator.pattern, kindFor(init.decl.kind)),
                    .for_in => |head| if (head.binding == .declared) try self.addPattern(head.binding.declared.pattern, kindFor(head.binding.declared.kind)),
                    .for_of => |head| if (head.binding == .declared) try self.addPattern(head.binding.declared.pattern, kindFor(head.binding.declared.kind)),
                }
                try self.collectStatement(item.body);
            },
            .labelled => |item| try self.collectStatement(item.body),
            .try_stmt => |item| {
                try self.collectStatement(item.block);
                if (item.handler) |handler| {
                    if (handler.param) |param| try self.addPattern(param, .catch_binding);
                    try self.collectStatement(handler.body);
                }
                if (item.finalizer) |finalizer| try self.collectStatement(finalizer);
            },
            .switch_stmt => |item| for (item.cases) |case| for (case.consequent) |child| try self.collectStatement(child),
            .export_decl => |item| if (item == .declaration) try self.collectStatement(item.declaration),
            else => {},
        }
    }

    fn addFree(self: *ScopeAnalyzer, name: []const u8) !void {
        if (self.local_names.contains(name) or self.free_names.contains(name)) return;
        try self.free_names.put(self.allocator, name, {});
        try self.free.append(self.allocator, name);
    }

    fn markCaptured(self: *ScopeAnalyzer, name: []const u8) !void {
        if (!self.local_names.contains(name) or self.captured_names.contains(name)) return;
        try self.captured_names.put(self.allocator, name, {});
        try self.captured.append(self.allocator, name);
    }

    fn scanBody(self: *ScopeAnalyzer, body: zfunctions.FunctionBody) !void {
        switch (body) {
            .block => |block| try self.scanStatement(block),
            .expression => |expression| try self.scanNode(expression),
        }
    }

    fn scanStatement(self: *ScopeAnalyzer, statement: *const zstatements.Statement) !void {
        switch (statement.data) {
            .expr_stmt, .throw_stmt => |expression| try self.scanNode(expression),
            .block => |items| for (items) |item| try self.scanStatement(item),
            .variable => |variable| for (variable.declarators) |declarator| if (declarator.init) |init| try self.scanNode(init),
            .if_stmt => |item| {
                try self.scanNode(item.test_expr);
                try self.scanStatement(item.consequent);
                if (item.alternate) |alternate| try self.scanStatement(alternate);
            },
            .while_stmt => |item| {
                try self.scanNode(item.test_expr);
                try self.scanStatement(item.body);
            },
            .do_while => |item| {
                try self.scanStatement(item.body);
                try self.scanNode(item.test_expr);
            },
            .for_stmt => |item| {
                try self.scanForHead(item.head);
                try self.scanStatement(item.body);
            },
            .return_stmt => |value| if (value) |expression| try self.scanNode(expression),
            .labelled => |item| try self.scanStatement(item.body),
            .try_stmt => |item| {
                try self.scanStatement(item.block);
                if (item.handler) |handler| try self.scanStatement(handler.body);
                if (item.finalizer) |finalizer| try self.scanStatement(finalizer);
            },
            .switch_stmt => |item| {
                try self.scanNode(item.discriminant);
                for (item.cases) |case| {
                    if (case.test_expr) |test_expr| try self.scanNode(test_expr);
                    for (case.consequent) |child| try self.scanStatement(child);
                }
            },
            .with_stmt => |item| {
                try self.scanNode(item.object);
                try self.scanStatement(item.body);
            },
            .function_declaration => |ptr| try self.scanNested(zfunctions.asFunctionNode(ptr)),
            .class_declaration => |ptr| try self.scanClass(zfunctions.asClassNode(ptr)),
            .export_decl => |item| switch (item) {
                .declaration => |decl| try self.scanStatement(decl),
                .default => |expression| try self.scanNode(expression),
                else => {},
            },
            else => {},
        }
    }

    fn scanForHead(self: *ScopeAnalyzer, head: zstatements.ForHead) !void {
        switch (head) {
            .c_style => |item| {
                if (item.init) |init| if (init == .expr) try self.scanNode(init.expr);
                if (item.test_expr) |test_expr| try self.scanNode(test_expr);
                if (item.update) |update| try self.scanNode(update);
            },
            .for_in => |item| try self.scanNode(item.object),
            .for_of => |item| try self.scanNode(item.iterable),
        }
    }

    fn scanNested(self: *ScopeAnalyzer, nested: *const zfunctions.FunctionNode) !void {
        var analysis = try ScopeAnalyzer.analyze(self.allocator, nested);
        defer analysis.deinit(self.allocator);
        for (analysis.free_names) |name| {
            if (self.local_names.contains(name)) try self.markCaptured(name) else try self.addFree(name);
        }
    }

    fn scanClass(self: *ScopeAnalyzer, class: *const zfunctions.ClassNode) !void {
        if (class.superclass) |superclass| try self.scanNode(superclass);
        for (class.elements) |element| {
            switch (element.key) {
                .computed => |key| try self.scanNode(key),
                else => {},
            }
            if (element.value) |value| try self.scanNode(value);
            if (element.function) |function| try self.scanNested(function);
        }
    }

    fn scanNode(self: *ScopeAnalyzer, node: *const zparser.Node) !void {
        switch (node.data) {
            .identifier => |name| try self.addFree(name),
            .template_literal => |template| for (template.expressions) |expression| try self.scanNode(expression),
            .array_literal => |items| for (items) |item| if (item) |expression| try self.scanNode(expression),
            .object_literal => |items| for (items) |item| switch (item) {
                .spread => |expression| try self.scanNode(expression),
                .property => |property| {
                    if (property.computed) try self.scanNode(property.key);
                    try self.scanNode(property.value);
                },
            },
            .spread, .paren, .await_expr => |operand| try self.scanNode(operand),
            .unary => |unary| try self.scanNode(unary.operand),
            .binary => |binary| {
                try self.scanNode(binary.left);
                try self.scanNode(binary.right);
            },
            .logical => |logical| {
                try self.scanNode(logical.left);
                try self.scanNode(logical.right);
            },
            .assignment => |assignment| {
                try self.scanNode(assignment.target);
                try self.scanNode(assignment.value);
            },
            .conditional => |conditional| {
                try self.scanNode(conditional.test_expr);
                try self.scanNode(conditional.consequent);
                try self.scanNode(conditional.alternate);
            },
            .sequence => |items| for (items) |item| try self.scanNode(item),
            .call => |call| {
                try self.scanNode(call.callee);
                for (call.args) |argument| try self.scanNode(argument);
            },
            .new_expr => |new_expr| {
                try self.scanNode(new_expr.callee);
                if (new_expr.args) |args| for (args) |argument| try self.scanNode(argument);
            },
            .member => |member| {
                try self.scanNode(member.object);
                if (member.computed) try self.scanNode(member.property);
            },
            .function_like => |ptr| try self.scanNested(zfunctions.asFunctionNode(ptr)),
            .class_like => |ptr| try self.scanClass(zfunctions.asClassNode(ptr)),
            .yield_expr => |yield_expr| if (yield_expr.argument) |argument| try self.scanNode(argument),
            else => {},
        }
    }
};

test "scope analyzer assigns parameter and local slots" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function f(a, b) { var c = a; let d = b; const e = c; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var analysis = try ScopeAnalyzer.analyze(std.testing.allocator, function);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(?u16, 0), analysis.localSlot("a"));
    try std.testing.expectEqual(@as(?u16, 1), analysis.localSlot("b"));
    try std.testing.expectEqual(@as(?u16, 2), analysis.localSlot("c"));
    try std.testing.expectEqual(@as(?u16, 3), analysis.localSlot("d"));
    try std.testing.expectEqual(@as(?u16, 4), analysis.localSlot("e"));
    try std.testing.expectEqual(@as(u16, 5), analysis.register_count);
}

test "scope analyzer marks locals captured by a nested closure" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const parser = try zfunctions.Parser.init(arena_state.allocator(), "function outer(x) { let y = 1; return function inner() { return x + y + global; }; }");
    const statement = try parser.parseStatement();
    const function = zfunctions.asFunctionNode(statement.data.function_declaration);
    var analysis = try ScopeAnalyzer.analyze(std.testing.allocator, function);
    defer analysis.deinit(std.testing.allocator);
    try std.testing.expect(analysis.capturesLocal("x"));
    try std.testing.expect(analysis.capturesLocal("y"));
    try std.testing.expectEqual(@as(usize, 1), analysis.free_names.len);
    try std.testing.expectEqualStrings("global", analysis.free_names[0]);
}
