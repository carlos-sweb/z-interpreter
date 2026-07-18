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
    pub fn assign(self: *Environment, name: []const u8, value: JSValue) AssignError!void {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.tdz.contains(name)) return AssignError.BeforeInitialization;
            if (e.bindings.getPtr(name)) |slot| {
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

    /// Walks up until a non-null super_ctor is found -- null means
    /// `super(...)` is not legal here (not inside a derived constructor).
    pub fn resolveSuperCtor(self: *Environment) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.super_ctor) |v| return v;
        }
        return null;
    }
};
