const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const EnvError = error{ReferenceError};

/// A lexical scope. Environments are arena-allocated for the whole
/// interpreter run and never individually freed -- see Interpreter's own
/// doc comment for why (closures need their defining environment to
/// outlive the call that created them; proper GC/refcounting of the
/// environment graph is out of scope for a first interpreter).
pub const Environment = struct {
    parent: ?*Environment,
    bindings: std.StringHashMapUnmanaged(JSValue) = .empty,
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

    /// var/let/const declarations and function parameters all land here.
    /// Always defines in THIS environment (never walks up). Redeclaration
    /// silently overwrites -- no TDZ/no-redeclaration checking, consistent
    /// with this phase's no-hoisting simplification (see Interpreter).
    pub fn define(self: *Environment, arena: Allocator, name: []const u8, value: JSValue) !void {
        try self.bindings.put(arena, name, value);
    }

    /// Walks the parent chain. Returns null if the name isn't bound
    /// anywhere -- callers turn that into error.ReferenceError.
    pub fn get(self: *Environment, name: []const u8) ?JSValue {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.bindings.get(name)) |v| return v;
        }
        return null;
    }

    /// Walks the parent chain to find the OWNING environment and
    /// overwrites the binding there (does not create a new binding in the
    /// current environment -- that's `define`'s job). No implicit global
    /// creation: an undeclared name is a hard error.
    pub fn assign(self: *Environment, name: []const u8, value: JSValue) EnvError!void {
        var env: ?*Environment = self;
        while (env) |e| : (env = e.parent) {
            if (e.bindings.getPtr(name)) |slot| {
                slot.* = value;
                return;
            }
        }
        return EnvError.ReferenceError;
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
