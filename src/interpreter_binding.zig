//! Step 5 Phase C batch 7: the binding+iter cluster -- destructuring/
//! binding-pattern initialization, destructuring assignment, for-in/
//! for-of iteration, and the iterator-protocol helpers (resolveIterator/
//! drainIterator/iterableItems/yield*). Split out of interpreter.zig;
//! see z-interpreter-refactor.md.

const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const zparser = @import("zparser");
const zstatements = @import("zstatements");
const zstring = @import("zstring");

const coercion = @import("coercion.zig");
const builtins = @import("builtins.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const Completion = interpreter_mod.Completion;
const FiberState = interpreter_mod.FiberState;

/// The source side of array destructuring, shared by binding patterns
/// and destructuring assignment: the same narrowed iterables as for-of
/// (arrays by element, strings by code point); anything else is the
/// real TypeError Node raises.
/// Every branch returns a FRESH, caller-owned slice (the container
/// only -- the `JSValue`s inside are the same already-alive
/// references the source held, not retained here; callers `.retain()`
/// individually wherever they actually store one). Callers must
/// free the returned slice with `self.gc_allocator.free(...)` once
/// done. The `.array` case dupes rather than returning
/// `box.value.toSlice()`'s borrowed slice directly -- a single
/// uniform contract across every branch, same reasoning as
/// `ownEnumerableKeys`/`freeOwnedKeys`'s always-owned contract.
pub fn iterableItems(self: *Interpreter, value: JSValue) anyerror![]const JSValue {
    const arena = self.gc_allocator;
    return switch (value) {
        .array => |box| blk: {
            const src = box.value.toSlice();
            const out = try arena.alloc(JSValue, src.len);
            @memcpy(out, src);
            break :blk out;
        },
        .string => |box| blk: {
            var cps: std.ArrayList(JSValue) = .empty;
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                try cps.append(arena, try self.gcNewString(cp));
            }
            break :blk try cps.toOwnedSlice(arena);
        },
        // A user iterable (Symbol.iterator) or a hand-written iterator
        // (duck-typed `next`) -- drained fully.
        .object => try self.drainIterator(try self.resolveIterator(value)),
        // Sets iterate their values; Maps their [key, value] pairs --
        // so `[...set]`, `Array.from(map)`, `f(...set)` all work.
        .set => |box| blk: {
            const vals = box.value.values();
            const out = try arena.alloc(JSValue, vals.len);
            for (vals, 0..) |v, i| out[i] = v;
            break :blk out;
        },
        .map => |box| blk: {
            const ks = box.value.keys();
            const vs = box.value.values();
            var out: std.ArrayList(JSValue) = .empty;
            for (ks, vs) |k, v| {
                var pair = try self.gcNewArray();
                _ = try pair.array.value.push(k.retain());
                _ = try pair.array.value.push(v.retain());
                try out.append(arena, pair);
            }
            break :blk try out.toOwnedSlice(arena);
        },
        // Structurally recognized like array/set/map above (no
        // Symbol.iterator lookup) -- needed for `[...ta]`/`for...of`/
        // `Array.from(ta)` AND for this engine's own TypedArray
        // constructors' iterable-source overload
        // (`new Int32Array(new Uint8Array([1,2,3]))`).
        .typed_array => |box| blk: {
            const out = try arena.alloc(JSValue, box.value.len);
            var i: usize = 0;
            while (i < box.value.len) : (i += 1) {
                out[i] = try builtins.typedElemGet(self, box.value.kind, &box.value.owner.array_buffer.value, box.value.byte_offset, box.value.len, i);
            }
            break :blk out;
        },
        else => self.throwError(.type_error, "{s} is not iterable", .{value.typeOf()}),
    };
}

/// The iterator object for a `.object`: its `[Symbol.iterator]()`
/// result if it has one, else the object itself if it's already an
/// iterator (callable `next`). TypeError otherwise (not iterable).
pub fn resolveIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    if (self.symbol_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        const method = try self.getProperty(obj, key);
        if (method == .function) {
            const iter = try method.function.value.call(method.function.value.ctx, arena, obj, &.{});
            if (iter != .object) return self.throwError(.type_error, "Result of the Symbol.iterator method is not an object", .{});
            return iter;
        }
    }
    // Fallback: the object is itself an iterator (generator objects,
    // hand-written `{ next() {} }`).
    if ((try self.getProperty(obj, "next")) == .function) return obj;
    return self.throwError(.type_error, "{s} is not iterable", .{obj.typeOf()});
}

