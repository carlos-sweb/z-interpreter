//! Shared JIT constants, layout offsets, and emitters used by the
//! whole-function tiers and the OSR compiler.



pub const std = @import("std");
pub const Allocator = std.mem.Allocator;
pub const zvalue = @import("zvalue");
pub const zstring = @import("zstring");
pub const JSValue = zvalue.JSValue;
pub const environment_mod = @import("../environment.zig");
pub const Environment = environment_mod.Environment;
pub const codeblock = @import("../bytecode/codeblock.zig");
pub const vm = @import("../bytecode/vm.zig");
pub const math_builtins = @import("../math_builtins.zig");
pub const string_builtins = @import("../string_builtins.zig");
pub const x64_asm = @import("x64_asm.zig");
pub const Assembler = x64_asm.Assembler;
pub const Label = x64_asm.Label;
pub const Xmm = x64_asm.Xmm;

pub const JitFn = codeblock.JitFn;
pub const OsrFn = codeblock.OsrFn;
pub const JitGlobalSlot = codeblock.JitGlobalSlot;
pub const HOT_THRESHOLD: u32 = 32;
pub const OSR_THRESHOLD: u32 = 64;
pub const HEADER_FUNCTION: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.function, @as(*zvalue.Rc(zvalue.Callable), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
pub const HEADER_ARRAY: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.array, @as(*zvalue.Rc(zvalue.ZArray(JSValue)), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
pub const HEADER_OBJECT: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.object, @as(*zvalue.Rc(zvalue.ZObject(JSValue)), @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
pub const StringBox = zvalue.Rc(zstring.ZString);
pub const ZStr = zstring.ZString;
pub const HEADER_STRING: u32 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.string, @as(*StringBox, @ptrFromInt(8)));
    break :blk @intCast(dummy.bits >> 47);
};
pub const HEADER_TYPED_ARRAY_BITS: u64 = blk: {
    const dummy: JSValue = JSValue.fromHeap(.typed_array, @as(*zvalue.Rc(zvalue.TypedArrayBox), @ptrFromInt(8)));
    break :blk dummy.bits & JSValue.TAG15_MASK;
};

pub const str_val_off: i32 = @intCast(@offsetOf(StringBox, "value"));
pub const str_data_ptr_off: i32 = str_val_off + @as(i32, @intCast(@offsetOf(ZStr, "data")));
pub const str_data_len_off: i32 = str_data_ptr_off + @as(i32, @intCast(@sizeOf(usize)));
comptime {
    std.debug.assert(@sizeOf([]const u8) == 2 * @sizeOf(usize));
    std.debug.assert(str_data_len_off == str_data_ptr_off + @as(i32, @intCast(@sizeOf(usize))));
}

pub const ObjectBox = zvalue.Rc(zvalue.ZObject(JSValue));
pub const ZObj = zvalue.ZObject(JSValue);
pub const PropMap = @TypeOf(@as(ZObj, undefined).properties);
pub const PropDataList = PropMap.DataList;
pub const PropEntry = PropMap.Data;
pub const Prop = @TypeOf(@as(PropEntry, undefined).value);
pub const KeySlice = @TypeOf(@as(PropEntry, undefined).key);

pub const PropIC = struct {
    block: ?*const codeblock.CodeBlock = null,
    key_ptr: [*]const u8 = undefined,
    interned_key_ptr: ?[*]const u8 = null,
    pc: u32 = 0,
    shape_id: u32 = 0,
    next_shape: u32 = 0,
    cached_shape_id: u32 = 0,
    slot_idx: u32 = 0,
};

pub const key_byte_offset_multiplier: usize = blk: {
    var dummy: PropDataList = .empty;
    dummy.capacity = 1;
    dummy.len = 1;
    dummy.bytes = @ptrFromInt(0x1000);
    const slice_ptr = @intFromPtr(dummy.items(.key).ptr);
    break :blk slice_ptr - 0x1000;
};
pub const key_size: i32 = @intCast(@sizeOf(KeySlice));
pub const key_ptr_offset: i32 = blk: {
    const dummy_key: *KeySlice = @ptrFromInt(0x1000);
    break :blk @intCast(@intFromPtr(&dummy_key.ptr) - 0x1000);
};

pub const value_byte_offset_multiplier: usize = blk: {
    var dummy: PropDataList = .empty;
    dummy.capacity = 1;
    dummy.len = 1;
    dummy.bytes = @ptrFromInt(0x1000);
    const slice_ptr = @intFromPtr(dummy.items(.value).ptr);
    break :blk slice_ptr - 0x1000;
};

pub const box_val_offset: i32 = @offsetOf(ObjectBox, "value");
pub const zobj_shape_id_offset: i32 = box_val_offset + @offsetOf(ZObj, "shape_id");
pub const zobj_cached_shape_id_offset: i32 = box_val_offset + @offsetOf(ZObj, "cached_shape_id");
pub const zobj_cached_len_offset: i32 = box_val_offset + @offsetOf(ZObj, "cached_len");
pub const zobj_active_len_offset: i32 = box_val_offset + @offsetOf(ZObj, "active_len");
pub const zobj_is_frozen_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_frozen");
pub const zobj_is_extensible_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_extensible");
pub const zobj_entries_offset: i32 = box_val_offset + @offsetOf(ZObj, "properties") + @offsetOf(PropMap, "entries");
pub const zobj_entries_bytes_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "bytes");
pub const zobj_entries_len_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "len");
pub const zobj_entries_cap_offset: i32 = zobj_entries_offset + @offsetOf(PropDataList, "capacity");

