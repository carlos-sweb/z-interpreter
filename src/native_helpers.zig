//! Shared native-function plumbing: `interp(ctx)`/`arg(args,i)`/
//! `native(self,name,call_fn)` were hand-copied, byte-identical, in both
//! `builtins.zig` and `temporal_builtins.zig` (z-interpreter-refactor.md,
//! Step 2). Extracted into its own leaf module -- no dependency on
//! anything else in `builtins.zig` -- so any future domain-split file
//! (Step 5) imports this instead of reaching into `builtins.zig`'s
//! internals or growing its own third copy.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;
const Interpreter = @import("interpreter.zig").Interpreter;

pub const NativeFn = *const fn (ctx: *anyopaque, allocator: Allocator, this_value: JSValue, args: []const JSValue) anyerror!JSValue;

/// A native method's callable plus its real spec `.length` (arity) --
/// the value type for every `*_methods` `StaticStringMap` and for
/// `installBuiltin`'s static-method entries. Ground truth for each
/// entry's `arity` came from querying real Node (`fn.length`), not the
/// spec text by hand -- see `~/.plans/pendientes/native-arity-fix.md`.
pub const MethodSpec = struct {
    call: NativeFn,
    arity: usize = 0,
};

pub fn interp(ctx: *anyopaque) *Interpreter {
    return @ptrCast(@alignCast(ctx));
}

pub fn arg(args: []const JSValue, i: usize) JSValue {
    return if (i < args.len) args[i] else JSValue.UNDEFINED;
}

pub fn native(self: *Interpreter, name: []const u8, arity: usize, call_fn: NativeFn) !JSValue {
    return self.gcNewFunction(.{
        .ctx = self,
        .name = name,
        .arity = arity,
        .call = call_fn,
    });
}
