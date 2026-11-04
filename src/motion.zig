// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Range = @import("buffer.zig").Range;
const cellWidth = @import("buffer.zig").cellWidth;

pub const Motion = enum { left, down, up, right, start, first, end, word, back, word_end, first_line, last_line };
pub const Operator = enum { delete, change };
pub const Shape = enum { exclusive, inclusive, linewise };
// null means end-of-line affinity, rather than a large artificial column.
pub const Goal = ?usize;
pub const Result = struct { destination: usize, shape: Shape, goal: Goal };
pub const Selection = struct { range: Range, linewise: bool };

pub fn column(buffer: *const Buffer, offset: usize) usize {
    var result: usize = 0;
    for (buffer.bytes()[buffer.starts.items[buffer.rowAt(offset)]..offset]) |byte| result += cellWidth(byte, result);
    return result;
}

pub fn normal(buffer: *const Buffer, offset: usize) usize {
    const row = @min(buffer.rowAt(@min(offset, buffer.bytes().len)), buffer.lineCount() - 1);
    return @min(offset, last(buffer, row));
}

fn last(buffer: *const Buffer, row: usize) usize {
    return buffer.starts.items[row] + (buffer.line(row).len -| 1);
}

fn first(buffer: *const Buffer, row: usize) usize {
    const text = buffer.line(row);
    for (text, 0..) |byte, index| {
        if (byte != ' ' and byte != '\t') return buffer.starts.items[row] + index;
    }
    return last(buffer, row);
}

/// A normal cursor on a tab occupies its final display cell, as in Vim.
/// No virtual positions inside the tab are introduced.
pub fn screenColumn(buffer: *const Buffer, offset: usize, insert: bool) usize {
    const start = column(buffer, offset);
    const row = buffer.rowAt(offset);
    if (!insert and offset < buffer.starts.items[row] + buffer.line(row).len)
        return start + cellWidth(buffer.bytes()[offset], start) - 1;
    return start;
}

fn atColumn(buffer: *const Buffer, row: usize, goal: Goal) usize {
    if (goal == null) return last(buffer, row);
    var col: usize = 0;
    const start = buffer.starts.items[row];
    for (buffer.line(row), 0..) |byte, index| {
        const width = cellWidth(byte, col);
        if (col + width > goal.?) return start + index;
        col += width;
    }
    return last(buffer, row);
}

fn next(buffer: *const Buffer, offset: usize) usize {
    if (offset == buffer.bytes().len) return offset;
    return offset + if (buffer.bytes()[offset] == '\r' and offset + 1 < buffer.bytes().len and buffer.bytes()[offset + 1] == '\n') @as(usize, 2) else 1;
}

fn previous(buffer: *const Buffer, offset: usize) usize {
    if (offset == 0) return 0;
    return offset - if (offset >= 2 and std.mem.eql(u8, buffer.bytes()[offset - 2 .. offset], "\r\n")) @as(usize, 2) else 1;
}

const Class = enum { blank, keyword, punctuation, empty };
fn class(buffer: *const Buffer, offset: usize) Class {
    if (offset == buffer.bytes().len) return .blank;
    const byte = buffer.bytes()[offset];
    if (byte == '\n' or (byte == '\r' and offset + 1 < buffer.bytes().len and buffer.bytes()[offset + 1] == '\n')) {
        if (offset == 0 or buffer.bytes()[offset - 1] == '\n') return .empty;
        return .blank;
    }
    if (byte == ' ' or byte == '\t') return .blank;
    if (std.ascii.isAlphanumeric(byte) or byte == '_') return .keyword;
    return .punctuation;
}