/// Like resolveIterator, but for `for await`: tries `[Symbol.
/// asyncIterator]()` first (a real async iterator, e.g. an async
/// generator object); falls back to the ordinary sync-iterator
/// resolution (AsyncFromSyncIterator wrapping -- the caller Awaits
/// each produced value either way, which is what actually makes a
/// plain Symbol.iterator object work under `for await`).
pub fn resolveAsyncIterator(self: *Interpreter, obj: JSValue) anyerror!JSValue {
    const arena = self.gc_allocator;
    if (self.symbol_async_iterator) |sym| {
        const key = try self.encodeKey(sym);
        defer self.gc_allocator.free(key);
        const method = try self.getProperty(obj, key);
        if (method == .function) {
            const iter = try method.function.value.call(method.function.value.ctx, arena, obj, &.{});
            if (iter != .object) return self.throwError(.type_error, "Result of the Symbol.asyncIterator method is not an object", .{});
            return iter;
        }
    }
    return self.resolveIterator(obj);
}

/// Runs an iterator object to completion, collecting its values.
pub fn drainIterator(self: *Interpreter, iter: JSValue) anyerror![]const JSValue {
    const arena = self.gc_allocator;
    const next_fn = try self.getProperty(iter, "next");
    if (next_fn != .function) return self.throwError(.type_error, "iterator.next is not a function", .{});
    var out: std.ArrayList(JSValue) = .empty;
    while (true) {
        const step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iter, &.{});
        if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
        if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
        try out.append(arena, try self.getProperty(step, "value"));
    }
    return out.toOwnedSlice(arena);
}

/// `yield* iterable`: drives an inner iterable, re-yielding each of
/// its values from the current (outer) generator and forwarding the
/// outer's resume value into the inner. Narrowed to iterator-protocol
/// objects (callable `next`), arrays, and strings -- no arbitrary
/// Symbol.iterator. The expression's own value is the inner
/// iterator's return value (arrays/strings: undefined).
pub fn evalYieldDelegate(self: *Interpreter, env: *Environment, fs: *FiberState, arg_node: *zparser.Node) anyerror!JSValue {
    const arena = self.gc_allocator;
    const iterable = try self.evalExpression(env, arg_node);

    // Iterator-protocol object: forward next(resume), return the
    // completion value.
    if (iterable == .object) {
        const next_fn = try self.getProperty(iterable, "next");
        if (next_fn == .function) {
            var resume_value = JSValue.UNDEFINED;
            while (true) {
                const step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iterable, &.{resume_value});
                if (step != .object) return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                if (coercion.isTruthy(try self.getProperty(step, "done"))) {
                    return self.getProperty(step, "value");
                }
                fs.yielded = try self.getProperty(step, "value");
                fs.fiber.suspendSelf();
                if (fs.resume_is_throw) {
                    fs.resume_is_throw = false;
                    return self.throwValue(fs.resume_value);
                }
                resume_value = fs.resume_value;
            }
        }
    }

    // Arrays and strings: re-yield each element (resume value is not
    // fed anywhere -- they aren't real iterators).
    const items = try self.iterableItems(iterable);
    defer arena.free(items);
    for (items) |item| {
        fs.yielded = item;
        fs.fiber.suspendSelf();
        if (fs.resume_is_throw) {
            fs.resume_is_throw = false;
            return self.throwValue(fs.resume_value);
        }
    }
    return JSValue.UNDEFINED;
}

/// How bindPattern lands a name: `.define` creates the binding in
/// `env` (let/const/params/catch); `.assign` writes to an existing
/// binding up the chain -- `var` declarators, whose bindings the
/// hoisting pre-pass already created at function scope.
const BindMode = enum { define, assign };

