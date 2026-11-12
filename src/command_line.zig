// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const input = @import("input.zig");
const Line = @import("command.zig").Line;

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
    /// `:e!`
    reload,
};

/// How a key ended the line.
pub const Outcome = union(enum) {
    /// Enter on a supported command.
    run: File,
    /// Enter on anything else.
    invalid,
    /// Escape or Ctrl-C.
    cancel,
};

/// The `:` line, open over either screen. Arrows, other sequences and pastes
/// leave it unchanged. A command's path borrows the line until it next opens.
pub const CommandLine = struct {
    open: bool = false,
    line: Line = .{},

    pub fn begin(self: *CommandLine) void {
        self.open = true;
        self.line.clear();
    }

    /// Feeds one event to the open line. The line closes on any outcome, and
    /// on Backspace when it is empty, which has none.
    pub fn feed(self: *CommandLine, event: input.Event) ?Outcome {
        std.debug.assert(self.open);
        // Escape acts as Ctrl-C.
        const byte = switch (event) {
            .escape => 3,
            .key => |byte| byte,
            else => return null,
        };
        switch (byte) {
            3 => {
                self.open = false;
                return .cancel;
            },
            '\r', '\n' => {
                self.open = false;
                if (self.line.invalid) return .invalid;
                return if (parse(self.line.text())) |command| .{ .run = command } else .invalid;
            },
            else => {
                if (!self.line.edit(byte)) self.open = false;
                return null;
            },
        }
    }
};

fn parse(line: []const u8) ?File {
    if (std.mem.eql(u8, line, "q")) return .{ .quit = false };
    if (std.mem.eql(u8, line, "q!")) return .{ .quit = true };
    if (std.mem.eql(u8, line, "qa")) return .{ .quit_all = false };
    if (std.mem.eql(u8, line, "qa!")) return .{ .quit_all = true };
    if (std.mem.eql(u8, line, "wq")) return .write_quit;
    if (std.mem.eql(u8, line, "w")) return .{ .write = "" };
    if (std.mem.eql(u8, line, "e!")) return .reload;
    if (std.mem.startsWith(u8, line, "w ") and line.len > 2) return .{ .write = line[2..] };
    return null;
}

const testing = std.testing;
const max_line = @import("command.zig").max_line;

/// Opens the line and types `keys`, returning the last key's outcome.
fn typed(command_line: *CommandLine, keys: []const u8) ?Outcome {
    command_line.begin();
    var outcome: ?Outcome = null;
    for (keys) |byte| outcome = command_line.feed(.{ .key = byte });
    return outcome;
}

test "the command line runs each supported command and refuses anything else" {
    var command_line: CommandLine = .{};
    const cases = [_]struct { keys: []const u8, file: File }{
        .{ .keys = "q\r", .file = .{ .quit = false } },
        .{ .keys = "q!\n", .file = .{ .quit = true } },
        .{ .keys = "qa\r", .file = .{ .quit_all = false } },
        .{ .keys = "qa!\r", .file = .{ .quit_all = true } },
        .{ .keys = "wq\r", .file = .write_quit },
        .{ .keys = "w\r", .file = .{ .write = "" } },
        .{ .keys = "e!\r", .file = .reload },
        .{ .keys = "w\x7fq\r", .file = .{ .quit = false } },
    };
    for (cases) |case| {
        try testing.expectEqualDeep(Outcome{ .run = case.file }, typed(&command_line, case.keys).?);
        try testing.expect(!command_line.open);
    }
    // A copy's path borrows the line.
    const copy = typed(&command_line, "w my copy.zig\r").?.run.write;
    try testing.expectEqualStrings("my copy.zig", copy);
    const refused = [_][]const u8{
        "qa!!\r", "wq!\r", "w \r", "q\x00\r", "/a\r", "\r", "q\xc3\xa9\r",
    };
    for (refused) |keys| {
        try testing.expectEqualDeep(Outcome.invalid, typed(&command_line, keys).?);
        try testing.expect(!command_line.open);
    }
}

test "an overlong command line is refused, even after Backspace" {
    var command_line: CommandLine = .{};
    command_line.begin();
    for (0..max_line + 1) |_| try testing.expect(command_line.feed(.{ .key = 'q' }) == null);
    try testing.expect(command_line.feed(.{ .key = 0x7f }) == null);
    try testing.expectEqualDeep(Outcome.invalid, command_line.feed(.{ .key = '\r' }).?);
}

test "Escape and Ctrl-C cancel the command line; Backspace closes it only when empty" {
    var command_line: CommandLine = .{};
    for ([_]input.Event{ .escape, .{ .key = 3 } }) |cancel| {
        _ = typed(&command_line, "w source");
        try testing.expectEqualDeep(Outcome.cancel, command_line.feed(cancel).?);
        try testing.expect(!command_line.open);
    }
    _ = typed(&command_line, "w");
    try testing.expect(command_line.feed(.{ .key = 0x08 }) == null);
    try testing.expect(command_line.open);
    try testing.expect(command_line.feed(.{ .key = 0x7f }) == null);
    try testing.expect(!command_line.open);
    // Opening again starts an empty line.
    try testing.expectEqualDeep(Outcome.invalid, typed(&command_line, "\r").?);
}

test "arrows, other sequences and pasted commands leave the command line unchanged" {
    var command_line: CommandLine = .{};
    _ = typed(&command_line, "q");
    const events = [_]input.Event{ .ignored, .{ .arrow = .up }, .paste_begin };
    for (events) |event| try testing.expect(command_line.feed(event) == null);
    for (":q!\r\x03") |byte| try testing.expect(command_line.feed(.{ .paste_byte = byte }) == null);
    try testing.expect(command_line.feed(.paste_end) == null);
    try testing.expect(command_line.open);
    const quit: Outcome = .{ .run = .{ .quit = false } };
    try testing.expectEqualDeep(quit, command_line.feed(.{ .key = '\r' }).?);
}