pub const prop_val_offset: i32 = @offsetOf(Prop, "value");
pub const prop_desc_offset: i32 = @offsetOf(Prop, "descriptor");
pub const prop_size: i32 = @intCast(@sizeOf(Prop));

pub const ic_size: i32 = @intCast(@sizeOf(PropIC));
pub const ic_block_offset: i32 = @offsetOf(PropIC, "block");
pub const ic_key_ptr_offset: i32 = @offsetOf(PropIC, "key_ptr");
pub const ic_interned_key_ptr_offset: i32 = @offsetOf(PropIC, "interned_key_ptr");
pub const ic_pc_offset: i32 = @offsetOf(PropIC, "pc");
pub const ic_shape_id_offset: i32 = @offsetOf(PropIC, "shape_id");
pub const ic_next_shape_offset: i32 = @offsetOf(PropIC, "next_shape");
pub const ic_cached_shape_id_offset: i32 = @offsetOf(PropIC, "cached_shape_id");
pub const ic_slot_idx_offset: i32 = @offsetOf(PropIC, "slot_idx");

pub const ctx_frame_ptr_offset: i32 = @offsetOf(codeblock.OsrContext, "frame_ptr");
pub const ctx_prop_ic_ptr_offset: i32 = @offsetOf(codeblock.OsrContext, "prop_ic_ptr");
pub const ctx_global_obj_offset: i32 = @offsetOf(codeblock.OsrContext, "global_obj_box_ptr");
pub const frame_closure_env_offset: i32 = @offsetOf(vm.CallFrame, "closure_env");
pub const frame_has_rc_offset: i32 = @offsetOf(vm.CallFrame, "has_rc");

pub const MathIntrinsicGuard = struct {
    prop_name: []const u8 = "",
    expected_bits: u64 = 0,
};

