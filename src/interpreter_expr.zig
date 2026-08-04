//! Step 5 Phase C batch 9 (FINAL): the expr+propkey cluster --
//! evalExpression and its whole family (unary/assignment/call/new
//! dispatch), plus property-key encoding (mutually coupled with expr).
//! Split out of interpreter.zig; see z-interpreter-refactor.md.
//!
//! NOTE: this cluster's original line range in interpreter.zig was NOT
//! purely this cluster -- batches 5/6's alias blocks for interpreter_props
//! and interpreter_support happened to sit physically interspersed within
//! it (their real bodies had already moved out in earlier batches; only
//! the one-line pub-const aliases remained, sitting between propertyKeyString
//! and evalInstanceof, and between evalIn and evalUnary). Those alias
//! blocks were deliberately left IN PLACE in interpreter.zig -- they are
//! not part of this cluster, just neighbors -- and are not duplicated here.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zparser = @import("zparser");
const zobject = @import("zobject");
const znumber = @import("znumber");
const zfunctions = @import("zfunctions");
const zbigint = @import("zbigint");

const coercion = @import("coercion.zig");
const builtins = @import("builtins.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const ClassCtx = interpreter_mod.ClassCtx;
const Environment = interpreter_mod.Environment;

pub fn evalExpression(self: *Interpreter, env: *Environment, node: *zparser.Node) anyerror!JSValue {
    // The stack-depth guard (byte-based: adapts to Debug/Release
    // frame sizes and to fiber stacks) -- deep call chains AND deep
    // expression trees both surface as the real RangeError instead
    // of a native stack overflow.
    if (self.stack_limit != 0 and @frameAddress() < self.stack_limit) {
        return self.throwError(.range_error, "Maximum call stack size exceeded", .{});
    }
    const arena = self.gc_allocator;
    switch (node.data) {
        .number_literal => |n| return JSValue.fromNumber(n),
        .string_literal => |s| return try self.gcNewString(s),
        .boolean_literal => |b| return JSValue.fromBool(b),
        .null_literal => return JSValue.NULL,
        .identifier => |name| switch (env.lookup(name)) {
            .value => |v| return v,
            .tdz => return self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
            .not_found => return self.throwError(.reference_error, "{s} is not defined", .{name}),
        },
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
                    const s = try self.toDisplayStringJS(arena, v);
                    defer arena.free(s);
                    try buf.appendSlice(arena, s);
                }
            }
            return try self.gcNewString(buf.items);
        },
        .array_literal => |elements| {
            var arr = try self.gcNewArray();
            for (elements) |maybe_el| {
                const el = maybe_el orelse {
                    _ = try arr.array.value.push(JSValue.UNDEFINED);
                    continue;
                };
                if (el.data == .spread) {
                    const spread_val = try self.evalExpression(env, el.data.spread);
                    const items = try self.iterableItems(spread_val);
                    defer arena.free(items);
                    for (items) |item| _ = try arr.array.value.push(item.retain());
                    continue;
                }
                const v = try self.evalExpression(env, el);
                _ = try arr.array.value.push(v.retain());
            }
            return arr;
        },
        .object_literal => |elements| {
            var obj = try self.ordinaryObject();
            for (elements) |el| {
                switch (el) {
                    .property => |prop| {
                        const pk = try self.propertyKeyString(env, prop.computed, prop.key);
                        defer pk.free(self.gc_allocator);
                        const key_str = pk.key;
                        switch (prop.kind) {
                            .init => {
                                const value = try self.evalExpression(env, prop.value);
                                // NamedEvaluation: `{ x: AnonFn }` names
                                // the function/class with the (already
                                // static-or-computed-resolved) key.
                                try self.maybeNameAnonymousValue(prop.value, value, key_str);
                                try obj.object.value.set(key_str, value.retain());
                            },
                            .method => {
                                const f = try self.makeObjectMethodClosure(env, zfunctions.asFunctionNode(prop.value.data.function_like), obj);
                                try obj.object.value.set(key_str, f);
                            },
                            // get+set for the same key merge into one
                            // accessor property (defineAccessor's
                            // contract); data-only consumers see
                            // UNDEFINED as its value.
                            .get, .set => {
                                const f = try self.makeObjectMethodClosure(env, zfunctions.asFunctionNode(prop.value.data.function_like), obj);
                                try obj.object.value.defineAccessor(
                                    key_str,
                                    if (prop.kind == .get) f else null,
                                    if (prop.kind == .set) f else null,
                                    JSValue.UNDEFINED,
                                );
                            },
                        }
                    },
                    .spread => |spread_node| {
                        const spread_val = try self.evalExpression(env, spread_node.data.spread);
                        if (spread_val == .proxy) {
                            // ownKeys trap (or delegate) for the key
                            // list, `get` trap (or delegate) per key
                            // for the value -- same narrowing as
                            // every other trap site (no per-key
                            // enumerability re-check via
                            // getOwnPropertyDescriptor).
                            const ks = try builtins.ownEnumerableKeys(self, arena, spread_val);
                            defer builtins.freeOwnedKeys(arena, ks);
                            for (ks) |k| {
                                if (isSymbolKey(k)) continue;
                                try obj.object.value.set(k, try self.getProperty(spread_val, k));
                            }
                        } else {
                            if (spread_val != .object) return error.NotImplemented;
                            const keys = try spread_val.object.value.keys(arena);
                            defer arena.free(keys);
                            for (keys) |k| {
                                try obj.object.value.set(k, spread_val.object.value.get(k).?.retain());
                            }
                        }
                    },
                }
            }
            return obj;
        },
        .unary => |u| return self.evalUnary(env, u),
        .binary => |b| {
            // `#x in obj` (private brand check): the LHS is a bare
            // private name -- it must NOT be evaluated as an identifier
            // (that would be a ReferenceError); intercept on the node.
            if (b.op == .in and b.left.data == .identifier and b.left.data.identifier.len > 0 and b.left.data.identifier[0] == '#') {
                const r = try self.evalExpression(env, b.right);
                return JSValue.fromBool(try self.privateHas(env, r, b.left.data.identifier));
            }
            const l = try self.evalExpression(env, b.left);
            const r = try self.evalExpression(env, b.right);
            // instanceof/in need the throw machinery and the prototype
            // chain, which coercion.zig doesn't have -- intercepted
            // here, never delegated.
            switch (b.op) {
                .instanceof => return self.evalInstanceof(l, r),
                .in => return self.evalIn(l, r),
                // `coercion.binaryOp`'s own `.eq`/`.ne` cases can't do
                // ToPrimitive on an object operand (no interpreter
                // access there) -- routed through the ToPrimitive-aware
                // wrapper instead of `coercion.binaryOp`.
                .eq => return JSValue.fromBool(try self.looseEqualsJS(arena, l, r)),
                .ne => return JSValue.fromBool(!try self.looseEqualsJS(arena, l, r)),
                else => {
                    if (try self.bigintArithmetic(b.op, l, r)) |result| return result;
                    if (b.op == .add) {
                        if (try self.stringConcat(l, r)) |result| return result;
                    }
                    return try coercion.binaryOp(arena, b.op, l, r);
                },
            }
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
            // `super.x` as a plain value: lookup on the parent
            // prototype (accessor getters get the current `this` --
            // getProperty's receiver rule -- close enough for this
            // narrow phase).
            if (m.object.data == .super_expr) {
                const pk = try self.memberKeyString(env, m);
                defer pk.free(self.gc_allocator);
                // Object-literal methods (home_object) resolve their
                // home's CURRENT prototype dynamically, every access --
                // see Environment.home_object's doc comment for why this
                // differs from the class-method super_proto case just
                // below (a fixed snapshot). Checked first since the two
                // are mutually exclusive.
                if (env.resolveSuperHome()) |home| {
                    const p = home.object.value.getPrototype();
                    const sproto: JSValue = if (p) |pp| blk: {
                        const Box = @TypeOf(home.object.*);
                        const box: *Box = @fieldParentPtr("value", pp);
                        break :blk (JSValue{ .object = box }).retain();
                    } else JSValue.NULL;
                    defer sproto.deinit();
                    return try self.getProperty(sproto, pk.key);
                }
                const sproto = env.resolveSuperProto() orelse
                    return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
                return try self.getProperty(sproto, pk.key);
            }
            const obj = try self.evalExpression(env, m.object);
            if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
            if (privateMemberName(m)) |pn| return self.privateGet(env, obj, pn);
            const pk = try self.memberKeyString(env, m);
            defer pk.free(self.gc_allocator);
            return try self.getProperty(obj, pk.key);
        },
        .function_like => |ptr| return try self.makeClosure(env, zfunctions.asFunctionNode(ptr)),
        .class_like => |ptr| return try self.evalClass(env, zfunctions.asClassNode(ptr)),
        // The suspension points. The parser only produces these inside
        // generator/async bodies, which only execute on a fiber -- a
        // missing current_fiber would be an interpreter bug.
        .yield_expr => |y| {
            const fs = self.current_fiber orelse return error.NotImplemented;
            if (!fs.is_generator) return error.NotImplemented;
            if (y.delegate) return self.evalYieldDelegate(env, fs, y.argument.?);
            var value = if (y.argument) |a| try self.evalExpression(env, a) else JSValue.UNDEFINED;
            // AsyncGeneratorYield: an async generator's `yield` first
            // Awaits its operand (so `yield somePromise` yields the
            // RESOLVED value, and rejection propagates as a thrown
            // exception at the yield point) before suspending.
            if (fs.is_async) value = try self.awaitValue(fs, value);
            fs.yielded = value;
            fs.fiber.suspendSelf();
            if (fs.resume_is_throw) {
                fs.resume_is_throw = false;
                return self.throwValue(fs.resume_value);
            }
            return fs.resume_value;
        },
        .await_expr => |operand_node| {
            const fs = self.current_fiber orelse return error.NotImplemented;
            if (!fs.is_async) return error.NotImplemented;
            const operand = try self.evalExpression(env, operand_node);
            return self.awaitValue(fs, operand);
        },
        // Bare `super` outside call/member position, or super in a
        // non-method context (the call/member interceptors resolve
        // their own bindings first and raise this same error when
        // there's nothing to resolve).
        .super_expr => return self.throwError(.syntax_error, "'super' keyword unexpected here", .{}),
        .new_expr => |n| return self.evalNew(env, n),
        .regex_literal => |r| return self.makeRegex(r.pattern, r.flags),
        .bigint_literal => |raw| return self.gcNewBigInt(raw),
        // Only ever nested inside array/object-literal/call-argument
        // constructs, which unwrap `.data.spread` themselves before
        // recursing -- never reached as a standalone expression.
        .spread => unreachable,
    }
}

