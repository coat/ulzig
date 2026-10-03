//! This is a port of the wonderful C implementation by hundred rabbits:
//! https://git.sr.ht/~rabbits/uxn-utils/tree/main/item/cli/lz

pub const UlzError = error{
    OutputTooSmall,
    InvalidInstruction,
    UnexpectedEof,
};

const min_match_length: u16 = 4;
const max_dict_len: usize = 256;
const max_match_len: u16 = 0x3fff + min_match_length;

/// Decodes ULZ compressed `in` into `out`, returning the number of bytes
/// written.
///
/// Returns `error.OutputTooSmall` if `out` cannot hold the decoded data. Use
/// `decodedLen` to size `out` exactly.
pub fn decodeInto(in: []const u8, out: []u8) UlzError!usize {
    var i: usize = 0;
    var o: usize = 0;
    while (i < in.len) {
        const c = in[i];
        i += 1;
        var len: usize = undefined;
        var src: [*]const u8 = undefined;
        if (c < 0x80) {
            // LIT: 0LLLLLLL, followed by `L + 1` literal bytes.
            len = @as(usize, c) + 1;
            if (in.len - i < len) return error.UnexpectedEof;
            src = in.ptr + i;
            i += len;
        } else {
            // CPY1: 10LLLLLL, or CPY2: 11LLLLLL LLLLLLLL, followed by `offset - 1`.
            len = c & 0x3f;
            if (c & 0x40 != 0) {
                if (i >= in.len) return error.UnexpectedEof;
                len = (len << 8) | in[i];
                i += 1;
            }
            len += min_match_length;
            if (i >= in.len) return error.UnexpectedEof;
            const offset = @as(usize, in[i]) + 1;
            i += 1;
            if (offset > o) return error.InvalidInstruction;
            src = out.ptr + o - offset;
        }
        if (out.len - o < len) return error.OutputTooSmall;
        // Forward byte copy: required for overlapping CPY, and shared with LIT.
        for (out[o..][0..len], src[0..len]) |*d, s| d.* = s;
        o += len;
    }
    return o;
}

/// Returns the decoded length of ULZ compressed `in` without decoding it.
///
/// Validates `in` the same way as `decodeInto`. Can be called at comptime to
/// size a static buffer for embedded data:
///
/// ```zig
/// var buf: [ulz.decodedLen(asset) catch unreachable]u8 = undefined;
/// ```
pub fn decodedLen(in: []const u8) UlzError!usize {
    if (@inComptime()) @setEvalBranchQuota(@intCast(in.len * 8 + 1000));
    var i: usize = 0;
    var o: usize = 0;
    while (i < in.len) {
        const c = in[i];
        i += 1;
        if (c < 0x80) {
            const len = @as(usize, c) + 1;
            if (in.len - i < len) return error.UnexpectedEof;
            i += len;
            o += len;
        } else {
            var len: usize = c & 0x3f;
            if (c & 0x40 != 0) {
                if (i >= in.len) return error.UnexpectedEof;
                len = (len << 8) | in[i];
                i += 1;
            }
            if (i >= in.len) return error.UnexpectedEof;
            if (@as(usize, in[i]) + 1 > o) return error.InvalidInstruction;
            i += 1;
            o += len + min_match_length;
        }
    }
    return o;
}

/// Decodes a ULZ compressed slice of bytes.
///
/// The `allocator` is used to allocate the returned slice of decompressed data.
/// The caller is responsible for freeing the returned slice.
pub fn decode(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, try decodedLen(compressed));
    errdefer allocator.free(out);
    _ = try decodeInto(compressed, out);
    return out;
}

/// Encodes a slice of bytes using the ULZ compression format.
///
/// The `allocator` is used to allocate the returned slice of compressed data.
/// The caller is responsible for freeing the returned slice.
pub fn encode(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;

    var in_pos: usize = 0;
    // Index of the active LIT command byte, used for combining literals.
    var active_lit_idx: ?usize = null;

    while (in_pos < raw.len) {
        const dict_len = @min(in_pos, max_dict_len);
        const lookahead_len = @min(raw.len - in_pos, max_match_len);

        var best_match_len: u16 = 0;
        var best_match_offset: u16 = 0;

        if (lookahead_len >= min_match_length) {
            // Iterate backwards through the dictionary to find the longest match.
            // `offset` is the distance to go back, from 1 to `dict_len`.
            var offset: u16 = 1;
            while (offset <= dict_len) : (offset += 1) {
                const match_start_in_history = in_pos - offset;

                var current_match_len: u16 = 0;
                while (current_match_len < lookahead_len and
                    raw[in_pos + current_match_len] ==
                        raw[match_start_in_history + (current_match_len % offset)])
                {
                    current_match_len += 1;
                }

                if (current_match_len > best_match_len) {
                    best_match_len = current_match_len;
                    best_match_offset = offset;
                }
            }
        }

        if (best_match_len >= min_match_length) {
            // CPY instruction.
            // A literal run is broken by a CPY, so reset the index.
            active_lit_idx = null;

            const match_ctl = best_match_len - min_match_length;
            if (match_ctl > 0x3F) {
                // CPY2 for lengths > 63 + 4
                // Command: 11 HHHHHH (6 high bits of length)
                try output.append(allocator, @as(u8, @intCast((match_ctl >> 8) | 0xc0)));
                // Followed by 8 low bits of length
                try output.append(allocator, @as(u8, @intCast(match_ctl & 0xff)));
            } else {
                // CPY1 for lengths <= 63 + 4
                // Command: 10 LLLLLL (6 bits of length)
                try output.append(allocator, @as(u8, @intCast(match_ctl | 0x80)));
            }
            // Offset is stored as `offset - 1`
            try output.append(allocator, @as(u8, @intCast(best_match_offset - 1)));
            in_pos += best_match_len;
        } else {
            // LIT instruction.
            if (active_lit_idx) |cmd_idx| {
                // An active literal run exists. Try to extend it.
                if (output.items[cmd_idx] < 0x7f) {
                    // The run is not full, so increment its length counter.
                    output.items[cmd_idx] += 1;
                } else {
                    // The run is full (128 bytes). Start a new one.
                    active_lit_idx = output.items.len;
                    try output.append(allocator, 0); // Command byte for length 1 (0 = len-1)
                }
            } else {
                // No active literal run. Start a new one.
                active_lit_idx = output.items.len;
                try output.append(allocator, 0); // Command byte for length 1
            }
            // Append the literal byte itself to the stream.
            try output.append(allocator, raw[in_pos]);
            in_pos += 1;
        }
    }

    return output.toOwnedSlice(allocator);
}

const std = @import("std");