pub noinline fn jitCheckMathIntrinsic(
    ctx: *codeblock.OsrContext,
    prop_ptr: [*]const u8,
    prop_len: usize,
    expected_bits: u64,
) callconv(.c) u64 {
    const frame: *vm.CallFrame = @ptrCast(@alignCast(ctx.frame_ptr));
    const env = frame.closure_env orelse return 1;
    const prop_name = prop_ptr[0..prop_len];
    var cur: ?*Environment = env;
    while (cur) |e| : (cur = e.parent) {
        if (e.tdz.contains("Math")) return 1;
        if (e.bindingIndex("Math")) |idx| {
            const math_val = e.bindings.items[idx].value;
            if (!math_val.isObject()) return 1;
            const rec = math_val.asObject().value.getOwnRecord(prop_name) orelse return 1;
            if (rec.isAccessor()) return 1;
            return if (rec.value.bits == expected_bits) 0 else 1;
        }
    }
    return 1;
}
pub const osr_ic_shape_off: i32 = @offsetOf(codeblock.OsrPropIC, "shape_id");
pub const osr_ic_slot_off: i32 = @offsetOf(codeblock.OsrPropIC, "slot_idx");
pub const osr_ic_slot_byte_off: i32 = @offsetOf(codeblock.OsrPropIC, "slot_byte_off");
pub const osr_ic_next_shape_off: i32 = @offsetOf(codeblock.OsrPropIC, "next_shape");
pub const osr_ic_cached_shape_off: i32 = @offsetOf(codeblock.OsrPropIC, "cached_shape_id");
pub const obj_rc_off: i32 = @intCast(@offsetOf(ObjectBox, "_count"));
pub const zobj_is_sealed_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_sealed");
pub const zobj_is_error_data_offset: i32 = box_val_offset + @offsetOf(ZObj, "is_error_data");

pub const ArrayBox = zvalue.Rc(zvalue.ZArray(JSValue));
pub const ZArr = zvalue.ZArray(JSValue);
pub const ArrList = @FieldType(ZArr, "items");
pub const HoleyState = ZArr.HoleyState;
pub const HoleMaskList = @FieldType(HoleyState, "hole_mask");
pub const arr_rc_off: i32 = @intCast(@offsetOf(ArrayBox, "_count"));
pub const arr_val_off: i32 = @intCast(@offsetOf(ArrayBox, "value"));
pub const arr_holey_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "holey")));
pub const arr_list_off: i32 = arr_val_off + @as(i32, @intCast(@offsetOf(ZArr, "items")));
pub const arr_items_ptr_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "items")));
pub const arr_items_len_off: i32 = arr_items_ptr_off + 8;
pub const arr_items_cap_off: i32 = arr_list_off + @as(i32, @intCast(@offsetOf(ArrList, "capacity")));
pub const h_mask_off: i32 = @intCast(@offsetOf(HoleyState, "hole_mask"));
pub const h_mask_ptr_off: i32 = h_mask_off + @as(i32, @intCast(@offsetOf(HoleMaskList, "items")));
pub const h_mask_len_off: i32 = h_mask_ptr_off + 8;
pub const h_is_holey_off: i32 = @intCast(@offsetOf(HoleyState, "is_holey"));
pub const h_log_len_off: i32 = @intCast(@offsetOf(HoleyState, "logical_length"));

pub fn constantName(block: *const codeblock.CodeBlock, idx: u8) ?[]const u8 {
    if (idx >= block.constants.len) return null;
    return switch (block.constants[idx]) {
        .string, .property_key => |s| s,
        else => null,
    };
}

pub fn jitResolveGlobalSlot(
    env_ptr: ?*anyopaque,
    name_ptr: [*]const u8,
    name_len: usize,
    slot: *JitGlobalSlot,
) callconv(.c) u8 {
    const env: *Environment = @ptrCast(@alignCast(env_ptr orelse return 1));
    const name = name_ptr[0..name_len];
    var cur: ?*Environment = env;
    while (cur) |e| : (cur = e.parent) {
        if (e.tdz.contains(name)) return 1;
        if (e.bindingIndex(name)) |idx| {
            slot.* = .{
                .env = env_ptr,
                .value_ptr = &e.bindings.items[idx].value,
                .struct_version = environment_mod.env_struct_version,
                .is_mutable = @intFromBool(!e.consts.contains(name)),
            };
            return 0;
        }
    }
    return 1;
}

