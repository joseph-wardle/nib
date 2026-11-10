// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const char = @import("char.zig");

// Temporary loading/editing bounds; the roadmap records their removal criteria.
pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_lines = 256 * 1024;

pub const Range = struct { start: usize, end: usize };
pub const Error = Allocator.Error || error{
    FileTooLarge,
    TooManyLines,
    InvalidRange,
    InvalidCursor,
    UnsupportedText,
};

const Edit = struct {
    start: usize,
    // One allocation owns removed bytes followed by inserted bytes.
    data: std.ArrayList(u8),
    removed_len: usize,

    fn removed(self: Edit) []const u8 {
        return self.data.items[0..self.removed_len];
    }

    fn inserted(self: Edit) []const u8 {
        return self.data.items[self.removed_len..];
    }
};

const Group = struct {
    edits: std.ArrayList(Edit) = .empty,
    before: usize,
    after: usize,

    fn deinit(self: *Group, allocator: Allocator) void {
        for (self.edits.items) |*edit| edit.data.deinit(allocator);
        self.edits.deinit(allocator);
    }
};

/// Owns mutable bytes, a detached loaded/saved base, and linear edit history.
/// All borrowed slices expire on mutation. Release with the original allocator.
/// Editable text is always valid UTF-8 (see `char.editable`), and cursor
/// offsets and edited ranges are character boundaries: never inside a UTF-8
/// sequence or between CR and LF. Mode-specific cursor landing and display
/// columns belong to navigation, not this storage.
pub const Buffer = struct {
    text: std.ArrayList(u8) = .empty,
    // Unlike the viewer index, includes the insertion row after a final LF.
    starts: std.ArrayList(usize) = .empty,
    base: []const u8,
    cursor: usize = 0,
    editable: bool,
    history: std.ArrayList(Group) = .empty,
    position: usize = 0,
    saved_position: ?usize = 0,
    grouping: bool = false,
    active_group: bool = false,
    group_cursor: usize = 0,

    pub fn fromBytes(allocator: Allocator, content: []const u8) (Allocator.Error || error{ FileTooLarge, TooManyLines })!Buffer {
        if (content.len > max_file_bytes) return error.FileTooLarge;
        const count = 1 + std.mem.count(u8, content, "\n");
        if (logicalLines(content, count) > max_lines) return error.TooManyLines;
        var self: Buffer = .{
            .base = try allocator.dupe(u8, content),
            .editable = char.editable(content),
        };
        errdefer self.deinit(allocator);
        try self.text.appendSlice(allocator, content);
        try self.starts.ensureTotalCapacity(allocator, count);
        self.starts.appendAssumeCapacity(0);
        for (content, 0..) |byte, offset| {
            if (byte == '\n') self.starts.appendAssumeCapacity(offset + 1);
        }
        return self;
    }

    pub fn deinit(self: *Buffer, allocator: Allocator) void {
        for (self.history.items) |*group| group.deinit(allocator);
        self.history.deinit(allocator);
        self.starts.deinit(allocator);
        self.text.deinit(allocator);
        allocator.free(self.base);
        self.* = undefined;
    }

    pub fn bytes(self: *const Buffer) []const u8 {
        return self.text.items;
    }

    /// A final LF ends the last line rather than starting another;
    /// insertionRows also counts the empty row after it.
    pub fn lineCount(self: *const Buffer) usize {
        return logicalLines(self.bytes(), self.starts.items.len);
    }

    pub fn insertionRows(self: *const Buffer) usize {
        return self.starts.items.len;
    }

    pub fn lineRange(self: *const Buffer, row: usize) Range {
        return .{
            .start = self.starts.items[row],
            .end = if (row + 1 < self.starts.items.len) self.starts.items[row + 1] else self.text.items.len,
        };
    }

    pub fn line(self: *const Buffer, row: usize) []const u8 {
        const range = self.lineRange(row);
        var end = range.end;
        if (end > range.start and self.text.items[end - 1] == '\n') {
            end -= 1;
            if (end > range.start and self.text.items[end - 1] == '\r') end -= 1;
        }
        return self.text.items[range.start..end];
    }

    /// Last line start at or before a validated offset, including trailing EOF.
    pub fn rowAt(self: *const Buffer, offset: usize) usize {
        std.debug.assert(offset <= self.text.items.len);
        var low: usize = 0;
        var high = self.starts.items.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.starts.items[middle] <= offset) low = middle + 1 else high = middle;
        }
        return low - 1;
    }

    pub fn setCursor(self: *Buffer, offset: usize) error{InvalidCursor}!void {
        if (!boundary(self.bytes(), offset)) return error.InvalidCursor;
        self.cursor = offset;
    }

    /// Current terminator, otherwise first existing terminator, otherwise LF.
    pub fn newlineAt(self: *const Buffer, offset: usize) []const u8 {
        const range = self.lineRange(self.rowAt(offset));
        if (range.end > range.start and self.text.items[range.end - 1] == '\n') return terminator(self.bytes(), range.end - 1);
        if (std.mem.indexOfScalar(u8, self.bytes(), '\n')) |lf| return terminator(self.bytes(), lf);
        return "\n";
    }

    pub fn modified(self: *const Buffer) bool {
        return self.saved_position == null or self.saved_position.? != self.position;
    }

    /// Ends an insertion group; subsequent edits form a new command.
    pub fn endGroup(self: *Buffer) void {
        self.grouping = false;
        self.active_group = false;
    }

    /// Complete a modal command with its final normal-mode cursor. Ordinary
    /// endGroup leaves the replacement API's cursor accounting unchanged.
    pub fn endCommand(self: *Buffer) void {
        if (self.active_group) self.history.items[self.position - 1].after = self.cursor;
        self.endGroup();
    }

    /// Capture the command cursor now, before insertion entry can move it.
    /// The next successful edit starts one group; further edits join it until
    /// endGroup. Failed edits retain earlier successful edits in the group.
    pub fn beginGroup(self: *Buffer) void {
        self.endGroup();
        self.grouping = true;
        self.group_cursor = self.cursor;
    }

    /// In-memory convenience. Filesystem saves prepare the owned base before
    /// publication and use acceptSaved so accounting afterward cannot allocate.
    pub fn markSaved(self: *Buffer, allocator: Allocator) Allocator.Error!void {
        const base = try allocator.dupe(u8, self.bytes());
        self.acceptSaved(allocator, base);
    }

    /// Takes ownership of a preallocated copy of the successfully saved bytes.
    /// The caller must verify publication before transferring this allocation.
    pub fn acceptSaved(self: *Buffer, allocator: Allocator, base: []const u8) void {
        std.debug.assert(std.mem.eql(u8, base, self.bytes()));
        allocator.free(self.base);
        self.base = base;
        self.saved_position = self.position;
        self.endGroup();
    }

    /// Replaces a half-open range, then sets a byte cursor in the result.
    /// Input may alias this buffer. No-op replacements create no history and
    /// leave the cursor unchanged. Every fallible operation precedes mutation.
    pub fn replace(self: *Buffer, allocator: Allocator, range: Range, inserted: []const u8, cursor_after: usize) Error!void {
        if (range.start > range.end or !boundary(self.bytes(), range.start) or !boundary(self.bytes(), range.end)) return error.InvalidRange;
        if (!self.editable or !char.editable(inserted)) return error.UnsupportedText;
        const removed = self.text.items[range.start..range.end];
        const remaining = self.text.items.len - removed.len;
        if (inserted.len > max_file_bytes - remaining) return error.FileTooLarge;
        const length = remaining + inserted.len;
        const rows = self.starts.items.len - std.mem.count(u8, removed, "\n") + std.mem.count(u8, inserted, "\n");
        const final_byte: ?u8 = if (range.end < self.text.items.len) self.text.items[self.text.items.len - 1] else if (inserted.len != 0) inserted[inserted.len - 1] else if (range.start != 0) self.text.items[range.start - 1] else null;
        if (rows - @intFromBool(final_byte == '\n') > max_lines) return error.TooManyLines;
        if (cursor_after > length) return error.InvalidCursor;
        // Boundary ranges of valid text joined with valid text stay valid, and
        // its CR is always followed by LF, so only the resulting cursor needs a
        // virtual read: never on a continuation byte or the LF of a CRLF.
        if (cursor_after > 0 and cursor_after < length) {
            const after = self.resultByte(range, inserted, cursor_after);
            if (char.continuation(after)) return error.InvalidCursor;
            const before = self.resultByte(range, inserted, cursor_after - 1);
            if (after == '\n' and before == '\r') return error.InvalidCursor;
        }
        if (std.mem.eql(u8, removed, inserted)) return;

        const owned = try allocator.alloc(u8, removed.len + inserted.len);
        errdefer allocator.free(owned);
        @memcpy(owned[0..removed.len], removed);
        @memcpy(owned[removed.len..], inserted);
        const edit: Edit = .{ .start = range.start, .data = .fromOwnedSlice(owned), .removed_len = removed.len };
        // Coalesce edits inside newly typed text, and consecutive backwards
        // deletions. Long insert/Backspace sessions then replay a few ranges
        // instead of moving a large suffix once per original keystroke.
        const merge: enum { none, typed, backwards } = if (self.active_group) merge: {
            const edits = self.history.items[self.position - 1].edits.items;
            const last = edits[edits.len - 1];
            if (last.removed_len == 0 and range.start >= last.start and
                range.end - last.start <= last.inserted().len) break :merge .typed;
            if (inserted.len == 0 and last.inserted().len == 0 and range.end == last.start) break :merge .backwards;
            break :merge .none;
        } else .none;
        var new_group: Group = .{ .before = if (self.grouping) self.group_cursor else self.cursor, .after = cursor_after };
        errdefer new_group.edits.deinit(allocator);
        if (self.active_group and merge == .none) {
            try self.history.items[self.position - 1].edits.ensureUnusedCapacity(allocator, 1);
        } else if (!self.active_group) {
            try new_group.edits.ensureUnusedCapacity(allocator, 1);
            try self.history.ensureTotalCapacity(allocator, self.position + 1);
        }
        try self.text.ensureTotalCapacity(allocator, length);
        try self.starts.ensureTotalCapacity(allocator, rows);
        if (merge != .none) {
            const edits = self.history.items[self.position - 1].edits.items;
            try edits[edits.len - 1].data.ensureUnusedCapacity(allocator, if (merge == .typed) inserted.len else removed.len);
        }

        // Discarding redo is part of the successful edit, never its preparation.
        if (self.saved_position) |saved| {
            if (saved > self.position) self.saved_position = null;
        }
        for (self.history.items[self.position..]) |*group| group.deinit(allocator);
        self.history.shrinkRetainingCapacity(self.position);
        if (!self.active_group) {
            self.history.appendAssumeCapacity(new_group);
            self.position += 1;
        }
        const group = &self.history.items[self.position - 1];
        group.after = cursor_after;
        self.apply(range, edit.inserted());
        if (merge != .none) {
            const last = &group.edits.items[group.edits.items.len - 1];
            if (merge == .typed) {
                last.data.replaceRangeAssumeCapacity(range.start - last.start, range.end - range.start, edit.inserted());
            } else {
                last.data.replaceRangeAssumeCapacity(0, 0, edit.removed());
                last.start = range.start;
                last.removed_len += edit.removed_len;
            }
            allocator.free(owned);
        } else group.edits.appendAssumeCapacity(edit);
        self.cursor = cursor_after;
        self.active_group = self.grouping;
    }

    pub fn undo(self: *Buffer, allocator: Allocator) Allocator.Error!bool {
        return self.replay(allocator, false);
    }

    pub fn redo(self: *Buffer, allocator: Allocator) Allocator.Error!bool {
        return self.replay(allocator, true);
    }

    fn replay(self: *Buffer, allocator: Allocator, forward: bool) Allocator.Error!bool {
        if (if (forward) self.position == self.history.items.len else self.position == 0) return false;
        const group = self.history.items[if (forward) self.position else self.position - 1];
        // Every intermediate version was cap-validated when originally edited.
        // Reserve the maxima for the entire command before replaying any edit.
        var length = self.text.items.len;
        var rows = self.starts.items.len;
        var max_length = length;
        var max_rows = rows;
        for (0..group.edits.items.len) |i| {
            const edit = group.edits.items[if (forward) i else group.edits.items.len - i - 1];
            const removed = if (forward) edit.removed() else edit.inserted();
            const inserted = if (forward) edit.inserted() else edit.removed();
            length = length - removed.len + inserted.len;
            rows = rows - std.mem.count(u8, removed, "\n") + std.mem.count(u8, inserted, "\n");
            max_length = @max(max_length, length);
            max_rows = @max(max_rows, rows);
        }
        try self.text.ensureTotalCapacity(allocator, max_length);
        try self.starts.ensureTotalCapacity(allocator, max_rows);
        for (0..group.edits.items.len) |i| {
            const edit = group.edits.items[if (forward) i else group.edits.items.len - i - 1];
            const removed = if (forward) edit.removed() else edit.inserted();
            const inserted = if (forward) edit.inserted() else edit.removed();
            self.apply(.{ .start = edit.start, .end = edit.start + removed.len }, inserted);
        }
        self.cursor = if (forward) group.after else group.before;
        if (forward) self.position += 1 else self.position -= 1;
        self.endGroup();
        return true;
    }

    fn resultByte(self: *const Buffer, range: Range, inserted: []const u8, offset: usize) u8 {
        if (offset < range.start) return self.text.items[offset];
        if (offset - range.start < inserted.len) return inserted[offset - range.start];
        return self.text.items[offset - inserted.len + (range.end - range.start)];
    }

    fn apply(self: *Buffer, range: Range, inserted: []const u8) void {
        const first = self.rowAt(range.start) + 1;
        const end = self.rowAt(range.end) + 1;
        const added = std.mem.count(u8, inserted, "\n");
        const old_rows = self.starts.items.len;
        const new_rows = old_rows - (end - first) + added;
        if (new_rows > old_rows) self.starts.items.len = new_rows;
        const suffix = self.starts.items[end..old_rows];
        const destination = self.starts.items[first + added .. new_rows];
        if (first + added > end) std.mem.copyBackwards(usize, destination, suffix) else std.mem.copyForwards(usize, destination, suffix);
        self.starts.items.len = new_rows;
        for (self.starts.items[first + added ..]) |*offset| offset.* = offset.* - (range.end - range.start) + inserted.len;
        var row = first;
        for (inserted, 0..) |byte, i| {
            if (byte == '\n') {
                self.starts.items[row] = range.start + i + 1;
                row += 1;
            }
        }
        self.text.replaceRangeAssumeCapacity(range.start, range.end - range.start, inserted);
    }
};