/// A property key that a symbol value can also produce. Symbols
/// encode to a reserved `\x00S<ptr>` string (invisible to string
/// iteration; registered for getOwnPropertySymbols); everything else
/// goes through ToString. Always returns a FRESH, caller-owned
/// allocation (even for a symbol seen before) -- `self.symbol_keys`
/// keeps its own independent copy as the map key, so the two owners
/// never alias the same buffer.
pub fn encodeKey(self: *Interpreter, value: JSValue) anyerror![]const u8 {
    if (value == .symbol) {
        const arena = self.gc_allocator;
        const key = try std.fmt.allocPrint(arena, "\x00S{x}", .{@intFromPtr(value.symbol)});
        if (!self.symbol_keys.contains(key)) {
            const stored_key = try arena.dupe(u8, key);
            try self.symbol_keys.put(arena, stored_key, value.retain());
        }
        return key;
    }
    return coercion.toDisplayString(self.gc_allocator, value);
}

/// True for the reserved symbol-key encoding -- these must stay
/// invisible to for-in / Object.keys/values/entries / JSON.
pub fn isSymbolKey(k: []const u8) bool {
    return k.len > 0 and k[0] == 0;
}

/// A property-key string that may or may not be a fresh allocation --
/// `.identifier`/literal keys are AST-borrowed (`owned = false`, must
/// NOT be freed: some consumers, e.g. `Environment.define`/`assign`,
/// store the key slice directly rather than duplicating it, so freeing
/// a borrowed one would leave a dangling map key); computed keys go
/// through `encodeKey` and ARE a fresh allocation (`owned = true`).
/// Call `.free()` unconditionally at every call site -- it's a no-op
/// for the borrowed case.
pub const PropKey = struct {
    key: []const u8,
    owned: bool,

    pub fn free(self: PropKey, allocator: Allocator) void {
        if (self.owned) allocator.free(self.key);
    }
};

