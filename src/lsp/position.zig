// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("../text/buffer.zig").Buffer;
const char = @import("../text/char.zig");

pub const Encoding = enum { utf8, utf16 };
pub const Position = struct { line: u32, character: u32 };

/// The byte offset in `line`, one line's text without its line break, of the
/// character boundary that `character` names. A column past the text gives its
/// end, and one inside a character gives that character's start.
pub fn column(line: []const u8, character: u32, encoding: Encoding) usize {
    var columns: Columns = .init(line, encoding);
    return columns.at(character);
}

/// Finds columns in one line as `column` does, each UTF-16 one counted on
/// from the last found, so columns found in order cost one walk over the
/// line. Borrows `line`.
pub const Columns = struct {
    line: []const u8,
    encoding: Encoding,
    /// The last boundary found, and the UTF-16 units before it.
    byte: usize = 0,
    units: usize = 0,

    pub fn init(line: []const u8, encoding: Encoding) Columns {
        return .{ .line = line, .encoding = encoding };
    }

    pub fn at(self: *Columns, character: u32) usize {
        const line = self.line;
        switch (self.encoding) {
            .utf8 => return char.start(line, @min(character, line.len)),
            .utf16 => {
                if (character < self.units) self.* = .init(line, .utf16);
                while (self.byte < line.len) {
                    const decoded = char.decode(line, self.byte);
                    const units = units16(decoded);
                    if (self.units + units > character) break;
                    self.units += units;
                    self.byte += decoded.len;
                }
                return self.byte;
            },
        }
    }
};

/// The position of a character boundary `at` in `buffer`.
pub fn position(buffer: *const Buffer, at: usize, encoding: Encoding) Position {
    const bytes = buffer.bytes();
    const row = buffer.rowAt(at);
    const start = buffer.lineStart(row);
    const end = @min(at, buffer.contentEnd(row));
    const character = switch (encoding) {
        .utf8 => end - start,
        .utf16 => count: {
            var cursor = start;
            var units: usize = 0;
            while (cursor < end) {
                const decoded = char.decode(bytes, cursor);
                units += units16(decoded);
                cursor += decoded.len;
            }
            break :count units;
        },
    };
    // The size caps keep lines and columns far below 2^32.
    return .{ .line = @intCast(row), .character = @intCast(character) };
}

/// UTF-16 code units for one decoded character.
fn units16(character: char.Character) usize {
    const code = character.code orelse return 1;
    return if (code >= 0x10000) 2 else 1;
}

const testing = std.testing;

/// The character boundary in `buffer` that `at` names, converted from its
/// line's text as Locations rows are.
fn offset(buffer: *const Buffer, at: Position, encoding: Encoding) usize {
    return buffer.lineStart(at.line) + column(buffer.line(at.line), at.character, encoding);
}

fn expectRoundTrip(
    buffer: *const Buffer,
    at: usize,
    encoding: Encoding,
    expected: Position,
) !void {
    const found = position(buffer, at, encoding);
    try testing.expectEqual(expected, found);
    try testing.expectEqual(at, offset(buffer, found, encoding));
}

fn expectOffset(
    buffer: *const Buffer,
    line: u32,
    character: u32,
    encoding: Encoding,
    expected: usize,
) !void {
    const at: Position = .{ .line = line, .character = character };
    try testing.expectEqual(expected, offset(buffer, at, encoding));
}

test "UTF-8 and UTF-16 columns count the same text differently" {
    // "é" is 2 bytes and 1 unit; "😀" is 4 bytes and a surrogate pair.
    var buffer = try Buffer.fromBytes(testing.allocator, "aé😀b\n");
    defer buffer.deinit(testing.allocator);
    try expectRoundTrip(&buffer, 0, .utf8, .{ .line = 0, .character = 0 });
    try expectRoundTrip(&buffer, 1, .utf8, .{ .line = 0, .character = 1 });
    try expectRoundTrip(&buffer, 3, .utf8, .{ .line = 0, .character = 3 });
    try expectRoundTrip(&buffer, 7, .utf8, .{ .line = 0, .character = 7 });
    try expectRoundTrip(&buffer, 1, .utf16, .{ .line = 0, .character = 1 });
    try expectRoundTrip(&buffer, 3, .utf16, .{ .line = 0, .character = 2 });
    try expectRoundTrip(&buffer, 7, .utf16, .{ .line = 0, .character = 4 });
    try expectRoundTrip(&buffer, 8, .utf16, .{ .line = 0, .character = 5 });
}

