//! `Function.prototype.call`/`.apply`/`.bind`, and the `Function`
//! constructor (`new Function('a', 'return a')` -- a bounded eval).
//! z-interpreter-refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const zfunctions = @import("zfunctions");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const interpreter_class = @import("interpreter_class.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");
const property_desc = @import("property_desc.zig");
const object_builtins = @import("object_builtins.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

pub const function_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "call", MethodSpec{ .call = fnCall, .arity = 1 } },
    .{ "apply", MethodSpec{ .call = fnApply, .arity = 2 } },
    .{ "bind", MethodSpec{ .call = fnBind, .arity = 1 } },
    .{ "toString", MethodSpec{ .call = fnToString, .arity = 0 } },
});

fn isValidNativeFnName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, i| {
        const is_alpha = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '$';
        const is_digit = c >= '0' and c <= '9';
        if (i == 0) {
            if (!is_alpha) return false;
        } else {
            if (!is_alpha and !is_digit) return false;
        }
    }
    return true;
}

fn formatNativeFn(self: *Interpreter, allocator: Allocator, name: []const u8) anyerror!JSValue {
    if (isValidNativeFnName(name)) {
        const formatted = try std.fmt.allocPrint(allocator, "function {s}() {{ [native code] }}", .{name});
        defer allocator.free(formatted);
        return self.gcNewString(formatted);
    }
    return self.gcNewString("function () { [native code] }");
}

fn skipWsCommentsBackward(src: []const u8, pos_in: usize) usize {
    var p = pos_in;
    while (p > 0) {
        const c = src[p - 1];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0B or c == 0x0C) {
            p -= 1;
            continue;
        }
        if (p >= 2 and src[p - 2] == '*' and src[p - 1] == '/') {
            var q = p - 2;
            while (q >= 2) : (q -= 1) {
                if (src[q - 2] == '/' and src[q - 1] == '*') {
                    p = q - 2;
                    break;
                }
            } else break;
            continue;
        }
        break;
    }
    return p;
}

fn isIdentOrNumByte(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or
        c == '_' or c == '$' or c == '#' or c == '.' or c >= 0x80;
}

fn hasWordBefore(src: []const u8, end_pos: usize, word: []const u8) bool {
    if (end_pos < word.len) return false;
    const start_pos = end_pos - word.len;
    if (!std.mem.eql(u8, src[start_pos..end_pos], word)) return false;
    if (start_pos > 0 and isIdentOrNumByte(src[start_pos - 1])) return false;
    return true;
}

fn findMethodStart(src: []const u8, paren_pos: usize, fnode: *const zfunctions.FunctionNode, fn_name: []const u8) usize {
    var p = skipWsCommentsBackward(src, paren_pos);
    if (p == 0) return paren_pos;
    if (src[p - 1] == ']') {
        var depth: i32 = 1;
        p -= 1;
        while (p > 0 and depth > 0) {
            p -= 1;
            const c = src[p];
            if (c == '"' or c == '\'') {
                const quote = c;
                while (p > 0) {
                    p -= 1;
                    if (src[p] == quote) {
                        var bs: usize = 0;
                        var k = p;
                        while (k > 0 and src[k - 1] == '\\') {
                            bs += 1;
                            k -= 1;
                        }
                        if (bs % 2 == 0) break;
                    }
                }
            } else if (c == '/' and p > 0 and src[p - 1] == '*') {
                p -= 1;
                while (p >= 2) : (p -= 1) {
                    if (src[p - 2] == '/' and src[p - 1] == '*') {
                        p -= 2;
                        break;
                    }
                }
            } else if (c == ']') {
                depth += 1;
            } else if (c == '[') {
                depth -= 1;
            }
        }
    } else if (src[p - 1] == '"' or src[p - 1] == '\'') {
        const quote = src[p - 1];
        p -= 1;
        while (p > 0) {
            p -= 1;
            if (src[p] == quote) {
                var bs: usize = 0;
                var k = p;
                while (k > 0 and src[k - 1] == '\\') {
                    bs += 1;
                    k -= 1;
                }
                if (bs % 2 == 0) break;
            }
        }
    } else {
        while (p > 0 and isIdentOrNumByte(src[p - 1])) {
            p -= 1;
        }
    }

    if (fnode.is_generator) {
        const q = skipWsCommentsBackward(src, p);
        if (q > 0 and src[q - 1] == '*') p = q - 1;
    }
    if (fnode.is_async) {
        const q = skipWsCommentsBackward(src, p);
        if (hasWordBefore(src, q, "async")) p = q - 5;
    }
    if (!fnode.is_generator and !fnode.is_async) {
        if (std.mem.startsWith(u8, fn_name, "get ")) {
            const q = skipWsCommentsBackward(src, p);
            if (hasWordBefore(src, q, "get")) p = q - 3;
        } else if (std.mem.startsWith(u8, fn_name, "set ")) {
            const q = skipWsCommentsBackward(src, p);
            if (hasWordBefore(src, q, "set")) p = q - 3;
        }
    }
    return p;
}