pub fn memberKeyString(self: *Interpreter, env: *Environment, m: anytype) anyerror!PropKey {
    if (m.computed) {
        // NOT `defer k.deinit()`: evalExpression's ownership isn't
        // uniform -- an `.identifier` read returns the binding's
        // value BORROWED (env.lookup's `.value` case, no retain;
        // see evalExpression's own `.identifier` arm), while other
        // node kinds (literals, calls, getProperty reads) return an
        // owned value. Releasing unconditionally here double-frees
        // the extremely common `obj[someVar]` case (refcount
        // underflow, confirmed via Test262 nested for-in crash).
        const k = try self.evalExpression(env, m.property);
        return .{ .key = try self.encodeKey(k), .owned = true };
    }
    return switch (m.property.data) {
        .identifier => |name| .{ .key = name, .owned = false },
        else => error.NotImplemented,
    };
}

/// Same borrowed/owned contract as `memberKeyString`.
pub fn propertyKeyString(self: *Interpreter, env: *Environment, computed: bool, key: *zparser.Node) anyerror!PropKey {
    if (computed) {
        const v = try self.evalExpression(env, key);
        return .{ .key = try self.encodeKey(v), .owned = true };
    }
    return switch (key.data) {
        .identifier => |name| .{ .key = name, .owned = false },
        .string_literal => |s| .{ .key = s, .owned = false },
        .number_literal => |n| .{ .key = try znumber.FormattingMethods.toString(n, self.gc_allocator, null), .owned = true },
        else => error.NotImplemented,
    };
}


