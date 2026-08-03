//! Step 5 Phase C batch 4: the class+private+closures cluster --
//! class evaluation, private-field machinery, and closure creation.
//! Split out of interpreter.zig; see z-interpreter-refactor.md.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zparser = @import("zparser");
const zfunctions = @import("zfunctions");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

const coercion = @import("coercion.zig");

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const Environment = interpreter_mod.Environment;
const ClassCtx = interpreter_mod.ClassCtx;
const ClosureCtx = interpreter_mod.ClosureCtx;
const FieldDef = interpreter_mod.FieldDef;

/// ECMA-262 15.1.3 ExpectedArgumentCount: leading parameters up to (not
/// including) the first one with a default -- NOT `params.items.len`,
/// which counts every declared parameter regardless of defaults. A rest
/// parameter (`params.rest`, tracked separately from `.items` in this
/// AST) never adds to the count either way, so it needs no special
/// case here.
fn expectedArgumentCount(params: zfunctions.Params) usize {
    var count: usize = 0;
    for (params.items) |p| {
        if (p.default != null) break;
        count += 1;
    }
    return count;
}

/// Unwraps `(expr)` nodes -- real spec's `IsAnonymousFunctionDefinition`
/// looks through parenthesization (`let x = (() => {})` still names `x`,
/// confirmed against real Node), but this AST keeps `paren` as its own
/// node (semantically load-bearing elsewhere, e.g. `(-2) ** 2`), so
/// every syntactic check below has to see past it explicitly.
fn unwrapParen(node: *const zparser.Node) *const zparser.Node {
    var n = node;
    while (n.data == .paren) n = n.data.paren;
    return n;
}

/// ECMA-262 `IsAnonymousFunctionDefinition`: true only for a
/// FunctionExpression/GeneratorExpression/AsyncFunctionExpression/
/// AsyncGeneratorExpression with no BindingIdentifier, or an
/// ArrowFunction/AsyncArrowFunction (always anonymous by grammar) --
/// NOT "any expression that happens to evaluate to a function" (e.g.
/// `let x = make()` never triggers this, even if `make()` returns an
/// anonymous arrow). Generator/async-ness is an orthogonal flag on the
/// same `FunctionNode`, so no separate check is needed for those.
fn isAnonFnNode(node: *const zparser.Node) bool {
    const n = unwrapParen(node);
    if (n.data != .function_like) return false;
    const fnode = zfunctions.asFunctionNode(n.data.function_like);
    return switch (fnode.kind) {
        .arrow => true,
        .function_expr => |e| e.name == null,
        .function_decl, .method => false,
    };
}

/// Same idea as `isAnonFnNode`, for `ClassExpression` with no
/// `BindingIdentifier`.
fn isAnonClassNode(node: *const zparser.Node) bool {
    const n = unwrapParen(node);
    if (n.data != .class_like) return false;
    return zfunctions.asClassNode(n.data.class_like).name == null;
}

/// ECMA-262 NamedEvaluation: if `init_node` is syntactically one of the
/// anonymous-function-definition productions above, and the value it
/// evaluated to is a nameless `.function`, gives it `name` -- the
/// SetFunctionName step every named binding/assignment/property-value/
/// default/class-field context has to run. `name` is always dupe'd
/// rather than trusted to outlive the call (some callers -- e.g. a
/// computed object-literal property key -- free their copy before this
/// returns) -- onto `arena_state`, NOT `gc_allocator`: `Callable.name`
/// is never freed by `Callable.deinit()` (every existing name is an
/// AST-borrowed slice, permanent for the parse tree's lifetime), so a
/// `gc_allocator` dupe here would leak on every rename (confirmed: it
/// did, before this fix, showing up as a real leaked-allocation in
/// nearly every test that declares a named const/let arrow). `arena_
/// state` is the same "AST-adjacent, freed once at shutdown, never
/// individually freed" category this codebase already uses for exactly
/// this kind of permanent-but-not-GC-traced string.
pub fn maybeNameAnonymousValue(self: *Interpreter, init_node: *const zparser.Node, value: JSValue, name: []const u8) anyerror!void {
    if (!isAnonFnNode(init_node) and !isAnonClassNode(init_node)) return;
    if (value != .function or value.function.value.name.len != 0) return;
    value.function.value.name = try self.arena_state.allocator().dupe(u8, name);
}

