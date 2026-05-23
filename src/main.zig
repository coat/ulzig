pub fn main(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var args_iter = std.process.Args.Iterator.initAllocator(init.minimal.args, arena) catch return 1;
    _ = args_iter.skip();

    var args_list: std.ArrayList([:0]const u8) = .empty;
    args_list.append(arena, "ulz") catch return 1;
    while (args_iter.next()) |arg| {
        args_list.append(arena, arg) catch return 1;
    }
    const args = args_list.items;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);

    run(
        io,
        arena,
        .{
            .compressFn = compressFile,
            .decompressFn = decompressFile,
        },
        &stdout_writer.interface,
        args,
    ) catch |err| {
        switch (err) {
            error.NotEnoughArguments => {
                stdout_writer.interface.writeAll("Not enough arguments.\n" ++ usage) catch return 1;
                stdout_writer.interface.flush() catch return 1;
            },
            else => {},
        }
        return 1;
    };

    return 0;
}

fn run(io: std.Io, arena: std.mem.Allocator, ops: Operations, stdout: *std.Io.Writer, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        return error.NotEnoughArguments;
    }
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try stdout.writeAll(usage);
            try stdout.flush();
            return;
        }
    }

    const options = try Options.fromArgs(args);

    if (options.compress) {
        ops.compressFn(io, arena, options);
    } else {
        ops.decompressFn(io, arena, options);
    }
}

var visits: std.ArrayList(Options) = undefined;

test run {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    visits = .empty;
    defer visits.deinit(arena);

    const mockOperation = struct {
        pub fn call(_: std.Io, alloc: Allocator, options: Options) void {
            visits.append(alloc, options) catch return;
        }
    }.call;

    var discard_buf: [64]u8 = undefined;
    var writer = Io.Writer.Discarding.init(&discard_buf);

    const help_args = [_][:0]const u8{ "ulz", "-h" };
    try run(
        io,
        arena,
        .{
            .compressFn = mockOperation,
            .decompressFn = mockOperation,
        },
        &writer.writer,
        &help_args,
    );

    try expectEqual(0, visits.items.len);

    const args_with_output = [_][:0]const u8{ "ulz", "-o", "out.ulz", "tests/test.txt" };
    try run(
        io,
        arena,
        .{
            .compressFn = mockOperation,
            .decompressFn = mockOperation,
        },
        &writer.writer,
        &args_with_output,
    );
    try expectEqual(1, visits.items.len);
    try expectEqualStrings("out.ulz", visits.items[0].output.?);
    try expectEqualStrings("tests/test.txt", visits.items[0].file.?);

    visits = .empty;
    const min_args = [_][:0]const u8{ "ulz", "tests/test.txt" };
    try run(
        io,
        arena,
        .{
            .compressFn = mockOperation,
            .decompressFn = mockOperation,
        },
        &writer.writer,
        &min_args,
    );
    try expectEqual(1, visits.items.len);
    try expectEqual(true, visits.items[0].compress);
    try expectEqual(null, visits.items[0].output);
    try expectEqualStrings("tests/test.txt", visits.items[0].file.?);

    visits = .empty;
    const decompress_args = [_][:0]const u8{ "ulz", "-d", "tests/test.txt.ulz" };
    try run(
        io,
        arena,
        .{
            .compressFn = mockOperation,
            .decompressFn = mockOperation,
        },
        &writer.writer,
        &decompress_args,
    );
    try expectEqual(1, visits.items.len);
    try expectEqual(false, visits.items[0].compress);
    try expectEqualStrings("tests/test.txt.ulz", visits.items[0].file.?);

    visits = .empty;
    const no_args = [_][:0]const u8{"ulz"};
    try std.testing.expectError(error.NotEnoughArguments, run(
        io,
        arena,
        .{
            .compressFn = mockOperation,
            .decompressFn = mockOperation,
        },
        &writer.writer,
        &no_args,
    ));
}

const usage =
    \\
    \\Usage: ulz [-d | --decompress] [-o | --output <output>]
    \\           [-h | --help] FILE
    \\
    \\Compress and decompress files using ULZ.
    \\
    \\Options:
    \\
    \\  -d, --decompress Decompress
    \\  -o, --output     Write output to a single file
    \\  -h, --help       Show this help and exit
    \\
    \\Arguments:
    \\
    \\  FILE Input file
    \\
;