/// ECMA-262 13.10.2 InstanceofOperator, narrowed (no
/// Symbol.hasInstance): walk the LHS object's prototype chain looking
/// for the RHS function's prototype object, by pointer identity.
pub fn evalInstanceof(self: *Interpreter, l: JSValue, r: JSValue) anyerror!JSValue {
    // Best-effort unwrap, not a real Symbol.hasInstance trap dispatch
    // (that protocol doesn't exist in this engine at all yet, for
    // plain functions either -- pre-existing narrowing, not new).
    if (r == .proxy) return self.evalInstanceof(l, r.proxy.value.target);
    if (r != .function) {
        return self.throwError(.type_error, "Right-hand side of 'instanceof' is not callable", .{});
    }

    // Every error kind (TypeError/RangeError/.../URIError) shares ONE
    // prototype object (self.protos.@"error") -- each kind's OWN
    // `X.prototype` is still a real, separate, lazily-materialized
    // object (for property-descriptor purposes), but it's chained to
    // Object.prototype, not to self.protos.@"error". So the generic
    // chain walk below can only ever prove "instanceof Error", never
    // "instanceof TypeError" specifically -- checked here instead, by
    // identity against the value's own kind's global constructor (the
    // same trick getProperty's `.constructor` resolution already uses).
    // Falls through to the walk below for the generic Error case.
    if (l == .@"error") {
        if (self.global_env.get(l.@"error".value.kind.name())) |own_ctor| {
            if (zvalue.equality.strictEquals(own_ctor, r)) return JSValue.fromBool(true);
        }
    }

    // A never-touched prototype slot means this function never
    // constructed anything -- nothing can be an instance of it.
    const proto = r.function.value.prototype orelse return JSValue.fromBool(false);
    if (proto != .object) return JSValue.fromBool(false);
    // These boxed kinds have exactly one shared method-table prototype
    // each (no user-settable [[Prototype]] chain of their own, no
    // subclassing) -- the chain walk starts directly at the kind's
    // shared prototype object (materializeProtos already wires each of
    // these to be the SAME object as the matching global constructor's
    // `.prototype`) instead of "the instance's own prototype" like the
    // `.object` case below.
    var current: ?*const zobject.ZObject(JSValue) = switch (l) {
        .object => l.object.value.getPrototype(),
        .typed_array => |box| &self.typedArrayProto(box.value.kind).object.value,
        .array => &self.protos.array.object.value,
        .date => &self.protos.date.object.value,
        .regex => &self.protos.regex.object.value,
        .function => &self.protos.function.object.value,
        .map => &self.protos.map.object.value,
        .set => &self.protos.set.object.value,
        .promise => &self.protos.promise.object.value,
        .array_buffer => &self.protos.array_buffer.object.value,
        .data_view => &self.protos.data_view.object.value,
        .@"error" => &self.protos.@"error".object.value,
        .temporal => |box| &self.protos.temporalProtoFor(box.value).object.value,
        else => return JSValue.fromBool(false), // primitives are never instances
    };
    while (current) |p| : (current = p.getPrototype()) {
        if (p == &proto.object.value) return JSValue.fromBool(true);
    }
    return JSValue.fromBool(false);
}