fn logicalLines(bytes: []const u8, rows: usize) usize {
    return rows - @intFromBool(bytes.len != 0 and bytes[bytes.len - 1] == '\n');
}

fn boundary(bytes: []const u8, offset: usize) bool {
    return offset <= bytes.len and char.start(bytes, offset) == offset;
}

fn terminator(bytes: []const u8, lf: usize) []const u8 {
    return if (lf > 0 and bytes[lf - 1] == '\r') "\r\n" else "\n";
}

test "owned base, mixed terminators, and trailing insertion rows" {
    const allocator = std.testing.allocator;
    var input = [_]u8{ 'a', '\r', '\n', 'b', '\n', 'c' };
    var buffer = try Buffer.fromBytes(allocator, &input);
    defer buffer.deinit(allocator);
    @memset(&input, 'z');
    try std.testing.expectEqualStrings("a\r\nb\nc", buffer.bytes());
    try std.testing.expectEqualStrings(buffer.bytes(), buffer.base);
    try std.testing.expectEqualStrings("a", buffer.line(0));
    try std.testing.expectEqualStrings("b", buffer.line(1));
    try std.testing.expectEqualStrings("c", buffer.line(2));
    try std.testing.expectEqualStrings("\r\n", buffer.newlineAt(0));
    try std.testing.expectEqualStrings("\n", buffer.newlineAt(3));
    try std.testing.expectEqualStrings("\r\n", buffer.newlineAt(6));
    try std.testing.expectError(error.InvalidCursor, buffer.setCursor(2));
    try std.testing.expectError(error.InvalidRange, buffer.replace(allocator, .{ .start = 1, .end = 2 }, "", 1));
    try std.testing.expectError(error.InvalidCursor, buffer.replace(allocator, .{ .start = 0, .end = 1 }, "x", 2));
    try std.testing.expectEqual(@as(usize, 0), buffer.history.items.len);
    try std.testing.expect(!buffer.modified());

    try buffer.setCursor(6);
    buffer.beginGroup();
    try buffer.replace(allocator, .{ .start = 6, .end = 6 }, "\r\n", 8);
    try std.testing.expectEqual(@as(usize, 3), buffer.lineCount());
    try std.testing.expectEqual(@as(usize, 4), buffer.insertionRows());
    try std.testing.expectEqualStrings("", buffer.line(buffer.rowAt(buffer.cursor)));
    try buffer.replace(allocator, .{ .start = 8, .end = 8 }, "X", 9);
    buffer.endGroup();
    try std.testing.expectEqual(@as(usize, 4), buffer.lineCount());
    try std.testing.expectEqualStrings("a\r\nb\nc\r\nX", buffer.bytes());
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings("a\r\nb\nc", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    try std.testing.expect(!buffer.modified());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqual(@as(usize, 9), buffer.cursor);
    try std.testing.expectEqualStrings("a\r\nb\nc\r\nX", buffer.bytes());
}

test "empty EOF, range replacement, deletion, aliases, and no-op history" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "");
    defer buffer.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), buffer.lineCount());
    try std.testing.expectEqualStrings("\n", buffer.newlineAt(0));
    try buffer.replace(allocator, .{ .start = 0, .end = 0 }, "\n", 1);
    try std.testing.expectEqual(@as(usize, 2), buffer.insertionRows());
    try buffer.replace(allocator, .{ .start = 1, .end = 1 }, "abc", 4);
    try buffer.replace(allocator, .{ .start = 0, .end = 1 }, buffer.bytes()[1..], 0);
    try std.testing.expectEqualStrings("abcabc", buffer.bytes());
    try buffer.replace(allocator, .{ .start = 0, .end = 6 }, "", 0);
    try std.testing.expectEqualStrings("", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.insertionRows());
    try std.testing.expect(try buffer.undo(allocator));
    const position = buffer.position;
    try buffer.replace(allocator, .{ .start = 0, .end = 3 }, "abc", 3);
    try std.testing.expectEqual(position, buffer.position);
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    try std.testing.expect(try buffer.redo(allocator));
    while (try buffer.undo(allocator)) {}
    try std.testing.expect(!try buffer.undo(allocator));
    try std.testing.expectEqualStrings("", buffer.bytes());
    while (try buffer.redo(allocator)) {}
    try std.testing.expectEqualStrings("", buffer.bytes());
}