fn fnToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    const self = interp(ctx);
    if (this_value.isProxy()) {
        if (!property_desc.isCallableWithInterp(self, this_value)) {
            return self.throwError(.type_error, "Function.prototype.toString requires that 'this' be a Function", .{});
        }
        return self.gcNewString("function () { [native code] }");
    }
    if (zvalue.equality.strictEquals(this_value, self.protos.function)) {
        return self.gcNewString("function () { [native code] }");
    }
    if (!this_value.isFunction()) {
        return self.throwError(.type_error, "Function.prototype.toString requires that 'this' be a Function", .{});
    }
    const fn_val = this_value.asFunction().value;
    if (fn_val.call == interpreter_class.closureCall) {
        const cc: *const interpreter_mod.ClosureCtx = @ptrCast(@alignCast(fn_val.ctx));
        if (cc.source_full) |src| {
            if (cc.function_node.end <= src.len and cc.function_node.start <= cc.function_node.end) {
                var start_pos = cc.function_node.start;
                if (cc.function_node.kind == .method and start_pos < src.len and src[start_pos] == '(') {
                    start_pos = findMethodStart(src, start_pos, cc.function_node, fn_val.name);
                } else if (cc.function_node.is_async and !std.mem.startsWith(u8, src[start_pos..], "async")) {
                    const q = skipWsCommentsBackward(src, start_pos);
                    if (hasWordBefore(src, q, "async")) start_pos = q - 5;
                }
                return self.gcNewString(src[start_pos..cc.function_node.end]);
            }
        }
    } else if (fn_val.call == interpreter_class.classConstructorCall) {
        const cctx: *const interpreter_mod.ClassCtx = @ptrCast(@alignCast(fn_val.ctx));
        if (cctx.source_text) |st| return self.gcNewString(st);
    }
    const name = if (fn_val.call == boundCall) "" else fn_val.name;
    return formatNativeFn(self, allocator, name);
}

fn requireCallable(ctx: *anyopaque, this_value: JSValue, method: []const u8) anyerror!JSValue {
    const self = interp(ctx);
    if (!property_desc.isCallableWithInterp(self, this_value)) {
        return self.throwError(.type_error, "Function.prototype.{s} called on a non-function", .{method});
    }
    return this_value;
}

fn fnCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    const target = try requireCallable(ctx, this_value, "call");
    const this_arg = arg(args, 0);
    const rest = if (args.len > 1) args[1..] else &[_]JSValue{};
    return interp(ctx).callValue(target, this_arg, rest, "call");
}