/// Recovers a class-field key's readable source name for NamedEvaluation:
/// a private key is encoded as `\x00P<hex>|#name` (see `encodePrivateKey`
/// -- the source lexeme already includes its own `#`, so the part after
/// the last `|` matches real spec's "#name" PrivateName display exactly).
/// A plain (public) key is used as-is.
fn fieldDisplayName(key: []const u8) []const u8 {
    if (key.len == 0 or key[0] != 0) return key;
    if (std.mem.lastIndexOfScalar(u8, key, '|')) |i| return key[i + 1 ..];
    return key;
}

pub fn makeClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode) anyerror!JSValue {
    const arena = self.gc_allocator;
    // A named function expression's own name is visible inside its own
    // body (for self-recursion) even though it isn't bound in the
    // enclosing scope -- bind it in a thin wrapper env between `env`
    // and the closure's actual defining environment.
    const self_name: ?[]const u8 = switch (fnode.kind) {
        .function_expr => |e| e.name,
        else => null,
    };
    const closure_env = if (self_name != null) try self.gcChildEnv(env) else env;

    const ctx = try arena.create(ClosureCtx);
    ctx.* = .{ .interp = self, .function_node = fnode, .closure_env = closure_env };
    try self.gcTrackClosureCtx(ctx);
    const name: []const u8 = switch (fnode.kind) {
        .function_decl => |d| d.name,
        .function_expr => |e| e.name orelse "",
        .method => |m| m.name,
        .arrow => "",
    };
    const fn_value = try self.gcNewFunction(.{
        .ctx = ctx,
        .name = name,
        .arity = expectedArgumentCount(fnode.params),
        .call = closureCall,
        // Arrows and object-literal methods are not constructors
        // (spec); natives keep the default false via their own
        // newFunction call sites.
        .constructable = switch (fnode.kind) {
            .arrow, .method => false,
            .function_decl, .function_expr => true,
        },
    });
    if (self_name) |n| try closure_env.define(arena, n, fn_value.retain());
    return fn_value;
}

/// A class-body method closure: an ordinary makeClosure whose
/// ClosureCtx additionally carries the parent prototype (so `super.m()`
/// resolves inside the body) and the declaring class's private identity
/// (so `this.#x` resolves). Safe cast: makeClosure always installs a
/// ClosureCtx as the ctx of the closures it creates.
pub fn makeMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, super_proto: ?JSValue, private_ctx: ?*anyopaque) anyerror!JSValue {
    const v = try self.makeClosure(env, fnode);
    const cc: *ClosureCtx = @ptrCast(@alignCast(v.function.value.ctx));
    cc.super_proto = super_proto;
    cc.private_ctx = private_ctx;
    return v;
}

/// An object-literal method/getter/setter closure: an ordinary
/// makeClosure whose ClosureCtx additionally carries the object literal
/// itself as [[HomeObject]] (see Environment.home_object's doc comment
/// for why this is a distinct mechanism from makeMethodClosure's
/// super_proto -- dynamic prototype lookup vs. a class's fixed
/// snapshot). `home` must be the `.object` JSValue being built by the
/// enclosing object-literal evaluation.
pub fn makeObjectMethodClosure(self: *Interpreter, env: *Environment, fnode: *zfunctions.FunctionNode, home: JSValue) anyerror!JSValue {
    const v = try self.makeClosure(env, fnode);
    const cc: *ClosureCtx = @ptrCast(@alignCast(v.function.value.ctx));
    cc.home_object = home;
    return v;
}

// ===== Private (`#name`) member machinery =====
//
// ECMA-262's PrivateEnvironment/PrivateName pair, collapsed onto the
// existing property model: each class's ClassCtx pointer IS its private
// identity, and `#name` members are stored as ordinary properties under
// the reserved key `\x00P{ctx}|{name}` -- the `\x00` prefix is already
// invisible to every enumeration path (Object.keys, for-in, JSON,
// getOwnPropertyNames all skip it), so privates are non-reflective for
// free. The BRAND CHECK falls out of key mismatch: another class's
// `#name` encodes to a different key, and a miss is the spec TypeError.