test "saved positions survive undo and redo but not discarded branches" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "abc");
    defer buffer.deinit(allocator);
    try buffer.replace(allocator, .{ .start = 1, .end = 2 }, "B", 2);
    try buffer.markSaved(allocator);
    try std.testing.expectEqualStrings("aBc", buffer.base);
    try std.testing.expect(!buffer.modified());
    try buffer.replace(allocator, .{ .start = 2, .end = 3 }, "C", 3);
    try std.testing.expect(buffer.modified());
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expect(!buffer.modified());
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expect(buffer.modified());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expect(!buffer.modified());
    try std.testing.expect(try buffer.undo(allocator));
    try buffer.replace(allocator, .{ .start = 0, .end = 1 }, "A", 1);
    try std.testing.expect(!try buffer.redo(allocator));
    try std.testing.expect(buffer.modified());
    try std.testing.expectEqual(@as(?usize, null), buffer.saved_position);
    try std.testing.expectEqualStrings("aBc", buffer.base);
}

test "unsupported bytes are retained read-only and unsupported replacements are atomic" {
    const allocator = std.testing.allocator;
    const unsupported = [_][]const u8{
        "a\x00b", "a\x1bb", "a\rb", "a\x7fb", "\xff", "\xc2\x9b", "\xc3", "\xed\xa0\x80",
    };
    for (unsupported) |input| {
        var buffer = try Buffer.fromBytes(allocator, input);
        defer buffer.deinit(allocator);
        try std.testing.expect(!buffer.editable);
        try std.testing.expectEqualStrings(input, buffer.bytes());
        try std.testing.expectError(error.UnsupportedText, buffer.replace(allocator, .{ .start = 0, .end = input.len }, "", 0));
        try std.testing.expect(!buffer.modified());
    }
    var buffer = try Buffer.fromBytes(allocator, "ok\t\r\n");
    defer buffer.deinit(allocator);
    try std.testing.expect(buffer.editable);
    try std.testing.expectError(error.UnsupportedText, buffer.replace(allocator, .{ .start = 0, .end = 0 }, "a\rb", 0));
    try std.testing.expectEqualStrings("ok\t\r\n", buffer.bytes());
}