fn fnApply(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const target = try requireCallable(ctx, this_value, "apply");
    const this_arg = arg(args, 0);
    const arg_list = arg(args, 1);
    const self = interp(ctx);
    if (arg_list.isUndefined() or arg_list.isNull()) {
        return self.callValue(target, this_arg, &.{}, "apply");
    }
    if (!builtin_helpers.isObjectLike(arg_list)) {
        return self.throwError(.type_error, "CreateListFromArrayLike called on non-object", .{});
    }
    if (arg_list.tag() == .array and !arg_list.asArray().value.isHoley() and !arg_list.asArray().value.isSparse() and !arg_list.asArray().value.hasElementDescriptors()) {
        return self.callValue(target, this_arg, arg_list.asArray().value.toSlice(), "apply");
    }
    const items = try builtin_helpers.arrayLikeToList(self, allocator, arg_list);
    defer {
        for (items) |it| it.deinit();
        allocator.free(items);
    }
    return self.callValue(target, this_arg, items, "apply");
}

/// ctx for one bound function: the target, the fixed this, and any
/// pre-applied arguments.
pub const BoundCtx = struct {
    interp: *Interpreter,
    target: JSValue,
    bound_this: JSValue,
    pre_args: []const JSValue,
    /// Owned (formatted fresh per `.bind()` call -- "bound " ++ target's
    /// name); freed alongside the ctx itself, see freeGarbageNode's
    /// `.bound_ctx` case. Unlike every other `Callable.name` in this file
    /// (always a string literal or AST-borrowed slice), this one is real
    /// heap memory that needs an owner.
    name: []const u8,
};

fn boundCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value; // a bound function ignores its call-site this (spec)
    const bc: *BoundCtx = @ptrCast(@alignCast(ctx));
    const total = try allocator.alloc(JSValue, bc.pre_args.len + args.len);
    defer allocator.free(total);
    @memcpy(total[0..bc.pre_args.len], bc.pre_args);
    @memcpy(total[bc.pre_args.len..], args);
    return bc.interp.callValue(bc.target, bc.bound_this, total, bc.name);
}

/// Internal bound-function identity used by [[Construct]] dispatch. This is
/// deliberately not a JS-visible marker: only our own `boundCall` callback
/// may expose a `BoundCtx` through this helper.
pub fn boundContext(value: JSValue) ?*BoundCtx {
    if (value.isFunction() and value.asFunction().value.call == boundCall) {
        return @ptrCast(@alignCast(value.asFunction().value.ctx));
    }
    return null;
}

/// [[Bind]] preserves [[Construct]] exactly when the target has it.
fn fnBind(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const self = interp(ctx);
    const target = try requireCallable(ctx, this_value, "bind");
    const bc = try allocator.create(BoundCtx);
    const pre = if (args.len > 1) args[1..] else &[_]JSValue{};
    const pre_copy = try allocator.alloc(JSValue, pre.len);
    for (pre, 0..) |a, i| pre_copy[i] = a.retain();
    const len_key = try self.gcNewString("length");
    defer len_key.deinit();
    const has_len_val = try object_builtins.objHasOwnProperty(ctx, allocator, target, &.{len_key});
    defer has_len_val.deinit();
    const target_has_len = has_len_val.isBool() and has_len_val.asBool();
    var bound_len_f: f64 = 0;
    if (target_has_len) {
        const target_len_v = try self.getProperty(target, "length");
        defer target_len_v.deinit();
        if (target_len_v.isNumber()) {
            const n = target_len_v.asNumber();
            const int_len: f64 = if (std.math.isNan(n) or n == 0)
                0
            else if (std.math.isInf(n))
                n
            else
                @trunc(n);
            bound_len_f = @max(0.0, int_len - @as(f64, @floatFromInt(pre.len)));
        }
    }
    const target_name = try self.getProperty(target, "name");
    defer target_name.deinit();
    const target_name_str = if (target_name.isString()) target_name.asString().value.data else "";
    const name = try std.fmt.allocPrint(allocator, "bound {s}", .{target_name_str});
    bc.* = .{
        .interp = self,
        .target = target.retain(),
        .bound_this = arg(args, 0).retain(),
        .pre_args = pre_copy,
        .name = name,
    };
    try self.gcTrackBoundCtx(bc);
    const bound_arity: usize = if (std.math.isInf(bound_len_f))
        std.math.maxInt(usize)
    else
        @intFromFloat(@min(bound_len_f, @as(f64, @floatFromInt(std.math.maxInt(usize)))));
    const bound_fn = try self.gcNewFunction(.{
        .ctx = bc,
        .name = name,
        .arity = bound_arity,
        .call = boundCall,
        .constructable = self.isConstructor(target),
    });
    errdefer bound_fn.deinit();

    if (std.math.isInf(bound_len_f)) {
        var len_desc = property_desc.ParsedDesc{
            .has_value = true,
            .value = JSValue.fromNumber(bound_len_f),
            .has_writable = true,
            .writable = false,
            .has_enumerable = true,
            .enumerable = false,
            .has_configurable = true,
            .configurable = true,
        };
        _ = try property_desc.defineOwnProperty(self, bound_fn, "length", &len_desc);
    }

    const target_proto = try object_builtins.objectGetPrototypeOf(ctx, allocator, JSValue.UNDEFINED, &.{target});
    defer target_proto.deinit();
    if (!zvalue.equality.strictEquals(target_proto, self.protos.function)) {
        try self.setOwnedPrototype(bound_fn, target_proto);
    }
    return bound_fn;
}