fn word(buffer: *const Buffer, offset: usize, motion: Motion) usize {
    var pos = offset;
    if (motion == .back) {
        if (pos == 0) return pos;
        pos = previous(buffer, pos);
        while (pos != 0 and class(buffer, pos) == .blank) pos = previous(buffer, pos);
        const kind = class(buffer, pos);
        if (kind == .empty) return pos;
        while (pos != 0 and class(buffer, previous(buffer, pos)) == kind) pos = previous(buffer, pos);
    } else if (motion == .word) {
        const kind = class(buffer, pos);
        if (kind == .empty) pos = next(buffer, pos) else {
            while (pos < buffer.bytes().len and class(buffer, pos) == kind) pos = next(buffer, pos);
        }
        while (pos < buffer.bytes().len and class(buffer, pos) == .blank) pos = next(buffer, pos);
    } else {
        pos = next(buffer, pos);
        while (pos < buffer.bytes().len and (class(buffer, pos) == .blank or class(buffer, pos) == .empty)) pos = next(buffer, pos);
        const kind = class(buffer, pos);
        while (pos < buffer.bytes().len and next(buffer, pos) < buffer.bytes().len and class(buffer, next(buffer, pos)) == kind) pos = next(buffer, pos);
    }
    return pos;
}

/// Requires a normal-mode cursor. Resolves without moving it or mutating text.
/// null is a failed motion. Counts saturate at text boundaries, never loop over
/// absent text. Explicit count matters for G; 0 is invalid at this boundary.
pub fn resolve(buffer: *const Buffer, goal: Goal, motion: Motion, count: ?usize, operator: ?Operator) ?Result {
    const amount = count orelse 1;
    if (amount == 0) return null;
    const origin = normal(buffer, buffer.cursor);
    std.debug.assert(origin == buffer.cursor);
    const row = buffer.rowAt(origin);
    const start = buffer.starts.items[row];
    var destination = origin;
    var shape: Shape = .exclusive;
    var new_goal = goal;
    switch (motion) {
        .left => destination = origin - @min(amount, origin - start),
        .right => destination = @min(origin +| amount, start + buffer.line(row).len - @intFromBool(operator == null and buffer.line(row).len != 0)),
        .start => destination = start,
        .first => destination = first(buffer, row),
        .end => {
            if (amount > 1 and row == buffer.lineCount() - 1) return null;
            destination = last(buffer, @min(row +| (amount - 1), buffer.lineCount() - 1));
            shape = .inclusive;
            new_goal = null;
        },
        .down, .up => {
            const target = if (motion == .down) @min(row +| amount, buffer.lineCount() - 1) else row -| amount;
            if (target == row) return null;
            destination = atColumn(buffer, target, goal);
            shape = .linewise;
        },
        .first_line, .last_line => {
            const target = @min(if (count) |n| n - 1 else if (motion == .first_line) 0 else buffer.lineCount() - 1, buffer.lineCount() - 1);
            destination = first(buffer, target);
            shape = .linewise;
        },
        .word, .back, .word_end => {
            const change_word = operator == .change and motion == .word and class(buffer, origin) != .blank and class(buffer, origin) != .empty;
            const actual: Motion = if (change_word) .word_end else motion;
            shape = if (actual == .word_end) .inclusive else .exclusive;
            var remaining = amount;
            while (remaining != 0) : (remaining -= 1) {
                const before = destination;
                const first_change = change_word and remaining == amount;
                // cw includes the current word even when already on its end.
                if (first_change) {
                    const kind = class(buffer, destination);
                    while (next(buffer, destination) < buffer.bytes().len and class(buffer, next(buffer, destination)) == kind) destination = next(buffer, destination);
                } else destination = word(buffer, destination, actual);
                if (operator != null and actual == .word and remaining == 1 and buffer.rowAt(destination) > buffer.rowAt(before) and class(buffer, before) != .empty) {
                    // The final w step stops at this line's end for operators.
                    destination = buffer.starts.items[buffer.rowAt(before)] + buffer.line(buffer.rowAt(before)).len;
                }
                if (operator != null and actual == .word and destination == buffer.bytes().len) {
                    const final_row = buffer.lineCount() - 1;
                    destination = buffer.starts.items[final_row] + buffer.line(final_row).len;
                }
                if (operator != null and actual == .back and destination == 0 and remaining > 1 and class(buffer, 0) == .empty) return null;
                if ((destination == before and !first_change) or (destination == 0 and actual == .back) or destination == buffer.bytes().len) break;
            }
            if (operator == null or shape == .inclusive) destination = normal(buffer, destination);
        },
    }
    if (motion != .up and motion != .down and motion != .end) new_goal = screenColumn(buffer, normal(buffer, destination), false);
    // Inclusive motions still operate on the character when already there.
    if (destination == origin and shape == .exclusive and !(operator == null and (motion == .start or motion == .first))) return null;
    return .{ .destination = destination, .shape = shape, .goal = new_goal };
}

