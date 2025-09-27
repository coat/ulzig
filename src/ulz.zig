//! This is a port of the wonderful C implementation by hundred rabbits: https://git.sr.ht/~rabbits/uxn-utils/tree/main/item/cli/lz

pub const UlzError = error{
    OutputTooSmall,
    InvalidInstruction,
    UnexpectedEof,
};

const min_match_length: u16 = 4;
const max_dict_len: usize = 256;
const max_match_len: u16 = 0x3fff + min_match_length;

/// Decodes a ULZ compressed slice of bytes.
///
/// The `allocator` is used to allocate the returned slice of decompressed data.
/// The caller is responsible for freeing the returned slice.
pub fn decode(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var output = std.ArrayList(u8).empty;

    var i: usize = 0;
    while (i < compressed.len) {
        const command = compressed[i];
        i += 1;

        if (command & 0x80 == 0) {
            // LIT: The 7 low bits of the command byte are `length - 1`.
            const length: u8 = (command & 0x7f) + 1;

            if (i + length > compressed.len) return UlzError.UnexpectedEof;

            try output.appendSlice(allocator, compressed[i..][0..length]);
            i += length;
        } else {
            // CPY
            const length: u16 = if (command & 0x40 == 0) blk: {
                // CPY1: 10LLLLLL (6 bits for length)
                const len_ctl = command & 0x3f;
                break :blk @as(u16, len_ctl) + min_match_length;
            } else blk: {
                // CPY2: 11LLLLLL LLLLLLLL (14 bits for length)
                if (i >= compressed.len) return UlzError.UnexpectedEof;
                const high_byte = command & 0x3f;
                const low_byte = compressed[i];
                i += 1;
                const len_ctl = (@as(u16, high_byte) << 8) | @as(u16, low_byte);
                break :blk len_ctl + min_match_length;
            };

            if (i >= compressed.len) return UlzError.UnexpectedEof;
            const offset: u16 = @as(u16, compressed[i]) + 1;

            i += 1;

            // Capture the output length *before* we start appending. This provides
            // a stable boundary for the history buffer.
            const start_len = output.items.len;
            if (offset > start_len) return UlzError.InvalidInstruction;

            var p = start_len - offset;
            var c: u16 = 0;
            while (c < length) : (c += 1) {
                try output.append(allocator, output.items[p]);
                p += 1;
                // If the read pointer reaches the end of the original history window,
                // wrap it around to the start of that window.
                if (p == start_len) {
                    p = start_len - offset;
                }
            }
        }
    }

    return output.toOwnedSlice(allocator);
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

test {
    const allocator = std.testing.allocator;

    const encoded_data: []const u8 = &.{
        0x28, 0x42, 0x6c, 0x75, 0x65, 0x20, 0x6c, 0x69, 0x6b, 0x65, 0x20, 0x6d, 0x79, 0x20,
        0x63, 0x6f, 0x72, 0x76, 0x65, 0x74, 0x74, 0x65, 0x20, 0x69, 0x74, 0x73, 0x20, 0x69,
        0x6e, 0x20, 0x61, 0x6e, 0x64, 0x20, 0x6f, 0x75, 0x74, 0x73, 0x69, 0x64, 0x65, 0x0a,
        0x81, 0x28, 0x23, 0x61, 0x72, 0x65, 0x20, 0x74, 0x68, 0x65, 0x20, 0x77, 0x6f, 0x72,
        0x64, 0x73, 0x20, 0x49, 0x20, 0x73, 0x61, 0x79, 0x0a, 0x41, 0x6e, 0x64, 0x20, 0x77,
        0x68, 0x61, 0x74, 0x20, 0x49, 0x20, 0x74, 0x68, 0x69, 0x6e, 0x6b, 0x8a, 0x29, 0x09,
        0x66, 0x65, 0x65, 0x6c, 0x69, 0x6e, 0x67, 0x73, 0x0a, 0x54, 0x80, 0x22, 0x06, 0x6c,
        0x69, 0x76, 0x65, 0x20, 0x69, 0x6e, 0x80, 0x50, 0x17, 0x20, 0x6d, 0x65, 0x0a, 0x49,
        0x27, 0x6d, 0x20, 0x62, 0x6c, 0x75, 0x65, 0x0a, 0x44, 0x61, 0x20, 0x62, 0x61, 0x20,
        0x64, 0x65, 0x65, 0x20, 0x64, 0x82, 0x09, 0x00, 0x69, 0xb5, 0x12,
    };

    const expected_decoded_data =
        \\Blue like my corvette its in and outside
        \\Blue are the words I say
        \\And what I think
        \\Blue are the feelings
        \\That live inside me
        \\I'm blue
        \\Da ba dee da ba di
        \\Da ba dee da ba di
        \\Da ba dee da ba di
        \\Da ba dee da ba di
    ;

    // Test decoding
    const decoded_data = try decode(allocator, encoded_data);
    defer allocator.free(decoded_data);
    try std.testing.expectEqualSlices(u8, expected_decoded_data, decoded_data);

    // Test encoding
    const re_encoded_data = try encode(allocator, decoded_data);
    defer allocator.free(re_encoded_data);
    try std.testing.expectEqualSlices(u8, encoded_data, re_encoded_data);
}

test "CPY2" {
    const allocator = std.testing.allocator;

    const encoded_data: []const u8 = &.{ 0x00, 0x6f, 0xcb, 0xb3, 0x00 };

    const expected_decoded_data: [3000]u8 = @splat('o');

    // Test decoding
    const decoded_data = try decode(allocator, encoded_data);
    defer allocator.free(decoded_data);
    try std.testing.expectEqualSlices(u8, &expected_decoded_data, decoded_data);

    // Test encoding
    const re_encoded_data = try encode(allocator, decoded_data);
    defer allocator.free(re_encoded_data);
    try std.testing.expectEqualSlices(u8, encoded_data, re_encoded_data);

    const data: [300_000]u8 = @splat('o');
    const encoded_large_data = try encode(allocator, &data);
    defer allocator.free(encoded_large_data);
}

const std = @import("std");