/// Recursive BindingInitialization (ECMA-262 8.6.2) -- every binding
/// position (declarators, params, catch, for-in/of declared bindings)
/// funnels here. Destructuring as an assignment target (`[a, b] =
/// arr` without a declaration) is separate machinery (phase 8b), not
/// this. Defaults are evaluated in `env` itself, so a later element's
/// default can reference an earlier binding (`[a, b = a]` -- real
/// spec order). Ownership: the caller keeps its reference to `value`;
/// identifier bindings retain.
pub fn bindPattern(self: *Interpreter, env: *Environment, pattern: *const zstatements.BindingPattern, value: JSValue, mode: BindMode) anyerror!void {
    const arena = self.gc_allocator;
    switch (pattern.*) {
        .identifier => |id| {
            const v = value.retain();
            switch (mode) {
                .define => try env.define(arena, id.name, v),
                // The pre-pass defined every var name; the fallback
                // define is belt-and-braces, not a real path.
                .assign => env.assign(id.name, v) catch try env.define(arena, id.name, v),
            }
        },
        .array => |arr_pat| {
            const items = try self.iterableItems(value);
            defer arena.free(items);
            for (arr_pat.elements, 0..) |maybe_el, i| {
                const el = maybe_el orelse continue; // elision hole
                var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                if (v == .@"undefined") {
                    if (el.default) |def| {
                        v = try self.evalExpression(env, def);
                        // NamedEvaluation: `[a = AnonFn]` names it "a".
                        if (el.pattern.* == .identifier) {
                            try self.maybeNameAnonymousValue(def, v, el.pattern.identifier.name);
                        }
                    }
                }
                try self.bindPattern(env, el.pattern, v, mode);
            }
            if (arr_pat.rest) |rest_pat| {
                var rest_arr = try self.gcNewArray();
                if (arr_pat.elements.len < items.len) {
                    for (items[arr_pat.elements.len..]) |item| {
                        _ = try rest_arr.array.value.push(item.retain());
                    }
                }
                try self.bindPattern(env, rest_pat, rest_arr, mode);
            }
        },
        .object => |obj_pat| {
            if (value == .@"undefined" or value == .@"null") {
                const what: []const u8 = if (value == .@"null") "null" else "undefined";
                if (obj_pat.properties.len > 0) {
                    return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ obj_pat.properties[0].key, what, what });
                }
                return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
            }
            // getProperty is the whole point of the reuse: string
            // `.length`, error `.message`, prototype-chain lookups on
            // objects -- all already live there.
            for (obj_pat.properties) |prop| {
                var v = try self.getProperty(value, prop.key);
                if (v == .@"undefined") {
                    if (prop.default) |def| {
                        v = try self.evalExpression(env, def);
                        // NamedEvaluation: `{a = AnonFn}` names it "a".
                        if (prop.value.* == .identifier) {
                            try self.maybeNameAnonymousValue(def, v, prop.value.identifier.name);
                        }
                    }
                }
                try self.bindPattern(env, prop.value, v, mode);
            }
            if (obj_pat.rest) |rest_name| {
                // Own keys of an object source, minus the ones already
                // destructured; non-object sources rest to an empty
                // object (narrowed -- real JS copies own enumerable
                // props of the coerced object).
                var rest_obj = try self.ordinaryObject();
                if (value == .proxy) {
                    const ks = try builtins.ownEnumerableKeys(self, arena, value);
                    defer builtins.freeOwnedKeys(arena, ks);
                    outer_p: for (ks) |k| {
                        if (Interpreter.isSymbolKey(k)) continue;
                        for (obj_pat.properties) |prop| {
                            if (std.mem.eql(u8, prop.key, k)) continue :outer_p;
                        }
                        try rest_obj.object.value.set(k, try self.getProperty(value, k));
                    }
                } else if (value == .object) {
                    const keys = try value.object.value.keys(arena);
                    defer arena.free(keys);
                    outer: for (keys) |k| {
                        for (obj_pat.properties) |prop| {
                            if (std.mem.eql(u8, prop.key, k)) continue :outer;
                        }
                        try rest_obj.object.value.set(k, value.object.value.get(k).?.retain());
                    }
                }
                switch (mode) {
                    .define => try env.define(arena, rest_name.name, rest_obj),
                    .assign => env.assign(rest_name.name, rest_obj) catch try env.define(arena, rest_name.name, rest_obj),
                }
            }
        },
    }
}