/// The `in` operator: property existence including the prototype chain
/// (ZObject.has already walks it). Arrays support numeric indices and
/// "length"; primitives are a real spec TypeError; map/set/etc are
/// objects in real JS but have no property model here yet.
pub fn evalIn(self: *Interpreter, l: JSValue, r: JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    // ToPropertyKey, not ToDisplayString: `Symbol.iterator in arr` must
    // resolve the same key encoding `arr[Symbol.iterator]` would (see
    // `encodeKey`) -- a Symbol left-hand side isn't stringified at all
    // in real spec.
    const key = try self.encodeKey(l);
    defer arena.free(key);
    return switch (r) {
        .object => |box| JSValue.fromBool(box.value.has(key)),
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromBool(true);
            const idx = std.fmt.parseInt(usize, key, 10) catch break :blk JSValue.fromBool(false);
            break :blk JSValue.fromBool(idx < box.value.length());
        },
        // `key` is the raw `\x00S<ptr>` encoding when `l` is a symbol --
        // display the real "Symbol(desc)" form in the message instead
        // of leaking that internal encoding to user-visible text.
        .@"undefined", .@"null", .boolean, .number, .string => if (l == .symbol)
            self.throwError(.type_error, "Cannot use 'in' operator to search for 'Symbol({s})'", .{l.symbol.value.description orelse ""})
        else
            self.throwError(.type_error, "Cannot use 'in' operator to search for '{s}'", .{key}),
        // has(target, property) -- ToBoolean-coerced.
        .proxy => |box| blk: {
            if (try self.proxyTrap(box, "has")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val });
                defer result.deinit();
                break :blk JSValue.fromBool(coercion.isTruthy(result));
            }
            break :blk try self.evalIn(l, box.value.target);
        },
        .function, .regex, .symbol, .map, .set, .@"error", .date, .promise, .bigint, .array_buffer, .data_view, .typed_array, .temporal => error.NotImplemented,
    };
}


pub fn evalUnary(self: *Interpreter, env: *Environment, u: anytype) anyerror!JSValue {
    switch (u.op) {
        .not => return JSValue.fromBool(!coercion.isTruthy(try self.evalExpression(env, u.operand))),
        .minus => {
            const v = try self.evalExpression(env, u.operand);
            if (v == .bigint) return try self.gcNewBigIntValue(try v.bigint.value.negate());
            return JSValue.fromNumber(-(try self.toNumberJS(v)));
        },
        .plus => {
            // Real spec: unary `+` is ALWAYS a ToNumber, and
            // ToNumber(bigint) is itself a TypeError -- unlike
            // explicit `Number(1n)` (a different, permissive
            // conversion), so this can't just delegate to
            // coercion.toNumber (which intentionally allows the
            // explicit-conversion case).
            const v = try self.evalExpression(env, u.operand);
            if (v == .bigint) return self.throwError(.type_error, "Cannot convert a BigInt value to a number", .{});
            return JSValue.fromNumber(try self.toNumberJS(v));
        },
        .typeof => {
            // typeof on an undeclared identifier is "undefined", not a
            // ReferenceError -- a real, deliberate spec quirk. But a
            // TDZ binding still throws (`typeof x; let x;` is the real
            // ReferenceError).
            if (u.operand.data == .identifier) {
                const name = u.operand.data.identifier;
                switch (env.lookup(name)) {
                    .value => |v| return try self.gcNewString(v.typeOf()),
                    .tdz => return self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
                    .not_found => return try self.gcNewString("undefined"),
                }
            }
            const v = try self.evalExpression(env, u.operand);
            return try self.gcNewString(v.typeOf());
        },
        .void_op => {
            _ = try self.evalExpression(env, u.operand);
            return JSValue.UNDEFINED;
        },
        .pre_inc, .pre_dec => {
            const old = try self.evalExpression(env, u.operand);
            const new_val = try self.incDecOne(old, u.op == .pre_inc);
            try self.assignTo(env, u.operand, new_val);
            return new_val;
        },
        .post_inc, .post_dec => {
            const old = try self.evalExpression(env, u.operand);
            const new_val = try self.incDecOne(old, u.op == .post_inc);
            try self.assignTo(env, u.operand, new_val);
            // Real spec: the EXPRESSION's value is `old` already
            // ToNumeric'd, not the raw pre-coercion operand (e.g.
            // `let x = "1"; x++` evaluates to the number 1, not the
            // string "1"). For bigint, a fresh independently-owned
            // box holding the same value -- `old`'s own box's
            // ownership (borrowed vs retained) depends on what kind
            // of expression `u.operand` was, same pre-existing
            // non-uniformity `evalExpression` has everywhere else in
            // this engine, so it's left untouched rather than
            // guessed at; this returns a value of its own instead of
            // trying to share `old`'s.
            return if (old == .bigint) try self.gcNewBigIntValue(try old.bigint.value.clone()) else JSValue.fromNumber(try coercion.toNumber(old));
        },
        .bitnot => {
            const v = try self.evalExpression(env, u.operand);
            if (v == .bigint) return try self.gcNewBigIntValue(try zbigint.ZBigInt.not(self.gc_allocator, v.bigint.value));
            const n = try coercion.toInt32(v);
            return JSValue.fromNumber(@floatFromInt(~n));
        },
        .delete => {
            // Always-strict delete: unqualified identifiers are the
            // real SyntaxError; member deletion enforces
            // configurable; anything else evaluates and yields true.
            if (u.operand.data == .identifier) {
                return self.throwError(.syntax_error, "Delete of an unqualified identifier in strict mode.", .{});
            }
            if (u.operand.data == .member) {
                const m = u.operand.data.member;
                // `delete this.#x` is a spec EARLY error; surfaced at
                // runtime here (narrowing -- no static private scope).
                if (privateMemberName(m)) |pn| {
                    return self.throwError(.syntax_error, "Private fields can not be deleted: {s}", .{pn});
                }
                const obj = try self.evalExpression(env, m.object);
                const pk = try self.memberKeyString(env, m);
                defer pk.free(self.gc_allocator);
                return JSValue.fromBool(try self.deletePropertyOnValue(obj, pk.key));
            }
            _ = try self.evalExpression(env, u.operand);
            return JSValue.fromBool(true);
        },
    }
}

