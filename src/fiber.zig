//! Minimal stackful-coroutine wrapper over std.Io.fiber's raw
//! context-switch primitives -- the suspension mechanism behind
//! generators and async/await. The tree-walking evaluator runs
//! UNCHANGED on the fiber's stack; `yield`/`await` switch back to the
//! scheduler side and `next()`/promise-resumption switch back in.
//!
//! Deliberately NOT std.Io.Evented (experimental, opaque scheduling):
//! one fiber runs at a time, cooperatively -- JS run-to-completion
//! semantics fall out of the design. Mechanism mirrors how the stdlib's
//! own Uring backend creates fibers: a context struct placed at the top
//! of the fresh stack, an initial Context whose pc targets a naked
//! trampoline that recovers that struct from the stack pointer, and the
//! `Switch` message arriving in the second-argument register.
//! Validated by a standalone spike before this file existed.
const std = @import("std");
const builtin = @import("builtin");
const iofiber = std.Io.fiber;
const Allocator = std.mem.Allocator;

pub const supported = switch (builtin.cpu.arch) {
    .x86_64, .aarch64 => true,
    else => false,
};

/// 8 MiB of virtual address space per fiber (lazily paged by the OS --
/// untouched pages cost nothing), matching a typical main-thread stack
/// so the interpreter's stack-depth guard behaves the same on and off
/// fibers. Fiber stacks are arena-allocated and never individually
/// freed -- consistent with the interpreter's arena-per-run model; the
/// GC phase revisits this.
const stack_size = 8 * 1024 * 1024;

pub const Fiber = struct {
    /// How to resume this fiber (valid while suspended; initially aims
    /// at the trampoline).
    resume_ctx: iofiber.Context,
    /// Where suspendSelf returns to (the resumer's saved state).
    return_ctx: iofiber.Context,
    entry_fn: *const fn (arg: *anyopaque) void,
    arg: *anyopaque,
    /// Set by the entry wrapper when entry_fn returns. Switching into a
    /// finished fiber is illegal (asserted).
    finished: bool,
    /// Lowest usable stack address -- the interpreter's stack-depth
    /// guard refuses to recurse past `stack_floor + margin` while this
    /// fiber runs (stacks grow down).
    stack_floor: usize,

    /// Allocates the stack, places the Fiber struct at its top, and arms
    /// the initial context. `entry(arg)` starts running on the first
    /// switchTo; when it returns, the fiber marks itself finished and
    /// switches back one final time.
    pub fn init(arena: Allocator, entry: *const fn (arg: *anyopaque) void, arg: *anyopaque) !*Fiber {
        comptime std.debug.assert(supported);
        const stack = try arena.alignedAlloc(u8, .fromByteUnits(16), stack_size);
        const top = @intFromPtr(stack.ptr) + stack.len;
        const self_addr = std.mem.alignBackward(usize, top - @sizeOf(Fiber), 16);
        const self: *Fiber = @ptrFromInt(self_addr);
        self.* = .{
            .resume_ctx = switch (builtin.cpu.arch) {
                .x86_64 => .{ .rsp = self_addr - 8, .rbp = 0, .rip = @intFromPtr(&trampoline) },
                .aarch64 => .{ .sp = self_addr, .fp = 0, .pc = @intFromPtr(&trampoline) },
                else => comptime unreachable,
            },
            .return_ctx = undefined,
            .entry_fn = entry,
            .arg = arg,
            .finished = false,
            .stack_floor = @intFromPtr(stack.ptr),
        };
        return self;
    }

    /// Scheduler -> fiber. Returns when the fiber suspends or finishes.
    pub fn switchTo(self: *Fiber) void {
        std.debug.assert(!self.finished);
        _ = iofiber.contextSwitch(&.{ .old = &self.return_ctx, .new = &self.resume_ctx });
    }

    /// Fiber -> scheduler. Only legal from code running ON this fiber.
    pub fn suspendSelf(self: *Fiber) void {
        _ = iofiber.contextSwitch(&.{ .old = &self.resume_ctx, .new = &self.return_ctx });
    }

    fn trampoline() callconv(.naked) void {
        switch (builtin.cpu.arch) {
            .x86_64 => asm volatile (
                \\ leaq 8(%%rsp), %%rdi
                \\ jmp %[call:P]
                :
                : [call] "X" (&start),
            ),
            .aarch64 => asm volatile (
                \\ mov x0, sp
                \\ b %[call]
                :
                : [call] "X" (&start),
            ),
            else => comptime unreachable,
        }
    }

    fn start(self: *Fiber, message: *const iofiber.Switch) callconv(.withStackAlign(.c, 16)) noreturn {
        _ = message;
        self.entry_fn(self.arg);
        self.finished = true;
        _ = iofiber.contextSwitch(&.{ .old = &self.resume_ctx, .new = &self.return_ctx });
        unreachable; // switched into a finished fiber
    }
};

test "a fiber suspends with state and resumes to completion" {
    const Counter = struct {
        fiber: *Fiber = undefined,
        value: u32 = 0,

        fn entry(arg: *anyopaque) void {
            const c: *@This() = @ptrCast(@alignCast(arg));
            var i: u32 = 1;
            while (i <= 3) : (i += 1) {
                c.value = i;
                c.fiber.suspendSelf();
            }
        }
    };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    var counter: Counter = .{};
    const f = try Fiber.init(arena_state.allocator(), Counter.entry, &counter);
    counter.fiber = f;

    var total: u32 = 0;
    while (!f.finished) {
        f.switchTo();
        if (!f.finished) total += counter.value;
    }
    try std.testing.expectEqual(@as(u32, 6), total);
}