/// Destructuring *assignment* (ECMA-262 13.15.5
/// DestructuringAssignmentEvaluation): the target is an array/object
/// *literal* node reinterpreted as a pattern -- already validated at
/// parse time by z-parser's isValidAssignmentPattern, so the shapes
/// seen here are exactly the valid ones. Mirrors bindPattern's source
/// semantics (iterableItems, getProperty lookups, defaults only on
/// undefined), but every leaf goes through assignTo -- which is what
/// makes member-expression targets (`[o.x] = [1]`) work, something
/// BindingPattern can't even represent.
pub fn destructuringAssign(self: *Interpreter, env: *Environment, target: *zparser.Node, value: JSValue) anyerror!void {
    const arena = self.gc_allocator;
    switch (target.data) {
        .array_literal => |elements| {
            const items = try self.iterableItems(value);
            defer arena.free(items);
            for (elements, 0..) |maybe_el, i| {
                const el = maybe_el orelse continue; // hole still consumes its index
                if (el.data == .spread) {
                    // Parse-time validation guarantees this is last.
                    var rest_arr = try self.gcNewArray();
                    if (i < items.len) {
                        for (items[i..]) |item| _ = try rest_arr.array.value.push(item.retain());
                    }
                    try self.destructuringAssignTarget(env, el.data.spread, rest_arr);
                    break;
                }
                var v = if (i < items.len) items[i] else JSValue.UNDEFINED;
                var el_target = el;
                if (el.data == .assignment and el.data.assignment.op == .assign) {
                    if (v == .@"undefined") v = try self.evalExpression(env, el.data.assignment.value);
                    el_target = el.data.assignment.target;
                }
                try self.destructuringAssignTarget(env, el_target, v);
            }
        },
        .object_literal => |elements| {
            if (value == .@"undefined" or value == .@"null") {
                const what: []const u8 = if (value == .@"null") "null" else "undefined";
                const first_key: ?[]const u8 = for (elements) |el| {
                    switch (el) {
                        .property => |p| if (!p.computed and p.key.data == .identifier) break p.key.data.identifier,
                        .spread => {},
                    }
                } else null;
                if (first_key) |k| {
                    return self.throwError(.type_error, "Cannot destructure property '{s}' of '{s}' as it is {s}.", .{ k, what, what });
                }
                return self.throwError(.type_error, "Cannot destructure '{s}' as it is {s}.", .{ what, what });
            }
            var consumed: std.ArrayList(Interpreter.PropKey) = .empty;
            defer {
                for (consumed.items) |pk| pk.free(arena);
                consumed.deinit(arena);
            }
            for (elements) |el| {
                switch (el) {
                    .property => |prop| {
                        const pk = try self.propertyKeyString(env, prop.computed, prop.key);
                        const key = pk.key;
                        try consumed.append(arena, pk);
                        var v = try self.getProperty(value, key);
                        var el_target = prop.value;
                        if (el_target.data == .assignment and el_target.data.assignment.op == .assign) {
                            if (v == .@"undefined") v = try self.evalExpression(env, el_target.data.assignment.value);
                            el_target = el_target.data.assignment.target;
                        }
                        try self.destructuringAssignTarget(env, el_target, v);
                    },
                    .spread => |sp| {
                        // Object rest: own keys not already consumed;
                        // non-object sources rest to an empty object
                        // (same narrowing as bindPattern's rest). The
                        // element holds a `.spread` node wrapping the
                        // actual target.
                        const arg = sp.data.spread;
                        var rest_obj = try self.ordinaryObject();
                        if (value == .proxy) {
                            const ks = try builtins.ownEnumerableKeys(self, arena, value);
                            defer builtins.freeOwnedKeys(arena, ks);
                            outer_p: for (ks) |k| {
                                if (Interpreter.isSymbolKey(k)) continue;
                                for (consumed.items) |c| {
                                    if (std.mem.eql(u8, c.key, k)) continue :outer_p;
                                }
                                try rest_obj.object.value.set(k, try self.getProperty(value, k));
                            }
                        } else if (value == .object) {
                            const keys = try value.object.value.keys(arena);
                            defer arena.free(keys);
                            outer: for (keys) |k| {
                                for (consumed.items) |c| {
                                    if (std.mem.eql(u8, c.key, k)) continue :outer;
                                }
                                try rest_obj.object.value.set(k, value.object.value.get(k).?.retain());
                            }
                        }
                        try self.destructuringAssignTarget(env, arg, rest_obj);
                    },
                }
            }
        },
        else => unreachable, // only ever called with array/object literal targets
    }
}

