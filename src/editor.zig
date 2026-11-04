// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const EditError = @import("buffer.zig").Error;
const max_file_bytes = @import("buffer.zig").max_file_bytes;
const max_lines = @import("buffer.zig").max_lines;
const motion = @import("motion.zig");
const input = @import("input.zig");
const command = @import("command.zig");

/// Modal editing state. The caller owns the document and handles file actions
/// immediately (their paths borrow parser storage). No terminal or I/O ownership.
pub const Editor = struct {
    parser: command.Parser = .{},
    goal: motion.Goal = 0,
    notice: []const u8 = "",
    paste: std.ArrayList(u8) = .empty,
    paste_failed: bool = false,
    paste_cr: bool = false,
    paste_newline: [2]u8 = undefined,
    paste_newline_len: usize = 0,

    pub fn deinit(self: *Editor, allocator: Allocator) void {
        self.paste.deinit(allocator);
    }

    pub fn inserting(self: *const Editor) bool {
        return self.parser.mode == .insert;
    }

    pub fn interruptPaste(self: *Editor) void {
        if (self.parser.pasting) {
            self.paste.clearRetainingCapacity();
            self.paste_failed = true;
            self.notice = "Paste interrupted; nothing inserted";
        }
    }

    pub fn feed(self: *Editor, allocator: Allocator, buffer: *Buffer, event: input.Event) ?command.File {
        if (event == .escape or (event == .key and event.key == 3)) self.notice = "";
        const action = self.parser.feed(event) orelse return null;
        switch (action) {
            .file => |file| return file,
            .invalid => self.notice = "Unsupported command or count",
            else => self.edit(allocator, buffer, action) catch |err| {
                self.notice = editError(err);
                // Insert entry is tentative; a failed open/change must not
                // enter insert mode or leave an active, empty command group.
                if (action == .insert or action == .operate) {
                    self.parser.cancel();
                    buffer.endGroup();
                }
            },
        }
        return null;
    }

    fn edit(self: *Editor, allocator: Allocator, buffer: *Buffer, action: command.Action) EditError!void {
        switch (action) {
            .move => |movement| {
                self.notice = "";
                if (motion.resolve(buffer, self.goal, movement.motion, movement.count, null)) |result| {
                    buffer.cursor = result.destination;
                    self.goal = result.goal;
                }
            },
            .insert => |insertion| {
                if (!buffer.editable) return error.UnsupportedText;
                self.notice = "";
                buffer.beginGroup();
                const row = buffer.rowAt(buffer.cursor);
                const start = buffer.starts.items[row];
                const end = start + buffer.line(row).len;
                switch (insertion) {
                    .before => {},
                    .after => buffer.cursor = @min(buffer.cursor + 1, end),
                    .above, .below => {
                        const newline = buffer.newlineAt(buffer.cursor);
                        const offset = if (insertion == .above) start else end;
                        // Insert before the existing terminator, preserving its
                        // exact bytes while adding a blank row with local style.
                        try buffer.replace(allocator, .{ .start = offset, .end = offset }, newline, offset + if (insertion == .below) newline.len else 0);
                    },
                }
            },
            .operate => |operation| {
                if (!buffer.editable) return error.UnsupportedText;
                self.notice = "";
                const result = switch (operation.movement) {
                    .motion => |movement| motion.resolve(buffer, self.goal, movement.motion, movement.count, operation.operator) orelse return,
                    .lines => |count| result: {
                        const row = buffer.rowAt(buffer.cursor);
                        const last = row + @min(count - 1, buffer.lineCount() - row - 1);
                        break :result motion.Result{ .destination = buffer.starts.items[last], .shape = .linewise, .goal = 0 };
                    },
                };
                const selection = motion.operatorRange(buffer, result, operation.operator);
                var range = selection.range;
                const changing = operation.operator == .change;
                // A linewise change keeps the last selected terminator, if
                // present, so insertion stays on a blank logical line.
                if (changing and selection.linewise and range.end > range.start and buffer.bytes()[range.end - 1] == '\n') {
                    range.end -= 1;
                    if (range.end > range.start and buffer.bytes()[range.end - 1] == '\r') range.end -= 1;
                }
                buffer.beginGroup();
                try buffer.replace(allocator, range, "", range.start);
                if (changing) {
                    self.parser.mode = .insert;
                } else {
                    buffer.cursor = motion.normal(buffer, buffer.cursor);
                    // Linewise deletion lands at the first nonblank character.
                    if (selection.linewise) buffer.cursor = motion.resolve(buffer, 0, .first, null, null).?.destination;
                    buffer.endCommand();
                }
                self.goal = motion.screenColumn(buffer, buffer.cursor, changing);
            },
            .text => |byte| try insert(allocator, buffer, &.{byte}),
            .tab => try insert(allocator, buffer, "\t"),
            .newline => try insert(allocator, buffer, buffer.newlineAt(buffer.cursor)),
            .backspace => {
                if (buffer.cursor != 0) {
                    const end = buffer.cursor;
                    const start = end - if (end >= 2 and std.mem.eql(u8, buffer.bytes()[end - 2 .. end], "\r\n")) @as(usize, 2) else 1;
                    try buffer.replace(allocator, .{ .start = start, .end = end }, "", start);
                }
            },
            .end_insert => {
                const row = buffer.rowAt(buffer.cursor);
                if (buffer.cursor > buffer.starts.items[row]) buffer.cursor -= 1;
                buffer.cursor = motion.normal(buffer, buffer.cursor);
                buffer.endCommand();
                self.goal = motion.screenColumn(buffer, buffer.cursor, false);
            },
            .undo, .redo => {
                const changed = if (action == .undo) try buffer.undo(allocator) else try buffer.redo(allocator);
                self.notice = if (changed) "" else "No more history";
                buffer.cursor = motion.normal(buffer, buffer.cursor);
                self.goal = motion.screenColumn(buffer, buffer.cursor, false);
            },
            .paste_begin => {
                self.paste.clearRetainingCapacity();
                self.paste_failed = false;
                self.paste_cr = false;
                const newline = buffer.newlineAt(buffer.cursor);
                @memcpy(self.paste_newline[0..newline.len], newline);
                self.paste_newline_len = newline.len;
                self.notice = "";
            },
            .paste_byte => |byte| {
                if (self.paste_failed) return;
                if (byte == '\n' and self.paste_cr) {
                    self.paste_cr = false;
                    return;
                }
                self.paste_cr = byte == '\r';
                const bytes: []const u8 = switch (byte) {
                    '\r', '\n' => self.paste_newline[0..self.paste_newline_len],
                    '\t', 0x20...0x7e => &.{byte},
                    else => {
                        self.paste_failed = true;
                        self.notice = "Unsupported paste; nothing inserted";
                        return;
                    },
                };
                if (bytes.len > max_file_bytes - self.paste.items.len) {
                    self.paste_failed = true;
                    self.notice = "Paste exceeds temporary 8 MiB limit; nothing inserted";
                    return;
                }
                self.paste.appendSlice(allocator, bytes) catch |err| {
                    self.paste_failed = true;
                    self.notice = editError(err);
                };
            },
            .paste_end => {
                defer self.paste.clearRetainingCapacity();
                if (!self.paste_failed) try insert(allocator, buffer, self.paste.items);
            },
            else => unreachable,
        }
    }
};