/// Encodes a private member's storage key for a given class identity.
pub fn encodePrivateKey(self: *Interpreter, class_id: *anyopaque, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(self.gc_allocator, "\x00P{x}|{s}", .{ @intFromPtr(class_id), name });
}

/// The object that actually stores a receiver's private members:
/// the object itself, or a function's statics bag (`C.#staticField`).
/// Null for primitives (they can never carry a brand).
pub fn privateHolder(self: *Interpreter, obj: JSValue) !?JSValue {
    return switch (obj) {
        .object => obj,
        .function => try self.functionStatics(obj),
        else => null,
    };
}

pub fn privateGet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!JSValue {
    const ctx = env.resolvePrivateCtx() orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse
        return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
    // Own->chain record walk with accessor dispatch (instance fields
    // are own props; private methods/accessors live on the prototype).
    var current: ?*const @TypeOf(holder.object.value) = &holder.object.value;
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const g = rec.getter orelse
                return self.throwError(.type_error, "'{s}' was defined without a getter", .{name});
            return try g.function.value.call(g.function.value.ctx, self.gc_allocator, obj, &.{});
        }
        return rec.value.retain();
    }
    return self.throwError(.type_error, "Cannot read private member {s} from an object whose class did not declare it", .{name});
}

pub fn privateSet(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8, value: JSValue) anyerror!void {
    const ctx = env.resolvePrivateCtx() orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse
        return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
    const hv = &holder.object.value;
    if (hv.getOwnRecord(key)) |rec| {
        if (rec.isAccessor()) {
            const s = rec.setter orelse
                return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
            _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
            return;
        }
        // A brand-checked private FIELD write updates in place.
        hv.set(key, value.retain()) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => unreachable, // reserved keys are never frozen/sealed
        };
        return;
    }
    // Chain walk: a prototype hit is an accessor (setter dispatch) or a
    // private METHOD (not writable, spec TypeError).
    var current = hv.getPrototype();
    while (current) |o| : (current = o.getPrototype()) {
        const rec = o.getOwnRecord(key) orelse continue;
        if (rec.isAccessor()) {
            const s = rec.setter orelse
                return self.throwError(.type_error, "'{s}' was defined without a setter", .{name});
            _ = try s.function.value.call(s.function.value.ctx, self.gc_allocator, obj, &.{value});
            return;
        }
        return self.throwError(.type_error, "Cannot assign to private method {s}", .{name});
    }
    return self.throwError(.type_error, "Cannot write private member {s} to an object whose class did not declare it", .{name});
}

/// `#name in obj` -- true iff obj carries this class's brand for the
/// name (an own-or-prototype private entry under the encoded key).
pub fn privateHas(self: *Interpreter, env: *Environment, obj: JSValue, name: []const u8) anyerror!bool {
    const ctx = env.resolvePrivateCtx() orelse
        return self.throwError(.syntax_error, "Private field '{s}' must be declared in an enclosing class", .{name});
    const key = try self.encodePrivateKey(ctx, name);
    defer self.gc_allocator.free(key);
    const holder = (try self.privateHolder(obj)) orelse return false;
    var current: ?*const @TypeOf(holder.object.value) = &holder.object.value;
    while (current) |o| : (current = o.getPrototype()) {
        if (o.getOwnRecord(key) != null) return true;
    }
    return false;
}

