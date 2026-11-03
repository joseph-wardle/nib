// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const source = @import("snapshot.zig");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");

/// Logical rows and display columns; the caller reserves terminal margins/status.
pub const Viewport = struct {
    top: usize = 0,
    left: usize = 0,

    pub fn follow(self: *Viewport, buffer: *const Buffer, rows: usize, columns: usize, insert: bool) void {
        const count = if (insert) buffer.insertionRows() else buffer.lineCount();
        const row = @min(buffer.rowAt(buffer.cursor), count - 1);
        const col = motion.screenColumn(buffer, buffer.cursor, insert);
        self.top = @min(self.top, count -| @max(rows, 1));
        if (row < self.top) self.top = row else if (row - self.top >= @max(rows, 1)) self.top = row - (@max(rows, 1) - 1);
        if (col < self.left) self.left = col else if (col - self.left >= @max(columns, 1)) self.left = col - (@max(columns, 1) - 1);
    }

    /// null when no content cell exists, including a one-row terminal. Returned
    /// coordinates are zero-based, relative to the content area, never status.
    pub fn cursor(self: Viewport, buffer: *const Buffer, rows: usize, columns: usize, insert: bool) ?struct { row: usize, column: usize } {
        const row = buffer.rowAt(buffer.cursor);
        const col = motion.screenColumn(buffer, buffer.cursor, insert);
        if (row < self.top or col < self.left or row - self.top >= rows or col - self.left >= columns) return null;
        return .{ .row = row - self.top, .column = col - self.left };
    }

    /// No allocation or mutation; output is padded printable ASCII.
    pub fn renderRow(self: Viewport, buffer: *const Buffer, row: usize, output: []u8) void {
        if (self.top >= buffer.insertionRows() or row >= buffer.insertionRows() - self.top) {
            @memset(output, ' ');
            return;
        }
        renderText(buffer.line(self.top + row), self.left, output);
    }
};

/// Clips by display column, including inside a tab. Also suitable for a path
/// label: every control/non-ASCII byte becomes '?', including embedded newlines.
/// Tabs use eight-column stops from the beginning of text, before clipping.
pub fn renderText(text: []const u8, left: usize, output: []u8) void {
    @memset(output, ' ');
    if (output.len == 0) return;
    var column: usize = 0;
    for (text) |byte| {
        const width = source.cellWidth(byte, column);
        const skipped = left -| column;
        const offset = column -| left;
        if (offset >= output.len) break;
        if (skipped < width) {
            const count = @min(width - skipped, output.len - offset);
            const cell: u8 = if (byte == '\t') ' ' else if (byte >= 0x20 and byte <= 0x7e) byte else '?';
            @memset(output[offset..][0..count], cell);
        }
        column += width;
    }
}

test "rendering clips inside tabs and pads short rows" {
    var text = try Buffer.fromBytes(std.testing.allocator, "a\tb\tc\nshort\n");
    defer text.deinit(std.testing.allocator);
    var buffer: [12]u8 = undefined;
    var viewport: Viewport = .{ .left = 4 };
    viewport.renderRow(&text, 0, &buffer);
    try std.testing.expectEqualStrings("    b       ", &buffer);
    viewport.left = 7;
    viewport.renderRow(&text, 0, buffer[0..4]);
    try std.testing.expectEqualStrings(" b  ", buffer[0..4]);
    viewport.left = 8;
    viewport.renderRow(&text, 0, buffer[0..9]);
    try std.testing.expectEqualStrings("b       c", buffer[0..9]);
    viewport.left = 16;
    viewport.renderRow(&text, 0, buffer[0..4]);
    try std.testing.expectEqualStrings("c   ", buffer[0..4]);
    viewport.left = 0;
    viewport.renderRow(&text, 1, &buffer);
    try std.testing.expectEqualStrings("short       ", &buffer);
    viewport.renderRow(&text, 2, buffer[0..4]);
    try std.testing.expectEqualStrings("    ", buffer[0..4]);
}