pub noinline fn emitGlobalSlotLookup(
    a: *Assembler,
    slot_addr: u64,
    ver_addr: u64,
    name: []const u8,
    bailout_label: Label,
) !void {
    const resolve_label = try a.createLabel();
    const hit_label = try a.createLabel();

    try a.movRegImm64(.r10, slot_addr);
    try a.movRegImm64(.r11, ver_addr);
    // slot.env == %r14 (offset 0)
    try a.movRegMem(.rax, .r10, 0);
    try a.cmpRegReg(.rax, .r14);
    try a.jcc(.ne, resolve_label);
    // slot.struct_version == env_struct_version (offset 16)
    try a.movRegMem(.rax, .r11, 0);
    try a.movRegMem(.rcx, .r10, 16);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.e, hit_label);

    a.bindLabel(resolve_label);
    try a.movRegReg(.rdi, .r14);
    try a.movRegImm64(.rsi, @intFromPtr(name.ptr));
    try a.movRegImm64(.rdx, name.len);
    try a.movRegReg(.rcx, .r10);
    try a.movRegImm64(.rax, @intFromPtr(&jitResolveGlobalSlot));
    try a.movRegReg(.rbx, .rsp);
    try a.andRegImm8(.rsp, -16);
    try a.callReg(.rax);
    try a.movRegReg(.rsp, .rbx);
    try a.testRegReg(.rax, .rax);
    try a.jcc(.ne, bailout_label);
    try a.movRegImm64(.r10, slot_addr);

    a.bindLabel(hit_label);
}

pub noinline fn emitGuardNonHeapInOsr(a: *Assembler, reg_idx: u8, _: Label) !void {
    const clean_lbl = try a.createLabel();
    try a.movRegMem(.rdx, .r12, @intCast(@as(usize, reg_idx) * 8));
    try a.cmpRegReg(.rdx, .r14);
    try a.jcc(.b, clean_lbl);
    try a.pushReg(.rax);
    try a.pushReg(.rcx);
    try a.lea(.rdi, .r12, @intCast(@as(usize, reg_idx) * 8));
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitDeinitSlot));
    try a.callReg(.rax);
    try a.popReg(.rcx);
    try a.popReg(.rax);
    a.bindLabel(clean_lbl);
}

pub noinline fn emitCmpToBool(a: *Assembler, opcode: codeblock.Opcode) !void {
    // Assumes %xmm0 = lhs, %xmm1 = rhs; produces JSValue.fromBool(result) in %rax.
    const done_lbl = try a.createLabel();
    const true_lbl = try a.createLabel();

    switch (opcode) {
        .lt_num, .lt_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(.a, true_lbl);
        },
        .le_num, .le_local_const => {
            try a.ucomisd(.xmm1, .xmm0);
            try a.jcc(.ae, true_lbl);
        },
        .gt_num, .gt_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.a, true_lbl);
        },
        .ge_num, .ge_local_const => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.ae, true_lbl);
        },
        .eq, .loose_eq, .eq_local_const => {
            const false_lbl = try a.createLabel();
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, false_lbl);
            try a.jcc(.e, true_lbl);
            a.bindLabel(false_lbl);
        },
        .ne, .loose_ne => {
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, true_lbl);
            try a.jcc(.ne, true_lbl);
        },
        else => unreachable,
    }
    try a.movRegImm64(.rax, JSValue.fromBool(false).bits);
    try a.jmp(done_lbl);
    a.bindLabel(true_lbl);
    try a.movRegImm64(.rax, JSValue.fromBool(true).bits);
    a.bindLabel(done_lbl);
}

pub noinline fn emitCondJump(a: *Assembler, is_true_jump: bool, src_reg: u8, target_lbl: Label, bail_lbl: Label) !void {
    const num_lbl = try a.createLabel();
    const fallthrough_lbl = try a.createLabel();

    try a.movRegMem(.rax, .r12, @intCast(@as(usize, src_reg) * 8));
    try a.cmpRegReg(.rax, .r15);
    try a.jcc(.b, num_lbl);

    try a.cmpRegReg(.rax, .r15);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    const null_bits = JSValue.NULL.bits;
    try a.movRegImm64(.rcx, null_bits);
    try a.cmpRegReg(.rax, .rcx);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    const false_bits = JSValue.fromBool(false).bits;
    const true_bits = JSValue.fromBool(true).bits;
    try a.movRegImm64(.rcx, false_bits);
    try a.cmpRegReg(.rax, .rcx);
    if (is_true_jump) {
        try a.jcc(.e, fallthrough_lbl);
    } else {
        try a.jcc(.e, target_lbl);
    }
    try a.movRegImm64(.rcx, true_bits);
    try a.cmpRegReg(.rax, .rcx);
    try a.jcc(.ne, bail_lbl);
    if (is_true_jump) {
        try a.jmp(target_lbl);
    } else {
        try a.jmp(fallthrough_lbl);
    }

    a.bindLabel(num_lbl);
    try a.movqXmmReg(.xmm0, .rax);
    try a.xorpd(.xmm1, .xmm1);
    try a.ucomisd(.xmm0, .xmm1);
    if (is_true_jump) {
        try a.jcc(.p, fallthrough_lbl);
        try a.jcc(.ne, target_lbl);
    } else {
        try a.jcc(.p, target_lbl);
        try a.jcc(.e, target_lbl);
    }
    a.bindLabel(fallthrough_lbl);
}