/// Runs a class's instance-field initializers against a fresh instance
/// (this = the instance, private names resolvable, `super.x` usable).
/// Called at constructor entry for base classes and right after
/// `super()` returns for derived ones.
pub fn runInstanceFields(self: *Interpreter, cctx: *ClassCtx, instance: JSValue) anyerror!void {
    if (cctx.instance_fields.len == 0) return;
    if (instance != .object) return; // exotic `this` -- nothing to define on
    const field_env = try self.gcChildEnv(cctx.closure_env);
    field_env.this_value = instance;
    field_env.super_proto = cctx.super_proto;
    field_env.private_ctx = cctx;
    for (cctx.instance_fields) |fd| {
        const v = if (fd.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
        // NamedEvaluation: `class C { x = AnonFn }` names it "x" --
        // `fieldDisplayName` recovers "#x" from a private key's
        // internal `\x00P<hex>|#x` encoding, per real spec.
        if (fd.value) |vexpr| try self.maybeNameAnonymousValue(vexpr, v, fieldDisplayName(fd.key));
        const is_private = fd.key.len > 0 and fd.key[0] == 0;
        const target = &instance.object.value;
        target.set(fd.key, v.retain()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // A constructor can freeze/preventExtensions `this` BEFORE
            // fields initialize. Per spec, a PUBLIC field then fails
            // with a TypeError (CreateDataPropertyOrThrow) -- but a
            // PRIVATE field still installs: private names are not
            // ordinary properties, so [[Extensible]]/frozen don't apply.
            // Bypass by briefly lifting the flags for the private add.
            error.ObjectIsFrozen, error.ObjectNotExtensible, error.PropertyNotWritable => {
                if (!is_private) {
                    return self.throwError(.type_error, "Cannot define property {s}, object is not extensible", .{fd.key});
                }
                const saved_frozen = target.is_frozen;
                const saved_ext = target.is_extensible;
                target.is_frozen = false;
                target.is_extensible = true;
                defer {
                    target.is_frozen = saved_frozen;
                    target.is_extensible = saved_ext;
                }
                target.set(fd.key, v.retain()) catch |e2| return switch (e2) {
                    error.OutOfMemory => error.OutOfMemory,
                    else => unreachable, // flags lifted; nothing else can gate a fresh key
                };
            },
            else => return err,
        };
    }
}

/// ECMA-262 15.7 ClassDefinitionEvaluation, narrowed: a constructable
/// function (classConstructorCall) whose prototype object holds the
/// instance methods/accessors and chains to the parent's prototype;
/// statics live in the function's bag, chained to the parent's bag
/// (static inheritance). Fields (public/private/static), private
/// methods/accessors, computed keys, and static blocks all supported;
/// still no new.target/decorators -- see README.
pub fn evalClass(self: *Interpreter, env: *Environment, cnode: *zfunctions.ClassNode) anyerror!JSValue {
    const arena = self.gc_allocator;

    var super_ctor: ?JSValue = null;
    var super_proto: ?JSValue = null;
    if (cnode.superclass) |sc_expr| {
        const sc = try self.evalExpression(env, sc_expr);
        if (sc != .function or !sc.function.value.constructable) {
            defer sc.deinit();
            const shown = try coercion.toDisplayString(arena, sc);
            defer arena.free(shown);
            return self.throwError(.type_error, "Class extends value {s} is not a constructor or null", .{shown});
        }
        super_ctor = sc;
        super_proto = try self.functionPrototype(sc);
    }

    // Named classes can self-reference inside method bodies (same
    // wrapper-env trick as named function expressions).
    const closure_env = if (cnode.name != null) try self.gcChildEnv(env) else env;

    var proto = try self.gcNewObject();
    if (super_proto) |sp|
        try proto.object.value.setPrototype(&sp.object.value)
    else if (self.protos.object == .object)
        try proto.object.value.setPrototype(&self.protos.object.object.value);

    var ctor_fnode: ?*zfunctions.FunctionNode = null;
    for (cnode.elements) |el| {
        if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) {
            ctor_fnode = el.function;
        }
    }

    const cctx = try arena.create(ClassCtx);
    cctx.* = .{
        .interp = self,
        .ctor_fnode = ctor_fnode,
        .closure_env = closure_env,
        .name = cnode.name orelse "",
        .super_ctor = super_ctor,
        .super_proto = super_proto,
    };
    try self.gcTrackClassCtx(cctx);
    const class_fn = try self.gcNewFunction(.{
        .ctx = cctx,
        .name = cnode.name orelse "",
        .arity = if (ctor_fnode) |f| expectedArgumentCount(f.params) else 0,
        .call = classConstructorCall,
        .constructable = true,
    });
    // Real spec (MakeConstructor): `constructor` is installed with
    // [[Enumerable]]: false, same as every class method/accessor below.
    try proto.object.value.defineProperty("constructor", class_fn.retain(), .{ .writable = true, .enumerable = false, .configurable = true });
    class_fn.function.value.prototype = proto;

    // A derived class always gets a statics bag chained to the
    // parent's (forcing the parent's into existence) so static
    // inheritance works even when this class declares no statics.
    if (super_ctor) |parent| {
        const parent_bag = try self.functionStatics(parent);
        const bag = try self.functionStatics(class_fn);
        try bag.object.value.setPrototype(&parent_bag.object.value);
    }

    // The class's own name binds BEFORE static elements run (spec:
    // ClassDefinitionEvaluation initializes the inner binding before
    // static fields/blocks execute, so `static { C.x = 1 }` works).
    if (cnode.name) |n| try closure_env.define(arena, n, class_fn.retain());

    // One pass, in declaration order (the spec's order matters for
    // computed-key evaluation, static field initializers, and static
    // blocks, which all run interleaved right here).
    var instance_fields: std.ArrayList(FieldDef) = .empty;
    for (cnode.elements) |el| {
        if (el.kind == .static_block) {
            // Runs once, now, with this = the class and privates in
            // scope.
            _ = try invokeFunctionNode(self, el.function.?, closure_env, arena, class_fn, super_proto, null, cctx, &.{}, null);
            continue;
        }

        // Resolve the property key: computed keys evaluate ONCE, here,
        // in order; private keys encode against this class's identity.
        const key: []const u8 = switch (el.key) {
            .ident => |n| n,
            .private => |n| try self.encodePrivateKey(cctx, n),
            .computed => |expr| blk: {
                // encodeKey handles BOTH symbols (`[Symbol.iterator]`,
                // encoded like any symbol-keyed property) and ordinary
                // values (ToPropertyKey string form). Neither `kv` nor
                // the encoded key itself is freed here: evalExpression's
                // ownership isn't uniform (an `.identifier` read is
                // BORROWED, no retain -- see memberKeyString's doc
                // comment for the Test262-confirmed crash this caused
                // once already), and the encoded key must outlive this
                // loop iteration anyway (stored in `instance_fields`
                // for per-construction use; freeGarbageNode's
                // `.class_ctx` case only frees the array, not each
                // key's content -- documented residual gap, narrow/
                // one-time-per-class, not chased further here).
                const kv = try self.evalExpression(closure_env, expr);
                break :blk try self.encodeKey(kv);
            },
        };

        // Real spec: a static class element (field, method, accessor,
        // or generator) named "prototype" is a TypeError -- confirmed
        // against real Node (a LITERAL `static prototype(){}` is
        // actually an earlier parse-time SyntaxError there, which this
        // engine's parser doesn't implement yet; this runtime check at
        // least catches every case reachable today, matching the
        // spec-mandated computed-key case -- `static ['prototype'](){}`
        // -- exactly, and improves the literal case from silently
        // doing nothing to a real TypeError).
        if (el.is_static and std.mem.eql(u8, key, "prototype")) {
            return self.throwError(.type_error, "Classes may not have a static property named 'prototype'", .{});
        }

        if (el.kind == .field) {
            if (el.is_static) {
                // Static fields initialize at DEFINITION time, in
                // order, with this = the class function.
                const field_env = try self.gcChildEnv(closure_env);
                field_env.this_value = class_fn;
                field_env.super_proto = super_proto;
                field_env.private_ctx = cctx;
                const v = if (el.value) |vexpr| try self.evalExpression(field_env, vexpr) else JSValue.UNDEFINED;
                // NamedEvaluation: `class C { static x = AnonFn }` names
                // it "x" (or "#x" for a private static field, via
                // fieldDisplayName -- see runInstanceFields).
                if (el.value) |vexpr| try self.maybeNameAnonymousValue(vexpr, v, fieldDisplayName(key));
                const bag = try self.functionStatics(class_fn);
                try bag.object.value.set(key, v.retain());
            } else {
                // Instance fields are CAPTURED here (key already
                // resolved) and initialized per-instance at
                // construction time.
                try instance_fields.append(arena, .{ .key = key, .value = el.value });
            }
            continue;
        }

        // Methods / accessors.
        if (!el.is_static and el.kind == .method and el.key == .ident and std.mem.eql(u8, el.key.ident, "constructor")) continue;
        const m = try self.makeMethodClosure(closure_env, el.function.?, super_proto, cctx);
        const target = if (el.is_static) try self.functionStatics(class_fn) else proto;
        // Real spec (ClassDefinitionEvaluation/PropertyDefinitionEvaluation
        // for MethodDefinition): every class method/accessor is installed
        // via DefinePropertyOrThrow with [[Enumerable]]: false --
        // `target.object.value.set`/`defineAccessor`'s own defaults
        // (Property.init: enumerable true, matching a plain object
        // literal) are wrong here. Regular methods get an explicit
        // descriptor directly; accessors go through defineAccessor
        // first (so a separate `get x(){}`/`set x(v){}` pair still
        // merges into ONE property, its own documented behavior) then
        // have their descriptor corrected the same way
        // definePropertyFromJs already does for JS-level accessors.
        const method_attrs = zvalue.PropertyDescriptor{ .writable = true, .enumerable = false, .configurable = true };
        switch (el.kind) {
            .method => try target.object.value.defineProperty(key, m, method_attrs),
            .get => {
                try target.object.value.defineAccessor(key, m, null, JSValue.UNDEFINED);
                const rec = target.object.value.getOwnRecordMut(key).?;
                rec.descriptor.enumerable = false;
                rec.descriptor.configurable = true;
            },
            .set => {
                try target.object.value.defineAccessor(key, null, m, JSValue.UNDEFINED);
                const rec = target.object.value.getOwnRecordMut(key).?;
                rec.descriptor.enumerable = false;
                rec.descriptor.configurable = true;
            },
            .field, .static_block => unreachable,
        }
    }
    cctx.instance_fields = try instance_fields.toOwnedSlice(arena);
    return class_fn;
}

