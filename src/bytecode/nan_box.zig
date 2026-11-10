const std = @import("std");
const zvalue = @import("zvalue");
const JSValue = zvalue.JSValue;

pub const NaNBoxedValue = struct {
    bits: u64,

    pub const BASE_BOX: u64 = 0xFFF8_0000_0000_0000;
    pub const CANONICAL_NAN: u64 = 0x7FF8_0000_0000_0001;
    pub const PTR_MASK: u64 = 0x0000_FFFF_FFFF_FFFF;
    pub const TAG_MASK: u64 = 0xFFFF_0000_0000_0000;

    // Primitives encoded in the low payload bits of BASE_BOX
    pub const TAG_UNDEFINED: u64 = BASE_BOX | 1;
    pub const TAG_NULL: u64 = BASE_BOX | 2;
    pub const TAG_FALSE: u64 = BASE_BOX | 3;
    pub const TAG_TRUE: u64 = BASE_BOX | 4;

    // Heap variants (tags 5..7 map to distinct upper-16-bit headers)
    pub const TAG_STRING: u64 = BASE_BOX | (5 << 48); // 0xFFFD_0000_0000_0000
    pub const TAG_ARRAY: u64 = BASE_BOX | (6 << 48); // 0xFFFE_0000_0000_0000
    pub const TAG_OBJECT: u64 = BASE_BOX | (7 << 48); // 0xFFFF_0000_0000_0000

    // Additional heap tags (note: tags >= 8 wrap modulo 8 in bits 48..50)
    pub const TAG_FUNCTION: u64 = BASE_BOX | (8 << 48); // 0xFFF8_0000_0000_0000
    pub const TAG_BIGINT: u64 = BASE_BOX | (9 << 48); // 0xFFF9_0000_0000_0000
    pub const TAG_SYMBOL: u64 = BASE_BOX | (10 << 48); // 0xFFFA_0000_0000_0000
    pub const TAG_REGEX: u64 = BASE_BOX | (11 << 48); // 0xFFFB_0000_0000_0000
    pub const TAG_MAP: u64 = BASE_BOX | (12 << 48); // 0xFFFC_0000_0000_0000

    pub fn isBoxed(bits: u64) bool {
        return (bits & 0xFFF8_0000_0000_0000) == 0xFFF8_0000_0000_0000 and (bits & 0x0007_FFFF_FFFF_FFFF) != 0;
    }

    pub fn isNumber(self: NaNBoxedValue) bool {
        return !isBoxed(self.bits) or self.bits == CANONICAL_NAN;
    }

    pub fn asNumber(self: NaNBoxedValue) f64 {
        if (self.bits == CANONICAL_NAN) return std.math.nan(f64);
        return @bitCast(self.bits);
    }

    pub fn fromJSValue(v: JSValue) NaNBoxedValue {
        switch (v) {
            .number => |n| {
                if (std.math.isNan(n)) {
                    return .{ .bits = CANONICAL_NAN };
                }
                return .{ .bits = @bitCast(n) };
            },
            .boolean => |b| return .{ .bits = if (b) TAG_TRUE else TAG_FALSE },
            .undefined => return .{ .bits = TAG_UNDEFINED },
            .null => return .{ .bits = TAG_NULL },
            .string => |box| return fromHeapPtr(TAG_STRING, box),
            .array => |box| return fromHeapPtr(TAG_ARRAY, box),
            .object => |box| return fromHeapPtr(TAG_OBJECT, box),
            .function => |box| return fromHeapPtr(TAG_FUNCTION, box),
            .bigint => |box| return fromHeapPtr(TAG_BIGINT, box),
            .symbol => |box| return fromHeapPtr(TAG_SYMBOL, box),
            .regex => |box| return fromHeapPtr(TAG_REGEX, box),
            .map => |box| return fromHeapPtr(TAG_MAP, box),
            .set => |box| return fromHeapPtr(TAG_MAP, box),
            .@"error" => |box| return fromHeapPtr(TAG_OBJECT, box),
            .date => |box| return fromHeapPtr(TAG_OBJECT, box),
            .promise => |box| return fromHeapPtr(TAG_OBJECT, box),
            .proxy => |box| return fromHeapPtr(TAG_OBJECT, box),
            .array_buffer => |box| return fromHeapPtr(TAG_OBJECT, box),
            .data_view => |box| return fromHeapPtr(TAG_OBJECT, box),
            .typed_array => |box| return fromHeapPtr(TAG_ARRAY, box),
            .temporal => |box| return fromHeapPtr(TAG_OBJECT, box),
        }
    }

    fn fromHeapPtr(tag_prefix: u64, ptr: anytype) NaNBoxedValue {
        const raw = @intFromPtr(ptr);
        std.debug.assert(raw <= PTR_MASK);
        return .{ .bits = tag_prefix | (raw & PTR_MASK) };
    }

    pub fn toJSValue(self: NaNBoxedValue) JSValue {
        const v = self.toJSValueNoRetain();
        return v.retain();
    }

    pub fn toJSValueNoRetain(self: NaNBoxedValue) JSValue {
        if (!isBoxed(self.bits)) {
            return JSValue.fromNumber(@bitCast(self.bits));
        }
        if (self.bits == CANONICAL_NAN) {
            return JSValue.fromNumber(std.math.nan(f64));
        }
        const tag = self.bits & TAG_MASK;
        const raw_ptr = self.bits & PTR_MASK;

        if (tag == BASE_BOX) {
            switch (raw_ptr) {
                1 => return JSValue.UNDEFINED,
                2 => return JSValue.NULL,
                3 => return JSValue.fromBool(false),
                4 => return JSValue.fromBool(true),
                else => return .{ .function = @ptrFromInt(raw_ptr) },
            }
        }

        return switch (tag) {
            TAG_STRING => .{ .string = @ptrFromInt(raw_ptr) },
            TAG_ARRAY => .{ .array = @ptrFromInt(raw_ptr) },
            TAG_OBJECT => .{ .object = @ptrFromInt(raw_ptr) },
            TAG_BIGINT => .{ .bigint = @ptrFromInt(raw_ptr) },
            TAG_SYMBOL => .{ .symbol = @ptrFromInt(raw_ptr) },
            TAG_REGEX => .{ .regex = @ptrFromInt(raw_ptr) },
            TAG_MAP => .{ .map = @ptrFromInt(raw_ptr) },
            else => JSValue.UNDEFINED,
        };
    }

    pub fn retain(self: NaNBoxedValue) void {
        if (!isBoxed(self.bits)) return;
        const tag = self.bits & TAG_MASK;
        const raw_ptr = self.bits & PTR_MASK;
        if (tag == BASE_BOX and raw_ptr <= 4) return;
        _ = self.toJSValueNoRetain().retain();
    }

    pub fn deinit(self: NaNBoxedValue) void {
        if (!isBoxed(self.bits)) return;
        const tag = self.bits & TAG_MASK;
        const raw_ptr = self.bits & PTR_MASK;
        if (tag == BASE_BOX and raw_ptr <= 4) return;
        self.toJSValueNoRetain().deinit();
    }
};
