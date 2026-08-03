//! Step 5 Phase C batch 5: the propaccess+protos cluster --
//! property get/set/delete dispatch by receiver type, and materializing
//! the builtin prototype objects. Split out of interpreter.zig; see
//! z-interpreter-refactor.md.

const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const coercion = @import("coercion.zig");
const builtins = @import("builtins.zig");
const native_helpers = @import("native_helpers.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;

pub fn getProperty(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!JSValue {
    return switch (obj) {
        // Own-then-chain walk over property *records* (not values), so
        // accessor properties dispatch: a getter is invoked with
        // this = the original receiver (not the prototype that holds
        // it), a setter-only accessor reads as undefined. Data
        // properties behave exactly as the old ZObject.get did.
        .object => |box| blk: {
            const arena = self.gc_allocator;
            // `globalThis`: a global binding (Object, a top-level `var`,
            // ...) shadows its own props; a miss falls through to the
            // normal own->chain walk (defineProperty'd props, then
            // Object.prototype methods). Top-level `var`/function names
            // live in global_var_env (a child of global_env, kept
            // separate so `let console = 5` can shadow the builtin) --
            // its `.get` walks its own parent chain, so this still finds
            // global_env's builtins too; must start from global_var_env,
            // not global_env directly, or every script-level var/function
            // would be invisible through globalThis (confirmed against
            // real Node this must resolve, e.g. `var x=1; globalThis.x
            // === 1`).
            if (self.global_object) |go| {
                if (obj.object == go.object) {
                    const lookup_env = self.global_var_env orelse self.global_env;
                    if (lookup_env.get(key)) |v| break :blk v.retain();
                }
            }
            var current: ?*const @TypeOf(box.value) = &box.value;
            while (current) |o| : (current = o.getPrototype()) {
                const rec = o.getOwnRecord(key) orelse continue;
                if (rec.isAccessor()) {
                    const g = rec.getter orelse break :blk JSValue.UNDEFINED;
                    break :blk try g.function.value.call(g.function.value.ctx, arena, obj, &.{});
                }
                break :blk rec.value.retain();
            }
            // Chain miss: ordinary objects chain to the real
            // Object.prototype (which carries hasOwnProperty & co as own
            // properties), so a genuine miss here is `undefined`. Objects
            // with a null prototype (Object.create(null)) correctly
            // inherit nothing.
            break :blk JSValue.UNDEFINED;
        },
        .array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.length()));
            const idx = std.fmt.parseInt(usize, key, 10) catch {
                // Method (via Array.prototype) or a named own property
                // (exec-result index/input/groups); else undefined.
                if (try self.getFromProto(obj, self.protos.array, key)) |m| break :blk m;
                break :blk (self.arrayExtra(obj, key) orelse JSValue.UNDEFINED).retain();
            };
            if (idx >= box.value.length()) break :blk JSValue.UNDEFINED;
            break :blk box.value.get(idx).retain();
        },
        .string => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.data.len));
            if (std.fmt.parseInt(usize, key, 10)) |idx| {
                // Indexed access: the one-char string at that position,
                // or undefined past the end (real JS string indexing).
                if (idx < box.value.data.len) break :blk try self.gcNewString(box.value.data[idx .. idx + 1]);
                break :blk JSValue.UNDEFINED;
            } else |_| {}
            if (try self.getFromProto(obj, self.protos.string, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // `catch (e) { console.log(e.message) }` is the most common
        // catch body in existence -- name/message are read-only views
        // over ZError's existing fields.
        .@"error" => |box| blk: {
            if (std.mem.eql(u8, key, "name")) break :blk try self.gcNewString(box.value.kind.name());
            if (std.mem.eql(u8, key, "message")) break :blk try self.gcNewString(box.value.message);
            // `thrown.constructor === TypeError` -- what Test262's
            // assert.throws actually compares. Same function identity
            // every time: the global binding for this kind's name.
            if (std.mem.eql(u8, key, "constructor")) {
                break :blk (self.global_env.get(box.value.kind.name()) orelse JSValue.UNDEFINED).retain();
            }
            if (try self.getFromProto(obj, self.protos.@"error", key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .function => |box| blk: {
            // functionPrototype() returns a borrow of Callable.prototype's
            // own reference (matching every other branch here, which all
            // retain before returning -- necessary now that
            // Callable.deinit() actually releases .prototype). Gated on
            // constructability (same condition objectGetOwnPropertyDescriptor
            // already uses for this exact key) -- a non-constructable
            // function (native methods, arrows, ...) has NO `.prototype`
            // at all per real spec, confirmed against Node:
            // `Function.prototype.toString.prototype === undefined`,
            // `(() => {}).prototype === undefined`. Materializing one
            // unconditionally here was also a second bug: it made
            // hasOwnProperty(fn, "prototype") flip to true right after
            // the first plain read, since that check ORs in
            // `prototype != null`.
            if (std.mem.eql(u8, key, "prototype")) {
                if (box.value.prototype) |p| break :blk p.retain();
                if (!box.value.constructable) break :blk JSValue.UNDEFINED;
                break :blk (try self.functionPrototype(obj)).retain();
            }
            // The statics bag (class statics, F.myProp = 1) shadows
            // the Function.prototype methods, like an own property
            // would. Recursing through getProperty gives accessor
            // dispatch and -- because class bags chain to the
            // parent's bag -- static inheritance. Narrowing: a static
            // getter's `this` is the bag, not the class function, so
            // `this.otherStatic` works but `this === C` doesn't.
            //
            // Checked BEFORE the name/length fallbacks below: real
            // spec's `.name`/`.length` are configurable own data
            // properties, so an explicit `static name(){}` (installed
            // via DefineMethod, which overwrites the auto-created own
            // property) or a direct `fn.name = "x"` (routed into this
            // same bag by setPropertyOnValue) must win over the
            // Callable-struct-backed default.
            if (box.value.statics) |bag| {
                if (bag.object.value.has(key)) break :blk try self.getProperty(bag, key);
            }
            if (std.mem.eql(u8, key, "name")) break :blk try self.gcNewString(box.value.name);
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.arity));
            if (try self.getFromProto(obj, self.protos.function, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .number => blk: {
            if (try self.getFromProto(obj, self.protos.number, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .boolean => blk: {
            if (try self.getFromProto(obj, self.protos.boolean, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .date => blk: {
            if (try self.getFromProto(obj, self.protos.date, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .bigint => blk: {
            if (try self.getFromProto(obj, self.protos.bigint, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .temporal => |box| blk: {
            const proto = self.protos.temporalProtoFor(box.value);
            if (try self.getFromProto(obj, proto, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // get(target, property, receiver) -- receiver is the proxy
        // itself, not the target (matters when the trap forwards via
        // Reflect.get(target, property, receiver) for correct `this`
        // binding on inherited accessors -- narrowing: this engine's
        // Reflect.get, once it exists, ignores the receiver arg like
        // getFromProto already does elsewhere).
        .proxy => |box| blk: {
            if (try self.proxyTrap(box, "get")) |trap_fn| {
                defer trap_fn.deinit();
                const key_val = try self.gcNewString(key);
                defer key_val.deinit();
                break :blk try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val, obj });
            }
            break :blk try self.getProperty(box.value.target, key);
        },
        .promise => blk: {
            if (try self.getFromProto(obj, self.protos.promise, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .map => |box| blk: {
            if (std.mem.eql(u8, key, "size")) break :blk JSValue.fromNumber(@floatFromInt(box.value.size()));
            if (try self.getFromProto(obj, self.protos.map, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .set => |box| blk: {
            if (std.mem.eql(u8, key, "size")) break :blk JSValue.fromNumber(@floatFromInt(box.value.size()));
            if (try self.getFromProto(obj, self.protos.set, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // `.byteLength` is a real spec ACCESSOR property (no parens),
        // computed here rather than stored -- same category as
        // array/string's own special-cased `.length`.
        .array_buffer => |box| blk: {
            if (std.mem.eql(u8, key, "byteLength")) break :blk JSValue.fromNumber(@floatFromInt(box.value.byteLength()));
            if (try self.getFromProto(obj, self.protos.array_buffer, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // `.buffer`/`.byteOffset`/`.byteLength` are all real spec
        // accessor properties. `.buffer` returns the SAME `.array_buffer`
        // JSValue this view was constructed over (retained) -- real JS:
        // `dv.buffer === buf`.
        .data_view => |box| blk: {
            if (std.mem.eql(u8, key, "buffer")) break :blk box.value.owner.retain();
            if (std.mem.eql(u8, key, "byteOffset")) break :blk JSValue.fromNumber(@floatFromInt(box.value.view.byte_offset));
            if (std.mem.eql(u8, key, "byteLength")) break :blk JSValue.fromNumber(@floatFromInt(box.value.view.byte_length));
            if (try self.getFromProto(obj, self.protos.data_view, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // Integer-indexed exotic access: a canonical numeric index
        // out of `[0,len)` reads as `undefined` (real spec) --
        // NEVER falls through to the prototype chain like a plain
        // object's missing numeric-string key would.
        .typed_array => |box| blk: {
            if (std.mem.eql(u8, key, "length")) break :blk JSValue.fromNumber(@floatFromInt(box.value.len));
            if (std.mem.eql(u8, key, "buffer")) break :blk box.value.owner.retain();
            if (std.mem.eql(u8, key, "byteOffset")) break :blk JSValue.fromNumber(@floatFromInt(box.value.byte_offset));
            if (std.mem.eql(u8, key, "byteLength")) break :blk JSValue.fromNumber(@floatFromInt(box.value.len * box.value.kind.elemSize()));
            if (std.fmt.parseInt(usize, key, 10)) |idx| {
                if (idx >= box.value.len) break :blk JSValue.UNDEFINED;
                break :blk try builtins.typedElemGet(self, box.value.kind, &box.value.owner.array_buffer.value, box.value.byte_offset, box.value.len, idx);
            } else |_| {}
            if (try self.getFromProto(obj, self.typedArrayProto(box.value.kind), key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .symbol => |box| blk: {
            if (std.mem.eql(u8, key, "description")) {
                break :blk if (box.value.description) |d| try self.gcNewString(d) else JSValue.UNDEFINED;
            }
            if (try self.getFromProto(obj, self.protos.symbol, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        .regex => blk: {
            const st = self.regexState(obj);
            if (std.mem.eql(u8, key, "source")) break :blk try self.gcNewString(st.source);
            // Real spec: `.flags` is a COMPUTED property, canonical
            // fixed order (d,g,i,m,s,u,v,y) -- NOT a passthrough of the
            // source text's own flag order (confirmed against real
            // Node: `/x/yusmigd`.flags === "dgimsuy", not "yusmigd").
            if (std.mem.eql(u8, key, "flags")) {
                var buf: [8]u8 = undefined;
                break :blk try self.gcNewString(Interpreter.canonicalFlags(st, &buf));
            }
            if (std.mem.eql(u8, key, "global")) break :blk JSValue.fromBool(st.global);
            if (std.mem.eql(u8, key, "ignoreCase")) break :blk JSValue.fromBool(st.ignore_case);
            if (std.mem.eql(u8, key, "multiline")) break :blk JSValue.fromBool(st.multiline);
            if (std.mem.eql(u8, key, "dotAll")) break :blk JSValue.fromBool(st.dot_all);
            if (std.mem.eql(u8, key, "sticky")) break :blk JSValue.fromBool(st.sticky);
            if (std.mem.eql(u8, key, "unicode")) break :blk JSValue.fromBool(st.unicode);
            if (std.mem.eql(u8, key, "hasIndices")) break :blk JSValue.fromBool(st.has_indices);
            if (std.mem.eql(u8, key, "unicodeSets")) break :blk JSValue.fromBool(st.unicode_sets);
            if (std.mem.eql(u8, key, "lastIndex")) break :blk JSValue.fromNumber(@floatFromInt(st.last_index));
            if (try self.getFromProto(obj, self.protos.regex, key)) |m| break :blk m;
            break :blk JSValue.UNDEFINED;
        },
        // Spec says TypeError here (not ReferenceError). The optional
        // chaining guards short-circuit BEFORE getProperty, so `a?.b`
        // on null still yields undefined without ever reaching this.
        .@"undefined", .@"null" => self.throwError(.type_error, "Cannot read properties of {s} (reading '{s}')", .{ if (obj == .@"null") "null" else "undefined", key }),
    };
}


/// Writing to an array: numeric indices (grow with undefined holes
/// past the end -- narrowing vs true sparse arrays) and `length`
/// (truncate/extend). Any other key is NotImplemented (arrays have no
/// general property bag here).
pub fn setArrayProperty(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
    _ = self;
    const arr = &obj.array.value;
    if (std.mem.eql(u8, key, "length")) {
        const n = try coercion.toUint32(value);
        const cur = arr.length();
        if (n < cur) {
            var i = cur;
            while (i > n) : (i -= 1) {
                if (arr.pop()) |v| v.deinit();
            }
        } else {
            var i = cur;
            while (i < n) : (i += 1) _ = try arr.push(JSValue.UNDEFINED);
        }
        return;
    }
    const idx = std.fmt.parseInt(usize, key, 10) catch return error.NotImplemented;
    const cur = arr.length();
    if (idx < cur) {
        arr.toSliceMut()[idx].deinit();
        arr.toSliceMut()[idx] = value.retain();
    } else {
        var i = cur;
        while (i < idx) : (i += 1) _ = try arr.push(JSValue.UNDEFINED);
        _ = try arr.push(value.retain());
    }
}

/// Integer-indexed exotic [[Set]]: a canonical numeric index writes
/// through `typedElemSet` (which itself coerces the value BEFORE
/// checking bounds and silently no-ops if out of range -- matches
/// real spec exactly, verified against real Node). Any other key is
/// `error.NotImplemented`, same narrowing `setArrayProperty` already
/// has for arrays (no general property bag).
pub fn setTypedArrayProperty(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
    const box = obj.typed_array;
    const idx = std.fmt.parseInt(usize, key, 10) catch return error.NotImplemented;
    try builtins.typedElemSet(self, box.value.kind, &box.value.owner.array_buffer.value, box.value.byte_offset, box.value.len, idx, value);
}

/// [[Set]] on an `.object` JSValue with accessor dispatch: a setter
/// anywhere on the chain is invoked with this = the receiver; a
/// getter-only accessor swallows the write silently (sloppy-mode
/// [[Set]]); the first *data* record found stops the walk and the
/// write shadows it as an own property, exactly like real JS.
pub fn setObjectProperty(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
    var current: ?*const @TypeOf(obj.object.value) = &obj.object.value;
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const s = rec.setter orelse return; // getter-only: silent no-op
            _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
            return;
        }
        break;
    }
    // Always-strict [[Set]] failures are real TypeErrors, not raw
    // Zig errors (the descriptor flags finally bite here).
    // getOwn (NOT get): get() walks the prototype chain, which would
    // capture an INHERITED value here and wrongly release something
    // the prototype object still owns -- set() only ever touches own
    // properties, so the displaced value must come from getOwn().
    const old = obj.object.value.getOwn(key);
    obj.object.value.set(key, value.retain()) catch |err| return switch (err) {
        error.PropertyNotWritable => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
        error.ObjectIsFrozen => self.throwError(.type_error, "Cannot assign to read only property '{s}' of object", .{key}),
        error.ObjectNotExtensible => self.throwError(.type_error, "Cannot add property {s}, object is not extensible", .{key}),
        else => err,
    };
    // The property write above just overwrote (or shadowed) whatever
    // was there -- release the value it displaced (ZObject.set doesn't
    // know about JSValue/refcounting, so this is the interpreter's job).
    if (old) |o| o.deinit();
}

/// Deletes `obj`'s own `key`, releasing the displaced value/getter/
/// setter (ZObject.delete() frees the key string but knows nothing
/// about JSValue/refcounting). ALWAYS returns true on this path --
/// matches real spec [[Delete]]: removing a missing key is still a
/// "successful" delete; the only failure case (non-configurable/
/// frozen) throws instead of returning false, same as before this
/// was factored out of `evalUnary`'s `.delete` case (now shared with
/// a Proxy's `deleteProperty` trap fallback, when absent).
pub fn deleteObjectProperty(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!bool {
    const old_rec = obj.object.value.getOwnRecord(key);
    const old_value = if (old_rec) |r| r.value else null;
    const old_getter = if (old_rec) |r| r.getter else null;
    const old_setter = if (old_rec) |r| r.setter else null;
    const removed = obj.object.value.delete(key) catch |err| return switch (err) {
        error.PropertyNotConfigurable, error.ObjectIsFrozen => self.throwError(.type_error, "Cannot delete property '{s}' of object", .{key}),
        else => err,
    };
    if (removed) {
        if (old_value) |v| v.deinit();
        if (old_getter) |g| g.deinit();
        if (old_setter) |s| s.deinit();
    }
    return true;
}

/// Full `obj[key] = value` dispatch by receiver type -- factored out
/// of `assignTo`'s `.member` case (which now just resolves `obj`/
/// `key` from the AST and delegates here) so `Reflect.set` can reuse
/// the exact same logic. Split, not a blanket conversion:
/// null/undefined is a real spec TypeError, but every other
/// non-object receiver this doesn't special-case (arrays/strings/
/// numbers already have their own arms above) is a genuine feature
/// gap -- NotImplemented is the honest answer, and a JS `catch` must
/// never swallow it.
pub fn setPropertyOnValue(self: *Interpreter, obj: JSValue, key: []const u8, value: JSValue) anyerror!void {
    if (obj == .@"undefined" or obj == .@"null") {
        return self.throwError(.type_error, "Cannot set properties of {s} (setting '{s}')", .{ if (obj == .@"null") "null" else "undefined", key });
    }
    if (obj == .function) {
        // `F.prototype = {...}` overwrites the callable's slot;
        // everything else goes into the statics bag (class statics,
        // F.myProp = 1 -- the old "functions have no property bag"
        // gap is gone).
        if (std.mem.eql(u8, key, "prototype")) {
            if (value != .object) return error.NotImplemented;
            obj.function.value.prototype = value.retain();
            return;
        }
        // `.name`/`.length` start life as virtual (writable: false)
        // properties backed by the Callable struct, not a real bag
        // entry -- a bare assignment (unlike a `static name(){}`
        // class member or `Object.defineProperty`, both of which use
        // [[DefineOwnProperty]] and bypass writability) must respect
        // that and fail, same as assigning any other non-writable
        // own data property. Once something HAS put an own record in
        // the bag (either of those two paths), plain assignment falls
        // through below and is governed by that record's own writable
        // flag, like any ordinary object property.
        if (std.mem.eql(u8, key, "name") or std.mem.eql(u8, key, "length")) {
            const already_own = if (obj.function.value.statics) |bag| bag.object.value.has(key) else false;
            if (!already_own) {
                return self.throwError(.type_error, "Cannot assign to read only property '{s}' of function", .{key});
            }
        }
        // Real [[Set]]: an inherited ACCESSOR (e.g.
        // `Object.defineProperty(Function.prototype, "x", {get,set})`)
        // must invoke the setter with `this` = this function, not
        // silently create an own property in the statics bag -- same
        // walk `setObjectProperty` already does for plain objects,
        // applied to the function's own prototype chain (getProperty's
        // `.function` case reads from this same `self.protos.function`
        // chain for inherited lookups).
        var current: ?*const @TypeOf(self.protos.function.object.value) = &self.protos.function.object.value;
        while (current) |o| : (current = o.getPrototype()) {
            const rec = o.getOwnRecord(key) orelse continue;
            if (rec.isAccessor()) {
                const s = rec.setter orelse return; // getter-only: silent no-op
                _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
                return;
            }
            break;
        }
        const bag = try self.functionStatics(obj);
        return self.setObjectProperty(bag, key, value);
    }
    if (obj == .array) return self.setArrayProperty(obj, key, value);
    if (obj == .typed_array) return self.setTypedArrayProperty(obj, key, value);
    if (obj == .@"error") {
        // No general property bag (same narrowing as arrays/regex),
        // but `.message` specifically must be writable: the extremely
        // common test262 harness idiom `catch(e){ e.message += "...";
        // throw e; }` needs it, and without this it was an uncatchable
        // NotImplemented that silently poisoned huge swaths of
        // otherwise-passing tests across many areas.
        if (std.mem.eql(u8, key, "message")) {
            const s = try coercion.toDisplayString(self.gc_allocator, value);
            defer self.gc_allocator.free(s);
            const box = obj.@"error";
            box.value.allocator.free(box.value.message);
            box.value.message = try box.value.allocator.dupe(u8, s);
            return;
        }
        return error.NotImplemented;
    }
    if (obj == .regex) {
        if (std.mem.eql(u8, key, "lastIndex")) {
            const n = try coercion.toNumber(value);
            // `lastIndex` may be set to any Number, including
            // Infinity, Number.MAX_VALUE or values beyond usize
            // (Test262 exercises exactly these). A bare
            // @intFromFloat would panic on an out-of-range float, so
            // saturate: anything at/above usize's range (and NaN,
            // which fails both comparisons) is stored as the max,
            // which always exceeds the subject length, so exec/test
            // correctly find no match and reset it to 0.
            const max_usize_f: f64 = @floatFromInt(std.math.maxInt(usize));
            self.regexState(obj).last_index = if (n >= max_usize_f)
                std.math.maxInt(usize)
            else if (n > 0)
                @intFromFloat(n)
            else
                0;
            return;
        }
        return error.NotImplemented;
    }
    if (obj == .proxy) {
        const box = obj.proxy;
        if (try self.proxyTrap(box, "set")) |trap_fn| {
            defer trap_fn.deinit();
            const key_val = try self.gcNewString(key);
            defer key_val.deinit();
            const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val, value, obj });
            defer result.deinit();
            // Always-strict engine: a falsy trap result is a real
            // TypeError, not a silent no-op.
            if (!coercion.isTruthy(result)) {
                return self.throwError(.type_error, "'set' on proxy: trap returned falsish for property '{s}'", .{key});
            }
            return;
        }
        // No trap: set directly on target, matching the narrow set
        // of receiver kinds this function already special-cases
        // above (function/array/regex/object).
        if (box.value.target == .object) return self.setObjectProperty(box.value.target, key, value);
        if (box.value.target == .array) return self.setArrayProperty(box.value.target, key, value);
        return error.NotImplemented;
    }
    if (obj != .object) return error.NotImplemented;
    // Writing a property on `globalThis` creates/updates a global
    // binding (`globalThis.foo = 1` makes `foo` a global).
    if (self.global_object) |go| {
        if (obj.object == go.object) {
            // `Environment.define` stores `key` BY REFERENCE (never
            // dupes -- every other call site passes an AST-borrowed,
            // forever-valid name). `key` here can be a caller-owned
            // slice (`globalThis[computed] = x`, or any Reflect.set
            // caller's own buffer) -- dupe defensively so the new
            // global binding's name always outlives it.
            try self.global_env.define(self.gc_allocator, try self.gc_allocator.dupe(u8, key), value.retain());
            return;
        }
    }
    try self.setObjectProperty(obj, key, value);
}

/// Full `delete obj[key]` dispatch by receiver type (proxy's
/// `deleteProperty` trap or no-trap delegation, plain object via
/// `deleteObjectProperty`, anything else a spec-matching no-op
/// `true`) -- factored out of `evalUnary`'s `.delete` case so
/// `Reflect.deleteProperty` can reuse the exact same logic.
pub fn deletePropertyOnValue(self: *Interpreter, obj: JSValue, key: []const u8) anyerror!bool {
    if (obj == .proxy) {
        const box = obj.proxy;
        if (try self.proxyTrap(box, "deleteProperty")) |trap_fn| {
            defer trap_fn.deinit();
            const key_val = try self.gcNewString(key);
            defer key_val.deinit();
            const result = try trap_fn.function.value.call(trap_fn.function.value.ctx, self.gc_allocator, box.value.handler, &.{ box.value.target, key_val });
            defer result.deinit();
            return coercion.isTruthy(result);
        }
        if (box.value.target == .object) return self.deleteObjectProperty(box.value.target, key);
        return true;
    }
    if (obj == .function) {
        // name/length are configurable (spec) but aren't backed by a
        // real ZObject bag entry -- they're read straight off the
        // Callable struct (see getProperty's `.function` case), so
        // "deleting" them just flips a side-table flag that
        // hasOwnProperty/getOwnPropertyDescriptor/getProperty all
        // consult instead of actually clearing Callable.name/.arity
        // (which stay intact -- other machinery, e.g. stack traces,
        // still needs the real name).
        if (std.mem.eql(u8, key, "name")) {
            try self.markFnPropDeleted(obj, "name");
            return true;
        }
        if (std.mem.eql(u8, key, "length")) {
            try self.markFnPropDeleted(obj, "length");
            return true;
        }
        return true;
    }
    if (obj != .object) return true;
    return self.deleteObjectProperty(obj, key);
}

/// The function's statics/property bag, created lazily on first touch
/// (same contract as functionPrototype).
pub fn functionStatics(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
    if (fn_val.function.value.statics) |s| return s;
    const bag = try self.gcNewObject();
    fn_val.function.value.statics = bag;
    return bag;
}

/// F.prototype, created lazily on first touch: a fresh `{}` whose
/// `constructor` points back at the function (real
/// `F.prototype.constructor === F` behavior). Chains to Object.prototype
/// once it exists (every ordinary object's [[Prototype]]).
pub fn functionPrototype(self: *Interpreter, fn_val: JSValue) anyerror!JSValue {
    if (fn_val.function.value.prototype) |p| return p;
    var proto = try self.gcNewObject();
    if (self.protos.object == .object) try proto.object.value.setPrototype(&self.protos.object.object.value);
    try proto.object.value.set("constructor", fn_val.retain());
    fn_val.function.value.prototype = proto;
    return proto;
}

/// A plain object whose [[Prototype]] is the real `Object.prototype` --
/// what every ordinary object (literal, result object, ...) must have so
/// `Object.getPrototypeOf({}) === Object.prototype` and inherited
/// methods resolve through the chain rather than a side table.
pub fn ordinaryObject(self: *Interpreter) !JSValue {
    const obj = try self.gcNewObject();
    if (self.protos.object == .object) try obj.object.value.setPrototype(&self.protos.object.object.value);
    return obj;
}

/// The specific `XArray.prototype` for a given `TypedKind` -- `u8`
/// and `u8_clamped` deliberately resolve to DIFFERENT prototypes
/// despite sharing storage (real JS: `Uint8Array.prototype !==
/// Uint8ClampedArray.prototype`).
pub fn typedArrayProto(self: *Interpreter, kind: zvalue.TypedKind) JSValue {
    return switch (kind) {
        .i8 => self.protos.int8_array,
        .u8 => self.protos.uint8_array,
        .u8_clamped => self.protos.uint8_clamped_array,
        .i16 => self.protos.int16_array,
        .u16 => self.protos.uint16_array,
        .i32 => self.protos.int32_array,
        .u32 => self.protos.uint32_array,
        .f32 => self.protos.float32_array,
        .f64 => self.protos.float64_array,
        .i64 => self.protos.bigint64_array,
        .u64 => self.protos.biguint64_array,
    };
}

/// Walk a builtin prototype object's own->chain records for `key`,
/// dispatching an accessor's getter with `this = receiver`. Returns null
/// on a full miss. This is how the primitive types (array/string/date/...)
/// resolve their methods now that those live on real prototype objects.
pub fn getFromProto(self: *Interpreter, receiver: JSValue, proto: JSValue, key: []const u8) anyerror!?JSValue {
    if (proto != .object) return null;
    const arena = self.gc_allocator;
    var current: ?*const @TypeOf(proto.object.value) = &proto.object.value;
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const gtr = rec.getter orelse return JSValue.UNDEFINED;
            return try gtr.function.value.call(gtr.function.value.ctx, arena, receiver, &.{});
        }
        return rec.value.retain();
    }
    return null;
}

/// Populate a builtin prototype with its method table as real own data
/// properties carrying the spec attributes for builtin methods
/// (writable, NON-enumerable, configurable), plus a non-enumerable
/// `constructor` back-reference. The functions come from `nativeMethod`,
/// which caches by identity so `[].push === Array.prototype.push` holds.
pub fn installProto(self: *Interpreter, proto: JSValue, comptime type_prefix: []const u8, methods: std.StaticStringMap(native_helpers.MethodSpec), ctor: JSValue) !void {
    const attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
    for (methods.keys()) |k| {
        const spec = methods.get(k).?;
        const f = try self.nativeMethod(type_prefix, k, spec.arity, spec.call);
        try proto.object.value.defineProperty(k, f, attrs);
    }
    try proto.object.value.defineProperty("constructor", ctor.retain(), attrs);
}

/// Installs `proto[Symbol.iterator]` as an alias for an already-
/// installed method -- real spec: `Array.prototype[Symbol.iterator]
/// === Array.prototype.values` (SAME identity, not just same
/// behavior; ditto `Map.prototype`/entries, `Set.prototype`/values,
/// `%TypedArray%.prototype`/values). Reuses `nativeMethod`'s cache
/// (the same (type_prefix, name) key `installProto` used for the
/// string-named method), so this returns the identical JSValue.
pub fn aliasSymbolIterator(self: *Interpreter, proto: JSValue, comptime type_prefix: []const u8, methods: std.StaticStringMap(native_helpers.MethodSpec), method_name: []const u8) !void {
    const sym = self.symbol_iterator orelse return;
    const key = try self.encodeKey(sym);
    defer self.gc_allocator.free(key);
    const aliased = methods.get(method_name).?;
    const f = try self.nativeMethod(type_prefix, method_name, aliased.arity, aliased.call);
    const attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
    try proto.object.value.defineProperty(key, f, attrs);
}

/// Materialize the real builtin prototype objects (Object.prototype,
/// Array.prototype, ...) from the method tables in builtins.zig. Called
/// once at the end of setupGlobals, after every constructor exists.
/// Object.prototype is the chain end ([[Prototype]] = null); every other
/// prototype chains to it.
pub fn materializeProtos(self: *Interpreter) !void {
    const g = self.global_env;

    const object_ctor = g.get("Object").?;
    const object_proto = try self.functionPrototype(object_ctor);
    self.protos.object = object_proto;
    try self.installProto(object_proto, "object", builtins.object_methods, object_ctor);

    inline for (.{
        .{ "array", "Array", builtins.array_methods },
        .{ "string", "String", builtins.string_methods },
        .{ "date", "Date", builtins.date_methods },
        .{ "function", "Function", builtins.function_methods },
        .{ "regex", "RegExp", builtins.regex_methods },
        .{ "map", "Map", builtins.map_methods },
        .{ "set", "Set", builtins.set_methods },
        .{ "symbol", "Symbol", builtins.symbol_methods },
        .{ "promise", "Promise", builtins.promise_methods },
        .{ "number", "Number", builtins.number_methods },
        .{ "boolean", "Boolean", builtins.boolean_methods },
        .{ "bigint", "BigInt", builtins.bigint_methods },
        .{ "array_buffer", "ArrayBuffer", builtins.array_buffer_methods },
        .{ "data_view", "DataView", builtins.dataview_methods },
    }) |e| {
        const ctor = g.get(e[1]).?;
        const proto = try self.functionPrototype(ctor);
        try proto.object.value.setPrototype(&object_proto.object.value);
        try self.installProto(proto, e[0], e[2], ctor);
        @field(self.protos, e[0]) = proto;
    }

    // Real spec: Number.prototype/Boolean.prototype/String.prototype
    // each carry their own internal slot ([[NumberData]]=+0,
    // [[BooleanData]]=false, [[StringData]]="") -- confirmed against
    // real Node that `Number.prototype.toString()` (called with no
    // `new Number()` receiver at all) returns "0", not a TypeError.
    // These 3 prototypes are ordinary `.object`s with nothing in
    // primitive_wrapper_data (only `new Number()`/etc via
    // boxPrimitiveIfConstructed register there), so every
    // requirePrimitive-gated method (toString/valueOf/toFixed/...)
    // was rejecting them outright. Registering the ambient primitive
    // here, once, makes them unbox exactly like a real boxed instance.
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(self.protos.number.object), JSValue.fromNumber(0));
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(self.protos.boolean.object), JSValue.fromBool(false));
    try self.primitive_wrapper_data.put(self.gc_allocator, @intFromPtr(self.protos.string.object), try self.gcNewString(""));

    // Real spec: Map.prototype/Set.prototype[Symbol.toStringTag] are
    // real own properties ("Map"/"Set") -- Object.prototype.toString's
    // fallback for types not in its hardcoded internal-slot list
    // reads through here (see objToString's own `.map`/`.set` cases,
    // which -- narrowing -- hardcode the same 2 strings directly
    // rather than consulting this property generically, so overriding
    // it here would NOT change what Object.prototype.toString.call
    // reports, only a direct property read of it).
    if (self.symbol_to_string_tag) |tag_sym| {
        const tag_key = try self.encodeKey(tag_sym);
        defer self.gc_allocator.free(tag_key);
        const tag_attrs = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = true };
        try self.protos.map.object.value.defineProperty(tag_key, try self.gcNewString("Map"), tag_attrs);
        try self.protos.set.object.value.defineProperty(tag_key, try self.gcNewString("Set"), tag_attrs);
    }

    // Real spec: Array.prototype/Map.prototype/Set.prototype's
    // [Symbol.iterator] own property aliases an already-installed
    // string-named method (verified via real Node identity checks) --
    // structural iteration (spread/for-of/Array.from, iterableItems in
    // this file) never consulted this property and still doesn't need
    // to; this only fixes explicit `arr[Symbol.iterator]` access and
    // any user/harness code (e.g. test262's own testTypedArray.js
    // `makeIterable`) that does the same.
    try self.aliasSymbolIterator(self.protos.array, "array", builtins.array_methods, "values");
    try self.aliasSymbolIterator(self.protos.map, "map", builtins.map_methods, "entries");
    try self.aliasSymbolIterator(self.protos.set, "set", builtins.set_methods, "values");

    // Types without a method table today: real (near-empty) prototypes so
    // getPrototypeOf / reflection still work and instances chain correctly.
    const proto_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
    inline for (.{.{ "error", "Error" }}) |e| {
        const ctor = g.get(e[1]).?;
        const proto = try self.functionPrototype(ctor);
        try proto.object.value.setPrototype(&object_proto.object.value);
        try proto.object.value.defineProperty("constructor", ctor.retain(), proto_attrs);
        try self.installProto(proto, e[0], builtins.error_methods, ctor);
        @field(self.protos, e[0]) = proto;
    }

    // %TypedArray%.prototype: abstract, not itself exposed as a
    // global (no constructor of its own) -- every concrete
    // `XArray.prototype` below chains to THIS instead of directly to
    // Object.prototype (real spec: `Int8Array.prototype.__proto__
    // === %TypedArray%.prototype`). Carries no methods this phase
    // (phase 3's job); exists purely for `instanceof`/
    // `getPrototypeOf` chain-identity correctness.
    const typed_array_base = try self.ordinaryObject();
    self.protos.typed_array_base = typed_array_base;
    // Phase 3: the real method surface (map/filter/forEach/slice/set/
    // subarray/...) lives ONCE here, not per concrete prototype --
    // every `XArray.prototype` below chains to this object, so
    // `getFromProto`'s existing chain walk gives every kind these
    // methods for free (matches real spec structure exactly).
    for (builtins.typed_array_methods.keys()) |k| {
        const spec = builtins.typed_array_methods.get(k).?;
        const f = try self.nativeMethod("typed_array", k, spec.arity, spec.call);
        try typed_array_base.object.value.defineProperty(k, f, proto_attrs);
    }
    // Real spec: %TypedArray%.prototype[Symbol.iterator] === %TypedArray%.prototype.values.
    try self.aliasSymbolIterator(typed_array_base, "typed_array", builtins.typed_array_methods, "values");
    const bpe_attrs = zvalue.PropertyDescriptor{ .writable = false, .enumerable = false, .configurable = false };
    inline for (.{
        .{ "int8_array", "Int8Array", 1 },
        .{ "uint8_array", "Uint8Array", 1 },
        .{ "uint8_clamped_array", "Uint8ClampedArray", 1 },
        .{ "int16_array", "Int16Array", 2 },
        .{ "uint16_array", "Uint16Array", 2 },
        .{ "int32_array", "Int32Array", 4 },
        .{ "uint32_array", "Uint32Array", 4 },
        .{ "float32_array", "Float32Array", 4 },
        .{ "float64_array", "Float64Array", 8 },
        .{ "bigint64_array", "BigInt64Array", 8 },
        .{ "biguint64_array", "BigUint64Array", 8 },
    }) |e| {
        const ctor = g.get(e[1]).?;
        const proto = try self.functionPrototype(ctor);
        // functionPrototype() defaulted this to Object.prototype --
        // re-parent to the shared base instead.
        try proto.object.value.setPrototype(&typed_array_base.object.value);
        try proto.object.value.defineProperty("constructor", ctor.retain(), proto_attrs);
        try proto.object.value.defineProperty("BYTES_PER_ELEMENT", JSValue.fromNumber(@floatFromInt(e[2])), bpe_attrs);
        @field(self.protos, e[0]) = proto;
    }
}