/// The shared body of every user-code invocation: fresh call env off the
/// closure env, this/super bindings, parameter binding (defaults, rest,
/// destructuring via bindPattern), then the body. `this_value` null =
/// don't bind (arrows -- resolveThis walks up instead).
// z-interpreter-refactor.md, Step 5 Phase C batch 3: `pub` so
// interpreter_runtime.zig's fiberEntry (async cluster) can reach it --
// also used by evalClass/closureCall/classConstructorCall (future
// class-cluster batch), staying here since multiple clusters need it.
pub fn invokeFunctionNode(
    self: *Interpreter,
    fnode: *zfunctions.FunctionNode,
    closure_env: *Environment,
    allocator: Allocator,
    this_value: ?JSValue,
    super_proto: ?JSValue,
    super_ctor: ?JSValue,
    private_ctx: ?*anyopaque,
    args: []const JSValue,
    home_object: ?JSValue,
) anyerror!JSValue {
    const call_env = try self.gcChildEnv(closure_env);
    if (this_value) |tv| call_env.this_value = tv;
    call_env.super_proto = super_proto;
    call_env.super_ctor = super_ctor;
    call_env.private_ctx = private_ctx;
    call_env.home_object = home_object;

    // `arguments`: every non-arrow call gets one (arrows inherit the
    // enclosing function's via the scope chain -- no binding here).
    // Materialized as a real array snapshot (always-strict => unmapped;
    // narrowing: not the exotic Arguments object -- see README). Defined
    // BEFORE params so a parameter/rest named `arguments` shadows it.
    if (fnode.kind != .arrow) {
        var arguments = try self.gcNewArray();
        for (args) |a| _ = try arguments.array.value.push(a.retain());
        try call_env.define(allocator, "arguments", arguments);
    }

    for (fnode.params.items, 0..) |param, i| {
        var value = if (i < args.len) args[i] else JSValue.UNDEFINED;
        if (value == .@"undefined") {
            if (param.default) |def| {
                value = try self.evalExpression(call_env, def);
                // NamedEvaluation: `function f(x = AnonFn)` names it "x".
                if (param.pattern.* == .identifier) {
                    try self.maybeNameAnonymousValue(def, value, param.pattern.identifier.name);
                }
            }
        }
        try self.bindPattern(call_env, param.pattern, value, .define);
    }
    if (fnode.params.rest) |rest| {
        var rest_arr = try self.gcNewArray();
        const start = fnode.params.items.len;
        if (start < args.len) {
            for (args[start..]) |a| _ = try rest_arr.array.value.push(a.retain());
        }
        // Real spec: a rest parameter can be a destructuring pattern
        // (`function f(...[a, b]) {}`), not just a plain identifier --
        // confirmed against real Node (test262 exercises this too).
        // bindPattern already handles both shapes (its `.identifier`
        // case is exactly the old `call_env.define(rest.name, ...)`
        // path), same as every other parameter above.
        try self.bindPattern(call_env, rest, rest_arr, .define);
    }

    switch (fnode.body) {
        .block => |body_stmt| {
            const c = try self.evalBody(call_env, body_stmt.data.block);
            if (c.type == .return_completion) return c.value;
            return JSValue.UNDEFINED;
        },
        .expression => |expr| return try self.evalExpression(call_env, expr),
    }
}