fn insert(allocator: Allocator, buffer: *Buffer, bytes: []const u8) EditError!void {
    try buffer.replace(allocator, .{ .start = buffer.cursor, .end = buffer.cursor }, bytes, buffer.cursor + bytes.len);
}

fn editError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedText => "Read-only: non-ASCII or unsupported control bytes",
        error.FileTooLarge => "Edit exceeds temporary 8 MiB limit",
        error.TooManyLines => "Edit exceeds temporary 262,144-line limit",
        error.OutOfMemory => "Not enough memory; edit refused",
        else => @errorName(err),
    };
}

fn keys(editor: *Editor, allocator: Allocator, buffer: *Buffer, bytes: []const u8) void {
    for (bytes) |byte| _ = editor.feed(allocator, buffer, .{ .key = byte });
}

fn pasted(editor: *Editor, allocator: Allocator, buffer: *Buffer, bytes: []const u8) void {
    _ = editor.feed(allocator, buffer, .paste_begin);
    for (bytes) |byte| _ = editor.feed(allocator, buffer, .{ .paste_byte = byte });
    _ = editor.feed(allocator, buffer, .paste_end);
}

test "composed operators have fixed Vim text and cursor results and one undo group" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { before: []const u8, keys: []const u8, after: []const u8, cursor: usize }{
        .{ .before = "one two three\n", .keys = "dw", .after = "two three\n", .cursor = 0 },
        .{ .before = "one two three\n", .keys = "cwNEW\x03", .after = "NEW two three\n", .cursor = 2 },
        .{ .before = "one\r\ntwo\nthree", .keys = "dd", .after = "two\nthree", .cursor = 0 },
        .{ .before = "one\r\ntwo\nthree", .keys = "ccNEW\x03", .after = "NEW\r\ntwo\nthree", .cursor = 2 },
        .{ .before = "one\r\ntwo\nthree", .keys = "dj", .after = "three", .cursor = 0 },
        .{ .before = "one two\nthree", .keys = "ld$", .after = "o\nthree", .cursor = 0 },
        .{ .before = "one two\nthree", .keys = "$db", .after = "one o\nthree", .cursor = 4 },
        .{ .before = "one\ntwo\nthree", .keys = "dw", .after = "\ntwo\nthree", .cursor = 0 },
        .{ .before = "a b c d e f g h\n", .keys = "2d3w", .after = "g h\n", .cursor = 0 },
        .{ .before = "one\ntwo", .keys = "GccNEW\x03", .after = "one\nNEW", .cursor = 6 },
        .{ .before = "one\ntwo\n", .keys = "Gdd", .after = "one\n", .cursor = 0 },
        .{ .before = "a\nb\nc\nd\n", .keys = "2ccX\x03", .after = "X\nc\nd\n", .cursor = 0 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        defer editor.deinit(allocator);
        keys(&editor, allocator, &buffer, case.keys);
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
        try std.testing.expectEqual(@as(usize, 1), buffer.position);
        keys(&editor, allocator, &buffer, "u");
        try std.testing.expectEqualStrings(case.before, buffer.bytes());
        keys(&editor, allocator, &buffer, "\x12");
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
    }
}

