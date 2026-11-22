const std = @import("std");

pub const Alphabet = enum {
    base64,
    base64url,
};

pub const LastChunkHandling = enum {
    loose,
    strict,
    stop_before_partial,
};

pub const DecodeResult = struct {
    read: usize,
    written: usize,
};

fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0c or c == '\r';
}

fn base64CharValue(c: u8, alphabet: Alphabet) ?u6 {
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 26);
    if (c >= '0' and c <= '9') return @intCast(c - '0' + 52);
    switch (alphabet) {
        .base64 => {
            if (c == '+') return 62;
            if (c == '/') return 63;
        },
        .base64url => {
            if (c == '-') return 62;
            if (c == '_') return 63;
        },
    }
    return null;
}

fn hexCharValue(c: u8) ?u4 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

pub fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8, alphabet: Alphabet, omit_padding: bool) ![]u8 {
    const table: *const [64]u8 = switch (alphabet) {
        .base64 => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/",
        .base64url => "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_",
    };
    const full_chunks = bytes.len / 3;
    const rem = bytes.len % 3;
    const out_len = full_chunks * 4 + if (rem == 0) @as(usize, 0) else if (omit_padding) (rem + 1) else @as(usize, 4);
    const out = try allocator.alloc(u8, out_len);
    var i: usize = 0;
    var o: usize = 0;
    while (i + 3 <= bytes.len) : (i += 3) {
        const b0 = bytes[i];
        const b1 = bytes[i + 1];
        const b2 = bytes[i + 2];
        out[o] = table[b0 >> 2];
        out[o + 1] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[o + 2] = table[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[o + 3] = table[b2 & 0x3F];
        o += 4;
    }
    if (rem == 1) {
        const b0 = bytes[i];
        out[o] = table[b0 >> 2];
        out[o + 1] = table[(b0 & 0x03) << 4];
        o += 2;
        if (!omit_padding) {
            out[o] = '=';
            out[o + 1] = '=';
        }
    } else if (rem == 2) {
        const b0 = bytes[i];
        const b1 = bytes[i + 1];
        out[o] = table[b0 >> 2];
        out[o + 1] = table[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[o + 2] = table[(b1 & 0x0F) << 2];
        o += 3;
        if (!omit_padding) {
            out[o] = '=';
        }
    }
    return out;
}

pub fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, idx| {
        out[idx * 2] = hex[b >> 4];
        out[idx * 2 + 1] = hex[b & 0x0F];
    }
    return out;
}

pub fn decodeBase64Into(
    input: []const u8,
    alphabet: Alphabet,
    last_chunk_handling: LastChunkHandling,
    out: []u8,
) error{SyntaxError}!DecodeResult {
    if (out.len == 0) return .{ .read = 0, .written = 0 };
    var read: usize = 0;
    var written: usize = 0;
    var index: usize = 0;

    while (true) {
        while (index < input.len and isAsciiWhitespace(input[index])) : (index += 1) {}
        if (index == input.len) {
            read = index;
            break;
        }

        var chunk: [4]u6 = undefined;
        var chunk_len: usize = 0;
        var pad_count: usize = 0;
        var chunk_end: usize = index;

        while (index < input.len and chunk_len + pad_count < 4) {
            const c = input[index];
            index += 1;
            if (isAsciiWhitespace(c)) continue;
            if (c == '=') {
                if (chunk_len < 2) return error.SyntaxError;
                pad_count += 1;
                chunk_end = index;
                while (index < input.len and pad_count + chunk_len < 4) {
                    const c2 = input[index];
                    index += 1;
                    if (isAsciiWhitespace(c2)) continue;
                    if (c2 != '=') return error.SyntaxError;
                    pad_count += 1;
                    chunk_end = index;
                }
                break;
            }
            const v = base64CharValue(c, alphabet) orelse return error.SyntaxError;
            chunk[chunk_len] = v;
            chunk_len += 1;
            chunk_end = index;
        }

        // Check for trailing non-whitespace after a padded or short chunk
        if (pad_count > 0 or chunk_len < 4) {
            var tail = index;
            while (tail < input.len and isAsciiWhitespace(input[tail])) : (tail += 1) {}
            if (tail < input.len) return error.SyntaxError;
            chunk_end = tail;
        }

        if (chunk_len == 1) {
            if (last_chunk_handling == .stop_before_partial) break;
            return error.SyntaxError;
        }

        if (pad_count > 0) {
            if (chunk_len == 2 and pad_count == 1) {
                if (last_chunk_handling == .stop_before_partial) break;
                return error.SyntaxError;
            }
            if (chunk_len + pad_count != 4) return error.SyntaxError;
            if (last_chunk_handling == .strict) {
                if (chunk_len == 2 and (chunk[1] & 0x0F) != 0) return error.SyntaxError;
                if (chunk_len == 3 and (chunk[2] & 0x03) != 0) return error.SyntaxError;
            }
            const decoded_len: usize = chunk_len - 1;
            if (written + decoded_len > out.len) break;
            const b0: u8 = (@as(u8, chunk[0]) << 2) | (@as(u8, chunk[1]) >> 4);
            out[written] = b0;
            if (decoded_len == 2) {
                const b1: u8 = ((@as(u8, chunk[1]) & 0x0F) << 4) | (@as(u8, chunk[2]) >> 2);
                out[written + 1] = b1;
            }
            written += decoded_len;
            read = chunk_end;
            break;
        }

        if (chunk_len < 4) {
            switch (last_chunk_handling) {
                .strict => return error.SyntaxError,
                .stop_before_partial => break,
                .loose => {
                    const decoded_len: usize = chunk_len - 1;
                    if (written + decoded_len > out.len) break;
                    const b0: u8 = (@as(u8, chunk[0]) << 2) | (@as(u8, chunk[1]) >> 4);
                    out[written] = b0;
                    if (decoded_len == 2) {
                        const b1: u8 = ((@as(u8, chunk[1]) & 0x0F) << 4) | (@as(u8, chunk[2]) >> 2);
                        out[written + 1] = b1;
                    }
                    written += decoded_len;
                    read = chunk_end;
                    break;
                },
            }
        }

        // Full 4-char chunk -> 3 bytes
        if (written + 3 > out.len) break;
        out[written] = (@as(u8, chunk[0]) << 2) | (@as(u8, chunk[1]) >> 4);
        out[written + 1] = ((@as(u8, chunk[1]) & 0x0F) << 4) | (@as(u8, chunk[2]) >> 2);
        out[written + 2] = ((@as(u8, chunk[2]) & 0x03) << 6) | @as(u8, chunk[3]);
        written += 3;
        read = chunk_end;
        if (written == out.len) break;
    }

    return .{ .read = read, .written = written };
}

pub fn decodeBase64Alloc(
    allocator: std.mem.Allocator,
    input: []const u8,
    alphabet: Alphabet,
    last_chunk_handling: LastChunkHandling,
) error{ OutOfMemory, SyntaxError }![]u8 {
    const max_bytes = (input.len / 4) * 3 + 3;
    const buf = try allocator.alloc(u8, max_bytes);
    errdefer allocator.free(buf);
    const res = try decodeBase64Into(input, alphabet, last_chunk_handling, buf);
    const trimmed = try allocator.realloc(buf, res.written);
    return trimmed;
}

pub fn decodeHexInto(input: []const u8, out: []u8) error{SyntaxError}!DecodeResult {
    if (input.len % 2 != 0) return error.SyntaxError;
    if (out.len == 0) return .{ .read = 0, .written = 0 };
    var read: usize = 0;
    var written: usize = 0;
    while (read + 2 <= input.len and written < out.len) {
        const hi = hexCharValue(input[read]) orelse return error.SyntaxError;
        const lo = hexCharValue(input[read + 1]) orelse return error.SyntaxError;
        out[written] = (@as(u8, hi) << 4) | @as(u8, lo);
        read += 2;
        written += 1;
    }
    return .{ .read = read, .written = written };
}

pub fn decodeHexAlloc(allocator: std.mem.Allocator, input: []const u8) error{ OutOfMemory, SyntaxError }![]u8 {
    if (input.len % 2 != 0) return error.SyntaxError;
    const out = try allocator.alloc(u8, input.len / 2);
    errdefer allocator.free(out);
    _ = try decodeHexInto(input, out);
    return out;
}
