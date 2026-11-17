// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("../text/buffer.zig").Buffer;
const char = @import("../text/char.zig");

pub const Encoding = enum { utf8, utf16 };
pub const Position = struct { line: u32, character: u32 };

/// The character boundary in `buffer` that `at` names.
pub fn offset(buffer: *const Buffer, at: Position, encoding: Encoding) usize {
    const bytes = buffer.bytes();
    if (at.line >= buffer.insertionRows()) return bytes.len;
    const start = buffer.lineStart(at.line);
    const end = buffer.contentEnd(at.line);
    switch (encoding) {
        .utf8 => return char.start(bytes, start + @min(at.character, end - start)),
        .utf16 => {
            var cursor = start;
            var units: usize = 0;
            while (cursor < end) {
                const character = char.decode(bytes, cursor);
                units += units16(character);
                if (units > at.character) break;
                cursor += character.len;
            }
            return cursor;
        },
    }
}

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
    for (2..5) |column| {
        const at: Position = .{ .line = 0, .character = @intCast(column) };
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

test "a line past the end gives the end of the text" {
    var buffer = try Buffer.fromBytes(testing.allocator, "one\ntwo\n");
    defer buffer.deinit(testing.allocator);
    for ([_]Encoding{ .utf8, .utf16 }) |encoding| {
        // The empty line after the final LF exists; the one after it doesn't.
        try expectRoundTrip(&buffer, 8, encoding, .{ .line = 2, .character = 0 });
        try expectOffset(&buffer, 3, 0, encoding, 8);
        try expectOffset(&buffer, 4_000_000_000, 7, encoding, 8);
    }
    var empty = try Buffer.fromBytes(testing.allocator, "");
    defer empty.deinit(testing.allocator);
    try expectRoundTrip(&empty, 0, .utf16, .{ .line = 0, .character = 0 });
    try expectOffset(&empty, 1, 0, .utf8, 0);
}

test "invalid bytes in read-only text count as one unit each" {
    var buffer = try Buffer.fromBytes(testing.allocator, "\xff\xfex");
    defer buffer.deinit(testing.allocator);
    try testing.expect(!buffer.editable);
    try expectRoundTrip(&buffer, 2, .utf16, .{ .line = 0, .character = 2 });
    try expectRoundTrip(&buffer, 2, .utf8, .{ .line = 0, .character = 2 });
}
