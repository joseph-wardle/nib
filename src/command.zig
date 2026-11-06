// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const input = @import("input.zig");
const motion = @import("motion.zig");

pub const Movement = struct { motion: motion.Motion, count: ?usize = null };
pub const Insertion = enum { before, after, below, above };
pub const Operation = struct {
    operator: motion.Operator,
    movement: union(enum) { motion: Movement, lines: usize },
};
/// Commands about files and the session rather than the text.
pub const File = union(enum) {
    /// `:q`, or `:q!` to discard.
    quit: bool,
    /// `:qa`, or `:qa!` to discard every file.
    quit_all: bool,
    /// `:w`, or `:w <path>` to write a copy.
    write: []const u8,
    /// `:wq`
    write_quit,
    reload,
    /// Ctrl-P: open the finder.
    find,
};
pub const Action = union(enum) {
    move: Movement,
    operate: Operation,
    insert: Insertion,
    text: u8,
    newline,
    backspace,
    tab,
    end_insert,
    undo,
    redo,
    file: File,
    paste_begin,
    paste_byte: u8,
    paste_end,
    invalid,
};
pub const Mode = enum { normal, insert, operator, command_line };

/// Owns incomplete commands, never text or terminal framing. Returned file paths
/// borrow line storage until the next feed; callers must handle actions promptly.
/// The application decides whether an editing action is available, and cancels
/// insertion if it refuses entry. Paste collection/mutation belongs to that app.
pub const Parser = struct {
    mode: Mode = .normal,
    count: ?usize = null,
    overflow: bool = false,
    pending_g: bool = false,
    operator: motion.Operator = .delete,
    operator_count: ?usize = null,
    line: [4096]u8 = undefined,
    line_len: usize = 0,
    line_invalid: bool = false,
    pasting: bool = false,

    pub fn cancel(self: *Parser) void {
        self.mode = .normal;
        self.count = null;
        self.overflow = false;
        self.pending_g = false;
        self.operator_count = null;
        self.line_len = 0;
        self.line_invalid = false;
    }

    pub fn feed(self: *Parser, event: input.Event) ?Action {
        switch (event) {
            .paste_begin => {
                self.pasting = true;
                return if (self.mode == .insert) .paste_begin else null;
            },
            .paste_byte => |byte| return if (self.pasting and self.mode == .insert) .{ .paste_byte = byte } else null,
            .paste_end => {
                self.pasting = false;
                return if (self.mode == .insert) .paste_end else null;
            },
            .ignored, .arrow => {
                if (self.mode == .normal or self.mode == .operator) self.cancel();
                return null;
            },
            .escape => {
                const inserting = self.mode == .insert;
                self.cancel();
                return if (inserting) .end_insert else null;
            },
            .key => |byte| {
                if (byte == 3) {
                    const inserting = self.mode == .insert;
                    self.cancel();
                    return if (inserting) .end_insert else null;
                }
                if (self.mode == .command_line) return self.commandLine(byte);
                if (self.mode == .insert) return switch (byte) {
                    '\r', '\n' => .newline,
                    0x08, 0x7f => .backspace,
                    '\t' => .tab,
                    0x20...0x7e => .{ .text = byte },
                    else => .invalid,
                };
                return self.normal(byte);
            },
        }
    }

    fn normal(self: *Parser, byte: u8) ?Action {
        if (!self.pending_g and byte >= '0' and byte <= '9' and (byte != '0' or self.count != null)) {
            const value = std.math.mul(usize, self.count orelse 0, 10) catch {
                self.overflow = true;
                return null;
            };
            self.count = std.math.add(usize, value, byte - '0') catch {
                self.overflow = true;
                return null;
            };
            return null;
        }
        if (self.overflow) return self.reject();
        if (byte == 'g' and !self.pending_g) {
            self.pending_g = true;
            return null;
        }
        const count = self.count;
        const operator_count = self.operator_count;
        const pending_operator = self.mode == .operator;
        const operator = self.operator;
        const pending_g = self.pending_g;
        self.cancel();
        const selected: ?motion.Motion = if (pending_g) (if (byte == 'g') .first_line else null) else switch (byte) {
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
            else => null,
        };
        if (selected) |selected_motion| {
            const combined = multiply(operator_count, count) catch return .invalid;
            const movement: Movement = .{ .motion = selected_motion, .count = combined };
            return if (pending_operator) .{ .operate = .{ .operator = operator, .movement = .{ .motion = movement } } } else .{ .move = movement };
        }
        if (pending_g) return .invalid;
        if (pending_operator) {
            if ((operator == .delete and byte == 'd') or (operator == .change and byte == 'c')) {
                const combined = multiply(operator_count, count) catch return .invalid;
                return .{ .operate = .{ .operator = operator, .movement = .{ .lines = combined orelse 1 } } };
            }
            return .invalid;
        }
        if (byte == 'd' or byte == 'c') {
            self.mode = .operator;
            self.operator = if (byte == 'd') .delete else .change;
            self.operator_count = count;
            return null;
        }
        // This subset deliberately does not repeat insertions or Ex/undo keys.
        if (count != null) return .invalid;
        switch (byte) {
            'i', 'a', 'o', 'O' => {
                self.mode = .insert;
                return .{ .insert = switch (byte) {
                    'i' => .before,
                    'a' => .after,
                    'o' => .below,
                    'O' => .above,
                    else => unreachable,
                } };
            },
            'u' => return .undo,
            0x12 => return .redo,
            0x10 => return .{ .file = .find },
            ':' => self.mode = .command_line,
            else => return .invalid,
        }
        return null;
    }

    fn reject(self: *Parser) Action {
        self.cancel();
        return .invalid;
    }

    fn commandLine(self: *Parser, byte: u8) ?Action {
        switch (byte) {
            '\r', '\n' => {
                // Reset state without overwriting storage borrowed by the action.
                const line = self.line[0..self.line_len];
                const invalid = self.line_invalid;
                self.cancel();
                if (invalid) return .invalid;
                if (std.mem.eql(u8, line, "q")) return .{ .file = .{ .quit = false } };
                if (std.mem.eql(u8, line, "q!")) return .{ .file = .{ .quit = true } };
                if (std.mem.eql(u8, line, "qa")) return .{ .file = .{ .quit_all = false } };
                if (std.mem.eql(u8, line, "qa!")) return .{ .file = .{ .quit_all = true } };
                if (std.mem.eql(u8, line, "wq")) return .{ .file = .write_quit };
                if (std.mem.eql(u8, line, "w")) return .{ .file = .{ .write = "" } };
                if (std.mem.eql(u8, line, "e!")) return .{ .file = .reload };
                if (std.mem.startsWith(u8, line, "w ") and line.len > 2)
                    return .{ .file = .{ .write = line[2..] } };
                return .invalid;
            },
            0x08, 0x7f => {
                if (self.line_len == 0) self.cancel() else self.line_len -= 1;
            },
            0x20...0x7e => {
                if (self.line_len == self.line.len) {
                    self.line_invalid = true;
                } else {
                    self.line[self.line_len] = byte;
                    self.line_len += 1;
                }
            },
            else => self.line_invalid = true,
        }
        return null;
    }
};

