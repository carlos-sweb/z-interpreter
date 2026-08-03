const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const EnvError = error{ReferenceError};
pub const AssignError = error{ ReferenceError, BeforeInitialization };

/// Result of a chain lookup: a live value, a binding that exists but is
/// still in its temporal dead zone (`x; let x = 1;`), or nothing at all.
pub const Lookup = union(enum) { value: JSValue, tdz, not_found };

/// A lexical scope. Environments are arena-allocated for the whole
/// interpreter run and never individually freed -- see Interpreter's own
/// doc comment for why (closures need their defining environment to
/// outlive the call that created them; proper GC/refcounting of the
/// environment graph is out of scope for a first interpreter).
pub const Environment = struct {
    parent: ?*Environment,
    bindings: std.StringHashMapUnmanaged(JSValue) = .empty,
    /// Names declared (let/const/class) in this scope but not yet
    /// initialized -- the temporal dead zone. Marked by the lexical
    /// hoisting pre-pass at scope entry; cleared by `define` when the
    /// declaration actually executes.
    tdz: std.StringHashMapUnmanaged(void) = .empty,
    /// Non-null only at a function-call boundary -- see Interpreter's
    /// this-binding handling. Falls through to JSValue.UNDEFINED at the
    /// global environment via `resolveThis`.
    this_value: ?JSValue = null,
    /// The `super` bindings, non-null only at a class method/constructor
    /// call boundary: the parent class's prototype object (for
    /// `super.m()`) and constructor function (for `super(...)`). Resolved
    /// by chain walk like `this` -- arrows nested in methods inherit.
    super_proto: ?JSValue = null,
    super_ctor: ?JSValue = null,
    /// Non-null only at an object-literal method/getter/setter call
    /// boundary: the object literal itself (real spec's [[HomeObject]]).
    /// Unlike `super_proto` (a class method's parent prototype, captured
    /// ONCE at class-definition time), `super.x` here must resolve the
    /// home object's CURRENT prototype at every access -- real spec's
    /// GetSuperBase reads home.[[GetPrototypeOf]]() fresh each time, so
    /// e.g. `Object.setPrototypeOf(obj, proto)` called after `obj`'s
    /// literal finished evaluating still changes what `super.m()` finds
    /// inside its methods (confirmed against real Node; test262 exercises
    /// exactly this). `resolveSuperHome` is checked BEFORE `super_proto`
    /// at the one `super.x` resolution site, so class semantics (which
    /// never set this field) are completely unaffected.
    home_object: ?JSValue = null,
    /// The enclosing class's identity (an opaque `*ClassCtx` pointer),
    /// non-null only at a class method/constructor/field-initializer call
    /// boundary -- ECMA-262's PrivateEnvironment, collapsed to a single
    /// class identity. `this.#x` resolves the private name against it.
    /// Chain-walked like `this`/super, so arrows in methods inherit it.
    private_ctx: ?*anyopaque = null,

    pub fn child(self: *Environment, arena: Allocator) !*Environment {
        const env = try arena.create(Environment);
        env.* = .{ .parent = self };
        return env;
    }

    /// Declarations and function parameters all land here. Always defines
    /// in THIS environment (never walks up). Clears any TDZ mark on the
    /// name -- an executing declaration IS the initialization.
    pub fn define(self: *Environment, arena: Allocator, name: []const u8, value: JSValue) !void {
        _ = self.tdz.remove(name);
        try self.bindings.put(arena, name, value);
    }

    /// Marks a lexically-declared name as existing-but-uninitialized in
    /// this scope. Set by the hoisting pre-pass at scope entry.
    pub fn markTDZ(self: *Environment, arena: Allocator, name: []const u8) !void {
        try self.tdz.put(arena, name, {});
    }

    /// True when this environment itself already declares the name (as a
    /// live binding or a TDZ mark) -- the redeclaration check.
    pub fn declaresLocally(self: *Environment, name: []const u8) bool {
        return self.bindings.contains(name) or self.tdz.contains(name);
    }

    /// Walks the parent chain. Returns null if the name isn't bound
    /// anywhere. TDZ-blind -- prefer `lookup` in evaluation paths; this
    /// stays for callers that only care about presence (typeof's
    /// undeclared case, globals setup).
    pub fn get(self: *Environment, name: []const u8) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.bindings.get(name)) |v| return v;
        }
        return null;
    }

    /// Chain lookup with TDZ awareness. The TDZ mark is consulted BEFORE
    /// the bindings at each level, and the walk stops at the first scope
    /// that knows the name either way -- so an inner `let x` in its dead
    /// zone correctly shadows an initialized outer `x`
    /// (`let x = 1; { x; let x = 2; }` is the real ReferenceError).
    pub fn lookup(self: *Environment, name: []const u8) Lookup {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.tdz.contains(name)) return .tdz;
            if (e.bindings.get(name)) |v| return .{ .value = v };
        }
        return .not_found;
    }

    /// Walks the parent chain to find the OWNING environment and
    /// overwrites the binding there (does not create a new binding in the
    /// current environment -- that's `define`'s job). No implicit global
    /// creation: an undeclared name is a hard error, and assigning to a
    /// binding still in its dead zone (`x = 1; let x;`) is its own error.
    ///
    /// Ownership: takes `value` (the caller must already own/have retained
    /// it, same contract as `define`), and releases whatever was
    /// previously in the slot -- every call site now retains before
    /// calling, so the displaced value is safe to release here.
    pub fn assign(self: *Environment, name: []const u8, value: JSValue) AssignError!void {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.tdz.contains(name)) return AssignError.BeforeInitialization;
            if (e.bindings.getPtr(name)) |slot| {
                slot.deinit();
                slot.* = value;
                return;
            }
        }
        return AssignError.ReferenceError;
    }

    /// Walks up until a non-null this_value is found; falls through to
    /// JSValue.UNDEFINED at the global environment.
    pub fn resolveThis(self: *Environment) JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.this_value) |v| return v;
        }
        return JSValue.UNDEFINED;
    }

    /// Walks up until a non-null super_proto is found -- null means
    /// `super` is not legal here (not inside a class method).
    pub fn resolveSuperProto(self: *Environment) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.super_proto) |v| return v;
        }
        return null;
    }

    /// Walks up until a non-null home_object is found -- see its own
    /// doc comment. Checked BEFORE resolveSuperProto at the `super.x`
    /// resolution site (object-literal methods never set super_proto,
    /// class methods never set home_object -- the two are mutually
    /// exclusive in practice, but checking home_object first is what
    /// makes that ordering-independent).
    pub fn resolveSuperHome(self: *Environment) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.home_object) |v| return v;
        }
        return null;
    }

    /// Walks up until a non-null private_ctx is found -- null means no
    /// enclosing class (a `#x` access there is an error).
    pub fn resolvePrivateCtx(self: *Environment) ?*anyopaque {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.private_ctx) |v| return v;
        }
        return null;
    }

    /// Walks up until a non-null super_ctor is found -- null means
    /// `super(...)` is not legal here (not inside a derived constructor).
    pub fn resolveSuperCtor(self: *Environment) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.super_ctor) |v| return v;
        }
        return null;
    }

    /// GC prep (roadmap item 15, phase 2): enumerates every node directly
    /// reachable from this environment, for a future mark-phase to recurse
    /// through. `visitor` is duck-typed with `value(JSValue) void` (a
    /// binding/this/super value) and `environment(*Environment) void`
    /// (the parent link -- environments aren't JSValues, so they get their
    /// own visit method). `tdz` holds only names, nothing to trace.
    ///
    /// Deliberately does NOT touch `private_ctx`: it's a `*ClassCtx` in
    /// disguise (`*anyopaque` here so this file doesn't need to know about
    /// the interpreter's class machinery) -- the caller special-cases it
    /// after calling this, once it has the real type back.
    pub fn traceChildren(self: *const Environment, visitor: anytype) void {
        if (self.parent) |p| visitor.environment(p);
        var it = self.bindings.valueIterator();
        while (it.next()) |v| visitor.value(v.*);
        if (self.this_value) |v| visitor.value(v);
        if (self.super_proto) |v| visitor.value(v);
        if (self.super_ctor) |v| visitor.value(v);
        if (self.home_object) |v| visitor.value(v);
    }
};