test "byte and logical line limits include EOF transitions and reversible edits" {
    const allocator = std.testing.allocator;
    const large = try allocator.alloc(u8, max_file_bytes + 1);
    defer allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectError(error.FileTooLarge, Buffer.fromBytes(allocator, large));
    var buffer = try Buffer.fromBytes(allocator, large[0 .. max_file_bytes - 1]);
    defer buffer.deinit(allocator);
    buffer.beginGroup();
    try buffer.replace(allocator, .{ .start = 0, .end = 0 }, "a", 1);
    try std.testing.expectError(error.FileTooLarge, buffer.replace(allocator, .{ .start = 1, .end = 1 }, "bc", 3));
    try std.testing.expectEqual(@as(usize, max_file_bytes), buffer.bytes().len);
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
    try std.testing.expectEqual(@as(usize, 1), buffer.history.items[0].edits.items.len);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqual(@as(usize, max_file_bytes), buffer.bytes().len);

    @memset(large[0 .. max_lines + 1], '\n');
    try std.testing.expectError(error.TooManyLines, Buffer.fromBytes(allocator, large[0 .. max_lines + 1]));
    var lines = try Buffer.fromBytes(allocator, large[0 .. max_lines - 1]);
    defer lines.deinit(allocator);
    const eof = lines.bytes().len;
    try lines.replace(allocator, .{ .start = eof, .end = eof }, "x", eof + 1);
    try std.testing.expectEqual(@as(usize, max_lines), lines.lineCount());
    // A final LF terminates the last line, without adding a logical line.
    try lines.replace(allocator, .{ .start = eof + 1, .end = eof + 1 }, "\n", eof + 2);
    try std.testing.expectEqual(@as(usize, max_lines), lines.lineCount());
    try std.testing.expectEqual(@as(usize, max_lines + 1), lines.insertionRows());
    const position = lines.position;
    try std.testing.expectError(error.TooManyLines, lines.replace(allocator, .{ .start = eof + 2, .end = eof + 2 }, "X", eof + 3));
    try std.testing.expectError(error.TooManyLines, lines.replace(allocator, .{ .start = 0, .end = 0 }, "\n", 1));
    try std.testing.expectEqual(position, lines.position);
    try std.testing.expect(try lines.undo(allocator));
    try std.testing.expect(try lines.redo(allocator));
    var reopened = try Buffer.fromBytes(allocator, lines.bytes());
    defer reopened.deinit(allocator);
    try std.testing.expectEqual(lines.lineCount(), reopened.lineCount());
}