fn multiply(first: ?usize, second: ?usize) error{Overflow}!?usize {
    if (first == null and second == null) return null;
    return try std.math.mul(usize, first orelse 1, second orelse 1);
}

fn keys(parser: *Parser, bytes: []const u8) ?Action {
    var action: ?Action = null;
    for (bytes) |byte| action = parser.feed(.{ .key = byte });
    return action;
}

test "motion and operator counts compose, distinguish zero and reject overflow" {
    var parser: Parser = .{};
    try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .start } }, keys(&parser, "0").?);
    try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .first_line, .count = 20 } }, keys(&parser, "20gg").?);
    try std.testing.expectEqualDeep(Action{ .operate = .{ .operator = .delete, .movement = .{ .motion = .{ .motion = .word, .count = 6 } } } }, keys(&parser, "2d3w").?);
    try std.testing.expectEqualDeep(Action{ .operate = .{ .operator = .change, .movement = .{ .lines = 6 } } }, keys(&parser, "2c3c").?);
    try std.testing.expectEqualDeep(Action{ .operate = .{ .operator = .delete, .movement = .{ .motion = .{ .motion = .start, .count = 2 } } } }, keys(&parser, "2d0").?);
    try std.testing.expectEqualDeep(Action{ .file = .find }, keys(&parser, "\x10").?);
    const refused = [_][]const u8{
        "999999999999999999999999999999999999l", "9223372036854775808d2w",
        "dgx",                                   "2i",
        "2u",                                    "q",
        "2\x10",                                 "d\x10",
        "g\x10",
    };
    for (refused) |invalid| {
        try std.testing.expectEqualDeep(Action.invalid, keys(&parser, invalid).?);
        try std.testing.expectEqual(Mode.normal, parser.mode);
        try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .back } }, keys(&parser, "b").?);
    }
}

