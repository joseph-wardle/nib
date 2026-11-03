// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Motion = @import("motion.zig").Motion;
pub const Movement = struct { motion: Motion, count: ?usize = null };

pub const Command = union(enum) { move: Movement, quit };

/// Stateful across reads: sequence payloads must never become viewer commands.
/// No escape-key action or timeout is needed. An unfinished sequence consumes
/// input until its terminator; Ctrl-C and Ctrl-Z remain terminal signals.
pub const Parser = struct {
    state: enum { ground, escape, intermediate, csi, string, string_escape, paste } = .ground,
    paste_end: usize = 0,
    string_bell: bool = false,
    parameter: usize = 0,
    plain_parameter: bool = true,

    count: ?usize = null,
    count_overflow: bool = false,
    pending_g: bool = false,

    fn cancel(self: *Parser) void {
        self.count = null;
        self.count_overflow = false;
        self.pending_g = false;
    }

    fn navigation(self: *Parser, byte: u8) ?Command {
        if (!self.pending_g and byte >= '0' and byte <= '9' and (byte != '0' or self.count != null)) {
            const value = std.math.mul(usize, self.count orelse 0, 10) catch {
                self.count_overflow = true;
                return null;
            };
            self.count = std.math.add(usize, value, byte - '0') catch {
                self.count_overflow = true;
                return null;
            };
            return null;
        }
        if (byte == 'g' and !self.pending_g and !self.count_overflow) {
            self.pending_g = true;
            return null;
        }
        const count = self.count;
        const pending_g = self.pending_g;
        const invalid = self.count_overflow;
        self.cancel();
        if (invalid) return null;
        if (pending_g) return if (byte == 'g') .{ .move = .{ .motion = .first_line, .count = count } } else null;
        const motion: Motion = switch (byte) {
            'h' => .left,
            'j' => .down,
            'k' => .up,
            'l' => .right,
            '0' => .start,
            '^' => .first,
            '$' => .end,
            'w' => .word,
            'b' => .back,
            'e' => .word_end,
            'G' => .last_line,
            'q' => return if (count == null) .quit else null,
            else => return null,
        };
        return .{ .move = .{ .motion = motion, .count = count } };
    }

    pub fn feed(self: *Parser, byte: u8) ?Command {
        switch (self.state) {
            .ground => {
                if (byte == 0x1b) {
                    self.cancel();
                    self.state = .escape;
                } else return self.navigation(byte);
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
        try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .down } }, parser.feed('j').?);
    }
    try std.testing.expectEqualDeep(Command.quit, parser.feed('q').?);
}

test "navigation counts, zero, gg/G and invalid commands remain bounded" {
    var parser: Parser = .{};
    for ("12") |byte| try std.testing.expect(parser.feed(byte) == null);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .right, .count = 12 } }, parser.feed('l').?);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .start } }, parser.feed('0').?);
    for ("20g") |byte| try std.testing.expect(parser.feed(byte) == null);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .first_line, .count = 20 } }, parser.feed('g').?);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .last_line } }, parser.feed('G').?);
    for ("999999999999999999999999999999999999l") |byte| try std.testing.expect(parser.feed(byte) == null);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .word } }, parser.feed('w').?);
    for ("2x3gq4\x1b[A") |byte| try std.testing.expect(parser.feed(byte) == null);
    try std.testing.expectEqualDeep(Command{ .move = .{ .motion = .back } }, parser.feed('b').?);
}
