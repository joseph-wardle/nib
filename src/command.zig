// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const char = @import("char.zig");
const input = @import("input.zig");
const motion = @import("motion.zig");
const search = @import("search.zig");

pub const Movement = struct { motion: motion.Motion, count: ?usize = null };
/// A search motion. A typed query borrows parser storage until the next feed.
pub const Search = struct {
    target: union(enum) {
        /// A query from the prompt, searched from where the prompt opened. An
        /// empty query repeats the last one in this direction.
        typed: struct { query: []const u8, direction: search.Direction },
        /// `n` (`same`) or `N` (`reverse`): the last query, relative to the
        /// last direction.
        repeat: enum { same, reverse },
    },
    count: ?usize = null,
};
/// The `/` and `?` prompt's progress, so the editor can preview and restore.
pub const Prompt = union(enum) {
    /// The prompt opened; the search starts from here.
    open,
    /// The query changed. Null when it is empty or invalid: show the origin.
    preview: ?Search,
    /// Escape, Ctrl-C or Backspace on an empty query: back to the origin.
    close,
    /// Enter on an invalid query: back to the origin, reported as unsupported.
    invalid,
};
pub const Insertion = enum { before, after, below, above };
pub const Operation = struct {
    operator: motion.Operator,
    movement: union(enum) { motion: Movement, lines: usize, search: Search },
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
    /// `n`, `N`, or Enter at a prompt opened in normal mode.
    jump: Search,
    prompt: Prompt,
    operate: Operation,
    insert: Insertion,
    /// One typed character; borrows parser storage until the next feed.
    text: []const u8,
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
pub const Mode = enum { normal, insert, operator, command_line, search };

/// Owns incomplete commands, never text or terminal framing. Returned file paths
/// and typed text borrow parser storage until the next feed; callers must handle
/// actions promptly. Insert mode collects a character's bytes across keys.
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
    /// The search prompt's direction, combined count and pending operator.
    prompt_direction: search.Direction = .forward,
    prompt_count: ?usize = null,
    prompt_operator: ?motion.Operator = null,
    pasting: bool = false,
    character: [4]u8 = undefined,
    character_len: u3 = 0,
    character_need: u3 = 0,
    /// Set by `feed` when insert mode dropped an invalid character, or one
    /// interrupted by another key or event; the caller reports it.
    discarded: bool = false,

    pub fn cancel(self: *Parser) void {
        self.mode = .normal;
        self.count = null;
        self.overflow = false;
        self.pending_g = false;
        self.operator_count = null;
        self.line_len = 0;
        self.line_invalid = false;
        self.prompt_count = null;
        self.prompt_operator = null;
        self.character_need = 0;
    }

    pub fn feed(self: *Parser, event: input.Event) ?Action {
        self.discarded = false;
        if (self.character_need != 0) {
            if (event == .key and char.continuation(event.key)) return self.continueCharacter(event.key);
            self.discarded = self.mode == .insert;
            self.character_need = 0;
        }
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
            .escape => return self.escape(),
            .key => |byte| {
                if (byte == 3) return self.escape();
                if (self.mode == .command_line) return self.commandLine(byte);
                if (self.mode == .search) return self.prompt(byte);
                if (self.mode == .insert) return switch (byte) {
                    '\r', '\n' => .newline,
                    0x08, 0x7f => .backspace,
                    '\t' => .tab,
                    0x20...0x7e => {
                        self.character[0] = byte;
                        return .{ .text = self.character[0..1] };
                    },
                    0x80...0xff => {
                        if (!self.beginCharacter(byte)) self.discarded = true;
                        return null;
                    },
                    else => .invalid,
                };
                // A non-ASCII character is one unsupported command, however
                // many bytes it has.
                if (byte >= 0x80) {
                    const rejected = self.reject();
                    _ = self.beginCharacter(byte);
                    return rejected;
                }
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
        if (byte == 'n' or byte == 'N' or byte == '/' or byte == '?') {
            const combined = multiply(operator_count, count) catch return .invalid;
            const operating: ?motion.Operator = if (pending_operator) operator else null;
            if (byte == '/' or byte == '?') {
                self.mode = .search;
                self.prompt_direction = if (byte == '/') .forward else .backward;
                self.prompt_count = combined;
                self.prompt_operator = operating;
                return .{ .prompt = .open };
            }
            const repeat: Search = .{
                .target = .{ .repeat = if (byte == 'n') .same else .reverse },
                .count = combined,
            };
            return searched(operating, repeat);
        }
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

    /// Starts collecting a character at its lead byte; false for a byte that
    /// cannot lead one.
    fn beginCharacter(self: *Parser, byte: u8) bool {
        const len = std.unicode.utf8ByteSequenceLength(byte) catch return false;
        self.character[0] = byte;
        self.character_len = 1;
        self.character_need = len;
        return true;
    }

    /// Outside insert mode, only skips the rest of a rejected character.
    fn continueCharacter(self: *Parser, byte: u8) ?Action {
        self.character[self.character_len] = byte;
        self.character_len += 1;
        if (self.character_len < self.character_need) return null;
        self.character_need = 0;
        if (self.mode != .insert) return null;
        const text = self.character[0..self.character_len];
        if (char.editable(text)) return .{ .text = text };
        self.discarded = true;
        return null;
    }

    /// Escape and Ctrl-C cancel whatever is pending.
    fn escape(self: *Parser) ?Action {
        const mode = self.mode;
        self.cancel();
        return switch (mode) {
            .insert => .end_insert,
            .search => .{ .prompt = .close },
            else => null,
        };
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
            else => self.editLine(byte),
        }
        return null;
    }

    fn prompt(self: *Parser, byte: u8) Action {
        switch (byte) {
            '\r', '\n' => {
                // Reset state without overwriting storage borrowed by the action.
                const typed = self.promptSearch();
                const invalid = self.line_invalid;
                const operator = self.prompt_operator;
                self.cancel();
                if (invalid) return .{ .prompt = .invalid };
                return searched(operator, typed);
            },
            0x08, 0x7f => if (self.line_len == 0) {
                self.cancel();
                return .{ .prompt = .close };
            },
            else => {},
        }
        self.editLine(byte);
        if (self.line_len == 0 or self.line_invalid) return .{ .prompt = .{ .preview = null } };
        return .{ .prompt = .{ .preview = self.promptSearch() } };
    }

    /// The prompt's query as a search; borrows `line`.
    fn promptSearch(self: *const Parser) Search {
        return .{
            .target = .{ .typed = .{
                .query = self.line[0..self.line_len],
                .direction = self.prompt_direction,
            } },
            .count = self.prompt_count,
        };
    }

    /// Editing shared by the `:` line and the search prompt. Only ASCII is
    /// accepted; anything else, or too long a line, invalidates it.
    fn editLine(self: *Parser, byte: u8) void {
        switch (byte) {
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
    }
};

/// A search motion as a jump, or as the motion of a pending operator.
fn searched(pending: ?motion.Operator, movement: Search) Action {
    const operator = pending orelse return .{ .jump = movement };
    return .{ .operate = .{ .operator = operator, .movement = .{ .search = movement } } };
}

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
        try std.testing.expectEqualDeep(Action{ .text = "d" }, keys(&parser, "d").?);
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

test "insert mode collects a character's bytes and drops invalid or interrupted ones" {
    var parser: Parser = .{};
    _ = keys(&parser, "i");
    for ([_][]const u8{ "\xc3\xa9", "\xe2\x9c\x85", "\xf0\x9d\x91\xa5" }) |character| {
        for (character[0 .. character.len - 1]) |byte| {
            try std.testing.expect(parser.feed(.{ .key = byte }) == null);
            try std.testing.expect(!parser.discarded);
        }
        const typed = parser.feed(.{ .key = character[character.len - 1] }).?;
        try std.testing.expectEqualStrings(character, typed.text);
        try std.testing.expect(!parser.discarded);
    }
    // A lone lead or continuation byte, an overlong form, a C1 control, a
    // surrogate and a code point above U+10FFFF are each dropped once.
    const invalid = [_][]const u8{
        "\xff", "\xa9", "\xc0\xaf", "\xc2\x9b", "\xed\xa0\x80", "\xf4\x90\x80\x80",
    };
    for (invalid) |bytes| {
        var discarded: usize = 0;
        for (bytes) |byte| {
            try std.testing.expect(parser.feed(.{ .key = byte }) == null);
            discarded += @intFromBool(parser.discarded);
        }
        try std.testing.expectEqual(@as(usize, 1), discarded);
        try std.testing.expectEqual(Mode.insert, parser.mode);
    }
    // An interrupting key or event drops the partial character and still acts.
    const interruptions = [_]struct { event: input.Event, action: Action }{
        .{ .event = .{ .key = 'x' }, .action = .{ .text = "x" } },
        .{ .event = .{ .key = '\r' }, .action = .newline },
        .{ .event = .{ .key = 0x7f }, .action = .backspace },
        .{ .event = .paste_begin, .action = .paste_begin },
        .{ .event = .escape, .action = .end_insert },
        .{ .event = .{ .key = 3 }, .action = .end_insert },
    };
    for (interruptions) |interruption| {
        parser.cancel();
        parser.pasting = false;
        _ = keys(&parser, "a\xe2\x82");
        try std.testing.expect(!parser.discarded);
        try std.testing.expectEqualDeep(interruption.action, parser.feed(interruption.event).?);
        try std.testing.expect(parser.discarded);
        _ = parser.feed(.ignored);
        try std.testing.expect(!parser.discarded);
    }
    // The interrupted bytes are not resumed by a later continuation byte.
    _ = keys(&parser, "a\xe2\x82");
    _ = parser.feed(.ignored);
    try std.testing.expect(parser.discarded);
    try std.testing.expect(parser.feed(.{ .key = 0xac }) == null);
    try std.testing.expect(parser.discarded);
}

test "normal mode rejects each non-ASCII character once and cancels pending commands" {
    var parser: Parser = .{};
    const commands = [_][]const u8{ "\u{e9}", "2d\u{2705}", "g\u{1d465}", "\xa9", "\xff" };
    for (commands) |bytes| {
        var rejected: usize = 0;
        for (bytes) |byte| {
            if (parser.feed(.{ .key = byte })) |action| {
                try std.testing.expectEqualDeep(Action.invalid, action);
                rejected += 1;
            }
            try std.testing.expect(!parser.discarded);
        }
        try std.testing.expectEqual(@as(usize, 1), rejected);
        try std.testing.expectEqual(Mode.normal, parser.mode);
        const word: Action = .{ .move = .{ .motion = .word } };
        try std.testing.expectEqualDeep(word, keys(&parser, "w").?);
    }
    // A key after a partial character is a command again.
    _ = keys(&parser, "\xe2\x9c");
    try std.testing.expectEqualDeep(Action{ .move = .{ .motion = .down } }, keys(&parser, "j").?);
    try std.testing.expect(!parser.discarded);
}

const next_word: Action = .{ .move = .{ .motion = .word } };

fn expectAction(expected: Action, actual: ?Action) !void {
    try std.testing.expectEqualDeep(expected, actual.?);
}

fn jump(query: []const u8, direction: search.Direction, count: ?usize) Action {
    return .{ .jump = typedSearch(query, direction, count) };
}

fn operate(operator: motion.Operator, movement: Search) Action {
    return .{ .operate = .{ .operator = operator, .movement = .{ .search = movement } } };
}

fn typedSearch(query: []const u8, direction: search.Direction, count: ?usize) Search {
    return .{ .target = .{ .typed = .{ .query = query, .direction = direction } }, .count = count };
}

test "slash and question mark open a prompt that previews each change and jumps on Enter" {
    var parser: Parser = .{};
    try expectAction(Action{ .prompt = .open }, keys(&parser, "/"));
    try std.testing.expectEqual(Mode.search, parser.mode);
    const first: Action = .{ .prompt = .{ .preview = typedSearch("f", .forward, null) } };
    try expectAction(first, keys(&parser, "f"));
    const second: Action = .{ .prompt = .{ .preview = typedSearch("fo", .forward, null) } };
    try expectAction(second, keys(&parser, "o"));
    try expectAction(jump("fo", .forward, null), keys(&parser, "\r"));
    try std.testing.expectEqual(Mode.normal, parser.mode);

    const counted: Action = .{ .prompt = .{ .preview = typedSearch("x y", .backward, 12) } };
    try expectAction(counted, keys(&parser, "12?x y"));
    try expectAction(jump("x y", .backward, 12), keys(&parser, "\n"));

    // An empty query is accepted; the editor repeats the last search.
    try expectAction(jump("", .backward, null), keys(&parser, "?\r"));
    try expectAction(next_word, keys(&parser, "w"));
}

test "n and N repeat with counts, alone and as operator motions" {
    var parser: Parser = .{};
    const same: Search = .{ .target = .{ .repeat = .same } };
    const reverse: Search = .{ .target = .{ .repeat = .reverse }, .count = 3 };
    try expectAction(Action{ .jump = same }, keys(&parser, "n"));
    try expectAction(Action{ .jump = reverse }, keys(&parser, "3N"));
    try expectAction(operate(.delete, same), keys(&parser, "dn"));
    try expectAction(operate(.change, reverse), keys(&parser, "c3N"));
    const refused = [_][]const u8{
        "gn", "g/", "99999999999999999999999n", "9223372036854775808d2/",
    };
    for (refused) |invalid| {
        try std.testing.expectEqualDeep(Action.invalid, keys(&parser, invalid).?);
        try std.testing.expectEqual(Mode.normal, parser.mode);
    }
}

test "operators keep their combined count through the prompt and take the search as motion" {
    var parser: Parser = .{};
    for ([_]struct { keys: []const u8, operator: motion.Operator, search: Search }{
        .{ .keys = "d/x\r", .operator = .delete, .search = typedSearch("x", .forward, null) },
        .{ .keys = "c?bar\r", .operator = .change, .search = typedSearch("bar", .backward, null) },
        .{ .keys = "d2/x\r", .operator = .delete, .search = typedSearch("x", .forward, 2) },
        .{ .keys = "2d3/x\r", .operator = .delete, .search = typedSearch("x", .forward, 6) },
        .{ .keys = "3c/\r", .operator = .change, .search = typedSearch("", .forward, 3) },
    }) |case| {
        try expectAction(operate(case.operator, case.search), keys(&parser, case.keys));
        try std.testing.expectEqual(Mode.normal, parser.mode);
    }
    // The preview carries the combined count too.
    const preview: Action = .{ .prompt = .{ .preview = typedSearch("y", .forward, 4) } };
    try expectAction(preview, keys(&parser, "2d2/y"));
}

test "Escape, Ctrl-C and Backspace on an empty query close the prompt and drop the operator" {
    for ([_][]const u8{ "\x1b", "\x03", "\x7f" }) |close| {
        for ([_][]const u8{ "/", "2?", "d/", "2c3?" }) |opening| {
            var parser: Parser = .{};
            try std.testing.expectEqualDeep(Action{ .prompt = .open }, keys(&parser, opening).?);
            const event: input.Event = if (close[0] == 0x1b) .escape else .{ .key = close[0] };
            try expectAction(Action{ .prompt = .close }, parser.feed(event));
            try std.testing.expectEqual(Mode.normal, parser.mode);
            try expectAction(next_word, keys(&parser, "w"));
        }
    }
    // With text typed, Escape and Ctrl-C still close; Backspace edits.
    var parser: Parser = .{};
    _ = keys(&parser, "d/ab");
    try expectAction(Action{ .prompt = .close }, parser.feed(.escape));
    _ = keys(&parser, "/ab");
    try expectAction(Action{ .prompt = .close }, keys(&parser, "\x03"));
    _ = keys(&parser, "/ab");
    const shorter: Action = .{ .prompt = .{ .preview = typedSearch("a", .forward, null) } };
    try expectAction(shorter, keys(&parser, "\x08"));
    const empty: Action = .{ .prompt = .{ .preview = null } };
    try expectAction(empty, keys(&parser, "\x7f"));
    try std.testing.expectEqual(Mode.search, parser.mode);
    try expectAction(Action{ .prompt = .close }, keys(&parser, "\x7f"));
    try std.testing.expectEqual(Mode.normal, parser.mode);
}

test "a non-ASCII, control or overlong query previews nothing and is refused on Enter" {
    const invalid = [_][]const u8{ "/caf\u{e9}", "?a\tb", "/a\x00", "d/\x1bx" };
    for (invalid) |typed| {
        var parser: Parser = .{};
        for (typed[0 .. typed.len - 1]) |byte| _ = parser.feed(.{ .key = byte });
        const last = parser.feed(.{ .key = typed[typed.len - 1] });
        // A lone ESC in this table is a key byte, not the decoded Escape event.
        try expectAction(.{ .prompt = .{ .preview = null } }, last);
        try expectAction(Action{ .prompt = .{ .preview = null } }, keys(&parser, "z"));
        try expectAction(Action{ .prompt = .invalid }, keys(&parser, "\r"));
        try std.testing.expectEqual(Mode.normal, parser.mode);
        try expectAction(next_word, keys(&parser, "w"));
    }
    var parser: Parser = .{};
    _ = keys(&parser, "/");
    for (0..parser.line.len) |_| _ = keys(&parser, "q");
    try std.testing.expect(keys(&parser, "q").?.prompt.preview == null);
    try expectAction(Action{ .prompt = .invalid }, keys(&parser, "\r"));
}

test "the prompt ignores paste and arrows, and the command line is unchanged by it" {
    var parser: Parser = .{};
    _ = keys(&parser, "/a");
    try std.testing.expect(parser.feed(.paste_begin) == null);
    for ("\r\x1bq") |byte| try std.testing.expect(parser.feed(.{ .paste_byte = byte }) == null);
    try std.testing.expect(parser.feed(.paste_end) == null);
    try std.testing.expect(parser.feed(.ignored) == null);
    try std.testing.expect(parser.feed(.{ .arrow = .up }) == null);
    try std.testing.expectEqual(Mode.search, parser.mode);
    try expectAction(jump("a", .forward, null), keys(&parser, "\r"));
    try expectAction(Action{ .file = .{ .quit = false } }, keys(&parser, ":q\r"));
    try expectAction(Action.invalid, keys(&parser, ":/a\r"));
}