pub fn ordinaryHasInstance(self: *Interpreter, allocator: Allocator, ctor: JSValue, obj: JSValue) anyerror!bool {
    const is_callable = property_desc.isCallable(ctor) or zvalue.equality.strictEquals(ctor, self.protos.function);
    if (!is_callable) return false;
    if (boundContext(ctor)) |bc| {
        return ordinaryHasInstance(self, allocator, bc.target, obj);
    }
    if (!builtin_helpers.isObjectLike(obj)) return false;
    if (obj.isError()) {
        if (self.global_env.get(obj.asError().value.kind.name())) |own_ctor| {
            if (zvalue.equality.strictEquals(own_ctor, ctor)) return true;
        }
    }
    const proto = try self.getProperty(ctor, "prototype");
    defer proto.deinit();
    if (!builtin_helpers.isObjectLike(proto)) {
        return self.throwError(.type_error, "Function has non-object prototype in instanceof check", .{});
    }
    var cur = try object_builtins.objectGetPrototypeOf(@ptrCast(self), allocator, JSValue.UNDEFINED, &.{obj});
    defer cur.deinit();
    while (!cur.isNull()) {
        if (zvalue.equality.strictEquals(cur, proto)) return true;
        const next = try object_builtins.objectGetPrototypeOf(@ptrCast(self), allocator, JSValue.UNDEFINED, &.{cur});
        cur.deinit();
        cur = next;
    }
    return false;
}

pub fn fnSymbolHasInstance(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const obj = arg(args, 0);
    return JSValue.fromBool(try ordinaryHasInstance(interp(ctx), allocator, this_value, obj));
}