test "a column inside a character lands on its start" {
    var buffer = try Buffer.fromBytes(testing.allocator, "a😀b");
    defer buffer.deinit(testing.allocator);
    // Between the two units of the surrogate pair.
    try expectOffset(&buffer, 0, 2, .utf16, 1);
    // Inside the UTF-8 sequence.
    for (2..5) |character| {
        const at: Position = .{ .line = 0, .character = @intCast(character) };
        try testing.expectEqual(@as(usize, 1), offset(&buffer, at, .utf8));
    }
}

test "columns past a line's text stop before its line break, CRLF included" {
    var buffer = try Buffer.fromBytes(testing.allocator, "ab\r\ncd\nef");
    defer buffer.deinit(testing.allocator);
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        try expectOffset(&buffer, 0, 2, encoding, 2);
        try expectOffset(&buffer, 0, 99, encoding, 2);
        try expectOffset(&buffer, 1, 99, encoding, 6);
        try expectOffset(&buffer, 2, 99, encoding, 9);
        try expectRoundTrip(&buffer, 4, encoding, .{ .line = 1, .character = 0 });
        try expectRoundTrip(&buffer, 8, encoding, .{ .line = 2, .character = 1 });
        // The CR of a CRLF is the end of the line's text.
        const break_start = position(&buffer, 3, encoding);
        try testing.expectEqual(Position{ .line = 0, .character = 2 }, break_start);
    }
}

test "the empty line after a final LF, and in an empty text, has a position" {
    var buffer = try Buffer.fromBytes(testing.allocator, "one\ntwo\n");
    defer buffer.deinit(testing.allocator);
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        try expectRoundTrip(&buffer, 8, encoding, .{ .line = 2, .character = 0 });
    }
    var empty = try Buffer.fromBytes(testing.allocator, "");
    defer empty.deinit(testing.allocator);
    try expectRoundTrip(&empty, 0, .utf16, .{ .line = 0, .character = 0 });
}

test "invalid bytes in read-only text count as one unit each" {
    var buffer = try Buffer.fromBytes(testing.allocator, "\xff\xfex");
    defer buffer.deinit(testing.allocator);
    try testing.expect(!buffer.editable);
    try expectRoundTrip(&buffer, 2, .utf16, .{ .line = 0, .character = 2 });
    try expectRoundTrip(&buffer, 2, .utf8, .{ .line = 0, .character = 2 });
}

test "a column is found from one line's text alone" {
    // "a", "é" (2 bytes, 1 unit), "😀" (4 bytes, 2 units), "b".
    const line = "a\xc3\xa9\xf0\x9f\x98\x80b";
    const utf8 = [_][2]usize{ .{ 0, 0 }, .{ 2, 1 }, .{ 3, 3 }, .{ 6, 3 }, .{ 7, 7 }, .{ 99, 8 } };
    for (utf8) |case| try testing.expectEqual(case[1], column(line, @intCast(case[0]), .utf8));
    const utf16 = [_][2]usize{ .{ 1, 1 }, .{ 2, 3 }, .{ 3, 3 }, .{ 4, 7 }, .{ 5, 8 }, .{ 99, 8 } };
    for (utf16) |case| try testing.expectEqual(case[1], column(line, @intCast(case[0]), .utf16));
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        try testing.expectEqual(@as(usize, 0), column("", 5, encoding));
        try testing.expectEqual(@as(usize, 2), column("\xff\xfex", 2, encoding));
    }
}

test "columns found in order or out of order agree with columns found alone" {
    const line = "a\xc3\xa9\xf0\x9f\x98\x80b\tc";
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        var columns: Columns = .init(line, encoding);
        for ([_]u32{ 0, 1, 2, 3, 3, 4, 9, 2, 0, 5, 99, 6 }) |character| {
            try testing.expectEqual(column(line, character, encoding), columns.at(character));
        }
    }
}
