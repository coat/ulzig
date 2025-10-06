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

    run(allocator, args) catch return 1;

    return 0;
}

fn run(arena: std.mem.Allocator, args: []const [:0]const u8) !void {
    if (args.len < 2) {
        try std.fs.File.stdout().writeAll(usage);
        return error.NotEnoughArguments;
    }
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, "-h", arg) or std.mem.eql(u8, "--help", arg)) {
            try std.fs.File.stdout().writeAll(usage);
            return;
        }
    }

    const options = try Flags.fromArgs(args);

    if (options.compress) {
        compressFile(arena, options.file.?, options.output);
    } else {
        decompressFile(arena, options.file.?, options.output);
    }
}

const usage =
    \\
    \\Usage: ulz [-z | --compress] [-d | --decompress] [-o | --output <output>]
    \\           [-h | --help] FILE
    \\
    \\Compress and decompress files using ULZ.
    \\
    \\Options:
    \\
    \\  -z, --compress   Compress (default)
    \\  -d, --decompress Decompress
    \\  -o, --output     Write output to a single file
    \\  -h, --help       Show this help and exit
    \\
    \\Arguments:
    \\
    \\  FILE Input file
    \\
;

fn compressFile(arena: std.mem.Allocator, filename: []const u8, output: ?[]const u8) void {
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

    compressFile(allocator, test_filename, output_filename);

    // Check output file exists and is not empty
    var file = try std.fs.cwd().openFile(output_filename, .{});
    defer file.close();
    const compressed = try file.readToEndAlloc(allocator, 1024);
    try std.testing.expect(compressed.len > 0);
}

fn decompressFile(arena: std.mem.Allocator, filename: []const u8, output: ?[]const u8) void {
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

    const compressed_filename = "test_decompress_input.ulz";
    defer std.fs.cwd().deleteFile(compressed_filename) catch {};
    compressFile(allocator, test_filename, compressed_filename);

    // Output file path for decompression
    const output_filename = "test_decompress_output.txt";
    defer std.fs.cwd().deleteFile(output_filename) catch {};

    decompressFile(allocator, compressed_filename, output_filename);

    // Check output file matches original content
    var file = try std.fs.cwd().openFile(output_filename, .{});
    defer file.close();
    const decompressed = try file.readToEndAlloc(allocator, 1024);
    try std.testing.expectEqualStrings(test_content, decompressed);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);

    std.process.exit(1);
}

const Flags = struct {
    compress: bool = true,
    output: ?[]const u8 = null,
    file: ?[]const u8 = null,

    pub fn fromArgs(args: []const [:0]const u8) !Flags {
        var flags: Flags = .default;

        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, "-z", arg) or std.mem.eql(u8, "--compress", arg)) {
                i += 1;
            } else if (std.mem.eql(u8, "-d", arg) or std.mem.eql(u8, "--decompress", arg)) {
                i += 1;
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

    pub const default: Flags = .{ .compress = true, .output = null, .file = null };
};

const ulz = @import("ulz");

const std = @import("std");
const builtin = @import("builtin");