test "line boundaries preserve empty lines and strip only LF or CRLF" {
    const Case = struct { text: []const u8, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .text = "", .lines = &.{""} },
        .{ .text = "\n", .lines = &.{""} },
        .{ .text = "\n\n", .lines = &.{ "", "" } },
        .{ .text = "abc", .lines = &.{"abc"} },
        .{ .text = "abc\n", .lines = &.{"abc"} },
        .{ .text = "a\n\nb", .lines = &.{ "a", "", "b" } },
        .{ .text = "a\r\n\r\nb\r", .lines = &.{ "a", "", "b\r" } },
        .{ .text = "\r\r\n", .lines = &.{"\r"} },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(std.testing.allocator, case.text);
        defer buffer.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.lines.len, buffer.lineCount());
        for (case.lines, 0..) |expected, row| try std.testing.expectEqualStrings(expected, buffer.line(row));
    }
}

test "edit, branch, grouped insertion, and saved-base failures retain observable state" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationWorkflow, .{});
}

fn allocationWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "a\r\nb");
    defer buffer.deinit(allocator);
    try buffer.setCursor(3);
    buffer.replace(allocator, .{ .start = 0, .end = 1 }, "FIRST\n", 6) catch |err| {
        try expectState(&buffer, "a\r\nb", 3, 0, 0, false);
        return err;
    };
    try std.testing.expect(try buffer.undo(allocator));
    buffer.replace(allocator, .{ .start = 0, .end = 1 }, "branch\n", 7) catch |err| {
        try expectState(&buffer, "a\r\nb", 3, 0, 1, false);
        try std.testing.expect(try buffer.redo(allocator));
        try std.testing.expectEqualStrings("FIRST\n\r\nb", buffer.bytes());
        return err;
    };
    buffer.beginGroup();
    buffer.replace(allocator, .{ .start = 0, .end = 6 }, "", 0) catch |err| {
        try expectState(&buffer, "branch\n\r\nb", 7, 1, 1, true);
        return err;
    };
    buffer.replace(allocator, .{ .start = 0, .end = 0 }, "much longer insertion\n\n\n", 24) catch |err| {
        try expectState(&buffer, "\n\r\nb", 0, 2, 2, true);
        try std.testing.expectEqual(@as(usize, 1), buffer.history.items[1].edits.items.len);
        return err;
    };
    buffer.markSaved(allocator) catch |err| {
        try std.testing.expectEqualStrings("a\r\nb", buffer.base);
        try std.testing.expect(buffer.modified());
        try std.testing.expectEqual(@as(usize, 24), buffer.cursor);
        return err;
    };
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings("branch\n\r\nb", buffer.bytes());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expect(!buffer.modified());
}