/// Resolves the same unchanged normal cursor and motion to a byte selection.
/// Includes CRLF as a unit. Linewise EOF deletion also
/// consumes the preceding terminator when the final line is unterminated.
/// Change callers keep a linewise replacement's line break when inserting.
pub fn operatorRange(buffer: *const Buffer, result: Result, operator: Operator) Selection {
    var low = @min(buffer.cursor, result.destination);
    var high = @max(buffer.cursor, result.destination);
    var shape = result.shape;
    const low_row = buffer.rowAt(low);
    var high_row = buffer.rowAt(high);
    if (shape == .exclusive and high_row > low_row and high == buffer.starts.items[high_row]) {
        if (low <= first(buffer, low_row)) {
            shape = .linewise;
            high_row -= 1;
        } else {
            high = buffer.starts.items[high_row - 1] + buffer.line(high_row - 1).len;
        }
    }
    // Vim's delete promotes a cross-line range when only indentation precedes
    // it and only whitespace follows it, avoiding a leftover blank line.
    if (operator == .delete and shape != .linewise and high_row > low_row and low <= first(buffer, low_row)) {
        const content_end = buffer.starts.items[high_row] + buffer.line(high_row).len;
        const after = @min(content_end, high + @intFromBool(shape == .inclusive and high < content_end));
        if (std.mem.trim(u8, buffer.bytes()[after..content_end], " \t").len == 0) shape = .linewise;
    }
    if (shape == .linewise) {
        low = buffer.starts.items[low_row];
        high = buffer.lineRange(high_row).end;
        if (operator == .delete and high == buffer.bytes().len and high_row == buffer.lineCount() - 1 and low != 0 and (high == 0 or buffer.bytes()[high - 1] != '\n')) low = previous(buffer, low);
    } else if (shape == .inclusive and high < buffer.starts.items[high_row] + buffer.line(high_row).len) {
        high = next(buffer, high);
    }
    return .{ .range = .{ .start = low, .end = high }, .linewise = shape == .linewise };
}

const expect = std.testing.expectEqual;

test "normal boundaries, horizontal counts, and line destinations" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "  alpha\r\n\t\nlast\n");
    defer buffer.deinit(std.testing.allocator);
    try expect(@as(usize, 14), normal(&buffer, buffer.bytes().len));
    try expect(@as(usize, 6), resolve(&buffer, 0, .right, std.math.maxInt(usize), null).?.destination);
    try expect(@as(usize, 7), resolve(&buffer, 0, .right, std.math.maxInt(usize), .delete).?.destination);
    try expect(@as(usize, 2), resolve(&buffer, 0, .first, null, null).?.destination);
    try expect(@as(usize, 11), resolve(&buffer, 0, .last_line, null, null).?.destination);
    try expect(@as(usize, 9), resolve(&buffer, 0, .last_line, 2, null).?.destination);
    buffer.cursor = 5;
    try expect(@as(usize, 0), resolve(&buffer, 5, .left, std.math.maxInt(usize), null).?.destination);
    try expect(@as(usize, 0), resolve(&buffer, 5, .start, null, null).?.destination);
    buffer.cursor = 14;
    try std.testing.expect(resolve(&buffer, 4, .down, 1, null) == null);
    try std.testing.expect(resolve(&buffer, 4, .end, 2, null) == null);
    try std.testing.expect(resolve(&buffer, 4, .word, 0, null) == null);
}