/// One target position inside a destructuring assignment: nested
/// literals recurse as patterns; everything else (identifier, member,
/// paren-wrapped) is an ordinary assignment leaf.
pub fn destructuringAssignTarget(self: *Interpreter, env: *Environment, node: *zparser.Node, value: JSValue) anyerror!void {
    switch (node.data) {
        .array_literal, .object_literal => try self.destructuringAssign(env, node, value),
        else => try self.assignTo(env, node, value),
    }
}

/// Binds the loop variable for one for-in/for-of iteration. Declared
/// let/const bindings get a FRESH child env per iteration, so
/// closures created in the body capture that iteration's value (real
/// let/const semantics); `for (var x of ...)` assigns to the single
/// hoisted function-scope binding instead (real shared-var
/// semantics). Existing bindings assign into the enclosing scope
/// chain.
pub fn bindForIteration(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue) anyerror!*Environment {
    switch (binding) {
        .declared => |d| {
            if (d.kind == .@"var") {
                try self.bindPattern(env, d.pattern, value, .assign);
                return env;
            }
            const iter_env = try self.gcChildEnv(env);
            try self.bindPattern(iter_env, d.pattern, value, .define);
            return iter_env;
        },
        .existing => |name| {
            // env.assign takes ownership -- retain, matching bindPattern's
            // convention (the caller keeps its own reference to `value`).
            env.assign(name.name, value.retain()) catch |err| return switch (err) {
                error.ReferenceError => self.throwError(.reference_error, "{s} is not defined", .{name.name}),
                error.BeforeInitialization => self.throwError(.reference_error, "Cannot access '{s}' before initialization", .{name.name}),
            };
            return env;
        },
        // `for ([a, b] of x)` over existing bindings -- a destructuring
        // assignment per iteration, no fresh env.
        .existing_pattern => |node| {
            try self.destructuringAssign(env, node, value);
            return env;
        },
    }
}

/// Runs one for-in/for-of iteration with the loop variable bound to
/// `value`. Returns null to proceed to the next iteration, or a
/// Completion the whole loop must deliver (an owned break converts to
/// normal-and-stop; everything else abrupt propagates).
pub fn forIterationStep(self: *Interpreter, env: *Environment, binding: zstatements.ForBinding, value: JSValue, body: *zstatements.Statement, labels: []const []const u8) anyerror!?Completion {
    const iter_env = try self.bindForIteration(env, binding, value);
    const c = try self.evalStatement(iter_env, body);
    switch (c.type) {
        .break_completion => {
            if (Interpreter.loopOwns(c.target, labels)) return Completion{};
            return c;
        },
        .continue_completion => {
            if (!Interpreter.loopOwns(c.target, labels)) return c;
            return null;
        },
        .return_completion => return c,
        .normal => return null,
    }
}