fn expectState(buffer: *const Buffer, bytes: []const u8, cursor: usize, position: usize, groups: usize, dirty: bool) !void {
    try std.testing.expectEqualStrings(bytes, buffer.bytes());
    try std.testing.expectEqual(cursor, buffer.cursor);
    try std.testing.expectEqual(position, buffer.position);
    try std.testing.expectEqual(groups, buffer.history.items.len);
    try std.testing.expectEqual(dirty, buffer.modified());
    try expectIndex(buffer);
}

fn expectIndex(buffer: *const Buffer) !void {
    var row: usize = 1;
    try std.testing.expectEqual(@as(usize, 0), buffer.starts.items[0]);
    for (buffer.bytes(), 0..) |byte, offset| {
        if (byte == '\n') {
            try std.testing.expectEqual(offset + 1, buffer.starts.items[row]);
            row += 1;
        }
    }
    try std.testing.expectEqual(row, buffer.insertionRows());
}

test "incremental index and history agree with independent replacement over varied ranges" {
    const allocator = std.testing.allocator;
    const original = "first\r\nsecond\n\r\nthird\r\n";
    var buffer = try Buffer.fromBytes(allocator, original);
    defer buffer.deinit(allocator);
    var random = std.Random.DefaultPrng.init(0x45a8);
    const rng = random.random();
    const replacements = [_][]const u8{ "", "x", "\n", "\r\n", "\n\n", "abc\r\ndef", "\tline\n" };
    for (0..500) |i| {
        if (i % 7 == 0) buffer.beginGroup();
        var start = rng.uintLessThan(usize, buffer.bytes().len + 1);
        var end = start + rng.uintLessThan(usize, buffer.bytes().len - start + 1);
        if (!boundary(buffer.bytes(), start)) start -= 1;
        if (!boundary(buffer.bytes(), end)) end += 1;
        const inserted = replacements[rng.uintLessThan(usize, replacements.len)];
        const expected = try std.mem.concat(allocator, u8, &.{ buffer.bytes()[0..start], inserted, buffer.bytes()[end..] });
        defer allocator.free(expected);
        try buffer.replace(allocator, .{ .start = start, .end = end }, inserted, start + inserted.len);
        try std.testing.expectEqualStrings(expected, buffer.bytes());
        try expectIndex(&buffer);
    }
    buffer.endGroup();
    const final = try allocator.dupe(u8, buffer.bytes());
    defer allocator.free(final);
    while (try buffer.undo(allocator)) try expectIndex(&buffer);
    try std.testing.expectEqualStrings(original, buffer.bytes());
    while (try buffer.redo(allocator)) try expectIndex(&buffer);
    try std.testing.expectEqualStrings(final, buffer.bytes());
}