fn closureCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const closure_ctx: *ClosureCtx = @ptrCast(@alignCast(ctx));
    const fnode = closure_ctx.function_node;
    // Arrows have no own `this` binding -- passing null makes
    // `resolveThis()` walk up to closure_env's, matching real lexical
    // `this` inheritance.
    const this: ?JSValue = if (fnode.kind != .arrow) this_value else null;
    if (fnode.is_generator and fnode.is_async) {
        return closure_ctx.interp.makeAsyncGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    if (fnode.is_generator) {
        return closure_ctx.interp.makeGeneratorObject(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    if (fnode.is_async) {
        return closure_ctx.interp.runAsyncFunction(fnode, closure_ctx.closure_env, this, closure_ctx.private_ctx, args);
    }
    return invokeFunctionNode(closure_ctx.interp, fnode, closure_ctx.closure_env, allocator, this, closure_ctx.super_proto, null, closure_ctx.private_ctx, args, closure_ctx.home_object);
}

fn classConstructorCall(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    const cctx: *ClassCtx = @ptrCast(@alignCast(ctx));
    const self = cctx.interp;
    if (self.construct_target != ctx) {
        return self.throwError(.type_error, "Class constructor {s} cannot be invoked without 'new'", .{cctx.name});
    }
    // Consume the token: plain calls made inside the constructor body
    // must not look like constructions (evalNew's defer restores it for
    // its own caller either way).
    self.construct_target = null;

    // Instance fields: a BASE class initializes them before its ctor body
    // (spec: right after this-creation); a DERIVED class defers them until
    // super() returns -- armed here, consumed by evalCall's super() branch
    // (save/restore keeps nested constructions inside the body correct).
    if (cctx.super_ctor == null) {
        try self.runInstanceFields(cctx, this_value);
    }

    if (cctx.ctor_fnode) |fnode| {
        if (cctx.super_ctor != null) {
            const prev_pending = self.pending_field_init;
            self.pending_field_init = cctx;
            defer self.pending_field_init = prev_pending;
            return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args, null);
        }
        return invokeFunctionNode(self, fnode, cctx.closure_env, allocator, this_value, cctx.super_proto, cctx.super_ctor, cctx, args, null);
    }
    // Implicit constructor: a derived class forwards this + args to its
    // parent (`constructor(...args) { super(...args) }`) and then runs its
    // own field initializers; a base class is a no-op.
    if (cctx.super_ctor) |parent| {
        self.construct_target = parent.function.value.ctx;
        defer self.construct_target = null;
        _ = try parent.function.value.call(parent.function.value.ctx, allocator, this_value, args);
        try self.runInstanceFields(cctx, this_value);
    }
    return JSValue.UNDEFINED;
}