/// for-of over the built-in iterables, natively: arrays (elements),
/// strings (Unicode code points -- the spec iterates by code point,
/// surrogate pairs together), maps ([key, value] pair arrays), sets
/// (values). Everything else -- plain objects included -- is a real
/// TypeError, exactly like Node (plain objects aren't iterable there
/// either). The one genuine gap vs. spec: user-defined iterables via
/// Symbol.iterator, impossible until ZObject supports symbol keys.
pub fn evalForOf(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
    const arena = self.gc_allocator;
    const is_await = head.is_await;
    // The parser only ever sets is_await inside an async function/async
    // generator body (await_allowed-gated), so a live fiber always
    // exists here; a missing one would be an interpreter bug -- same
    // contract as `.await_expr`/`.yield_expr`.
    const fs: ?*FiberState = if (is_await) (self.current_fiber orelse return error.NotImplemented) else null;
    const iterable = try self.evalExpression(env, head.iterable);
    switch (iterable) {
        .array => |box| {
            // Live iteration (ArrayIterator semantics): re-read length
            // each step and retain the element, so a body that mutates
            // the array (`array.pop()`) is observed and never leaves a
            // cached slice dangling.
            var i: usize = 0;
            while (i < box.value.length()) : (i += 1) {
                var item = box.value.get(i).retain();
                if (is_await) item = try self.awaitValue(fs.?, item);
                if (try self.forIterationStep(env, head.binding, item, body, labels)) |c| return c;
            }
        },
        .string => |box| {
            var it = std.unicode.Utf8Iterator{ .bytes = box.value.data, .i = 0 };
            while (it.nextCodepointSlice()) |cp| {
                var ch = try self.gcNewString(cp);
                if (is_await) ch = try self.awaitValue(fs.?, ch);
                if (try self.forIterationStep(env, head.binding, ch, body, labels)) |c| return c;
            }
        },
        .map => |box| {
            // Live iteration (MapIterator semantics): re-read the ordered
            // keys each step (delete compacts them), retaining key+value,
            // so a body that mutates the map is observed and never dangles.
            var i: usize = 0;
            while (true) {
                const ks = box.value.keys();
                if (i >= ks.len) break;
                const k = ks[i].retain();
                const v = (box.value.get(k) orelse JSValue.UNDEFINED).retain();
                i += 1;
                var entry = try self.gcNewArray();
                _ = try entry.array.value.push(k);
                _ = try entry.array.value.push(v);
                if (is_await) entry = try self.awaitValue(fs.?, entry);
                if (try self.forIterationStep(env, head.binding, entry, body, labels)) |c| return c;
            }
        },
        .set => |box| {
            // Live iteration (SetIterator semantics): re-read the ordered
            // values each step (delete compacts them) and retain the
            // element, so a body that mutates the set (`set.delete(x)`) is
            // observed and never dangles a cached slice.
            var i: usize = 0;
            while (true) {
                const vals = box.value.values();
                if (i >= vals.len) break;
                var v = vals[i].retain();
                i += 1;
                if (is_await) v = try self.awaitValue(fs.?, v);
                if (try self.forIterationStep(env, head.binding, v, body, labels)) |c| return c;
            }
        },
        // The iterator protocol: a user iterable via Symbol.iterator
        // (or Symbol.asyncIterator, for `for await`), or an object that
        // IS an iterator (duck-typed `next` -- generator objects,
        // hand-written iterators). The completion value (`done: true`'s
        // value) is excluded, per spec.
        .object => {
            const iter = if (is_await) try self.resolveAsyncIterator(iterable) else try self.resolveIterator(iterable);
            const next_fn = try self.getProperty(iter, "next");
            while (true) {
                var step = try next_fn.function.value.call(next_fn.function.value.ctx, arena, iter, &.{});
                // A real async iterator's next() returns a PROMISE of
                // {value,done}; the AsyncFromSyncIterator fallback
                // (plain Symbol.iterator) returns the {value,done}
                // object directly -- either way, awaiting a non-promise
                // is a harmless one-tick round trip, so this one check
                // handles both without needing to track which case
                // resolveAsyncIterator picked.
                if (is_await and step == .promise) step = try self.awaitValue(fs.?, step);
                if (step != .object) {
                    return self.throwError(.type_error, "Iterator result {s} is not an object", .{step.typeOf()});
                }
                if (coercion.isTruthy(try self.getProperty(step, "done"))) break;
                var value = try self.getProperty(step, "value");
                // Spec: for-await-of also Awaits the extracted VALUE
                // itself (AsyncFromSyncIteratorContinuation, for the
                // sync-fallback case). Awaiting an already-resolved
                // value from a genuine async iterator is a no-op
                // extra tick -- documented, narrowed simplification.
                if (is_await) value = try self.awaitValue(fs.?, value);
                if (try self.forIterationStep(env, head.binding, value, body, labels)) |c| return c;
            }
        },
        else => return self.throwError(.type_error, "{s} is not iterable", .{iterable.typeOf()}),
    }
    return .{};
}