pub fn evalAssignment(self: *Interpreter, env: *Environment, a: anytype) anyerror!JSValue {
    if (a.op == .assign) {
        const value = try self.evalExpression(env, a.value);
        switch (a.target.data) {
            // Cover-grammar reinterpretation: the literal IS the
            // pattern. The expression's own value stays the RHS
            // (`([a] = [7])[0]` is 7), per spec.
            .array_literal, .object_literal => try self.destructuringAssign(env, a.target, value),
            else => try self.assignTo(env, a.target, value),
        }
        // NamedEvaluation: `x = AnonFn` names the function/class "x" --
        // real spec gates this on IsIdentifierRef(LeftHandSideExpression),
        // i.e. only a bare identifier target (`obj.x = () => {}` does NOT
        // get named "x").
        if (a.target.data == .identifier) {
            try self.maybeNameAnonymousValue(a.value, value, a.target.data.identifier);
        }
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
            const bop = compoundToBinary(a.op);
            const result = blk: {
                if (try self.bigintArithmetic(bop, current, rhs)) |r| break :blk r;
                if (bop == .add) {
                    if (try self.stringConcat(current, rhs)) |r| break :blk r;
                }
                break :blk try coercion.binaryOp(self.gc_allocator, bop, current, rhs);
            };
            try self.assignTo(env, a.target, result);
            return result;
        },
    }
}

pub fn assignTo(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
    switch (target.data) {
        // env.assign takes ownership -- retain, matching bindPattern's
        // convention (the caller keeps its own reference to `value`).
        .identifier => |name| env.assign(name, value.retain()) catch |err| return switch (err) {
            error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name}),
            error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name}),
        },
        .paren => |inner| try self.assignTo(env, inner, value),
        .member => |m| {
            const obj = try self.evalExpression(env, m.object);
            if (privateMemberName(m)) |pn| return self.privateSet(env, obj, pn, value);
            const pk = try self.memberKeyString(env, m);
            defer pk.free(self.gc_allocator);
            return self.setPropertyOnValue(obj, pk.key, value);
        },
        else => return error.NotImplemented,
    }
}