test "one insertion region coalesces at either edge and inside with exact replay" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "left right\r\n");
    defer buffer.deinit(allocator);
    try buffer.setCursor(5);
    buffer.beginGroup();
    try buffer.replace(allocator, .{ .start = 5, .end = 5 }, "ac", 7);
    try buffer.replace(allocator, .{ .start = 6, .end = 6 }, "b", 7);
    try buffer.replace(allocator, .{ .start = 5, .end = 5 }, "[", 6);
    try buffer.replace(allocator, .{ .start = 9, .end = 9 }, "]\n", 11);
    try std.testing.expectEqualStrings("left [abc]\nright\r\n", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.history.items[0].edits.items.len);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings("left right\r\n", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqualStrings("left [abc]\nright\r\n", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 11), buffer.cursor);
    try expectIndex(&buffer);
}

test "failed insertion coalescing retains earlier typing and allocation-free replay" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, coalescingWorkflow, .{});
}

fn coalescingWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "abc");
    defer buffer.deinit(allocator);
    buffer.beginGroup();
    try buffer.replace(allocator, .{ .start = 1, .end = 1 }, "X", 2);
    buffer.replace(allocator, .{ .start = 2, .end = 2 }, "long insertion\n\n", 18) catch |err| {
        try expectState(&buffer, "aXbc", 2, 1, 1, true);
        try std.testing.expectEqualStrings("X", buffer.history.items[0].edits.items[0].inserted());
        try std.testing.expect(try buffer.undo(allocator));
        try std.testing.expectEqualStrings("abc", buffer.bytes());
        try std.testing.expect(try buffer.redo(allocator));
        try std.testing.expectEqualStrings("aXbc", buffer.bytes());
        return err;
    };
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings("abc", buffer.bytes());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqualStrings("aXlong insertion\n\nbc", buffer.bytes());
}

test "backwards deletion coalescing prepares all storage before changing prior history" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, backwardsWorkflow, .{});
}

fn backwardsWorkflow(allocator: Allocator) !void {
    const before = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789\r\nsuffix";
    var buffer = try Buffer.fromBytes(allocator, before);
    defer buffer.deinit(allocator);
    buffer.cursor = 50;
    buffer.beginGroup();
    try buffer.replace(allocator, .{ .start = 49, .end = 50 }, "", 49);
    buffer.replace(allocator, .{ .start = 0, .end = 49 }, "", 0) catch |err| {
        try std.testing.expectEqualStrings(before[0..49] ++ before[50..], buffer.bytes());
        try std.testing.expectEqual(@as(usize, 49), buffer.cursor);
        try std.testing.expect(try buffer.undo(allocator));
        try std.testing.expectEqualStrings(before, buffer.bytes());
        return err;
    };
    try std.testing.expectEqualStrings(before[50..], buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.history.items[0].edits.items.len);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings(before, buffer.bytes());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqualStrings(before[50..], buffer.bytes());
}