/// for-in over enumerable string keys: own + inherited (walking the
/// prototype chain, shadowed keys seen once), array/string indices as
/// STRINGS (for-in keys are always strings in real JS), and -- per
/// spec -- zero iterations without error over null/undefined. Types
/// with no string-keyed property model here (number, boolean, map,
/// set, ...) iterate zero times.
pub fn evalForIn(self: *Interpreter, env: *Environment, head: anytype, body: *zstatements.Statement, labels: []const []const u8) anyerror!Completion {
    const arena = self.gc_allocator;
    const target = try self.evalExpression(env, head.object);
    switch (target) {
        .object => |box| {
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            defer seen.deinit(arena);
            var keys_list: std.ArrayList([]const u8) = .empty;
            defer keys_list.deinit(arena);
            // `globalThis`: top-level var/function names and ad-hoc
            // globals aren't backed by a real ZObject record, so the
            // bag walk below would miss them entirely -- same gap as
            // ownEnumerableKeys (see its global_builtin_names comment).
            if (self.global_object) |go| {
                if (target.object == go.object) {
                    if (self.global_var_env) |gve| {
                        var it = gve.bindings.keyIterator();
                        while (it.next()) |k| {
                            if (seen.contains(k.*)) continue;
                            try seen.put(arena, k.*, {});
                            try keys_list.append(arena, k.*);
                        }
                    }
                    var it2 = self.global_env.bindings.keyIterator();
                    while (it2.next()) |k| {
                        if (self.global_builtin_names.contains(k.*)) continue;
                        if (seen.contains(k.*)) continue;
                        try seen.put(arena, k.*, {});
                        try keys_list.append(arena, k.*);
                    }
                }
            }
            var current: ?*const @TypeOf(box.value) = &box.value;
            while (current) |o| : (current = o.getPrototype()) {
                const ks = try o.keys(arena);
                defer arena.free(ks);
                for (ks) |k| {
                    if (Interpreter.isSymbolKey(k)) continue; // symbols never in for-in
                    if (!seen.contains(k)) {
                        try seen.put(arena, k, {});
                        try keys_list.append(arena, k);
                    }
                }
            }
            for (keys_list.items) |k| {
                const kv = try self.gcNewString(k);
                if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
            }
        },
        .array => |box| {
            const len = box.value.length();
            var i: usize = 0;
            while (i < len) : (i += 1) {
                const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                defer arena.free(key_str);
                const kv = try self.gcNewString(key_str);
                if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
            }
        },
        .string => |box| {
            // UTF-16 code unit count, not UTF-8 byte count -- same fix
            // as getProperty's .string case (interpreter_props.zig).
            var i: usize = 0;
            while (i < zstring.utf16.lengthUtf16(box.value.data)) : (i += 1) {
                const key_str = try std.fmt.allocPrint(arena, "{d}", .{i});
                defer arena.free(key_str);
                const kv = try self.gcNewString(key_str);
                if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
            }
        },
        // Narrowing: only the proxy's own (trap-aware) keys -- unlike
        // the .object case above, this does NOT continue walking a
        // prototype chain past the proxy (real for-in would need a
        // getPrototypeOf-trap-aware walk on top of this), matching
        // this engine's already-established "no invariant checking"
        // scope boundary for Proxy.
        .proxy => {
            const ks = try builtins.ownEnumerableKeys(self, arena, target);
            defer builtins.freeOwnedKeys(arena, ks);
            for (ks) |k| {
                if (Interpreter.isSymbolKey(k)) continue;
                const kv = try self.gcNewString(k);
                if (try self.forIterationStep(env, head.binding, kv, body, labels)) |c| return c;
            }
        },
        else => {}, // incl. null/undefined: zero iterations, no error (spec)
    }
    return .{};
}

