// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const source = @import("snapshot.zig");
const Snapshot = source.Snapshot;

pub const Direction = enum { left, down, up, right };

/// Offsets in logical lines and display columns. Geometry passed to clamp/move
/// is the content area; terminal margins and the status row belong to the caller.
pub const Viewport = struct {
    top: usize = 0,
    left: usize = 0,

    pub fn clamp(self: *Viewport, snapshot: Snapshot, rows: usize, columns: usize) void {
        self.top = @min(self.top, snapshot.line_starts.len -| @max(rows, 1));
        self.left = @min(self.left, snapshot.max_columns -| @max(columns, 1));
    }

    /// Returns whether the viewport changed, so callers can avoid idle redraws.
    pub fn move(self: *Viewport, snapshot: Snapshot, rows: usize, columns: usize, direction: Direction) bool {
        const previous = self.*;
        self.clamp(snapshot, rows, columns);
        switch (direction) {
            .left => self.left -|= 1,
            .down => self.top +|= 1,
            .up => self.top -|= 1,
            .right => self.left +|= 1,
        }
        self.clamp(snapshot, rows, columns);
        return previous.top != self.top or previous.left != self.left;
    }

    /// Fills one content row, padding beyond end-of-line/file with spaces.
    /// Does not mutate the snapshot or allocate. All output is printable ASCII.
    pub fn renderRow(self: Viewport, snapshot: Snapshot, row: usize, output: []u8) void {
        if (self.top >= snapshot.line_starts.len or row >= snapshot.line_starts.len - self.top) {
            @memset(output, ' ');
            return;
        }
        renderText(snapshot.line(self.top + row), self.left, output);
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
    var snapshot = try Snapshot.fromBytes(std.testing.allocator, "a\tb\tc\nshort\n");
    defer snapshot.deinit(std.testing.allocator);
    var buffer: [12]u8 = undefined;
    var viewport: Viewport = .{ .left = 4 };
    viewport.renderRow(snapshot, 0, &buffer);
    try std.testing.expectEqualStrings("    b       ", &buffer);
    viewport.left = 7;
    viewport.renderRow(snapshot, 0, buffer[0..4]);
    try std.testing.expectEqualStrings(" b  ", buffer[0..4]);
    viewport.left = 8;
    viewport.renderRow(snapshot, 0, buffer[0..9]);
    try std.testing.expectEqualStrings("b       c", buffer[0..9]);
    viewport.left = 16;
    viewport.renderRow(snapshot, 0, buffer[0..4]);
    try std.testing.expectEqualStrings("c   ", buffer[0..4]);
    viewport.left = 0;
    viewport.renderRow(snapshot, 1, &buffer);
    try std.testing.expectEqualStrings("short       ", &buffer);
    viewport.renderRow(snapshot, 2, buffer[0..4]);
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

test "scrolling reaches every line and column and clamps at each boundary" {
    var snapshot = try Snapshot.fromBytes(std.testing.allocator, "abcdef\n12\nlast\n");
    defer snapshot.deinit(std.testing.allocator);
    var viewport: Viewport = .{};
    try std.testing.expect(!viewport.move(snapshot, 2, 3, .up));
    try std.testing.expect(!viewport.move(snapshot, 2, 3, .left));
    try std.testing.expect(viewport.move(snapshot, 2, 3, .down));
    try std.testing.expect(!viewport.move(snapshot, 2, 3, .down));
    try std.testing.expectEqual(@as(usize, 1), viewport.top);
    for (0..3) |_| try std.testing.expect(viewport.move(snapshot, 2, 3, .right));
    try std.testing.expect(!viewport.move(snapshot, 2, 3, .right));
    try std.testing.expectEqual(@as(usize, 3), viewport.left);
    try std.testing.expect(viewport.move(snapshot, 2, 3, .up));
    var buffer: [3]u8 = undefined;
    viewport.renderRow(snapshot, 0, &buffer);
    try std.testing.expectEqualStrings("def", &buffer);
    viewport.clamp(snapshot, 1, 1);
    try std.testing.expect(viewport.move(snapshot, 1, 1, .down));
    try std.testing.expect(viewport.move(snapshot, 1, 1, .down));
    try std.testing.expectEqual(@as(usize, 2), viewport.top);
    viewport.clamp(snapshot, 100, 100);
    try std.testing.expectEqualDeep(Viewport{}, viewport);
}

test "zero geometry and extreme offsets never underflow or overflow" {
    var snapshot = try Snapshot.fromBytes(std.testing.allocator, "\n\tX");
    defer snapshot.deinit(std.testing.allocator);
    var viewport: Viewport = .{ .top = std.math.maxInt(usize), .left = std.math.maxInt(usize) };
    var buffer: [3]u8 = undefined;
    viewport.renderRow(snapshot, std.math.maxInt(usize), &buffer);
    try std.testing.expectEqualStrings("   ", &buffer);
    renderText("\tX", viewport.left, &buffer);
    try std.testing.expectEqualStrings("   ", &buffer);
    viewport.clamp(snapshot, 0, 0);
    try std.testing.expectEqualDeep(Viewport{ .top = 1, .left = 8 }, viewport);
    try std.testing.expect(!viewport.move(snapshot, 0, 0, .down));
    try std.testing.expect(!viewport.move(snapshot, 0, 0, .right));
    viewport.renderRow(snapshot, 0, &.{});
    viewport.clamp(snapshot, std.math.maxInt(usize), std.math.maxInt(usize));
    try std.testing.expectEqualDeep(Viewport{}, viewport);
    var empty = try Snapshot.fromBytes(std.testing.allocator, "");
    defer empty.deinit(std.testing.allocator);
    try std.testing.expect(!viewport.move(empty, 0, 0, .down));
    try std.testing.expect(!viewport.move(empty, 0, 0, .right));
}

test "a long line can be clipped near its end without wrapping or modification" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, 100 * 1024);
    defer allocator.free(bytes);
    @memset(bytes, 'a');
    @memcpy(bytes[bytes.len - 4 ..], "tail");
    var snapshot = try Snapshot.fromBytes(allocator, bytes);
    defer snapshot.deinit(allocator);
    var viewport: Viewport = .{ .left = std.math.maxInt(usize) };
    viewport.clamp(snapshot, 1, 4);
    var buffer: [4]u8 = undefined;
    viewport.renderRow(snapshot, 0, &buffer);
    try std.testing.expectEqualStrings("tail", &buffer);
    try std.testing.expectEqualSlices(u8, bytes, snapshot.bytes);
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