pub noinline fn emitSharedOp(a: *Assembler, block: *const codeblock.CodeBlock, op: codeblock.Op, is_osr: bool, bail_lbl: Label) !bool {
    switch (op.opcode) {
        .load_null => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.NULL.bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .load_true => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.fromBool(true).bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .load_false => {
            if (is_osr) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movRegImm64(.rax, JSValue.fromBool(false).bits);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .not => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            const false_bits = JSValue.fromBool(false).bits;
            const true_bits = JSValue.fromBool(true).bits;
            const is_false_lbl = try a.createLabel();
            const store_lbl = try a.createLabel();
            try a.movRegImm64(.rcx, false_bits);
            try a.cmpRegReg(.rax, .rcx);
            try a.jcc(.e, is_false_lbl);
            try a.movRegImm64(.rdx, true_bits);
            try a.cmpRegReg(.rax, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movRegReg(.rax, .rcx);
            try a.jmp(store_lbl);
            a.bindLabel(is_false_lbl);
            try a.movRegImm64(.rax, true_bits);
            a.bindLabel(store_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .neg => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movRegImm64(.rcx, 0x8000_0000_0000_0000);
            try a.xorRegReg64(.rax, .rcx);
            try a.ucomisd(.xmm0, .xmm0);
            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
            try a.cmovpRegReg(.rax, .rcx);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .div_num => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.divsd(.xmm0, .xmm1);
            try a.movqRegXmm(.rax, .xmm0);
            try a.ucomisd(.xmm0, .xmm0);
            try a.movRegImm64(.rcx, JSValue.CANONICAL_NAN);
            try a.cmovpRegReg(.rax, .rcx);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .mod_num => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            // lhs: positive exact integer in [0, 2^53 - 1] (also rejects -0.0 via sign bit)
            try a.movRegReg(.rdx, .rax);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.cvttsd2siqReg64Xmm(.rax, .xmm0);
            try a.movRegReg(.rdx, .rax);
            try a.shrRegImm8(.rdx, 53);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.cvtsi2sdqXmmReg64(.xmm2, .rax);
            try a.ucomisd(.xmm0, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            // rhs: strictly positive exact integer in [1, 2^53 - 1]
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 63);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.cvttsd2siqReg64Xmm(.rcx, .xmm1);
            try a.movRegReg(.rdx, .rcx);
            try a.shrRegImm8(.rdx, 53);
            try a.testRegReg(.rdx, .rdx);
            try a.jcc(.ne, bail_lbl);
            try a.testRegReg(.rcx, .rcx);
            try a.jcc(.e, bail_lbl);
            try a.cvtsi2sdqXmmReg64(.xmm2, .rcx);
            try a.ucomisd(.xmm1, .xmm2);
            try a.jcc(.p, bail_lbl);
            try a.jcc(.ne, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.xorRegReg64(.rdx, .rdx);
            try a.divReg64(.rcx);
            try a.cvtsi2sdqXmmReg64(.xmm0, .rdx);
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .not_bits => {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            try a.cmpReg32Imm32(.rax, -0x80000000);
            try a.jcc(.e, slow_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.notReg32(.rax);
            try a.cvtsi2sdXmmReg32(.xmm0, .rax);
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.b);
            try a.movRegImm32(.r8, 6);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
            if (!is_osr) {
                try a.movRegReg(.rbx, .rsp);
                try a.andRegImm8(.rsp, -16);
            }
            try a.callReg(.rax);
            if (!is_osr) {
                try a.movRegReg(.rsp, .rbx);
            }
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return true;
        },
        .and_bits, .or_bits, .xor_bits, .shl, .shr, .ushr => {
            const slow_lbl = try a.createLabel();
            const done_lbl = try a.createLabel();
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try a.cvttsd2siReg32Xmm(.rax, .xmm0);
            try a.cmpReg32Imm32(.rax, -0x80000000);
            try a.jcc(.e, slow_lbl);
            try a.cvttsd2siReg32Xmm(.rcx, .xmm1);
            try a.cmpReg32Imm32(.rcx, -0x80000000);
            try a.jcc(.e, slow_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            switch (op.opcode) {
                .and_bits => {
                    try a.andReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .or_bits => {
                    try a.orReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .xor_bits => {
                    try a.xorReg32Reg32(.rax, .rcx);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shl => {
                    try a.shlReg32Cl(.rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .shr => {
                    try a.sarReg32Cl(.rax);
                    try a.cvtsi2sdXmmReg32(.xmm0, .rax);
                },
                .ushr => {
                    try a.shrReg32Cl(.rax);
                    try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
                },
                else => unreachable,
            }
            try a.movqRegXmm(.rax, .xmm0);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            try a.jmp(done_lbl);

            a.bindLabel(slow_lbl);
            const kind_u32: u32 = switch (op.opcode) {
                .and_bits => 0,
                .or_bits => 1,
                .xor_bits => 2,
                .shl => 3,
                .shr => 4,
                .ushr => 5,
                else => unreachable,
            };
            try a.movRegReg(.rdi, .r12);
            try a.movRegImm32(.rsi, op.a);
            try a.movRegImm32(.rdx, op.b);
            try a.movRegImm32(.rcx, op.c);
            try a.movRegImm32(.r8, kind_u32);
            try a.movRegImm64(.rax, @intFromPtr(&vm.jitBitwise));
            if (!is_osr) {
                try a.movRegReg(.rbx, .rsp);
                try a.andRegImm8(.rsp, -16);
            }
            try a.callReg(.rax);
            if (!is_osr) {
                try a.movRegReg(.rsp, .rbx);
            }
            try a.testRegReg(.rax, .rax);
            try a.jcc(.ne, bail_lbl);
            a.bindLabel(done_lbl);
            return true;
        },
        .lt_num, .gt_num, .le_num, .ge_num, .eq, .ne, .loose_eq, .loose_ne => {
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            try a.movRegMem(.rcx, .r12, @intCast(@as(usize, op.c) * 8));
            try a.cmpRegReg(.rcx, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b and op.a != op.c) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movqXmmReg(.xmm1, .rcx);
            try emitCmpToBool(a, op.opcode);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        .lt_local_const, .gt_local_const, .le_local_const, .ge_local_const, .eq_local_const => {
            const c_bits = JSValue.fromNumber(block.constants[op.c].number).bits;
            try a.movRegMem(.rax, .r12, @intCast(@as(usize, op.b) * 8));
            try a.cmpRegReg(.rax, .r15);
            try a.jcc(.ae, bail_lbl);
            if (is_osr and op.a != op.b) try emitGuardNonHeapInOsr(a, op.a, bail_lbl);
            try a.movqXmmReg(.xmm0, .rax);
            try a.movRegImm64(.rcx, c_bits);
            try a.movqXmmReg(.xmm1, .rcx);
            try emitCmpToBool(a, op.opcode);
            try a.movMemReg(.r12, @intCast(@as(usize, op.a) * 8), .rax);
            return true;
        },
        else => return false,
    }
}

pub fn isKnownNum(known_num: u64, reg: u8) bool {
    if (reg >= 64) return false;
    return (known_num & (@as(u64, 1) << @intCast(reg))) != 0;
}

pub fn isKnownNonHeap(known_non_heap: u64, reg: u8) bool {
    if (reg >= 64) return false;
    return (known_non_heap & (@as(u64, 1) << @intCast(reg))) != 0;
}

pub fn markNum(reg: u8, known_num: *u64, known_non_heap: *u64) void {
    if (reg < 64) {
        const mask = @as(u64, 1) << @intCast(reg);
        known_num.* |= mask;
        known_non_heap.* |= mask;
    }
}

pub fn clearReg(reg: u8, known_num: *u64, known_non_heap: *u64) void {
    if (reg < 64) {
        const mask = ~(@as(u64, 1) << @intCast(reg));
        known_num.* &= mask;
        known_non_heap.* &= mask;
    }
}

pub noinline fn emitStringLengthToXmm0(
    a: *Assembler,
    str_reg: u8,
    use_r14_prepared: bool,
    bail_lbl: Label,
) !void {
    if (use_r14_prepared) {
        try a.movRegReg(.rax, .r14);
        try a.movRegImm64(.rcx, 0x3FFF_FFFF_FFFF_FFFF);
        try a.andRegReg(.rax, .rcx);
        try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
        return;
    }

    try a.movRegMem(.rax, .r12, @intCast(@as(usize, str_reg) * 8));
    try a.movRegReg(.rcx, .rax);
    try a.shrRegImm8(.rcx, 47);
    try a.cmpRegImm32(.rcx, HEADER_STRING);
    try a.jcc(.ne, bail_lbl);

    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rax, .rcx);

    try a.movRegReg(.rdi, .rax);
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitStringLength));
    try a.movRegReg(.rbx, .rsp);
    try a.andRegImm8(.rsp, -16);
    try a.callReg(.rax);
    try a.movRegReg(.rsp, .rbx);
    try a.cvtsi2sdqXmmReg64(.xmm0, .rax);
}

pub noinline fn emitStringCharCodeAtFromXmm0(
    a: *Assembler,
    str_reg: u8,
    use_r14_prepared: bool,
    idx_is_exact_int: bool,
    bail_lbl: Label,
) !void {
    const slow_lbl = try a.createLabel();
    const done_lbl = try a.createLabel();

    try a.movRegMem(.rax, .r12, @intCast(@as(usize, str_reg) * 8));
    if (!use_r14_prepared) {
        try a.movRegReg(.rcx, .rax);
        try a.shrRegImm8(.rcx, 47);
        try a.cmpRegImm32(.rcx, HEADER_STRING);
        try a.jcc(.ne, bail_lbl);
    }

    try a.movRegImm64(.rcx, JSValue.PTR_MASK);
    try a.andRegReg(.rax, .rcx);

    if (use_r14_prepared) {
        try a.movRegReg(.rcx, .r14);
        try a.shrRegImm8(.rcx, 62);
        try a.testRegReg(.rcx, .rcx);
        try a.jcc(.e, slow_lbl);

        try a.cvttsd2siqReg64Xmm(.rdx, .xmm0);
        if (!idx_is_exact_int) {
            try a.cvtsi2sdqXmmReg64(.xmm1, .rdx);
            try a.ucomisd(.xmm0, .xmm1);
            try a.jcc(.p, slow_lbl);
            try a.jcc(.ne, slow_lbl);
        }

        try a.cmpRegMem(.rdx, .rax, str_data_len_off);
        try a.jcc(.ae, slow_lbl);

        try a.movRegMem(.rcx, .rax, str_data_ptr_off);
        try a.addRegReg(.rcx, .rdx);
        try a.movzxReg64Mem8(.rcx, .rcx, 0);
        try a.cmpRegImm32(.rcx, 0x80);
        try a.jcc(.ae, slow_lbl);

        try a.cvtsi2sdXmmReg32(.xmm0, .rcx);
        try a.jmp(done_lbl);
    }

    a.bindLabel(slow_lbl);
    try a.movRegReg(.rdi, .rax);
    try a.movqRegXmm(.rsi, .xmm0);
    try a.movRegImm64(.rax, @intFromPtr(&vm.jitStringCharCodeAt));
    try a.movRegReg(.rbx, .rsp);
    try a.andRegImm8(.rsp, -16);
    try a.callReg(.rax);
    try a.movRegReg(.rsp, .rbx);
    try a.movqXmmReg(.xmm0, .rax);

    a.bindLabel(done_lbl);
}
