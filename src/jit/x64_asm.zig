const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

pub const is_supported_host = (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux);

pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,

    pub inline fn low3(self: Reg) u3 {
        return @truncate(@intFromEnum(self));
    }

    pub inline fn isExt(self: Reg) bool {
        return (@intFromEnum(self) & 8) != 0;
    }
};

pub const Xmm = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,

    pub inline fn low3(self: Xmm) u3 {
        return @truncate(@intFromEnum(self));
    }

    pub inline fn isExt(self: Xmm) bool {
        return (@intFromEnum(self) & 8) != 0;
    }
};

pub const Cond = enum(u4) {
    o = 0x0,
    no = 0x1,
    b = 0x2, // unsigned <  (CF=1)
    ae = 0x3, // unsigned >= (CF=0)
    e = 0x4, // ==          (ZF=1)
    ne = 0x5, // !=          (ZF=0)
    be = 0x6, // unsigned <= (CF=1 or ZF=1)
    a = 0x7, // unsigned >  (CF=0 and ZF=0)
    s = 0x8, // negative    (SF=1)
    ns = 0x9, // non-neg     (SF=0)
    p = 0xA, // parity / unordered NaN (PF=1)
    np = 0xB, // not parity / ordered (PF=0)
    l = 0xC, // signed <    (SF != OF)
    ge = 0xD, // signed >=   (SF == OF)
    le = 0xE, // signed <=   (ZF=1 or SF != OF)
    g = 0xF, // signed >    (ZF=0 and SF == OF)
};

pub const Label = u32;

const Fixup = struct {
    patch_offset: usize,
    target_label: Label,
};