const MockVisitor = struct {
    values: std.ArrayList(JSValue) = .empty,
    environments: std.ArrayList(*Environment) = .empty,

    fn value(self: *MockVisitor, v: JSValue) void {
        self.values.append(std.testing.allocator, v) catch unreachable;
    }
    fn environment(self: *MockVisitor, e: *Environment) void {
        self.environments.append(std.testing.allocator, e) catch unreachable;
    }
    fn deinit(self: *MockVisitor) void {
        self.values.deinit(std.testing.allocator);
        self.environments.deinit(std.testing.allocator);
    }
};

test "traceChildren visits the parent, every binding, this/super, but not tdz names or private_ctx" {
    const testing = std.testing;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var parent = Environment{ .parent = null };
    var child_env = try parent.child(arena);
    try child_env.define(arena, "x", JSValue.fromNumber(1));
    try child_env.define(arena, "y", JSValue.fromNumber(2));
    try child_env.markTDZ(arena, "z"); // TDZ-only: no value to visit
    child_env.this_value = JSValue.fromNumber(3);
    child_env.super_proto = JSValue.fromNumber(4);
    child_env.super_ctor = JSValue.fromNumber(5);
    child_env.private_ctx = @ptrFromInt(0xdead); // must NOT be visited (opaque here)

    var mock: MockVisitor = .{};
    defer mock.deinit();
    child_env.traceChildren(&mock);

    try testing.expectEqual(@as(usize, 1), mock.environments.items.len);
    try testing.expectEqual(&parent, mock.environments.items[0]);
    // x, y, this_value, super_proto, super_ctor -- exactly 5 values, nothing
    // from tdz-only "z" and no trace of private_ctx's opaque pointer.
    try testing.expectEqual(@as(usize, 5), mock.values.items.len);
    var sum: f64 = 0;
    for (mock.values.items) |v| sum += v.number;
    try testing.expectEqual(@as(f64, 1 + 2 + 3 + 4 + 5), sum);
}

test "traceChildren on the root environment (no parent) visits zero environments" {
    const testing = std.testing;
    var root = Environment{ .parent = null };
    var mock: MockVisitor = .{};
    defer mock.deinit();
    root.traceChildren(&mock);
    try testing.expectEqual(@as(usize, 0), mock.environments.items.len);
    try testing.expectEqual(@as(usize, 0), mock.values.items.len);
}
