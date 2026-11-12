// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");

/// Collects output so an ordinary frame reaches the terminal in one write.
/// Larger frames flush whenever the buffer fills. The capacity holds the
/// widest possible row at 3 bytes per cell, the most a drawn character takes,
/// so a row is never split.
pub const Frame = struct {
    screen: *terminal.Terminal,
    bytes: [3 * (std.math.maxInt(u16) + 1)]u8 = undefined,
    len: usize = 0,

    pub fn append(self: *Frame, data: []const u8) terminal.Error!void {
        @memcpy(try self.reserve(data.len), data);
    }

    /// The caller fills the returned bytes before the next append or reserve.
    pub fn reserve(self: *Frame, count: usize) terminal.Error![]u8 {
        const output = try self.room(count);
        self.commit(count);
        return output[0..count];
    }

    /// At least `count` free bytes, flushing first when fewer remain. The
    /// caller fills a prefix of them, then commits its length before the next
    /// append, reserve or room.
    pub fn room(self: *Frame, count: usize) terminal.Error![]u8 {
        std.debug.assert(count <= self.bytes.len);
        if (self.bytes.len - self.len < count) try self.flush();
        return self.bytes[self.len..];
    }

    pub fn commit(self: *Frame, count: usize) void {
        std.debug.assert(count <= self.bytes.len - self.len);
        self.len += count;
    }

    /// Shows the cursor at a zero-based cell.
    pub fn cursor(self: *Frame, row: usize, column: usize) terminal.Error!void {
        var position: [48]u8 = undefined;
        const text = "\x1b[{d};{d}H\x1b[?25h";
        const sequence = std.fmt.bufPrint(&position, text, .{ row + 1, column + 1 });
        try self.append(sequence catch unreachable);
    }

    pub fn flush(self: *Frame) terminal.Error!void {
        defer self.len = 0;
        try self.screen.write(self.bytes[0..self.len]);
    }
};

/// Sets the system clipboard to `text` with OSC 52, base64 encoded in whole
/// 3-byte groups straight into `sink`, which has Frame's `append`, `room`
/// and `commit`, so the encoding is never held whole.
pub fn setClipboard(sink: anytype, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    try sink.append("\x1b]52;c;");
    var rest = text;
    while (rest.len != 0) {
        const output = try sink.room(4);
        const taken = @min(rest.len, output.len / 4 * 3);
        sink.commit(encoder.encode(output, rest[0..taken]).len);
        rest = rest[taken..];
    }
    try sink.append("\x07");
}

/// Fills a row left to right with printable ASCII, then spaces.
pub const Line = struct {
    output: []u8,
    used: usize = 0,

    pub fn init(output: []u8) Line {
        @memset(output, ' ');
        return .{ .output = output };
    }

    pub fn left(self: *const Line) usize {
        return self.output.len - self.used;
    }

    pub fn put(self: *Line, text: []const u8) void {
        const count = @min(text.len, self.left());
        for (self.output[self.used..][0..count], text[0..count]) |*cell, byte| {
            cell.* = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
        }
        self.used += count;
    }
};

test "a row of 3-byte characters at the widest terminal fits the frame unsplit" {
    const columns = std.math.maxInt(u16);
    const text = try std.testing.allocator.alloc(u8, 3 * columns);
    defer std.testing.allocator.free(text);
    for (0..columns) |index| @memcpy(text[3 * index ..][0..3], "\u{2014}");
    var frame: Frame = .{ .screen = undefined };
    const output = try frame.room(3 * columns);
    frame.commit(view.renderText(text, 0, columns, output));
    try std.testing.expectEqualSlices(u8, text, frame.bytes[0..frame.len]);
}

const Allocator = std.mem.Allocator;
const view = @import("view.zig");

test "status lines show only printable ASCII and stop at the row's end" {
    var row: [8]u8 = undefined;
    var line: Line = .init(&row);
    line.put("a\x1b[2J");
    line.put("\xffbcdef");
    try std.testing.expectEqualStrings("a?[2J?bc", &row);
    try std.testing.expectEqual(@as(usize, 0), line.left());
}

test "the clipboard gets one OSC 52 of the text's base64 however the frame splits it" {
    const allocator = std.testing.allocator;
    const largest = @import("editor.zig").clipboard_limit;
    const text = try allocator.alloc(u8, largest);
    defer allocator.free(text);
    for (text, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% index / 251);
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    var output: std.ArrayList(u8) = .empty;
    defer output.deinit(allocator);
    const frame_size = @sizeOf(@FieldType(Frame, "bytes"));
    for ([_]usize{ 0, 1, 2, 3, 4, 5, 6, 7, largest }) |size| {
        const encoded_size = std.base64.standard.Encoder.calcSize(size);
        try expected.resize(allocator, encoded_size);
        const encoded = std.base64.standard.Encoder.encode(expected.items, text[0..size]);
        for ([_]usize{ 7, 8, 9, 10, 11, 64, frame_size }) |capacity| {
            output.clearRetainingCapacity();
            var sink: Collector = try .init(allocator, capacity, &output);
            defer sink.deinit(allocator);
            try setClipboard(&sink, text[0..size]);
            try sink.flush();
            const bytes = output.items;
            try std.testing.expect(std.mem.startsWith(u8, bytes, "\x1b]52;c;"));
            try std.testing.expect(std.mem.endsWith(u8, bytes, "\x07"));
            try std.testing.expectEqualStrings(encoded, bytes[7 .. bytes.len - 1]);
        }
    }
}

/// Frame's output interface, flushing into `output` whenever `capacity`
/// bytes are buffered.
const Collector = struct {
    bytes: []u8,
    len: usize = 0,
    output: *std.ArrayList(u8),

    fn init(allocator: Allocator, capacity: usize, output: *std.ArrayList(u8)) !Collector {
        return .{ .bytes = try allocator.alloc(u8, capacity), .output = output };
    }

    fn deinit(self: *Collector, allocator: Allocator) void {
        allocator.free(self.bytes);
    }

    fn append(self: *Collector, data: []const u8) !void {
        const output = try self.room(data.len);
        @memcpy(output[0..data.len], data);
        self.commit(data.len);
    }

    fn room(self: *Collector, count: usize) ![]u8 {
        std.debug.assert(count <= self.bytes.len);
        if (self.bytes.len - self.len < count) try self.flush();
        return self.bytes[self.len..];
    }

    fn commit(self: *Collector, count: usize) void {
        std.debug.assert(count <= self.bytes.len - self.len);
        self.len += count;
    }

    fn flush(self: *Collector) !void {
        try self.output.appendSlice(std.testing.allocator, self.bytes[0..self.len]);
        self.len = 0;
    }
};
