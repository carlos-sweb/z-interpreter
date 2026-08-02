//! `Symbol`: callable-but-not-constructable, the well-known symbols,
//! and the global `Symbol.for`/`Symbol.keyFor` registry. z-interpreter-
//! refactor.md, Step 5 Phase A.

const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const zbigint = @import("zbigint");
const JSValue = zvalue.JSValue;

const interpreter_mod = @import("interpreter.zig");
const Interpreter = interpreter_mod.Interpreter;
const coercion = @import("coercion.zig");
const native_helpers = @import("native_helpers.zig");
const builtin_helpers = @import("builtin_helpers.zig");

pub const NativeFn = native_helpers.NativeFn;
const MethodSpec = native_helpers.MethodSpec;
const interp = native_helpers.interp;
const arg = native_helpers.arg;
const native = native_helpers.native;
const dneMethod = builtin_helpers.dneMethod;
const dneConst = builtin_helpers.dneConst;
const requireTag = builtin_helpers.requireTag;
const installBuiltin = builtin_helpers.installBuiltin;

pub const symbol_methods = std.StaticStringMap(MethodSpec).initComptime(.{
    .{ "toString", MethodSpec{ .call = symbolToString, .arity = 0 } },
    .{ "valueOf", MethodSpec{ .call = symbolValueOf, .arity = 0 } },
});

fn symbolConstructor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    // `new Symbol()` is a real TypeError -- Symbol is not a constructor.
    if (self.construct_target == ctx) {
        return self.throwError(.type_error, "Symbol is not a constructor", .{});
    }
    const desc: ?[]const u8 = switch (arg(args, 0)) {
        .undefined => null,
        else => |v| try coercion.toDisplayString(allocator, v),
    };
    defer if (desc) |d| allocator.free(d);
    return self.gcNewSymbol(desc);
}

fn symbolToString(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = args;
    if (this_value != .symbol) return interp(ctx).throwError(.type_error, "Symbol.prototype.toString requires a symbol", .{});
    const s = try this_value.symbol.value.toString(allocator);
    defer allocator.free(s);
    return interp(ctx).gcNewString(s);
}

fn symbolValueOf(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = ctx;
    _ = allocator;
    _ = args;
    return this_value.retain();
}

fn symbolFor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = this_value;
    const self = interp(ctx);
    const key = try coercion.toDisplayString(allocator, arg(args, 0));
    if (self.symbol_registry.get(key)) |sym| {
        allocator.free(key);
        return sym.retain();
    }
    // Not found: `key`'s ownership transfers to symbol_registry as its
    // own hashmap key (no separate free -- matches self.symbol_keys'
    // established convention elsewhere).
    const sym = try self.gcNewSymbol(key);
    try self.symbol_registry.put(self.gc_allocator, key, sym.retain());
    return sym;
}

fn symbolKeyFor(ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue {
    _ = allocator;
    _ = this_value;
    const self = interp(ctx);
    const target = arg(args, 0);
    if (target != .symbol) return self.throwError(.type_error, "Symbol.keyFor requires a symbol", .{});
    var it = self.symbol_registry.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* == .symbol and entry.value_ptr.symbol == target.symbol) {
            return interp(ctx).gcNewString(entry.key_ptr.*);
        }
    }
    return JSValue.UNDEFINED;
}

/// Installs the `Symbol` constructor, its well-known-symbol statics, and
/// `for`/`keyFor`. Also sets `self.symbol_iterator`/`self.symbol_async_iterator`
/// (real side effects other domains read -- e.g. builtin iterator objects).
pub fn install(self: *Interpreter) !void {
    const arena = self.gc_allocator;
    const g = self.global_env;

    // Symbol: callable but NOT constructable (`new Symbol()` throws).
    // The well-known symbols and the for()/keyFor() registry are JSValue
    // symbols owned by the interpreter (identity = Rc box).
    const symbol_ctor = try self.gcNewFunction(.{ .ctx = self, .name = "Symbol", .arity = 0, .call = symbolConstructor });
    const symbol_statics = try self.functionStatics(symbol_ctor);
    inline for (.{ "iterator", "asyncIterator", "hasInstance", "toPrimitive", "toStringTag", "species", "isConcatSpreadable", "match", "replace", "search", "split", "unscopables" }) |wk| {
        const sym = try self.gcNewSymbol("Symbol." ++ wk);
        try dneConst(symbol_statics, wk, sym.retain());
        // These interpreter fields need their OWN retained reference --
        // they must not be an unretained alias of whatever else holds
        // `sym` (the Symbol.<wk> static property here), since that other
        // holder can independently release its copy (e.g. a reassignable
        // global binding losing its old value -- see the identical fix
        // for eval_fn/global_object just below).
        if (comptime std.mem.eql(u8, wk, "iterator")) self.symbol_iterator = sym.retain();
        if (comptime std.mem.eql(u8, wk, "asyncIterator")) self.symbol_async_iterator = sym.retain();
    }
    try dneMethod(symbol_statics, "for", try native(self, "for", 1, symbolFor));
    try dneMethod(symbol_statics, "keyFor", try native(self, "keyFor", 1, symbolKeyFor));
    try g.define(arena, "Symbol", symbol_ctor);
}
