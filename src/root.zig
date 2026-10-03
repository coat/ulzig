//! By convention, root.zig is the root source file when making a library.

pub const decode = ulz.decode;
pub const decodeInto = ulz.decodeInto;
pub const decodedLen = ulz.decodedLen;
pub const encode = ulz.encode;
pub const UlzError = ulz.UlzError;

const ulz = @import("ulz.zig");

comptime {
    @import("std").testing.refAllDecls(@This());
}