test "vertical motion retains display goal and end affinity through short and tabbed lines" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "0123456789\nx\n\tab\n\nabcdefghijk");
    defer buffer.deinit(std.testing.allocator);
    buffer.cursor = 5;
    var result = resolve(&buffer, 5, .down, 1, null).?;
    try expect(@as(usize, 11), result.destination);
    buffer.cursor = result.destination;
    result = resolve(&buffer, result.goal, .down, 1, null).?;
    try expect(@as(usize, 13), result.destination);
    try expect(@as(usize, 7), screenColumn(&buffer, result.destination, false));
    try expect(@as(usize, 0), screenColumn(&buffer, result.destination, true));
    buffer.cursor = result.destination;
    result = resolve(&buffer, result.goal, .down, 2, null).?;
    try expect(@as(usize, 23), result.destination);
    buffer.cursor = 0;
    result = resolve(&buffer, 0, .end, null, null).?;
    try std.testing.expect(result.goal == null);
    buffer.cursor = result.destination;
    result = resolve(&buffer, result.goal, .down, 4, null).?;
    try expect(@as(usize, 28), result.destination);
    try std.testing.expect(result.goal == null);
}

test "word classes, empty lines, CRLF, counts and bounded traversal" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "one_two++ x\r\n\r\nlast!");
    defer buffer.deinit(std.testing.allocator);
    const steps = [_]struct { motion: Motion, from: usize, to: usize }{
        .{ .motion = .word, .from = 0, .to = 7 },
        .{ .motion = .word, .from = 7, .to = 10 },
        .{ .motion = .word, .from = 10, .to = 13 },
        .{ .motion = .word, .from = 13, .to = 15 },
        .{ .motion = .back, .from = 15, .to = 13 },
        .{ .motion = .back, .from = 13, .to = 10 },
        .{ .motion = .word_end, .from = 0, .to = 6 },
        .{ .motion = .word_end, .from = 10, .to = 18 },
    };
    for (steps) |step| {
        buffer.cursor = step.from;
        try expect(step.to, resolve(&buffer, 0, step.motion, null, null).?.destination);
    }
    buffer.cursor = 0;
    try expect(@as(usize, 19), resolve(&buffer, 0, .word, std.math.maxInt(usize), null).?.destination);
    buffer.cursor = 19;
    try expect(@as(usize, 0), resolve(&buffer, 0, .back, std.math.maxInt(usize), null).?.destination);
}

test "operator fixtures resolve independently without moving the cursor or editing" {
    const Case = struct { text: []const u8, cursor: usize = 0, motion: Motion, count: ?usize = null, operator: Operator = .delete, expected: []const u8, linewise: ?bool = null };
    const cases = [_]Case{
        .{ .text = "one two\nthree", .motion = .word, .expected = "one " },
        .{ .text = "one two\nthree", .motion = .word, .operator = .change, .expected = "one" },
        .{ .text = "one two\nthree", .cursor = 2, .motion = .word, .operator = .change, .expected = "e" },
        .{ .text = "x y z", .motion = .word, .count = 2, .operator = .change, .expected = "x y" },
        .{ .text = "one  \r\ntwo", .motion = .word, .expected = "one  " },
        .{ .text = "one two\r\nthree", .motion = .word, .count = 2, .expected = "one two" },
        .{ .text = "one two\r\nthree", .motion = .word, .count = 3, .expected = "one two\r\nthree" },
        .{ .text = "one two", .cursor = 4, .motion = .back, .expected = "one " },
        .{ .text = "one two", .cursor = 4, .motion = .left, .expected = " " },
        .{ .text = "abc", .cursor = 2, .motion = .right, .expected = "c" },
        .{ .text = "abc\r\nnext", .motion = .down, .expected = "abc\r\nnext" },
        .{ .text = "abc\r\nnext", .cursor = 5, .motion = .last_line, .expected = "\r\nnext" },
        .{ .text = "abc\r\nnext", .cursor = 5, .motion = .last_line, .operator = .change, .expected = "next" },
        .{ .text = "abc\r\n", .cursor = 1, .motion = .end, .expected = "bc" },
        .{ .text = "\r\nnext", .motion = .end, .expected = "" },
        .{ .text = "abc\r\n", .motion = .last_line, .expected = "abc\r\n" },
        .{ .text = "  abc\r\nnext\r\nmore", .cursor = 1, .motion = .end, .count = 2, .expected = "  abc\r\nnext\r\n", .linewise = true },
        .{ .text = "  abc\r\nnext\r\nmore", .cursor = 1, .motion = .end, .count = 2, .operator = .change, .expected = " abc\r\nnext", .linewise = false },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(std.testing.allocator, case.text);
        defer buffer.deinit(std.testing.allocator);
        buffer.cursor = case.cursor;
        const result = resolve(&buffer, 0, case.motion, case.count, case.operator).?;
        const selection = operatorRange(&buffer, result, case.operator);
        if (case.linewise) |expected| try expect(expected, selection.linewise);
        const range = selection.range;
        try std.testing.expectEqualStrings(case.expected, buffer.bytes()[range.start..range.end]);
        try expect(case.cursor, buffer.cursor);
        try std.testing.expectEqualStrings(case.text, buffer.bytes());
        try std.testing.expect(!buffer.modified());
    }
}

