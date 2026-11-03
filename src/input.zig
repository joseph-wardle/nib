// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Direction = @import("view.zig").Direction;

pub const Command = union(enum) { move: Direction, quit };

/// Stateful across reads: sequence payloads must never become viewer commands.
/// No escape-key action or timeout is needed. An unfinished sequence consumes
/// input until its terminator; Ctrl-C and Ctrl-Z remain terminal signals.
pub const Parser = struct {
    state: enum { ground, escape, intermediate, csi, string, string_escape, paste } = .ground,
    paste_end: usize = 0,
    string_bell: bool = false,
    parameter: usize = 0,
    plain_parameter: bool = true,

    pub fn feed(self: *Parser, byte: u8) ?Command {
        switch (self.state) {
            .ground => switch (byte) {
                0x1b => self.state = .escape,
                'h' => return .{ .move = .left },
                'j' => return .{ .move = .down },
                'k' => return .{ .move = .up },
                'l' => return .{ .move = .right },
                'q' => return .quit,
                else => {},
            },
            .escape => switch (byte) {
                '[' => {
                    self.state = .csi;
                    self.parameter = 0;
                    self.plain_parameter = true;
                },
                ']', 'P', 'X', '^', '_' => {
                    self.state = .string;
                    self.string_bell = byte == ']';
                },
                'O' => self.state = .intermediate, // SS3 function/cursor keys.
                0x20...0x2f => self.state = .intermediate,
                0x1b => {},
                else => self.state = .ground,
            },
            .intermediate => {
                if (byte == 0x1b) self.state = .escape else if (byte >= 0x30 and byte <= 0x7e) self.state = .ground;
            },
            .csi => {
                if (byte == 0x1b) {
                    self.state = .escape;
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = if (byte == '~' and self.plain_parameter and self.parameter == 200) .paste else .ground;
                    self.paste_end = 0;
                } else if (byte >= '0' and byte <= '9') {
                    self.parameter = @min(1000, self.parameter * 10 + byte - '0');
                } else {
                    self.plain_parameter = false;
                }
            },
            .string => {
                if (byte == 0x07 and self.string_bell) self.state = .ground else if (byte == 0x1b) self.state = .string_escape;
            },
            .string_escape => {
                self.state = if (byte == '\\') .ground else if (byte == 0x1b) .string_escape else .string;
            },
            .paste => {
                const end = "\x1b[201~";
                self.paste_end = if (byte == end[self.paste_end]) self.paste_end + 1 else if (byte == end[0]) 1 else 0;
                if (self.paste_end == end.len) self.state = .ground;
            },
        }
        return null;
    }
};

test "fragmented escape sequences and bracketed paste cannot execute commands" {
    var parser: Parser = .{};
    for ([_][]const u8{ "\x1b[A", "\x1bOq", "\x1bq", "\x1b[9999999999999q", "\x1b]qhjkl\x07", "\x1bPq\x07hjkl\x1b\\", "\x1bXqhjkl\x1b\\", "\x1b[200~qhjkl\x1b[20xq\x1b[201~", "\x1b(B" }) |sequence| {
        for (sequence) |byte| try std.testing.expect(parser.feed(byte) == null);
        try std.testing.expectEqualDeep(Command{ .move = .down }, parser.feed('j').?);
    }
    try std.testing.expectEqualDeep(Command.quit, parser.feed('q').?);
}