test "insert entry, newline style, backspace and EOF stay reversible" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { before: []const u8, keys: []const u8, after: []const u8, cursor: usize, undo_cursor: usize = 0 }{
        .{ .before = "abc", .keys = "$a\rX\tY\x7fZ\x03", .after = "abc\nX\tZ", .cursor = 6, .undo_cursor = 2 },
        .{ .before = "abc\r\nlast", .keys = "oX\x03", .after = "abc\r\nX\r\nlast", .cursor = 5 },
        .{ .before = "abc\r\nlast", .keys = "OX\x03", .after = "X\r\nabc\r\nlast", .cursor = 0 },
        .{ .before = "abc", .keys = "oX\x03", .after = "abc\nX", .cursor = 4 },
        .{ .before = "", .keys = "i\rX\x03", .after = "\nX", .cursor = 1 },
        .{ .before = "a\r\nb", .keys = "ji\x7fX\x03", .after = "aXb", .cursor = 1, .undo_cursor = 3 },
        .{ .before = "abc", .keys = "iX\x03", .after = "Xabc", .cursor = 0 },
        .{ .before = "abc", .keys = "aX\x03", .after = "aXbc", .cursor = 1 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        defer editor.deinit(allocator);
        keys(&editor, allocator, &buffer, case.keys);
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
        keys(&editor, allocator, &buffer, "u");
        try std.testing.expectEqualStrings(case.before, buffer.bytes());
        try std.testing.expectEqual(case.undo_cursor, buffer.cursor);
        keys(&editor, allocator, &buffer, "\x12");
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
    }
}

test "paste validates atomically, normalizes breaks, joins insert group and never executes commands" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\r\nb\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    keys(&editor, allocator, &buffer, "iX");
    pasted(&editor, allocator, &buffer, "1\n2\r\n3\r4\t");
    try std.testing.expectEqualStrings("X1\r\n2\r\n3\r\n4\ta\r\nb\n", buffer.bytes());
    for ([_][]const u8{ "BAD\x03:w\r", "BAD\x1a", "BAD\x1c", "BAD\x1b", "BAD\x00", "BAD\xff" }) |bad| {
        pasted(&editor, allocator, &buffer, bad);
        try std.testing.expectEqualStrings("X1\r\n2\r\n3\r\n4\ta\r\nb\n", buffer.bytes());
    }
    _ = editor.feed(allocator, &buffer, .paste_begin);
    _ = editor.feed(allocator, &buffer, .{ .paste_byte = 'x' });
    editor.interruptPaste();
    _ = editor.feed(allocator, &buffer, .paste_end);
    keys(&editor, allocator, &buffer, "\x03u");
    try std.testing.expectEqualStrings("a\r\nb\n", buffer.bytes());
    try std.testing.expect(!buffer.modified());
    pasted(&editor, allocator, &buffer, "iEVIL:q!\r");
    try std.testing.expectEqualStrings("a\r\nb\n", buffer.bytes());
}