test "UTF-8 text is editable, and refused replacements change nothing" {
    const allocator = std.testing.allocator;
    // é (2 bytes), € (3), CRLF, 材 (3), ✅ (3), 𝑥 (4).
    const before = "\u{e9}\u{20ac}\r\n\u{6750}\u{2705}\u{1d465}";
    var buffer = try Buffer.fromBytes(allocator, before);
    defer buffer.deinit(allocator);
    try std.testing.expect(buffer.editable);
    try buffer.replace(allocator, .{ .start = 0, .end = 0 }, "x", 1);
    const after = "x" ++ before;
    // Start, end, inserted text and cursor, then the refusal.
    const Refusal = struct { usize, usize, []const u8, usize, Error };
    const refused = [_]Refusal{
        // Ranges that split a sequence or a CRLF.
        .{ 2, 2, "", 1, error.InvalidRange },
        .{ 1, 4, "", 1, error.InvalidRange },
        .{ 7, 15, "", 7, error.InvalidRange },
        .{ 15, 17, "", 15, error.InvalidRange },
        // Cursors inside a sequence, in inserted text or in the surrounding text.
        .{ 1, 1, "\u{e9}", 2, error.InvalidCursor },
        .{ 1, 3, "", 2, error.InvalidCursor },
        .{ 0, 1, "", 15, error.InvalidCursor },
        // Inserted text that is not editable: truncated, a lone continuation
        // byte, overlong, a surrogate, C1 and DEL.
        .{ 1, 1, "\xc3", 1, error.UnsupportedText },
        .{ 1, 1, "\xa9", 1, error.UnsupportedText },
        .{ 1, 1, "\xc0\xaf", 1, error.UnsupportedText },
        .{ 1, 1, "\xed\xa0\x80", 1, error.UnsupportedText },
        .{ 1, 1, "\u{9b}", 1, error.UnsupportedText },
        .{ 1, 1, "\x7f", 1, error.UnsupportedText },
    };
    for (refused) |case| {
        const start, const end, const text, const cursor, const err = case;
        const range: Range = .{ .start = start, .end = end };
        try std.testing.expectError(err, buffer.replace(allocator, range, text, cursor));
        try expectState(&buffer, after, 1, 1, 1, true);
    }
    // Whole characters can be replaced, and replay restores the exact bytes.
    try buffer.replace(allocator, .{ .start = 3, .end = 6 }, "\u{2014}\u{3c3}", 8);
    const replaced = "x\u{e9}\u{2014}\u{3c3}\r\n\u{6750}\u{2705}\u{1d465}";
    try std.testing.expectEqualStrings(replaced, buffer.bytes());
    try buffer.replace(allocator, .{ .start = 16, .end = 20 }, "", 16);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings(after, buffer.bytes());
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqualStrings(replaced[0..16], buffer.bytes());
    try std.testing.expectEqual(@as(usize, 16), buffer.cursor);
    try std.testing.expectError(error.InvalidCursor, buffer.setCursor(15));
}

test "multi-byte insertion and deletion failures retain earlier edits and history" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, multibyteWorkflow, .{});
}

fn multibyteWorkflow(allocator: Allocator) !void {
    const before = "a\u{2014}b\r\n";
    var buffer = try Buffer.fromBytes(allocator, before);
    defer buffer.deinit(allocator);
    try buffer.setCursor(4);
    buffer.beginGroup();
    buffer.replace(allocator, .{ .start = 4, .end = 4 }, "\u{e9}", 6) catch |err| {
        try expectState(&buffer, before, 4, 0, 0, false);
        return err;
    };
    buffer.replace(allocator, .{ .start = 6, .end = 6 }, "\u{6750}\u{2705}\n", 13) catch |err| {
        try expectState(&buffer, "a\u{2014}\u{e9}b\r\n", 6, 1, 1, true);
        return err;
    };
    // Deleting a 3-byte character before the typed text.
    buffer.replace(allocator, .{ .start = 1, .end = 4 }, "", 1) catch |err| {
        try expectState(&buffer, "a\u{2014}\u{e9}\u{6750}\u{2705}\nb\r\n", 13, 1, 1, true);
        return err;
    };
    buffer.endGroup();
    const after = "a\u{e9}\u{6750}\u{2705}\nb\r\n";
    try expectState(&buffer, after, 1, 1, 1, true);
    try std.testing.expect(try buffer.undo(allocator));
    try expectState(&buffer, before, 4, 0, 1, false);
    try std.testing.expect(try buffer.redo(allocator));
    try std.testing.expectEqualStrings(after, buffer.bytes());
}
