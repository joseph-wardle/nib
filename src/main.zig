// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    try std.Io.File.stdout().writeStreamingAll(init.io, "Nib: Currently does nothing.\n");
}
