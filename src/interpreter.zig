const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const znumber = @import("znumber");
const JSValue = zvalue.JSValue;

const environment = @import("environment.zig");
pub const Environment = environment.Environment;
const completion_mod = @import("completion.zig");
pub const Completion = completion_mod.Completion;
const coercion = @import("coercion.zig");
const inspect = @import("inspect.zig");

/// A user-defined closure's opaque Callable context: the parsed function's
/// AST node, the environment it closed over at definition time, and a back
/// pointer to the Interpreter so `closureCall` can recurse into
/// `evalProgram`/`evalExpression`. Safe to store `*Interpreter` here
/// because closures are only ever created from inside `evalExpression`
/// (which already takes `self: *Interpreter`, i.e. the caller's own stable
/// address) -- never during `Interpreter.init`.
const ClosureCtx = struct {
    interp: *Interpreter,
    function_node: *zfunctions.FunctionNode,
    closure_env: *Environment,
};

pub const Interpreter = struct {
    arena_state: std.heap.ArenaAllocator,
    global_env: *Environment,
    /// Injected, not hardcoded to real stdout -- lets tests point this at
    /// an in-memory buffer instead of touching the process's actual
    /// stdout.
    console_writer: *std.Io.Writer,

    pub fn init(backing_allocator: Allocator, console_writer: *std.Io.Writer) !Interpreter {
        var self: Interpreter = .{
            .arena_state = std.heap.ArenaAllocator.init(backing_allocator),
            .global_env = undefined,
            .console_writer = console_writer,
        };
        const arena = self.arena_state.allocator();
        const global_env = try arena.create(Environment);
        global_env.* = .{ .parent = null };
        self.global_env = global_env;
        try self.setupGlobals();
        return self;
    }

    /// Frees every value/environment/closure this interpreter ever
    /// allocated, in one shot -- see the module-level doc comment on the
    /// "one arena per run" design (environment.zig).
    pub fn deinit(self: *Interpreter) void {
        self.arena_state.deinit();
    }

    fn setupGlobals(self: *Interpreter) !void {
        const arena = self.arena_state.allocator();
        var console_obj = try JSValue.newObject(arena);
        const log_fn = try JSValue.newFunction(arena, .{
            .ctx = self.console_writer,
            .name = "log",
            .call = consoleLogCall,
        });
        try console_obj.object.value.set("log", log_fn);
        try self.global_env.define(arena, "console", console_obj);
        // `undefined` is not a keyword in JS -- it's an ordinary
        // (writable-in-sloppy-mode-but-we-don't-care) global binding.
        try self.global_env.define(arena, "undefined", JSValue.UNDEFINED);
        try self.global_env.define(arena, "NaN", JSValue.fromNumber(std.math.nan(f64)));
        try self.global_env.define(arena, "Infinity", JSValue.fromNumber(std.math.inf(f64)));
    }

    /// Parses + evaluates a whole script; returns the completion value of
    /// the last top-level statement (UNDEFINED if the program is empty or
    /// ends on a non-value-producing statement).
    pub fn run(self: *Interpreter, source: []const u8) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        const parser = try zfunctions.Parser.init(arena, source);
        const program = try parser.parseProgram();
        const c = try self.evalProgram(self.global_env, program);
        return c.value;
    }

    pub fn evalProgram(self: *Interpreter, env: *Environment, program: []const *zstatements.Statement) anyerror!Completion {
        var last_value: JSValue = JSValue.UNDEFINED;
        for (program) |stmt| {
            const c = try self.evalStatement(env, stmt);
            if (c.type != .normal) return c;
            last_value = c.value;
        }
        return .{ .type = .normal, .value = last_value };
    }

    // ===== Statements =====

    pub fn evalStatement(self: *Interpreter, env: *Environment, stmt: *zstatements.Statement) anyerror!Completion {
        const arena = self.arena_state.allocator();
        switch (stmt.data) {
            .empty, .debugger => return .{},
            .expr_stmt => |expr| {
                const v = try self.evalExpression(env, expr);
                return .{ .type = .normal, .value = v };
            },
            .block => |stmts| {
                const block_env = try env.child(arena);
                return self.evalProgram(block_env, stmts);
            },
            .variable => |v| {
                for (v.declarators) |decl| {
                    const value = if (decl.init) |init_expr| try self.evalExpression(env, init_expr) else JSValue.UNDEFINED;
                    try env.define(arena, decl.name.name, value.retain());
                }
                return .{};
            },
            .if_stmt => |s| {
                const test_v = try self.evalExpression(env, s.test_expr);
                if (coercion.isTruthy(test_v)) return self.evalStatement(env, s.consequent);
                if (s.alternate) |alt| return self.evalStatement(env, alt);
                return .{};
            },
            .while_stmt => |s| {
                while (coercion.isTruthy(try self.evalExpression(env, s.test_expr))) {
                    const c = try self.evalStatement(env, s.body);
                    switch (c.type) {
                        .break_completion => {
                            if (c.target == null) break;
                            return c;
                        },
                        .continue_completion => {
                            if (c.target != null) return c;
                        },
                        .return_completion => return c,
                        .normal => {},
                    }
                }
                return .{};
            },
            .do_while => |s| {
                while (true) {
                    const c = try self.evalStatement(env, s.body);
                    switch (c.type) {
                        .break_completion => {
                            if (c.target == null) break;
                            return c;
                        },
                        .continue_completion => {
                            if (c.target != null) return c;
                        },
                        .return_completion => return c,
                        .normal => {},
                    }
                    if (!coercion.isTruthy(try self.evalExpression(env, s.test_expr))) break;
                }
                return .{};
            },
            .for_stmt => |s| return self.evalForStatement(env, s),
            .return_stmt => |arg| {
                const v = if (arg) |e| try self.evalExpression(env, e) else JSValue.UNDEFINED;
                return .{ .type = .return_completion, .value = v };
            },
            .break_stmt => |label| {
                if (label != null) return error.NotImplemented;
                return .{ .type = .break_completion };
            },
            .continue_stmt => |label| {
                if (label != null) return error.NotImplemented;
                return .{ .type = .continue_completion };
            },
            .labelled => |s| return self.evalStatement(env, s.body),
            .function_declaration => |ptr| {
                const fnode = zfunctions.asFunctionNode(ptr);
                const value = try self.makeClosure(env, fnode);
                const name = switch (fnode.kind) {
                    .function_decl => |d| d.name,
                    else => unreachable, // z-functions always produces .function_decl at statement position
                };
                try env.define(arena, name, value);
                return .{};
            },
            .throw_stmt, .try_stmt, .switch_stmt, .with_stmt => return error.NotImplemented,
        }
    }

    fn evalForStatement(self: *Interpreter, env: *Environment, s: anytype) anyerror!Completion {
        const arena = self.arena_state.allocator();
        switch (s.head) {
            .c_style => |head| {
                const loop_env = try env.child(arena);
                if (head.init) |init_clause| {
                    switch (init_clause) {
                        .decl => |d| {
                            for (d.declarators) |decl| {
                                const value = if (decl.init) |e| try self.evalExpression(loop_env, e) else JSValue.UNDEFINED;
                                try loop_env.define(arena, decl.name.name, value.retain());
                            }
                        },
                        .expr => |e| _ = try self.evalExpression(loop_env, e),
                    }
                }
                while (true) {
                    if (head.test_expr) |t| {
                        if (!coercion.isTruthy(try self.evalExpression(loop_env, t))) break;
                    }
                    const c = try self.evalStatement(loop_env, s.body);
                    switch (c.type) {
                        .break_completion => {
                            if (c.target == null) break;
                            return c;
                        },
                        .continue_completion => {
                            if (c.target != null) return c;
                        },
                        .return_completion => return c,
                        .normal => {},
                    }
                    if (head.update) |u| _ = try self.evalExpression(loop_env, u);
                }
                return .{};
            },
            .for_in, .for_of => return error.NotImplemented,
        }
    }

    // ===== Expressions =====

    pub fn evalExpression(self: *Interpreter, env: *Environment, node: *zparser.Node) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        switch (node.data) {
            .number_literal => |n| return JSValue.fromNumber(n),
            .string_literal => |s| return try JSValue.newString(arena, s),
            .boolean_literal => |b| return JSValue.fromBool(b),
            .null_literal => return JSValue.NULL,
            .identifier => |name| return env.get(name) orelse error.ReferenceError,
            .this_expr => return env.resolveThis(),
            .paren => |inner| return self.evalExpression(env, inner),
            .sequence => |items| {
                var result: JSValue = JSValue.UNDEFINED;
                for (items) |item| result = try self.evalExpression(env, item);
                return result;
            },
            .template_literal => |t| {
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(arena);
                for (t.quasis, 0..) |quasi, i| {
                    try buf.appendSlice(arena, quasi);
                    if (i < t.expressions.len) {
                        const v = try self.evalExpression(env, t.expressions[i]);
                        const s = try coercion.toDisplayString(arena, v);
                        defer arena.free(s);
                        try buf.appendSlice(arena, s);
                    }
                }
                return try JSValue.newString(arena, buf.items);
            },
            .array_literal => |elements| {
                var arr = try JSValue.newArray(arena);
                for (elements) |maybe_el| {
                    const el = maybe_el orelse {
                        _ = try arr.array.value.push(JSValue.UNDEFINED);
                        continue;
                    };
                    if (el.data == .spread) {
                        const spread_val = try self.evalExpression(env, el.data.spread);
                        if (spread_val != .array) return error.NotImplemented;
                        for (spread_val.array.value.toSlice()) |item| _ = try arr.array.value.push(item.retain());
                        continue;
                    }
                    const v = try self.evalExpression(env, el);
                    _ = try arr.array.value.push(v.retain());
                }
                return arr;
            },
            .object_literal => |elements| {
                var obj = try JSValue.newObject(arena);
                for (elements) |el| {
                    switch (el) {
                        .property => |prop| {
                            const key_str = try self.propertyKeyString(env, prop.computed, prop.key);
                            const value = try self.evalExpression(env, prop.value);
                            try obj.object.value.set(key_str, value.retain());
                        },
                        .spread => |spread_node| {
                            const spread_val = try self.evalExpression(env, spread_node.data.spread);
                            if (spread_val != .object) return error.NotImplemented;
                            const keys = try spread_val.object.value.keys(arena);
                            defer arena.free(keys);
                            for (keys) |k| {
                                try obj.object.value.set(k, spread_val.object.value.get(k).?.retain());
                            }
                        },
                    }
                }
                return obj;
            },
            .unary => |u| return self.evalUnary(env, u),
            .binary => |b| {
                const l = try self.evalExpression(env, b.left);
                const r = try self.evalExpression(env, b.right);
                return try coercion.binaryOp(arena, b.op, l, r);
            },
            .logical => |l| {
                const left = try self.evalExpression(env, l.left);
                return switch (l.op) {
                    .and_op => if (!coercion.isTruthy(left)) left else try self.evalExpression(env, l.right),
                    .or_op => if (coercion.isTruthy(left)) left else try self.evalExpression(env, l.right),
                    .nullish => if (left != .@"undefined" and left != .@"null") left else try self.evalExpression(env, l.right),
                };
            },
            .assignment => |a| return self.evalAssignment(env, a),
            .conditional => |c| {
                if (coercion.isTruthy(try self.evalExpression(env, c.test_expr))) return self.evalExpression(env, c.consequent);
                return self.evalExpression(env, c.alternate);
            },
            .call => |c| return self.evalCall(env, c),
            .member => |m| {
                const obj = try self.evalExpression(env, m.object);
                if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
                const key = try self.memberKeyString(env, m);
                return try self.getProperty(obj, key);
            },
            .function_like => |ptr| return try self.makeClosure(env, zfunctions.asFunctionNode(ptr)),
            .new_expr, .regex_literal, .bigint_literal => return error.NotImplemented,
            // Only ever nested inside array/object-literal/call-argument
            // constructs, which unwrap `.data.spread` themselves before
            // recursing -- never reached as a standalone expression.
            .spread => unreachable,
        }
    }

    fn memberKeyString(self: *Interpreter, env: *Environment, m: anytype) anyerror![]const u8 {
        if (m.computed) {
            const k = try self.evalExpression(env, m.property);
            return try coercion.toDisplayString(self.arena_state.allocator(), k);
        }
        return switch (m.property.data) {
            .identifier => |name| name,
            else => error.NotImplemented,
        };
    }

    fn propertyKeyString(self: *Interpreter, env: *Environment, computed: bool, key: *zparser.Node) anyerror![]const u8 {
        if (computed) {
            const v = try self.evalExpression(env, key);
            return try coercion.toDisplayString(self.arena_state.allocator(), v);
        }
        return switch (key.data) {
            .identifier => |name| name,
            .string_literal => |s| s,
            .number_literal => |n| try znumber.FormattingMethods.toString(n, self.arena_state.allocator(), null),
            else => error.NotImplemented,
        };
    }

    fn getProperty(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!JSValue {
        _ = self;
        return switch (obj) {
            .object => |box| (box.value.get(key) orelse JSValue.UNDEFINED).retain(),
            .array => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.length()));
                const idx = std.fmt.parseInt(usize, key, 10) catch return error.NotImplemented;
                if (idx >= box.value.length()) break :blk JSValue.UNDEFINED;
                break :blk box.value.get(idx).retain();
            },
            .string => |box| blk: {
                if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.data.len));
                break :blk error.NotImplemented;
            },
            .@"undefined", .@"null" => error.ReferenceError,
            else => error.NotImplemented,
        };
    }

    fn evalUnary(self: *Interpreter, env: *Environment, u: anytype) anyerror!JSValue {
        switch (u.op) {
            .not => return JSValue.fromBool(!coercion.isTruthy(try self.evalExpression(env, u.operand))),
            .minus => return JSValue.fromNumber(-(try coercion.toNumber(try self.evalExpression(env, u.operand)))),
            .plus => return JSValue.fromNumber(try coercion.toNumber(try self.evalExpression(env, u.operand))),
            .typeof => {
                // typeof on an undeclared identifier is "undefined", not a
                // ReferenceError -- a real, deliberate spec quirk.
                if (u.operand.data == .identifier) {
                    const v = env.get(u.operand.data.identifier) orelse
                        return try JSValue.newString(self.arena_state.allocator(), "undefined");
                    return try JSValue.newString(self.arena_state.allocator(), v.typeOf());
                }
                const v = try self.evalExpression(env, u.operand);
                return try JSValue.newString(self.arena_state.allocator(), v.typeOf());
            },
            .void_op => {
                _ = try self.evalExpression(env, u.operand);
                return JSValue.UNDEFINED;
            },
            .pre_inc, .pre_dec => {
                const old = try coercion.toNumber(try self.evalExpression(env, u.operand));
                const new_val = JSValue.fromNumber(if (u.op == .pre_inc) old + 1 else old - 1);
                try self.assignTo(env, u.operand, new_val);
                return new_val;
            },
            .post_inc, .post_dec => {
                const old = try coercion.toNumber(try self.evalExpression(env, u.operand));
                const new_val = JSValue.fromNumber(if (u.op == .post_inc) old + 1 else old - 1);
                try self.assignTo(env, u.operand, new_val);
                return JSValue.fromNumber(old);
            },
            .bitnot, .delete => return error.NotImplemented,
        }
    }

    fn evalAssignment(self: *Interpreter, env: *Environment, a: anytype) anyerror!JSValue {
        if (a.op == .assign) {
            const value = try self.evalExpression(env, a.value);
            try self.assignTo(env, a.target, value);
            return value;
        }
        switch (a.op) {
            .logical_and, .logical_or, .nullish => {
                const current = try self.evalExpression(env, a.target);
                const should_assign = switch (a.op) {
                    .logical_and => coercion.isTruthy(current),
                    .logical_or => !coercion.isTruthy(current),
                    .nullish => current == .@"undefined" or current == .@"null",
                    else => unreachable,
                };
                if (!should_assign) return current;
                const value = try self.evalExpression(env, a.value);
                try self.assignTo(env, a.target, value);
                return value;
            },
            else => {
                const current = try self.evalExpression(env, a.target);
                const rhs = try self.evalExpression(env, a.value);
                const result = try coercion.binaryOp(self.arena_state.allocator(), compoundToBinary(a.op), current, rhs);
                try self.assignTo(env, a.target, result);
                return result;
            },
        }
    }

    fn assignTo(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
        switch (target.data) {
            .identifier => |name| try env.assign(name, value),
            .paren => |inner| try self.assignTo(env, inner, value),
            .member => |m| {
                const obj = try self.evalExpression(env, m.object);
                const key = try self.memberKeyString(env, m);
                if (obj != .object) return error.NotImplemented;
                try obj.object.value.set(key, value.retain());
            },
            else => return error.NotImplemented,
        }
    }

    fn evalCall(self: *Interpreter, env: *Environment, c: anytype) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        var this_value: JSValue = JSValue.UNDEFINED;
        var callee_val: JSValue = undefined;
        if (c.callee.data == .member) {
            const m = c.callee.data.member;
            const obj = try self.evalExpression(env, m.object);
            if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
            const key = try self.memberKeyString(env, m);
            this_value = obj;
            callee_val = try self.getProperty(obj, key);
        } else {
            callee_val = try self.evalExpression(env, c.callee);
        }
        if (c.optional and (callee_val == .@"undefined" or callee_val == .@"null")) return JSValue.UNDEFINED;
        if (callee_val != .function) return error.NotImplemented;

        var args: std.ArrayList(JSValue) = .empty;
        for (c.args) |arg_node| {
            if (arg_node.data == .spread) {
                const spread_val = try self.evalExpression(env, arg_node.data.spread);
                if (spread_val != .array) return error.NotImplemented;
                for (spread_val.array.value.toSlice()) |item| try args.append(arena, item.retain());
            } else {
                try args.append(arena, try self.evalExpression(env, arg_node));
            }
        }
        return try callee_val.function.value.call(callee_val.function.value.ctx, arena, this_value, args.items);
    }

    fn makeClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode) anyerror!JSValue {
        const arena = self.arena_state.allocator();
        // A named function expression's own name is visible inside its own
        // body (for self-recursion) even though it isn't bound in the
        // enclosing scope -- bind it in a thin wrapper env between `env`
        // and the closure's actual defining environment.
        const self_name: ?[]const u8 = switch (fnode.kind) {
            .function_expr => |e| e.name,
            else => null,
        };
        const closure_env = if (self_name != null) try env.child(arena) else env;

        const ctx = try arena.create(ClosureCtx);
        ctx.* = .{ .interp = self, .function_node = fnode, .closure_env = closure_env };
        const name: []const u8 = switch (fnode.kind) {
            .function_decl => |d| d.name,
            .function_expr => |e| e.name orelse "",
            .arrow => "",
        };
        const fn_value = try JSValue.newFunction(arena, .{
            .ctx = ctx,
            .name = name,
            .arity = fnode.params.items.len,
            .call = closureCall,
        });
        if (self_name) |n| try closure_env.define(arena, n, fn_value.retain());
        return fn_value;
    }
};