test "Escape and Ctrl-C cancel each incomplete command; insert actions retain no buffer" {
    for ([_]input.Event{ .escape, .{ .key = 3 } }) |cancel| {
        for ([_][]const u8{ "2", "3g", "2d3", ":w source" }) |pending| {
            var parser: Parser = .{};
            _ = keys(&parser, pending);
            try std.testing.expect(parser.feed(cancel) == null);
            try std.testing.expectEqual(Mode.normal, parser.mode);
            try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .word } }, keys(&parser, "w").?);
        }
        var parser: Parser = .{};
        try std.testing.expectEqualDeep(Action{ .insert = .above }, keys(&parser, "O").?);
        try std.testing.expectEqualDeep(Action{ .text = 'd' }, keys(&parser, "d").?);
        try std.testing.expectEqualDeep(Action.newline, keys(&parser, "\r").?);
        try std.testing.expectEqualDeep(Action.backspace, keys(&parser, "\x7f").?);
        try std.testing.expectEqualDeep(Action.tab, keys(&parser, "\t").?);
        try std.testing.expectEqualDeep(Action.end_insert, parser.feed(cancel).?);
        try std.testing.expectEqual(Mode.normal, parser.mode);
    }
}

test "restricted command line borrows paths, edits, refuses overflow and ignores pasted commands" {
    var parser: Parser = .{};
    try std.testing.expectEqualDeep(Action{ .file = .{ .quit = false } }, keys(&parser, ":q\r").?);
    try std.testing.expectEqualDeep(Action{ .file = .{ .quit = true } }, keys(&parser, ":q!\n").?);
    try std.testing.expectEqualDeep(Action{ .file = .reload }, keys(&parser, ":e!\r").?);
    try std.testing.expectEqualStrings("my copy.zig", keys(&parser, ":w my copy.zig\r").?.file.write);
    try std.testing.expectEqualDeep(Action{ .file = .{ .quit = false } }, keys(&parser, ":w\x7fq\r").?);
    const quit_all: Action = .{ .file = .{ .quit_all = false } };
    try std.testing.expectEqualDeep(quit_all, keys(&parser, ":qa\r").?);
    const discard_all: Action = .{ .file = .{ .quit_all = true } };
    try std.testing.expectEqualDeep(discard_all, keys(&parser, ":qa!\r").?);
    try std.testing.expectEqualDeep(Action{ .file = .write_quit }, keys(&parser, ":wq\r").?);
    for ([_][]const u8{ ":qa!!\r", ":wq!\r", ":w \r", ":q\x00\r" }) |invalid| {
        try std.testing.expectEqualDeep(Action.invalid, keys(&parser, invalid).?);
    }
    _ = keys(&parser, ":");
    for (0..4097) |_| _ = keys(&parser, "q");
    _ = keys(&parser, "\x7f");
    try std.testing.expectEqualDeep(Action.invalid, keys(&parser, "\r").?);
    for ([_][]const u8{ "", "d", ":" }) |prefix| {
        parser.cancel();
        _ = keys(&parser, prefix);
        const mode = parser.mode;
        try std.testing.expect(parser.feed(.paste_begin) == null);
        for (":q!\r\x03di") |byte| try std.testing.expect(parser.feed(.{ .paste_byte = byte }) == null);
        try std.testing.expect(parser.feed(.paste_end) == null);
        try std.testing.expectEqual(mode, parser.mode);
    }
    parser.cancel();
    _ = keys(&parser, "i");
    try std.testing.expectEqualDeep(Action.paste_begin, parser.feed(.paste_begin).?);
    try std.testing.expectEqualDeep(Action{ .paste_byte = 3 }, parser.feed(.{ .paste_byte = 3 }).?);
    try std.testing.expectEqualDeep(Action.paste_end, parser.feed(.paste_end).?);
}

test "decoder precedence and cancellation compose with insert and pending commands" {
    var parser: Parser = .{};
    var decoder: input.Decoder = .{};
    _ = keys(&parser, "i");
    for ("\x1bOA\x1b[1;5A") |byte| {
        const events = decoder.feed(byte, 0);
        for (events.items[0..events.len]) |event| try std.testing.expect(parser.feed(event) == null);
    }
    // Ambiguous rapid O/[ prefixes stay terminal sequences, even in insert.
    try std.testing.expectEqual(Mode.insert, parser.mode);
    _ = decoder.feed(0x1b, 1000);
    const escaped = decoder.expire(1100);
    try std.testing.expectEqualDeep(Action.end_insert, parser.feed(escaped.items[0]).?);
    const above = decoder.feed('O', 1101);
    try std.testing.expectEqualDeep(Action{ .insert = .above }, parser.feed(above.items[0]).?);
    const cancel = decoder.feed(3, 1102);
    try std.testing.expectEqualDeep(Action.end_insert, parser.feed(cancel.items[0]).?);
    const first = decoder.feed('^', 1103);
    try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .first } }, parser.feed(first.items[0]).?);
    _ = keys(&parser, "2d3");
    const rapid_escape = decoder.feed(0x1b, 2000);
    try std.testing.expectEqual(@as(usize, 0), rapid_escape.len);
    const rapid_motion = decoder.feed('w', 2001);
    try std.testing.expect(parser.feed(rapid_motion.items[0]) == null);
    try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .word } }, parser.feed(rapid_motion.items[1]).?);
}
