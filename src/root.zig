//! By convention, root.zig is the root source file when making a library.

pub const decode = ulz.decode;
pub const encode = ulz.encode;

const ulz = @import("ulz.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
