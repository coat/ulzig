pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const gpa, const is_debug = gpa: {
        if (builtin.os.tag == .emscripten) break :gpa .{ std.heap.c_allocator, false };
        if (builtin.os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    try run(
        allocator,
        .{
            .compressFn = compressFile,
            .decompressFn = decompressFile,
        },
        args,
    );
}

fn run(arena: std.mem.Allocator, context: Operations, args: []const [:0]const u8) !void {
    const options = flags.parse(args, "ulz", Flags, .{});

    // combine positional file and trailing files into a single list
    var files = blk: {
        var all_files = std.ArrayList([]const u8).empty;
        try all_files.append(arena, options.positional.files);
        for (options.positional.trailing) |filename| {
            try all_files.append(arena, filename);
        }
        break :blk all_files.items;
    };

    // only process the last file if output is specified
    // flags.pars ensures at least one file is provided
    if (options.output) |_| {
        files = files[files.len - 1 ..];
    }

    for (files) |filename| {
        if (options.decompress) {
            context.decompressFn(arena, filename, options.output);
        } else if (options.compress) {
            context.compressFn(arena, filename, options.output);
        }
    }
}

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

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);

    std.process.exit(1);
}

const Flags = struct {
    pub const description =
        \\Compress and decompress files using ULZ.
    ;

    pub const switches = .{
        .compress = 'z',
        .decompress = 'd',
        .output = 'o',
    };

    pub const descriptions = .{
        .compress = "Compress (default)",
        .decompress = "Decompress",
        .output = "Write output to a single file",
    };

    compress: bool = true,
    decompress: bool = false,
    output: ?[]const u8 = null,

    positional: struct {
        pub const descriptions = .{
            .files = "One or more input files",
        };

        files: []const u8,
        trailing: []const []const u8,
    },
};

var called_files: std.ArrayList([]const u8) = undefined;

test "run processes only last file when -o is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    called_files = .empty;
    defer called_files.deinit(allocator);

    const mockOperation = struct {
        pub fn call(alloc: std.mem.Allocator, filename: []const u8, _: ?[]const u8) void {
            called_files.append(alloc, filename) catch return;
        }
    }.call;

    const args = [_][:0]const u8{ "ulz", "-o", "out.ulz", "tests/test.txt", "tests/test2.txt" };
    try run(allocator, .{
        .compressFn = mockOperation,
        .decompressFn = mockOperation,
    }, args[0..]);

    try std.testing.expectEqual(@as(usize, 1), called_files.items.len);
    try std.testing.expectEqualStrings("tests/test2.txt", called_files.items[0]);
}

test "run processes all files when -o is not set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    called_files = .empty;
    defer called_files.deinit(allocator);

    const mockOperation = struct {
        pub fn call(alloc: std.mem.Allocator, filename: []const u8, _: ?[]const u8) void {
            called_files.append(alloc, filename) catch return;
        }
    }.call;

    const args = [_][:0]const u8{ "ulz", "tests/test.txt", "tests/test2.txt" };
    try run(allocator, .{
        .compressFn = mockOperation,
        .decompressFn = mockOperation,
    }, args[0..]);

    try std.testing.expectEqual(@as(usize, 2), called_files.items.len);
    try std.testing.expectEqualStrings("tests/test.txt", called_files.items[0]);
    try std.testing.expectEqualStrings("tests/test2.txt", called_files.items[1]);
}

const Operations = struct {
    compressFn: fn (std.mem.Allocator, []const u8, ?[]const u8) void,
    decompressFn: fn (std.mem.Allocator, []const u8, ?[]const u8) void,
};

const ulz = @import("ulz");

const flags = @import("flags");

const std = @import("std");
const builtin = @import("builtin");
