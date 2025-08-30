//! By convention, root.zig is the root source file when making a library.

pub const decode = ulz.decode;
pub const encode = ulz.encode;

test {
    _ = ulz;
}

const ulz = @import("ulz.zig");

const std = @import("std");
