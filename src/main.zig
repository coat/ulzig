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

    const options = flags.parse(args, "ulz", Flags, .{});

    const files = blk: {
        var all_files = std.ArrayList([]const u8).empty;
        try all_files.append(allocator, options.positional.files);
        for (options.positional.trailing) |filename| {
            try all_files.append(allocator, filename);
        }
        break :blk all_files.items;
    };

    for (files) |filename| {
        if (options.decompress) {
            try decompressFile(allocator, filename, options.output);
        } else if (options.compress) {
            try compressFile(allocator, filename, options.output);
        }
    }
}

fn compressFile(arena: std.mem.Allocator, filename: []const u8, output: ?[]const u8) !void {
    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ filename, @errorName(err) });
    };
    defer file.close();

    const input = try file.readToEndAlloc(arena, 1024 * 1024);

    const compressed = try ulz.encode(arena, input);

    const output_filename = if (output) |out| out else try std.fmt.allocPrint(arena, "{s}.ulz", .{filename});

    var output_file = std.fs.cwd().createFile(output_filename, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_filename, @errorName(err) });
    };
    defer output_file.close();

    try output_file.writeAll(compressed[0..]);
}

fn decompressFile(arena: std.mem.Allocator, filename: []const u8, output_override: ?[]const u8) !void {
    var file = std.fs.cwd().openFile(filename, .{}) catch |err| {
        fatal("unable to open '{s}': {s}", .{ filename, @errorName(err) });
    };
    defer file.close();

    const input = try file.readToEndAlloc(arena, 1024 * 1024);

    const decompressed = try ulz.decode(arena, input);

    const output_file_path = if (output_override) |out| out else if (std.mem.endsWith(u8, filename, ".ulz"))
        filename[0 .. filename.len - 4]
    else
        try std.fmt.allocPrint(arena, "{s}.unlz", .{filename});

    var output_file = std.fs.cwd().createFile(output_file_path, .{}) catch |err| {
        fatal("unable to open '{s}' for writing: {s}", .{ output_file_path, @errorName(err) });
    };
    defer output_file.close();

    try output_file.writeAll(decompressed[0..]);
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

const ulz = @import("ulz");

const flags = @import("flags");

const std = @import("std");
const builtin = @import("builtin");