pub fn evalCall(self: *Interpreter, env: *Environment, c: anytype) anyerror!JSValue {
    const arena = self.gc_allocator;
    // `super(args)`: the parent constructor invoked with the CURRENT
    // `this` (the instance under construction), armed as a
    // construction so the parent's without-new check passes.
    if (c.callee.data == .super_expr) {
        const sctor = env.resolveSuperCtor() orelse
            return self.throwError(.syntax_error, "'super' keyword unexpected here", .{});
        const args = try self.evalArgs(env, c.args);
        defer self.gc_allocator.free(args);
        const prev_target = self.construct_target;
        self.construct_target = sctor.function.value.ctx;
        defer self.construct_target = prev_target;
        const result = try sctor.function.value.call(sctor.function.value.ctx, arena, env.resolveThis(), args);
        // The derived class's own instance fields initialize exactly
        // when super() returns (spec order: parent fields ran during
        // the parent ctor; own fields now; rest of the body after).
        if (self.pending_field_init) |p| {
            self.pending_field_init = null;
            const pc: *ClassCtx = @ptrCast(@alignCast(p));
            try self.runInstanceFields(pc, env.resolveThis());
        }
        return result;
    }
    // `super.m(args)`: method looked up on the PARENT prototype but
    // invoked with the current `this` -- the whole point of super.
    if (c.callee.data == .member and c.callee.data.member.object.data == .super_expr) {
        const m = c.callee.data.member;
        const pk = try self.memberKeyString(env, m);
        defer pk.free(self.gc_allocator);
        // Same home_object-first resolution as the `.member` GET case
        // above (see its own comment for why) -- duplicated here rather
        // than shared because this branch also needs the method value
        // itself (to validate callability) before invoking with the
        // enclosing `this`, not the prototype.
        const sproto: JSValue = blk: {
            if (env.resolveSuperHome()) |home| {
                const p = home.object.value.getPrototype();
                break :blk if (p) |pp| inner: {
                    const Box = @TypeOf(home.object.*);
                    const box: *Box = @fieldParentPtr("value", pp);
                    break :inner (JSValue{ .object = box }).retain();
                } else JSValue.NULL;
            }
            break :blk (env.resolveSuperProto() orelse
                return self.throwError(.syntax_error, "'super' keyword unexpected here", .{})).retain();
        };
        defer sproto.deinit();
        const method = try self.getProperty(sproto, pk.key);
        if (method != .function) {
            return self.throwError(.type_error, "(intermediate value).{s} is not a function", .{pk.key});
        }
        const args = try self.evalArgs(env, c.args);
        defer self.gc_allocator.free(args);
        return try method.function.value.call(method.function.value.ctx, arena, env.resolveThis(), args);
    }
    var this_value: JSValue = JSValue.UNDEFINED;
    var callee_val: JSValue = undefined;
    if (c.callee.data == .member) {
        const m = c.callee.data.member;
        const obj = try self.evalExpression(env, m.object);
        if (m.optional and (obj == .@"undefined" or obj == .@"null")) return JSValue.UNDEFINED;
        this_value = obj;
        if (privateMemberName(m)) |pn| {
            // `this.#m(args)` -- private method/field call, `this`
            // preserved like any member call.
            callee_val = try self.privateGet(env, obj, pn);
        } else {
            const pk = try self.memberKeyString(env, m);
            defer pk.free(self.gc_allocator);
            callee_val = try self.getProperty(obj, pk.key);
        }
    } else {
        callee_val = try self.evalExpression(env, c.callee);
    }
    if (c.optional and (callee_val == .@"undefined" or callee_val == .@"null")) return JSValue.UNDEFINED;
    // Best-effort callee name for the "is not a function" message --
    // no expression printer, just the two cheap cases. Needed both
    // for the immediate check below AND (a no-trap proxy chain whose
    // target still isn't callable) inside callValue's own recursion.
    const callee_name: []const u8 = switch (c.callee.data) {
        .identifier => |name| name,
        .member => |m| if (!m.computed and m.property.data == .identifier) m.property.data.identifier else "expression",
        else => "expression",
    };
    if (callee_val != .function and callee_val != .proxy) {
        return self.throwError(.type_error, "{s} is not a function", .{callee_name});
    }

    const args = try self.evalArgs(env, c.args);
        defer self.gc_allocator.free(args);
    // Direct eval: a call written literally as `eval(...)` where `eval`
    // still refers to the intrinsic runs its string argument in the
    // CURRENT scope (always-strict -> a child of it). Any other reference
    // to eval (aliased, member access) is indirect and runs the global
    // native below. Guarded on .function first -- callee_val.function
    // is a union field access, unsafe to touch when callee_val is
    // actually .proxy (a proxy is never literally the eval intrinsic).
    if (callee_val == .function) {
        if (self.eval_fn) |ev| {
            if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier, "eval") and callee_val.function == ev.function) {
                if (args.len == 0) return JSValue.UNDEFINED;
                if (args[0] != .string) return args[0].retain();
                return self.evalSource(env, args[0].string.value.data);
            }
        }
    }
    return try self.callValue(callee_val, this_value, args, callee_name);
}