fn createDynamicFunction(ctx: *anyopaque, allocator: Allocator, args: []const JSValue, header: []const u8) anyerror!JSValue {
    const self = interp(ctx);
    const ast_allocator = self.arena_state.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(ast_allocator, "(");
    try src.appendSlice(ast_allocator, header);
    try src.appendSlice(ast_allocator, " anonymous(");
    if (args.len > 1) {
        for (args[0 .. args.len - 1], 0..) |a, i| {
            if (i != 0) try src.appendSlice(ast_allocator, ",");
            const s = try self.toDisplayStringJS(allocator, a);
            defer allocator.free(s);
            try src.appendSlice(ast_allocator, s);
        }
    }
    try src.appendSlice(ast_allocator, "\n) {\n");
    if (args.len > 0) {
        const body = try self.toDisplayStringJS(allocator, args[args.len - 1]);
        defer allocator.free(body);
        try src.appendSlice(ast_allocator, body);
    }
    try src.appendSlice(ast_allocator, "\n})");

    const parser = zfunctions.Parser.init(ast_allocator, src.items) catch {
        return self.throwError(.syntax_error, "Invalid function source", .{});
    };
    const node = parser.parseExpression() catch |err| {
        return self.throwError(.syntax_error, "Function constructor: {s}", .{@errorName(err)});
    };
    interpreter_mod.normalizePrivateInNode(ast_allocator, src.items, node) catch |err| switch (err) {
        error.InvalidOctalLiteral => return self.throwError(.syntax_error, "Octal literals are not allowed in strict mode", .{}),
        error.InvalidStrictAssignment => return self.throwError(.syntax_error, "Unexpected eval or arguments in strict mode", .{}),
        else => return err,
    };
    const fnode_ptr = switch (node.data) {
        .paren => |inner| switch (inner.data) {
            .function_like => |ptr| ptr,
            else => return self.throwError(.syntax_error, "Invalid function source", .{}),
        },
        else => return self.throwError(.syntax_error, "Invalid function source", .{}),
    };
    const fnode = zfunctions.asFunctionNode(fnode_ptr);
    if (!try interpreter_class.validatePrivateIdentifiersInFunction(ast_allocator, fnode)) {
        return self.throwError(.syntax_error, "Private field must be declared in an enclosing class", .{});
    }
    const prev_source = self.current_source;
    const prev_strict = self.strict_mode;
    self.current_source = src.items;
    self.strict_mode = false;
    defer {
        self.current_source = prev_source;
        self.strict_mode = prev_strict;
    }
    const closure_scope = self.global_var_env orelse self.script_env orelse self.global_env;
    const fn_val = try self.makeClosure(closure_scope, fnode);
    const is_construct = if (self.construct_target) |ct| ct == ctx else false;
    if (is_construct) {
        if (self.construct_proto) |cp| {
            try self.setOwnedPrototype(fn_val, cp);
        }
    }
    return fn_val;
}

/// `new Function('a', 'b', 'return a + b')` -- compose, parse with the
/// real parser, close over the global env. A bounded eval.
fn functionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return createDynamicFunction(ctx, allocator, args, "function");
}

pub fn generatorFunctionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return createDynamicFunction(ctx, allocator, args, "function*");
}

pub fn asyncFunctionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return createDynamicFunction(ctx, allocator, args, "async function");
}

pub fn asyncGeneratorFunctionConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    return createDynamicFunction(ctx, allocator, args, "async function*");
}

pub fn isFunctionSubclassConstructor(call: NativeFn) bool {
    return call == generatorFunctionConstructor or
        call == asyncFunctionConstructor or
        call == asyncGeneratorFunctionConstructor;
}

pub fn throwTypeErrorFn(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    _ = args;
    return interp(ctx).throwError(.type_error, "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them", .{});
}

pub fn installThrowTypeError(self: *Interpreter) !void {
    const tte = try self.gcNewFunction(.{
        .ctx = self,
        .name = "",
        .arity = 0,
        .call = throwTypeErrorFn,
        .constructable = false,
    });
    const bag = try self.functionStatics(tte);
    const frozen_attrs = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = false };
    try bag.asObject().value.defineProperty("length", JSValue.fromNumber(0), frozen_attrs);
    try bag.asObject().value.defineProperty("name", try self.gcNewString(""), frozen_attrs);
    bag.asObject().value.freeze();
    self.throw_type_error = tte;

    const fn_proto = &self.protos.function.asObject().value;
    try fn_proto.defineAccessor("caller", tte.retain(), tte.retain(), JSValue.UNDEFINED);
    if (fn_proto.getOwnRecordMut("caller")) |rec| {
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }
    try fn_proto.defineAccessor("arguments", tte.retain(), tte.retain(), JSValue.UNDEFINED);
    if (fn_proto.getOwnRecordMut("arguments")) |rec| {
        rec.descriptor.enumerable = false;
        rec.descriptor.configurable = true;
    }
}

/// Installs the `Function` constructor (no statics).
pub fn install(self: *Interpreter) !void {
    // Function: a constructor that PARSES -- new Function('a', 'return a')
    // composes and compiles a real closure (a bounded eval). Its
    // .prototype carries the cached call/apply/bind for the detached
    // harness pattern.
    _ = try installBuiltin(self, .{ .name = "Function", .ctor = .{ .arity = 1, .call = functionConstructor, .constructable = true } });
}