fn compressFile(io: std.Io, arena: std.mem.Allocator, options: Options) void {
    const filename = options.file.?;
    const output = options.output;

    const input = Io.Dir.cwd().readFileAlloc(io, filename, arena, .unlimited) catch |err| {
        fatal("unable to read '{s}': {s}", .{ filename, @errorName(err) });
    };

    const compressed = ulz.encode(arena, input) catch |err| {
        fatal("unable to compress '{s}': {s}", .{ filename, @errorName(err) });
    };

    const output_filename = if (output) |out_filename| out_filename else std.fmt.allocPrint(arena, "{s}.ulz", .{filename}) catch @panic("OOM");

    var output_file = Io.Dir.cwd().createFile(io, output_filename, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_filename, @errorName(err) });
    };
    defer output_file.close(io);

    output_file.writeStreamingAll(io, compressed[0..]) catch |err| {
        fatal("unable to write to '{s}': {s}", .{ output_filename, @errorName(err) });
    };
}

test "compressFile writes compressed output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const test_filename = "test_compress_input.txt";
    const test_content = "hello world";
    {
        var file = try Io.Dir.cwd().createFile(io, test_filename, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_content);
    }
    defer Io.Dir.cwd().deleteFile(io, test_filename) catch {};

    const output_filename = "test_compress_output.ulz";
    defer Io.Dir.cwd().deleteFile(io, output_filename) catch {};

    compressFile(io, allocator, .{ .file = test_filename, .output = output_filename });

    const compressed = try Io.Dir.cwd().readFileAlloc(io, output_filename, allocator, .unlimited);
    try std.testing.expect(compressed.len > 0);
}

fn decompressFile(io: std.Io, arena: std.mem.Allocator, options: Options) void {
    const filename = options.file.?;
    const output = options.output;

    const input = Io.Dir.cwd().readFileAlloc(io, filename, arena, .unlimited) catch |err| {
        fatal("unable to read '{s}': {s}", .{ filename, @errorName(err) });
    };

    const decompressed = ulz.decode(arena, input) catch |err| {
        fatal("unable to decompress '{s}': {s}", .{ filename, @errorName(err) });
    };

    const output_file_path = if (output) |out| out else if (std.mem.endsWith(u8, filename, ".ulz"))
        filename[0 .. filename.len - 4]
    else
        std.fmt.allocPrint(arena, "{s}.unlz", .{filename}) catch @panic("OOM");

    var output_file = Io.Dir.cwd().createFile(io, output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close(io);

    output_file.writeStreamingAll(io, decompressed[0..]) catch |err| {
        fatal("unable to write to '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
}

test "decompressFile writes decompressed output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;

    const test_filename = "test_decompress_input.txt";
    const test_content = "zig is fun";
    {
        var file = try Io.Dir.cwd().createFile(io, test_filename, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, test_content);
    }
    defer Io.Dir.cwd().deleteFile(io, test_filename) catch {};

    const compressed_filename = "test_decompress_input.txt.ulz";
    defer Io.Dir.cwd().deleteFile(io, compressed_filename) catch {};

    compressFile(io, allocator, .{ .file = test_filename, .output = compressed_filename });

    const output_filename = "test_decompress_output.txt";
    defer Io.Dir.cwd().deleteFile(io, output_filename) catch {};

    decompressFile(io, allocator, .{ .file = compressed_filename, .output = output_filename });

    const decompressed = try Io.Dir.cwd().readFileAlloc(io, output_filename, allocator, .unlimited);
    try expectEqualStrings(test_content, decompressed);

    decompressFile(io, allocator, .{ .file = compressed_filename });
    const default_output_filename = "test_decompress_output.txt";
    defer Io.Dir.cwd().deleteFile(io, default_output_filename) catch {};
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);

    std.process.exit(1);
}

const Options = struct {
    compress: bool = true,
    output: ?[]const u8 = null,
    file: ?[]const u8 = null,

    pub fn fromArgs(args: []const [:0]const u8) !Options {
        var flags: Options = .default;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-d", arg) or std.mem.eql(u8, "--decompress", arg)) {
                flags.compress = false;
            } else if (std.mem.eql(u8, "-o", arg) or std.mem.eql(u8, "--output", arg)) {
                i += 1;
                if (i > args.len) fatal("expected arg after '{s}'", .{arg});
                if (flags.output != null) fatal("duplicated {s} argument", .{arg});
                flags.output = args[i];
            } else if (i == args.len - 1) {
                flags.file = arg;
            }
        }

        return flags;
    }

    pub const default: Options = .{ .compress = true, .output = null, .file = null };
};

const Operations = struct {
    compressFn: *const fn (std.Io, Allocator, Options) void,
    decompressFn: *const fn (std.Io, Allocator, Options) void,
};

const ulz = @import("ulz");

const std = @import("std");
const Io = std.Io;
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