test "refused input at byte and line caps keeps earlier typing and all undo and save positions" {
    const allocator = std.testing.allocator;
    const large = try allocator.alloc(u8, max_file_bytes);
    defer allocator.free(large);
    for ([_]bool{ false, true }) |lines| {
        @memset(large, if (lines) '\n' else 'x');
        const before = large[0..if (lines) max_lines - 1 else max_file_bytes - 1];
        var buffer = try Buffer.fromBytes(allocator, before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        defer editor.deinit(allocator);
        keys(&editor, allocator, &buffer, "iX");
        const cursor = buffer.cursor;
        const len = buffer.bytes().len;
        keys(&editor, allocator, &buffer, if (lines) "\r\r" else "Y\r");
        // With max_lines-1 LF plus X, one LF is allowed and the second is not.
        const expected = len + @as(usize, if (lines) 1 else 0);
        try std.testing.expectEqual(expected, buffer.bytes().len);
        try std.testing.expectEqual(cursor + @as(usize, if (lines) 1 else 0), buffer.cursor);
        pasted(&editor, allocator, &buffer, "Y\nY");
        try std.testing.expectEqual(expected, buffer.bytes().len);
        keys(&editor, allocator, &buffer, "\x03u");
        try std.testing.expectEqualStrings(before, buffer.bytes());
        keys(&editor, allocator, &buffer, "\x12");
        try std.testing.expectEqual(expected, buffer.bytes().len);
        try buffer.markSaved(allocator);
        var reopened = try Buffer.fromBytes(allocator, buffer.bytes());
        defer reopened.deinit(allocator);
        try std.testing.expectEqualStrings(buffer.bytes(), reopened.bytes());
    }
}

test "read-only edits and cancellations preserve original bytes and history" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "raw\xff\r");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    keys(&editor, allocator, &buffer, "iX\x03ddcwX\x03oO");
    try std.testing.expectEqualStrings("raw\xff\r", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 0), buffer.position);
    try std.testing.expect(!editor.inserting());
    var editable = try Buffer.fromBytes(allocator, "one two\n");
    defer editable.deinit(allocator);
    keys(&editor, allocator, &editable, "2d3\x03dg\x03\x03");
    try std.testing.expectEqualStrings("one two\n", editable.bytes());
    try std.testing.expectEqual(@as(usize, 0), editable.position);
}

test "allocation failures retain earlier insert edits and reject whole pastes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationWorkflow, .{});
}

fn allocationWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "abc\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    // Exercise fallible operations directly to propagate allocation failures to
    // the harness; production feed turns them into a visible notice.
    try editor.edit(allocator, &buffer, .{ .insert = .before });
    try editor.edit(allocator, &buffer, .{ .text = 'X' });
    editor.edit(allocator, &buffer, .{ .insert = .above }) catch |err| {
        try std.testing.expectEqualStrings("Xabc\n", buffer.bytes());
        return err;
    };
    try editor.edit(allocator, &buffer, .paste_begin);
    // Collection handles OOM by latching refusal until the end delimiter.
    try editor.edit(allocator, &buffer, .{ .paste_byte = 'Y' });
    if (editor.paste_failed) return error.OutOfMemory;
    editor.edit(allocator, &buffer, .paste_end) catch |err| {
        try std.testing.expectEqualStrings("\nXabc\n", buffer.bytes());
        return err;
    };
}

test "long insert and backspace sessions replay coalesced text and cursor exactly" {
    const allocator = std.testing.allocator;
    const before = "prefix\r\nabcdefghijklmnopqrstuvwxyz\r\nsuffix";
    var buffer = try Buffer.fromBytes(allocator, before);
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    keys(&editor, allocator, &buffer, "j$a123456789\x7f\x7f\x7fX\x03");
    try std.testing.expectEqualStrings("prefix\r\nabcdefghijklmnopqrstuvwxyz123456X\r\nsuffix", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.history.items[0].edits.items.len);
    keys(&editor, allocator, &buffer, "u\x12u");
    try std.testing.expectEqualStrings(before, buffer.bytes());
    keys(&editor, allocator, &buffer, "j$i");
    for (0..27) |_| keys(&editor, allocator, &buffer, "\x7f");
    keys(&editor, allocator, &buffer, "X\x03");
    const after = try allocator.dupe(u8, buffer.bytes());
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 2), buffer.history.items[0].edits.items.len);
    keys(&editor, allocator, &buffer, "u");
    try std.testing.expectEqualStrings(before, buffer.bytes());
    keys(&editor, allocator, &buffer, "\x12");
    try std.testing.expectEqualStrings(after, buffer.bytes());
}

test "paste collection overflow is bounded and inserts nothing" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "base");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    keys(&editor, allocator, &buffer, "iX");
    _ = editor.feed(allocator, &buffer, .paste_begin);
    for (0..max_file_bytes + 1) |_| _ = editor.feed(allocator, &buffer, .{ .paste_byte = 'a' });
    try std.testing.expect(editor.paste_failed);
    try std.testing.expectEqual(@as(usize, max_file_bytes), editor.paste.items.len);
    _ = editor.feed(allocator, &buffer, .paste_end);
    try std.testing.expectEqualStrings("Xbase", buffer.bytes());
    keys(&editor, allocator, &buffer, "\x03u");
    try std.testing.expectEqualStrings("base", buffer.bytes());
}
