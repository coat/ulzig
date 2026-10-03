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
    try expectEqualSlices(u8, expected_decoded_data, decoded_data);

    // Test encoding
    const re_encoded_data = try encode(allocator, decoded_data);
    defer allocator.free(re_encoded_data);
    try expectEqualSlices(u8, encoded_data, re_encoded_data);
}

test "CPY2" {
    const allocator = std.testing.allocator;

    const encoded_data: []const u8 = &.{ 0x00, 0x6f, 0xcb, 0xb3, 0x00 };

    const expected_decoded_data: [3000]u8 = @splat('o');

    // Test decoding
    const decoded_data = try decode(allocator, encoded_data);
    defer allocator.free(decoded_data);
    try expectEqualSlices(u8, &expected_decoded_data, decoded_data);

    // Test encoding
    const re_encoded_data = try encode(allocator, decoded_data);
    defer allocator.free(re_encoded_data);
    try expectEqualSlices(u8, encoded_data, re_encoded_data);
}

test "LIT run full" {
    const allocator = std.testing.allocator;

    const input = @embedFile("big.txt");
    const compressed = try encode(allocator, input);
    defer allocator.free(compressed);

    const decoded = try decode(allocator, compressed);
    defer allocator.free(decoded);
    try expectEqualSlices(u8, input, decoded);
}

test "decodeInto static buffer sized by comptime decodedLen" {
    const encoded_data = [_]u8{ 0x00, 0x6f, 0xcb, 0xb3, 0x00 };
    var buf: [decodedLen(&encoded_data) catch unreachable]u8 = undefined;
    try expectEqual(3000, buf.len);

    const n = try decodeInto(&encoded_data, &buf);
    try expectEqual(buf.len, n);
    const expected_decoded_data: [3000]u8 = @splat('o');
    try expectEqualSlices(u8, &expected_decoded_data, &buf);
}

test "decodeInto output too small" {
    var buf: [2999]u8 = undefined;
    try expectError(error.OutputTooSmall, decodeInto(&.{ 0x00, 0x6f, 0xcb, 0xb3, 0x00 }, &buf));
}

test "invalid input" {
    const allocator = std.testing.allocator;
    var buf: [64]u8 = undefined;

    // CPY before any output has been written.
    try expectError(error.InvalidInstruction, decodedLen(&.{ 0x80, 0x00 }));
    try expectError(error.InvalidInstruction, decodeInto(&.{ 0x80, 0x00 }, &buf));
    try expectError(error.InvalidInstruction, decode(allocator, &.{ 0x80, 0x00 }));

    // Truncated LIT, CPY1 offset, and CPY2 length.
    for ([_][]const u8{ &.{0x01}, &.{ 0x00, 0x61, 0x80 }, &.{ 0x00, 0x61, 0xc0 } }) |in| {
        try expectError(error.UnexpectedEof, decodedLen(in));
        try expectError(error.UnexpectedEof, decodeInto(in, &buf));
        try expectError(error.UnexpectedEof, decode(allocator, in));
    }
}

test "empty input" {
    const allocator = std.testing.allocator;
    try expectEqual(0, try decodedLen(&.{}));
    const decoded = try decode(allocator, &.{});
    defer allocator.free(decoded);
    try expectEqual(0, decoded.len);
}

const ulz = @import("ulz");
const encode = ulz.encode;
const decode = ulz.decode;
const decodeInto = ulz.decodeInto;
const decodedLen = ulz.decodedLen;

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlices = std.testing.expectEqualSlices;