test "all byte values and hostile filenames render as safe ASCII" {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var buffer: [512]u8 = undefined;
    renderText(&bytes, 0, &buffer);
    for (buffer) |byte| try std.testing.expect(byte >= 0x20 and byte <= 0x7e);
    renderText("file\x1b[2J\n\r\x7f\xc3\xa9", 0, buffer[0..14]);
    try std.testing.expectEqualStrings("file?[2J????? ", buffer[0..14]);
}

test "following scrolls only to reveal the cursor and survives tiny geometry" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "abcdef\n12\nlast\n");
    defer buffer.deinit(std.testing.allocator);
    var viewport: Viewport = .{};
    buffer.cursor = 4;
    viewport.follow(&buffer, 2, 3, false);
    try std.testing.expectEqualDeep(Viewport{ .left = 2 }, viewport);
    buffer.cursor = 12;
    viewport.follow(&buffer, 2, 3, false);
    try std.testing.expectEqualDeep(Viewport{ .top = 1, .left = 2 }, viewport);
    const cell = viewport.cursor(&buffer, 2, 3, false).?;
    try std.testing.expectEqual(@as(usize, 1), cell.row);
    try std.testing.expectEqual(@as(usize, 0), cell.column);
    viewport.follow(&buffer, 0, 0, false);
    try std.testing.expect(viewport.cursor(&buffer, 0, 0, false) == null);
    viewport.follow(&buffer, 100, 100, false);
    try std.testing.expectEqual(@as(usize, 0), viewport.top);
    buffer.cursor = 0;
    viewport.follow(&buffer, 2, 3, false);
    try std.testing.expectEqualDeep(Viewport{}, viewport);
    viewport.top = std.math.maxInt(usize);
    viewport.left = std.math.maxInt(usize);
    var output: [3]u8 = undefined;
    viewport.renderRow(&buffer, std.math.maxInt(usize), &output);
    try std.testing.expectEqualStrings("   ", &output);
    viewport.follow(&buffer, 0, 0, false);
    try std.testing.expectEqualDeep(Viewport{}, viewport);
}

test "tab cursor and trailing insertion row have visible cells only in content" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "\tX\r\n");
    defer buffer.deinit(std.testing.allocator);
    var viewport: Viewport = .{};
    viewport.follow(&buffer, 1, 3, false);
    try std.testing.expectEqual(@as(usize, 5), viewport.left);
    try std.testing.expectEqual(@as(usize, 2), viewport.cursor(&buffer, 1, 3, false).?.column);
    buffer.cursor = buffer.bytes().len;
    viewport.follow(&buffer, 1, 3, true);
    try std.testing.expectEqualDeep(Viewport{ .top = 1 }, viewport);
    try std.testing.expectEqual(@as(usize, 0), viewport.cursor(&buffer, 1, 3, true).?.column);
    try std.testing.expect(viewport.cursor(&buffer, 0, 3, true) == null);
}

test "a long line can be clipped near its end without wrapping or modification" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(bytes);
    @memset(bytes, 'a');
    @memcpy(bytes[bytes.len - 4 ..], "tail");
    var text = try Buffer.fromBytes(allocator, bytes);
    defer text.deinit(allocator);
    var viewport: Viewport = .{};
    text.cursor = text.bytes().len - 1;
    viewport.follow(&text, 1, 4, false);
    var buffer: [4]u8 = undefined;
    viewport.renderRow(&text, 0, &buffer);
    try std.testing.expectEqualStrings("tail", &buffer);
    try std.testing.expectEqualSlices(u8, bytes, text.bytes());
}

test "every clipping boundary agrees with a fully expanded line" {
    const expanded = "        A       BC";
    var buffer: [24]u8 = undefined;
    for (0..expanded.len + 2) |left| {
        for (0..buffer.len + 1) |width| {
            renderText("\tA\tBC", left, buffer[0..width]);
            for (buffer[0..width], 0..) |byte, column| {
                const index = left + column;
                const expected: u8 = if (index < expanded.len) expanded[index] else ' ';
                try std.testing.expectEqual(expected, byte);
            }
        }
    }
}