test "zero and first reset end affinity even without changing the byte cursor" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "a\n\nabcdef");
    defer buffer.deinit(std.testing.allocator);
    buffer.cursor = 2;
    for ([_]Motion{ .start, .first }) |command| {
        const reset = resolve(&buffer, null, command, null, null).?;
        try expect(@as(Goal, 0), reset.goal);
        try expect(@as(usize, 3), resolve(&buffer, reset.goal, .down, 1, null).?.destination);
    }
    try std.testing.expect(resolve(&buffer, null, .left, null, null) == null);
    try expect(@as(usize, 8), resolve(&buffer, null, .down, 1, null).?.destination);
}

test "word operators respect empty EOF and exclusive column-one conversion" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "abc\r\n\r\n");
    defer buffer.deinit(std.testing.allocator);
    buffer.cursor = 1;
    const result = resolve(&buffer, 1, .word, 2, .delete).?;
    const selection = operatorRange(&buffer, result, .delete);
    try std.testing.expectEqualStrings("bc", buffer.bytes()[selection.range.start..selection.range.end]);
    try std.testing.expect(!selection.linewise);
    buffer.cursor = 5;
    try std.testing.expect(resolve(&buffer, 0, .word, null, .delete) == null);
    buffer.cursor = 0;
    const forward = resolve(&buffer, 0, .word, 2, .delete).?;
    try std.testing.expect(operatorRange(&buffer, forward, .delete).linewise);
    var leading = try Buffer.fromBytes(std.testing.allocator, "\nabc");
    defer leading.deinit(std.testing.allocator);
    leading.cursor = 2;
    try std.testing.expect(resolve(&leading, 1, .back, 6, .delete) == null);
    leading.cursor = 1;
    const backward = resolve(&leading, 0, .back, 1, .delete).?;
    const line = operatorRange(&leading, backward, .delete);
    try std.testing.expect(line.linewise);
    try std.testing.expectEqualStrings("\n", leading.bytes()[line.range.start..line.range.end]);
}

test "empty documents have one normal position and no characterwise edit range" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "");
    defer buffer.deinit(std.testing.allocator);
    inline for (std.meta.tags(Motion)) |command| {
        for ([_]?usize{ null, 1, std.math.maxInt(usize) }) |count| {
            if (resolve(&buffer, 0, command, count, null)) |result| try expect(@as(usize, 0), result.destination);
            if (resolve(&buffer, 0, command, count, .delete)) |result| {
                try std.testing.expectEqualDeep(Range{ .start = 0, .end = 0 }, operatorRange(&buffer, result, .delete).range);
            }
        }
    }
}