fn compoundToBinary(op: zparser.AssignOp) zparser.BinaryOp {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .pow => .pow,
        .shl => .shl,
        .shr => .shr,
        .ushr => .ushr,
        .bitand => .bitand,
        .bitor => .bitor,
        .bitxor => .bitxor,
        .assign, .logical_and, .logical_or, .nullish => unreachable, // handled separately by evalAssignment
    };
}

fn closureCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const closure_ctx: *ClosureCtx = @ptrCast(@alignCast(ctx));
    const self = closure_ctx.interp;
    const fnode = closure_ctx.function_node;
    const call_env = try closure_ctx.closure_env.child(allocator);

    // Arrows have no own `this` binding -- leaving call_env.this_value
    // null makes `resolveThis()` walk up to closure_env's, matching real
    // lexical `this` inheritance.
    if (fnode.kind != .arrow) {
        call_env.this_value = this_value;
    }

    for (fnode.params.items, 0..) |param, i| {
        var value = if (i < args.len) args[i] else JSValue.UNDEFINED;
        if (value == .@"undefined") {
            if (param.default) |def| value = try self.evalExpression(call_env, def);
        }
        try call_env.define(allocator, param.binding.name, value.retain());
    }
    if (fnode.params.rest) |rest| {
        var rest_arr = try JSValue.newArray(allocator);
        const start = fnode.params.items.len;
        if (start < args.len) {
            for (args[start..]) |a| _ = try rest_arr.array.value.push(a.retain());
        }
        try call_env.define(allocator, rest.name, rest_arr);
    }

    switch (fnode.body) {
        .block => |body_stmt| {
            const c = try self.evalProgram(call_env, body_stmt.data.block);
            if (c.type == .return_completion) return c.value;
            return JSValue.UNDEFINED;
        },
        .expression => |expr| return try self.evalExpression(call_env, expr),
    }
}

fn consoleLogCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const writer: *std.Io.Writer = @ptrCast(@alignCast(ctx));
    try inspect.writeConsoleLog(allocator, writer, args);
    return JSValue.UNDEFINED;
}
