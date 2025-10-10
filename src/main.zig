pub const std_options: @import("std").Options = .{ .keep_sigpipe = true };

pub fn main() u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .emscripten) break :gpa .{ std.heap.c_allocator, false };
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast => .{ std.heap.smp_allocator, false },
            .ReleaseSmall => .{ std.heap.page_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = std.process.argsAlloc(allocator) catch return 1;

    var stdout_writer = std.fs.File.stdout().writer(&.{});
    const stdout = &stdout_writer.interface;

    run(
        allocator,
        .{
            .compressFn = compressFile,
            .decompressFn = decompressFile,
        },
        stdout,
        args,
    ) catch |err| {
        switch (err) {
            error.NotEnoughArguments => {
                stdout.writeAll("Not enough arguments.\n" ++ usage) catch return 1;
                stdout.flush() catch return 1;
            },
            else => {},
        }
        return 1;
    };

    return 0;
}

fn run(arena: std.mem.Allocator, ops: Operations, stdout: *std.Io.Writer, args: []const [:0]const u8) !void {
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
        ops.compressFn(arena, options);
    } else {
        ops.decompressFn(arena, options);
    }
}

var visits: std.ArrayList(Options) = undefined;

test run {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    visits = .empty;
    defer visits.deinit(arena);

    const mockOperation = struct {
        pub fn call(alloc: Allocator, options: Options) void {
            visits.append(alloc, options) catch return;
        }
    }.call;

    var writer = std.Io.Writer.Discarding.init(&.{});

    const help_args = [_][:0]const u8{ "ulz", "-h" };
    try run(
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

fn compressFile(arena: std.mem.Allocator, options: Options) void {
    const filename = options.file.?;
    const output = options.output;

    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ filename, @errorName(err) });
    };
    defer file.close();

    const input = file.readToEndAlloc(arena, 1024 * 1024) catch |err| {
        fatal("unable to read '{s}': {s}", .{ filename, @errorName(err) });
    };

    const compressed = ulz.encode(arena, input) catch |err| {
        fatal("unable to compress '{s}': {s}", .{ filename, @errorName(err) });
    };

    const output_filename = if (output) |out| out else std.fmt.allocPrint(arena, "{s}.ulz", .{filename}) catch @panic("OOM");

    var output_file = std.fs.cwd().createFile(output_filename, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_filename, @errorName(err) });
    };
    defer output_file.close();

    output_file.writeAll(compressed[0..]) catch |err| {
        fatal("unable to write to '{s}': {s}", .{ output_filename, @errorName(err) });
    };
}

test "compressFile writes compressed output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Prepare a test file
    const test_filename = "test_compress_input.txt";
    const test_content = "hello world";
    {
        var file = try std.fs.cwd().createFile(test_filename, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(test_filename) catch {};

    // Output file path
    const output_filename = "test_compress_output.ulz";
    defer std.fs.cwd().deleteFile(output_filename) catch {};

    compressFile(allocator, .{ .file = test_filename, .output = output_filename });

    // Check output file exists and is not empty
    var file = try std.fs.cwd().openFile(output_filename, .{});
    defer file.close();
    const compressed = try file.readToEndAlloc(allocator, 1024);
    try std.testing.expect(compressed.len > 0);
}

fn decompressFile(arena: std.mem.Allocator, options: Options) void {
    const filename = options.file.?;
    const output = options.output;

    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ filename, @errorName(err) });
    };
    defer file.close();

    const input = file.readToEndAlloc(arena, 1024 * 1024) catch |err| {
        fatal("unable to read '{s}': {s}", .{ filename, @errorName(err) });
    };

    const decompressed = ulz.decode(arena, input) catch |err| {
        fatal("unable to decompress '{s}': {s}", .{ filename, @errorName(err) });
    };

    const output_file_path = if (output) |out| out else if (std.mem.endsWith(u8, filename, ".ulz"))
        filename[0 .. filename.len - 4]
    else
        std.fmt.allocPrint(arena, "{s}.unlz", .{filename}) catch @panic("OOM");

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    output_file.writeAll(decompressed[0..]) catch |err| {
        fatal("unable to write to '{s}': {s}", .{ output_file_path, @errorName(err) });
    };
}

test "decompressFile writes decompressed output" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // Prepare a test file and compress it
    const test_filename = "test_decompress_input.txt";
    const test_content = "zig is fun";
    {
        var file = try std.fs.cwd().createFile(test_filename, .{});
        defer file.close();
        try file.writeAll(test_content);
    }
    defer std.fs.cwd().deleteFile(test_filename) catch {};

    const compressed_filename = "test_decompress_input.txt.ulz";
    defer std.fs.cwd().deleteFile(compressed_filename) catch {};

    compressFile(allocator, .{ .file = test_filename, .output = compressed_filename });

    // Output file path for decompression
    const output_filename = "test_decompress_output.txt";
    defer std.fs.cwd().deleteFile(output_filename) catch {};

    decompressFile(allocator, .{ .file = compressed_filename, .output = output_filename });

    // Check output file matches original content
    var file = try std.fs.cwd().openFile(output_filename, .{});
    defer file.close();
    const decompressed = try file.readToEndAlloc(allocator, 1024);
    try expectEqualStrings(test_content, decompressed);

    decompressFile(allocator, .{ .file = compressed_filename });
    const default_output_filename = "test_decompress_output.txt";
    defer std.fs.cwd().deleteFile(default_output_filename) catch {};
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
    compressFn: fn (Allocator, Options) void,
    decompressFn: fn (Allocator, Options) void,
};

const ulz = @import("ulz");

const std = @import("std");
const expectEqual = std.testing.expectEqual;
const expectEqualStrings = std.testing.expectEqualStrings;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
