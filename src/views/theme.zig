// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const Frame = @import("../terminal/frame.zig").Frame;

/// What a styled cell means. Each role's look comes from `looks`.
pub const Role = enum {
    line_number,
    current_line_number,
    search_match,
    selection,
    status,
    finder_chosen,
    finder_ignored,
    finder_matched,
};

/// The default theme: SGR parameters in the terminal's own palette, so Nib
/// follows its colour scheme and never paints a background of its own.
const looks: std.enums.EnumArray(Role, []const u8) = .init(.{
    .line_number = "90",
    .current_line_number = "1;33",
    .search_match = "33;7",
    .selection = "7",
    .status = "7",
    .finder_chosen = "7",
    .finder_ignored = "2",
    .finder_matched = "4;33",
});

/// Returns to unstyled text. The app ends each frame with `ESC [0m`, the same
/// reset spelled differently, and the PTY tests take that one as the end of a
/// frame, so views reset with this one.
pub const plain = "\x1b[m";

/// Starts drawing in exactly `roles` combined, whatever was drawn before:
/// every change is a full reset plus the roles' attributes. No roles is
/// `plain`.
pub fn set(frame: *Frame, roles: []const Role) terminal.Error!void {
    if (roles.len == 0) return frame.append(plain);
    try frame.append("\x1b[0");
    for (roles) |role| {
        try frame.append(";");
        try frame.append(looks.get(role));
    }
    try frame.append("m");
}

test "roles combine into one sequence that starts from a full reset" {
    var frame: Frame = .{ .screen = undefined };
    try set(&frame, &.{.search_match});
    try set(&frame, &.{ .finder_chosen, .finder_ignored, .finder_matched });
    try set(&frame, &.{});
    const expected = "\x1b[0;33;7m" ++ "\x1b[0;7;2;4;33m" ++ "\x1b[m";
    try std.testing.expectEqualStrings(expected, frame.bytes[0..frame.len]);
}