pub const Assembler = struct {
    allocator: Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    labels: std.ArrayListUnmanaged(?usize) = .empty,
    fixups: std.ArrayListUnmanaged(Fixup) = .empty,

    pub fn init(allocator: Allocator) Assembler {
        return .{ .allocator = allocator };
    }

    pub noinline fn deinit(self: *Assembler) void {
        self.code.deinit(self.allocator);
        self.labels.deinit(self.allocator);
        self.fixups.deinit(self.allocator);
    }

    inline fn rexW(r_ext: bool, b_ext: bool) u8 {
        return 0x48 | (if (r_ext) @as(u8, 4) else 0) | (if (b_ext) @as(u8, 1) else 0);
    }

    inline fn rexSSE(r_ext: bool, b_ext: bool) ?u8 {
        if (!r_ext and !b_ext) return null;
        return 0x40 | (if (r_ext) @as(u8, 4) else 0) | (if (b_ext) @as(u8, 1) else 0);
    }

    inline fn modRM(mod: u2, reg: u3, rm: u3) u8 {
        return (@as(u8, mod) << 6) | (@as(u8, reg) << 3) | @as(u8, rm);
    }

    noinline fn emitByte(self: *Assembler, b: u8) !void {
        try self.code.append(self.allocator, b);
    }

    noinline fn emitBytes(self: *Assembler, bytes: []const u8) !void {
        try self.code.appendSlice(self.allocator, bytes);
    }

    noinline fn emitU32(self: *Assembler, v: u32) !void {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, v, .little);
        try self.emitBytes(&buf);
    }

    noinline fn emitI32(self: *Assembler, v: i32) !void {
        try self.emitU32(@bitCast(v));
    }

    noinline fn emitU64(self: *Assembler, v: u64) !void {
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, v, .little);
        try self.emitBytes(&buf);
    }

    noinline fn emitMemOperand(self: *Assembler, reg_field: u3, base: Reg, disp: i32) !void {
        const rm = base.low3();
        if (disp == 0 and rm != 5) {
            try self.emitByte(modRM(0b00, reg_field, rm));
            if (rm == 4) try self.emitByte(0x24);
        } else if (disp >= -128 and disp <= 127) {
            try self.emitByte(modRM(0b01, reg_field, rm));
            if (rm == 4) try self.emitByte(0x24);
            try self.emitByte(@bitCast(@as(i8, @intCast(disp))));
        } else {
            try self.emitByte(modRM(0b10, reg_field, rm));
            if (rm == 4) try self.emitByte(0x24);
            try self.emitI32(disp);
        }
    }

    pub noinline fn createLabel(self: *Assembler) !Label {
        const id: Label = @intCast(self.labels.items.len);
        try self.labels.append(self.allocator, null);
        return id;
    }

    pub noinline fn bindLabel(self: *Assembler, label: Label) void {
        self.labels.items[label] = self.code.items.len;
    }

    pub noinline fn pushReg(self: *Assembler, reg: Reg) !void {
        if (reg.isExt()) try self.emitByte(0x41);
        try self.emitByte(0x50 + @as(u8, reg.low3()));
    }

    pub noinline fn popReg(self: *Assembler, reg: Reg) !void {
        if (reg.isExt()) try self.emitByte(0x41);
        try self.emitByte(0x58 + @as(u8, reg.low3()));
    }

    pub noinline fn ret(self: *Assembler) !void {
        try self.emitByte(0xC3);
    }

    pub noinline fn movRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x89);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn movRegImm64(self: *Assembler, dst: Reg, imm: u64) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        try self.emitByte(0xB8 + @as(u8, dst.low3()));
        try self.emitU64(imm);
    }

    pub noinline fn movRegImm32(self: *Assembler, dst: Reg, imm: u32) !void {
        if (dst.isExt()) try self.emitByte(0x41);
        try self.emitByte(0xB8 + @as(u8, dst.low3()));
        try self.emitU32(imm);
    }

    pub noinline fn xorRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x31);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn movRegMem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(dst.isExt(), base.isExt()));
        try self.emitByte(0x8B);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn movMemReg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), base.isExt()));
        try self.emitByte(0x89);
        try self.emitMemOperand(src.low3(), base, disp);
    }

    pub noinline fn lea(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(dst.isExt(), base.isExt()));
        try self.emitByte(0x8D);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn addRegImm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 0, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 0, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn addRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x01);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn subRegImm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 5, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 5, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn subRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x29);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn decReg64(self: *Assembler, reg: Reg) !void {
        try self.emitByte(rexW(false, reg.isExt()));
        try self.emitByte(0xFF);
        try self.emitByte(modRM(0b11, 1, reg.low3()));
    }

    pub noinline fn incReg64(self: *Assembler, reg: Reg) !void {
        try self.emitByte(rexW(false, reg.isExt()));
        try self.emitByte(0xFF);
        try self.emitByte(modRM(0b11, 0, reg.low3()));
    }

    pub noinline fn cmpRegReg(self: *Assembler, lhs: Reg, rhs: Reg) !void {
        try self.emitByte(rexW(rhs.isExt(), lhs.isExt()));
        try self.emitByte(0x39);
        try self.emitByte(modRM(0b11, rhs.low3(), lhs.low3()));
    }

    pub noinline fn cmpRegMem(self: *Assembler, lhs: Reg, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(lhs.isExt(), base.isExt()));
        try self.emitByte(0x3B);
        try self.emitMemOperand(lhs.low3(), base, disp);
    }

    pub noinline fn cmpMemImm32(self: *Assembler, base: Reg, disp: i32, imm: i32) !void {
        try self.emitByte(rexW(false, base.isExt()));
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitMemOperand(7, base, disp);
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitMemOperand(7, base, disp);
            try self.emitI32(imm);
        }
    }

    pub noinline fn testMem32Imm32(self: *Assembler, base: Reg, disp: i32, imm: u32) !void {
        if (base.isExt()) try self.emitByte(0x41);
        try self.emitByte(0xF7);
        try self.emitMemOperand(0, base, disp);
        try self.emitU32(imm);
    }

    pub noinline fn cmpRegImm32(self: *Assembler, lhs: Reg, imm: i32) !void {
        try self.emitByte(rexW(false, lhs.isExt()));
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 7, lhs.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 7, lhs.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn shrRegImm8(self: *Assembler, dst: Reg, count: u8) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        try self.emitByte(0xC1);
        try self.emitByte(modRM(0b11, 5, dst.low3()));
        try self.emitByte(count);
    }

    pub noinline fn shlRegImm8(self: *Assembler, dst: Reg, count: u8) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        try self.emitByte(0xC1);
        try self.emitByte(modRM(0b11, 4, dst.low3()));
        try self.emitByte(count);
    }

    pub noinline fn imulRegRegImm32(self: *Assembler, dst: Reg, src: Reg, imm: i32) !void {
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(rexW(dst.isExt(), src.isExt()));
            try self.emitByte(0x6B);
            try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(rexW(dst.isExt(), src.isExt()));
            try self.emitByte(0x69);
            try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn testRegReg(self: *Assembler, a: Reg, b: Reg) !void {
        try self.emitByte(rexW(b.isExt(), a.isExt()));
        try self.emitByte(0x85);
        try self.emitByte(modRM(0b11, b.low3(), a.low3()));
    }

    pub noinline fn cmovpRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(dst.isExt(), src.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0x4A);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn cmovccReg32Reg32(self: *Assembler, cond: Cond, dst: Reg, src: Reg) !void {
        try self.emitRex32(dst.isExt(), src.isExt());
        try self.emitByte(0x0F);
        try self.emitByte(0x40 + @as(u8, @intFromEnum(cond)));
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn andRegImm8(self: *Assembler, dst: Reg, imm: i8) !void {
        try self.emitByte(rexW(false, dst.isExt()));
        try self.emitByte(0x83);
        try self.emitByte(modRM(0b11, 4, dst.low3()));
        try self.emitByte(@bitCast(imm));
    }

    pub noinline fn andRegReg(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x21);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn xorRegReg64(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x31);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    noinline fn emitRex32(self: *Assembler, r_ext: bool, b_ext: bool) !void {
        const rex: u8 = 0x40 | (if (r_ext) @as(u8, 4) else 0) | (if (b_ext) @as(u8, 1) else 0);
        if (rex != 0x40) try self.emitByte(rex);
    }

    pub noinline fn movReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x89);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn addReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x01);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn subReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x29);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn imulReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(dst.isExt(), src.isExt());
        try self.emitByte(0x0F);
        try self.emitByte(0xAF);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn addReg32Imm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitRex32(false, dst.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 0, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 0, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn subReg32Imm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitRex32(false, dst.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 5, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 5, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn andReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x21);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn orReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x09);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn xorReg32Reg32(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitRex32(src.isExt(), dst.isExt());
        try self.emitByte(0x31);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn andReg32Imm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitRex32(false, dst.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 4, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 4, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn orReg32Imm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitRex32(false, dst.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 1, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 1, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn xorReg32Imm32(self: *Assembler, dst: Reg, imm: i32) !void {
        try self.emitRex32(false, dst.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 6, dst.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 6, dst.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn shlReg32Imm8(self: *Assembler, dst: Reg, count: u8) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xC1);
        try self.emitByte(modRM(0b11, 4, dst.low3()));
        try self.emitByte(count);
    }

    pub noinline fn shrReg32Imm8(self: *Assembler, dst: Reg, count: u8) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xC1);
        try self.emitByte(modRM(0b11, 5, dst.low3()));
        try self.emitByte(count);
    }

    pub noinline fn sarReg32Imm8(self: *Assembler, dst: Reg, count: u8) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xC1);
        try self.emitByte(modRM(0b11, 7, dst.low3()));
        try self.emitByte(count);
    }

    pub noinline fn notReg32(self: *Assembler, dst: Reg) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xF7);
        try self.emitByte(modRM(0b11, 2, dst.low3()));
    }

    pub noinline fn shlReg32Cl(self: *Assembler, dst: Reg) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xD3);
        try self.emitByte(modRM(0b11, 4, dst.low3()));
    }

    pub noinline fn shrReg32Cl(self: *Assembler, dst: Reg) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xD3);
        try self.emitByte(modRM(0b11, 5, dst.low3()));
    }

    pub noinline fn sarReg32Cl(self: *Assembler, dst: Reg) !void {
        try self.emitRex32(false, dst.isExt());
        try self.emitByte(0xD3);
        try self.emitByte(modRM(0b11, 7, dst.low3()));
    }

    pub noinline fn divReg32(self: *Assembler, divisor: Reg) !void {
        try self.emitRex32(false, divisor.isExt());
        try self.emitByte(0xF7);
        try self.emitByte(modRM(0b11, 6, divisor.low3()));
    }

    pub noinline fn divReg64(self: *Assembler, divisor: Reg) !void {
        try self.emitByte(rexW(false, divisor.isExt()));
        try self.emitByte(0xF7);
        try self.emitByte(modRM(0b11, 6, divisor.low3()));
    }

    pub noinline fn btReg64Reg64(self: *Assembler, base: Reg, bit: Reg) !void {
        try self.emitByte(rexW(bit.isExt(), base.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0xA3);
        try self.emitByte(modRM(0b11, bit.low3(), base.low3()));
    }

    pub noinline fn btrReg64Reg64(self: *Assembler, dst: Reg, bit: Reg) !void {
        try self.emitByte(rexW(bit.isExt(), dst.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0xB3);
        try self.emitByte(modRM(0b11, bit.low3(), dst.low3()));
    }

    pub noinline fn idivReg32(self: *Assembler, divisor: Reg) !void {
        try self.emitRex32(false, divisor.isExt());
        try self.emitByte(0xF7);
        try self.emitByte(modRM(0b11, 7, divisor.low3()));
    }

    pub noinline fn cmpReg32Imm32(self: *Assembler, lhs: Reg, imm: i32) !void {
        try self.emitRex32(false, lhs.isExt());
        if (imm >= -128 and imm <= 127) {
            try self.emitByte(0x83);
            try self.emitByte(modRM(0b11, 7, lhs.low3()));
            try self.emitByte(@bitCast(@as(i8, @intCast(imm))));
        } else {
            try self.emitByte(0x81);
            try self.emitByte(modRM(0b11, 7, lhs.low3()));
            try self.emitI32(imm);
        }
    }

    pub noinline fn testReg32Reg32(self: *Assembler, a: Reg, b: Reg) !void {
        try self.emitRex32(b.isExt(), a.isExt());
        try self.emitByte(0x85);
        try self.emitByte(modRM(0b11, b.low3(), a.low3()));
    }

    pub noinline fn cmpReg32Reg32(self: *Assembler, lhs: Reg, rhs: Reg) !void {
        try self.emitRex32(rhs.isExt(), lhs.isExt());
        try self.emitByte(0x39);
        try self.emitByte(modRM(0b11, rhs.low3(), lhs.low3()));
    }

    pub noinline fn setcc(self: *Assembler, cond: Cond, dst: Reg) !void {
        if (dst.isExt() or @intFromEnum(dst) >= 4) {
            try self.emitByte(0x40 | (if (dst.isExt()) @as(u8, 1) else 0));
        }
        try self.emitByte(0x0F);
        try self.emitByte(0x90 + @as(u8, @intFromEnum(cond)));
        try self.emitByte(modRM(0b11, 0, dst.low3()));
    }

    pub noinline fn movzxReg64Reg8(self: *Assembler, dst: Reg, src: Reg) !void {
        try self.emitByte(rexW(dst.isExt(), src.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn movzxReg64Mem8(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(dst.isExt(), base.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn movzxReg64Mem16(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(dst.isExt(), base.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0xB7);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn movReg32Mem(self: *Assembler, dst: Reg, base: Reg, disp: i32) !void {
        try self.emitRex32(dst.isExt(), base.isExt());
        try self.emitByte(0x8B);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn movMem32Reg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.emitRex32(src.isExt(), base.isExt());
        try self.emitByte(0x89);
        try self.emitMemOperand(src.low3(), base, disp);
    }

    pub noinline fn movMem16Reg(self: *Assembler, base: Reg, disp: i32, src: Reg) !void {
        try self.emitByte(0x66);
        try self.emitRex32(src.isExt(), base.isExt());
        try self.emitByte(0x89);
        try self.emitMemOperand(src.low3(), base, disp);
    }

    pub noinline fn movRegMemIndexed8(self: *Assembler, dst: Reg, base: Reg, index: Reg, disp: i32) !void {
        std.debug.assert(index != .rsp);
        const rex: u8 = 0x48 |
            (if (dst.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        try self.emitByte(rex);
        try self.emitByte(0x8B);
        const sib: u8 = (0b11 << 6) | (@as(u8, index.low3()) << 3) | @as(u8, base.low3());
        if (disp == 0 and base.low3() != 5) {
            try self.emitByte(modRM(0b00, dst.low3(), 4));
            try self.emitByte(sib);
        } else if (disp >= -128 and disp <= 127) {
            try self.emitByte(modRM(0b01, dst.low3(), 4));
            try self.emitByte(sib);
            try self.emitByte(@bitCast(@as(i8, @intCast(disp))));
        } else {
            try self.emitByte(modRM(0b10, dst.low3(), 4));
            try self.emitByte(sib);
            try self.emitI32(disp);
        }
    }

    pub noinline fn movMemIndexed8Reg(self: *Assembler, base: Reg, index: Reg, disp: i32, src: Reg) !void {
        std.debug.assert(index != .rsp);
        const rex: u8 = 0x48 |
            (if (src.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        try self.emitByte(rex);
        try self.emitByte(0x89);
        const sib: u8 = (0b11 << 6) | (@as(u8, index.low3()) << 3) | @as(u8, base.low3());
        if (disp == 0 and base.low3() != 5) {
            try self.emitByte(modRM(0b00, src.low3(), 4));
            try self.emitByte(sib);
        } else if (disp >= -128 and disp <= 127) {
            try self.emitByte(modRM(0b01, src.low3(), 4));
            try self.emitByte(sib);
            try self.emitByte(@bitCast(@as(i8, @intCast(disp))));
        } else {
            try self.emitByte(modRM(0b10, src.low3(), 4));
            try self.emitByte(sib);
            try self.emitI32(disp);
        }
    }

    noinline fn emitSibOperand(self: *Assembler, reg_field: u3, base: Reg, index: Reg, scale_bits: u2, disp: i32) !void {
        std.debug.assert(index != .rsp);
        const sib: u8 = (@as(u8, scale_bits) << 6) | (@as(u8, index.low3()) << 3) | @as(u8, base.low3());
        if (disp == 0 and base.low3() != 5) {
            try self.emitByte(modRM(0b00, reg_field, 4));
            try self.emitByte(sib);
        } else if (disp >= -128 and disp <= 127) {
            try self.emitByte(modRM(0b01, reg_field, 4));
            try self.emitByte(sib);
            try self.emitByte(@bitCast(@as(i8, @intCast(disp))));
        } else {
            try self.emitByte(modRM(0b10, reg_field, 4));
            try self.emitByte(sib);
            try self.emitI32(disp);
        }
    }

    pub noinline fn movReg32MemIndexed4(self: *Assembler, dst: Reg, base: Reg, index: Reg, disp: i32) !void {
        const rex_bits: u8 =
            (if (dst.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x8B);
        try self.emitSibOperand(dst.low3(), base, index, 0b10, disp);
    }

    pub noinline fn movMem32Indexed4Reg(self: *Assembler, base: Reg, index: Reg, disp: i32, src: Reg) !void {
        const rex_bits: u8 =
            (if (src.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x89);
        try self.emitSibOperand(src.low3(), base, index, 0b10, disp);
    }

    pub noinline fn movzxReg32Mem8Indexed1(self: *Assembler, dst: Reg, base: Reg, index: Reg, disp: i32) !void {
        const rex_bits: u8 =
            (if (dst.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitSibOperand(dst.low3(), base, index, 0b00, disp);
    }

    pub noinline fn movMem8Indexed1Reg(self: *Assembler, base: Reg, index: Reg, disp: i32, src: Reg) !void {
        const rex_bits: u8 =
            (if (src.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0 or @intFromEnum(src) >= 4) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x88);
        try self.emitSibOperand(src.low3(), base, index, 0b00, disp);
    }

    pub noinline fn movsdXmmMemIndexed8(self: *Assembler, dst: Xmm, base: Reg, index: Reg, disp: i32) !void {
        try self.emitByte(0xF2);
        const rex_bits: u8 =
            (if (dst.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x0F);
        try self.emitByte(0x10);
        try self.emitSibOperand(dst.low3(), base, index, 0b11, disp);
    }

    pub noinline fn movsdMemIndexed8Xmm(self: *Assembler, base: Reg, index: Reg, disp: i32, src: Xmm) !void {
        try self.emitByte(0xF2);
        const rex_bits: u8 =
            (if (src.isExt()) @as(u8, 4) else 0) |
            (if (index.isExt()) @as(u8, 2) else 0) |
            (if (base.isExt()) @as(u8, 1) else 0);
        if (rex_bits != 0) try self.emitByte(0x40 | rex_bits);
        try self.emitByte(0x0F);
        try self.emitByte(0x11);
        try self.emitSibOperand(src.low3(), base, index, 0b11, disp);
    }

    pub noinline fn callReg(self: *Assembler, target: Reg) !void {
        if (target.isExt()) try self.emitByte(0x41);
        try self.emitByte(0xFF);
        try self.emitByte(modRM(0b11, 2, target.low3()));
    }

    pub noinline fn incMem64(self: *Assembler, base: Reg, disp: i32) !void {
        try self.emitByte(rexW(false, base.isExt()));
        try self.emitByte(0xFF);
        try self.emitMemOperand(0, base, disp);
    }

    pub noinline fn movqXmmReg(self: *Assembler, dst: Xmm, src: Reg) !void {
        try self.emitByte(0x66);
        try self.emitByte(rexW(dst.isExt(), src.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0x6E);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn movqRegXmm(self: *Assembler, dst: Reg, src: Xmm) !void {
        try self.emitByte(0x66);
        try self.emitByte(rexW(src.isExt(), dst.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0x7E);
        try self.emitByte(modRM(0b11, src.low3(), dst.low3()));
    }

    pub noinline fn movsdXmmXmm(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x10, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn movsdXmmMem(self: *Assembler, dst: Xmm, base: Reg, disp: i32) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), base.isExt())) |r| try self.emitByte(r);
        try self.emitByte(0x0F);
        try self.emitByte(0x10);
        try self.emitMemOperand(dst.low3(), base, disp);
    }

    pub noinline fn movsdMemXmm(self: *Assembler, base: Reg, disp: i32, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(src.isExt(), base.isExt())) |r| try self.emitByte(r);
        try self.emitByte(0x0F);
        try self.emitByte(0x11);
        try self.emitMemOperand(src.low3(), base, disp);
    }

    pub noinline fn addsd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x58, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn subsd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x5C, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn mulsd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x59, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn divsd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x5E, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn sqrtsd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x51, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn xorpd(self: *Assembler, dst: Xmm, src: Xmm) !void {
        try self.emitByte(0x66);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x57, modRM(0b11, dst.low3(), src.low3()) });
    }

    pub noinline fn cvttsd2siReg32Xmm(self: *Assembler, dst: Reg, src: Xmm) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitByte(0x0F);
        try self.emitByte(0x2C);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn cvttsd2siqReg64Xmm(self: *Assembler, dst: Reg, src: Xmm) !void {
        try self.emitByte(0xF2);
        try self.emitByte(rexW(dst.isExt(), src.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0x2C);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn cvtsi2sdXmmReg32(self: *Assembler, dst: Xmm, src: Reg) !void {
        try self.emitByte(0xF2);
        if (rexSSE(dst.isExt(), src.isExt())) |r| try self.emitByte(r);
        try self.emitByte(0x0F);
        try self.emitByte(0x2A);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn cvtsi2sdqXmmReg64(self: *Assembler, dst: Xmm, src: Reg) !void {
        try self.emitByte(0xF2);
        try self.emitByte(rexW(dst.isExt(), src.isExt()));
        try self.emitByte(0x0F);
        try self.emitByte(0x2A);
        try self.emitByte(modRM(0b11, dst.low3(), src.low3()));
    }

    pub noinline fn ucomisd(self: *Assembler, lhs: Xmm, rhs: Xmm) !void {
        try self.emitByte(0x66);
        if (rexSSE(lhs.isExt(), rhs.isExt())) |r| try self.emitByte(r);
        try self.emitBytes(&.{ 0x0F, 0x2E, modRM(0b11, lhs.low3(), rhs.low3()) });
    }

    pub noinline fn jmp(self: *Assembler, target: Label) !void {
        try self.emitByte(0xE9);
        const patch_offset = self.code.items.len;
        try self.emitU32(0);
        try self.fixups.append(self.allocator, .{ .patch_offset = patch_offset, .target_label = target });
    }

    pub noinline fn jcc(self: *Assembler, cond: Cond, target: Label) !void {
        try self.emitByte(0x0F);
        try self.emitByte(0x80 + @as(u8, @intFromEnum(cond)));
        const patch_offset = self.code.items.len;
        try self.emitU32(0);
        try self.fixups.append(self.allocator, .{ .patch_offset = patch_offset, .target_label = target });
    }

    pub noinline fn callLabel(self: *Assembler, target: Label) !void {
        try self.emitByte(0xE8);
        const patch_offset = self.code.items.len;
        try self.emitU32(0);
        try self.fixups.append(self.allocator, .{ .patch_offset = patch_offset, .target_label = target });
    }

    pub noinline fn finalizeFixups(self: *Assembler) !void {
        for (self.fixups.items) |fixup| {
            const target = self.labels.items[fixup.target_label] orelse return error.UnboundLabel;
            const next_ip = fixup.patch_offset + 4;
            const delta = @as(isize, @intCast(target)) - @as(isize, @intCast(next_ip));
            const rel32: i32 = std.math.cast(i32, delta) orelse return error.JumpOutOfRange;
            std.mem.writeInt(u32, self.code.items[fixup.patch_offset..][0..4], @bitCast(rel32), .little);
        }
    }

    pub noinline fn finalizeExecutable(self: *Assembler) ![]align(std.heap.page_size_min) u8 {
        if (!comptime is_supported_host) return error.UnsupportedPlatform;
        try self.finalizeFixups();
        if (self.code.items.len == 0) return error.EmptyCode;
        const page_size = std.heap.page_size_min;
        const alloc_len = std.mem.alignForward(usize, self.code.items.len, page_size);
        const mem = try std.posix.mmap(
            null,
            alloc_len,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        );
        errdefer std.posix.munmap(mem);
        @memcpy(mem[0..self.code.items.len], self.code.items);
        if (std.os.linux.mprotect(mem.ptr, mem.len, .{ .READ = true, .EXEC = true }) != 0) {
            return error.MProtectFailed;
        }
        return mem;
    }
};

pub fn freeExecutable(mem: []align(std.heap.page_size_min) u8) void {
    if (comptime is_supported_host) {
        std.posix.munmap(mem);
    }
}

test "x64_asm emits and executes double addition with W^X mmap" {
    if (!comptime is_supported_host) return;
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();

    // fn(ptr: [*]u64) callconv(.c) u8: ptr[0] = as_f64(ptr[0]) + as_f64(ptr[1]); return 0;
    try a.movsdXmmMem(.xmm0, .rdi, 0);
    try a.movsdXmmMem(.xmm1, .rdi, 8);
    try a.addsd(.xmm0, .xmm1);
    try a.movsdMemXmm(.rdi, 0, .xmm0);
    try a.xorRegReg(.rax, .rax);
    try a.ret();

    const exec = try a.finalizeExecutable();
    defer freeExecutable(exec);

    const Fn = *const fn ([*]u64) callconv(.c) u8;
    const f: Fn = @ptrCast(exec.ptr);
    var vals = [2]u64{ @bitCast(@as(f64, 12.5)), @bitCast(@as(f64, 29.5)) };
    const rc = f(&vals);
    try std.testing.expectEqual(@as(u8, 0), rc);
    try std.testing.expectEqual(@as(f64, 42.0), @as(f64, @bitCast(vals[0])));
}

test "x64_asm emits and executes movsdXmmXmm with extended Xmm registers" {
    if (!comptime is_supported_host) return;
    var a = Assembler.init(std.testing.allocator);
    defer a.deinit();

    // fn(ptr: [*]u64) callconv(.c) u8: ptr[0] = as_f64(ptr[0]) + as_f64(ptr[1]); return 0;
    try a.movsdXmmMem(.xmm12, .rdi, 0);
    try a.movsdXmmMem(.xmm15, .rdi, 8);
    try a.movsdXmmXmm(.xmm4, .xmm12);
    try a.addsd(.xmm4, .xmm15);
    try a.movsdMemXmm(.rdi, 0, .xmm4);
    try a.xorRegReg(.rax, .rax);
    try a.ret();

    const exec = try a.finalizeExecutable();
    defer freeExecutable(exec);

    const Fn = *const fn ([*]u64) callconv(.c) u8;
    const f: Fn = @ptrCast(exec.ptr);
    var vals = [2]u64{ @bitCast(@as(f64, 100.5)), @bitCast(@as(f64, 200.25)) };
    const rc = f(&vals);
    try std.testing.expectEqual(@as(u8, 0), rc);
    try std.testing.expectEqual(@as(f64, 300.75), @as(f64, @bitCast(vals[0])));
}