/// Invokes `callee` (`.function` or `.proxy`, recursively unwrapping
/// nested proxies) with `this_value`/`args` -- the tail of every
/// plain function call, and a Proxy's `apply` trap dispatch (or its
/// no-trap fallback: delegate to target directly). Only ever called
/// with a callee already confirmed to be one of those two tags.
/// `callee_name` is only used for the "is not a function" message a
/// no-trap proxy chain can still hit if its target (transitively)
/// isn't callable -- e.g. `(new Proxy({}, {}))()`.
pub fn callValue(self: *Interpreter, callee: JSValue, this_value: JSValue, args: []const JSValue, callee_name: []const u8) anyerror!JSValue {
    if (callee == .proxy) {
        const box = callee.proxy;
        if (try self.proxyTrap(box, "apply")) |trap_fn| {
            defer trap_fn.deinit();
            const args_array = try self.argsToArray(args);
            defer args_array.deinit();
            return try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, this_value, args_array });
        }
        return self.callValue(box.value.target, this_value, args, callee_name);
    }
    if (callee != .function) return self.throwError(.type_error, "{s} is not a function", .{callee_name});
    return try callee.function.value.call(callee.function.value.ctx, self.gc_allocator, this_value, args);
}

pub fn evalArgs(self: *Interpreter, env: *Environment, arg_nodes: []const *zparser.Node) anyerror![]const JSValue {
    const arena = self.gc_allocator;
    var args: std.ArrayList(JSValue) = .empty;
    for (arg_nodes) |arg_node| {
        if (arg_node.data == .spread) {
            const spread_val = try self.evalExpression(env, arg_node.data.spread);
            const items = try self.iterableItems(spread_val);
            defer arena.free(items);
            for (items) |item| try args.append(arena, item.retain());
        } else {
            try args.append(arena, try self.evalExpression(env, arg_node));
        }
    }
    return args.toOwnedSlice(arena);
}

/// ECMA-262 10.2.2 [[Construct]], narrowed: fresh object wired to
/// F.prototype, constructor called with it as `this`, and an
/// object-like return value overrides the instance (a primitive
/// return is ignored -- the real rule). Delegates entirely to
/// `constructValue` (below), which also handles a Proxy `construct`
/// trap (or its no-trap fallback: delegate to target's own
/// [[Construct]]) recursively through nested proxies.
pub fn evalNew(self: *Interpreter, env: *Environment, n: anytype) anyerror!JSValue {
    const callee = try self.evalExpression(env, n.callee);
    const callee_name: []const u8 = switch (n.callee.data) {
        .identifier => |name| name,
        else => "expression",
    };
    // `new Foo` with no parens at all (args == null) is `new Foo()`.
    const args = try self.evalArgs(env, n.args orelse &.{});
    defer self.gc_allocator.free(args);
    return self.constructValue(callee, args, callee_name);
}

/// ECMA-262 IsConstructor: does `v` implement [[Construct]]? Unwraps
/// proxies to their target (a Proxy is a constructor iff its target
/// is, regardless of whether a `construct` trap is present).
pub fn isConstructor(self: *Interpreter, v: JSValue) bool {
    return switch (v) {
        .function => |f| f.value.constructable,
        .proxy => |p| self.isConstructor(p.value.target),
        else => false,
    };
}

pub fn constructValue(self: *Interpreter, callee: JSValue, args: []const JSValue, callee_name: []const u8) anyerror!JSValue {
    if (callee == .proxy) {
        const box = callee.proxy;
        if (try self.proxyTrap(box, "construct")) |trap_fn| {
            defer trap_fn.deinit();
            const args_array = try self.argsToArray(args);
            defer args_array.deinit();
            return try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, args_array, callee });
        }
        return self.constructValue(box.value.target, args, callee_name);
    }
    if (callee != .function or !callee.function.value.constructable) {
        return self.throwError(.type_error, "{s} is not a constructor", .{callee_name});
    }
    const proto = try self.functionPrototype(callee);
    var instance = try self.gcNewObject();
    try instance.object.value.setPrototype(&proto.object.value);
    // Arm the construct token for exactly this call -- see the field
    // doc on `construct_target`.
    const prev_target = self.construct_target;
    self.construct_target = callee.function.value.ctx;
    defer self.construct_target = prev_target;
    const result = try callee.function.value.call(callee.function.value.ctx, self.gc_allocator, instance, args);
    return switch (result) {
        .object, .array, .function, .regex, .map, .set, .@"error", .date, .promise, .proxy, .array_buffer, .data_view, .typed_array, .temporal => result,
        else => instance,
    };
}


/// A non-computed member access whose property name starts with '#' can
/// only have come from `.#name` syntax (ordinary identifiers can't contain
/// '#') -- it denotes PRIVATE member access. Computed `obj["#x"]` remains a
/// normal string-keyed property, per spec.
fn privateMemberName(m: anytype) ?[]const u8 {
    if (m.computed) return null;
    if (m.property.data != .identifier) return null;
    const n = m.property.data.identifier;
    if (n.len > 0 and n[0] == '#') return n;
    return null;
}

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

