// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const Range = @import("buffer.zig").Range;
const char = @import("char.zig");

pub const Motion = enum { left, down, up, right, start, first, end, word, back, word_end, first_line, last_line };
pub const Operator = enum { delete, change, yank };
pub const Shape = enum { exclusive, inclusive, linewise };
// null means end-of-line affinity, rather than a large artificial column.
pub const Goal = ?usize;
pub const Result = struct { destination: usize, shape: Shape, goal: Goal };
/// `copied` is what a register receives. It differs from `range` only when a
/// linewise delete at EOF also takes the preceding terminator.
pub const Selection = struct { range: Range, copied: Range, linewise: bool };
/// A visual selection's kind: `v` selects characters, `V` whole lines.
pub const Visual = enum { characterwise, linewise };

/// Display cells from the line start to a character boundary `offset`.
pub fn column(buffer: *const Buffer, offset: usize) usize {
    const bytes = buffer.bytes();
    var position = buffer.lineStart(buffer.rowAt(offset));
    var result: usize = 0;
    while (position < offset) {
        const character = measure(bytes, position, result);
        result += character.cells;
        position += character.len;
    }
    return result;
}

/// The normal-mode position for any offset: clamped to its line's last
/// character, then moved back to the start of the character containing it.
pub fn normal(buffer: *const Buffer, offset: usize) usize {
    const clamped = @min(offset, buffer.bytes().len);
    const row = @min(buffer.rowAt(clamped), buffer.lineCount() - 1);
    return char.start(buffer.bytes(), @min(clamped, last(buffer, row)));
}

fn last(buffer: *const Buffer, row: usize) usize {
    const start = buffer.lineStart(row);
    const end = buffer.contentEnd(row);
    return if (end == start) start else char.previous(buffer.bytes(), end);
}

fn first(buffer: *const Buffer, row: usize) usize {
    const text = buffer.line(row);
    for (text, 0..) |byte, index| {
        if (byte != ' ' and byte != '\t') return buffer.lineStart(row) + index;
    }
    return last(buffer, row);
}

/// The display cells a cursor covers, from `column`.
pub const Cells = struct { column: usize, width: usize };

/// A normal cursor on a tab occupies its final display cell, as in Vim, and on
/// a wide character both of its cells. An insert cursor, or one at a line end,
/// is one cell. No virtual positions inside a character are introduced.
pub fn screenCells(buffer: *const Buffer, offset: usize, insert: bool) Cells {
    const start = column(buffer, offset);
    const row = buffer.rowAt(offset);
    const end = buffer.contentEnd(row);
    if (insert or offset == end) return .{ .column = start, .width = 1 };
    const code = char.decode(buffer.bytes(), offset).code;
    const width = char.cells(code, start);
    if (code != null and code.? == '\t') return .{ .column = start + width - 1, .width = 1 };
    return .{ .column = start, .width = width };
}

pub fn screenColumn(buffer: *const Buffer, offset: usize, insert: bool) usize {
    return screenCells(buffer, offset, insert).column;
}

/// The character covering display cell `goal`, so a goal inside a wide
/// character or a tab selects it.
fn atColumn(buffer: *const Buffer, row: usize, goal: Goal) usize {
    const target = goal orelse return last(buffer, row);
    const bytes = buffer.bytes();
    const end = buffer.contentEnd(row);
    var position = buffer.lineStart(row);
    var col: usize = 0;
    while (position < end) {
        const character = measure(bytes, position, col);
        col += character.cells;
        if (col > target) return position;
        position += character.len;
    }
    return last(buffer, row);
}

// The cells and length of a line's character at `position`, starting at
// display column `col`. ASCII, most text, skips decoding.
fn measure(bytes: []const u8, position: usize, col: usize) struct { cells: usize, len: usize } {
    const byte = bytes[position];
    if (byte < 0x80) return .{ .cells = char.cells(byte, col), .len = 1 };
    const character = char.decode(bytes, position);
    return .{ .cells = char.cells(character.code, col), .len = character.len };
}

fn next(buffer: *const Buffer, offset: usize) usize {
    return char.next(buffer.bytes(), offset);
}

fn previous(buffer: *const Buffer, offset: usize) usize {
    return char.previous(buffer.bytes(), offset);
}

const Class = enum { blank, keyword, punctuation, empty };
fn class(buffer: *const Buffer, offset: usize) Class {
    const bytes = buffer.bytes();
    if (offset == bytes.len) return .blank;
    const byte = bytes[offset];
    if (byte == '\n' or (byte == '\r' and offset + 1 < bytes.len and bytes[offset + 1] == '\n')) {
        if (offset == 0 or bytes[offset - 1] == '\n') return .empty;
        return .blank;
    }
    return switch (char.class(char.decode(bytes, offset).code)) {
        .blank => .blank,
        .punctuation => .punctuation,
        .keyword => .keyword,
    };
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
    const start = buffer.lineStart(row);
    var destination = origin;
    var shape: Shape = .exclusive;
    var new_goal = goal;
    switch (motion) {
        // Steps stop at the line's edges, so huge counts cost one line.
        .left => {
            var remaining = amount;
            while (remaining != 0 and destination > start) : (remaining -= 1) {
                destination = previous(buffer, destination);
            }
        },
        .right => {
            const limit = if (operator == null) last(buffer, row) else buffer.contentEnd(row);
            var remaining = amount;
            while (remaining != 0 and destination < limit) : (remaining -= 1) {
                destination = next(buffer, destination);
            }
        },
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
                    destination = buffer.contentEnd(buffer.rowAt(before));
                }
                if (operator != null and actual == .word and destination == buffer.bytes().len) {
                    const final_row = buffer.lineCount() - 1;
                    destination = buffer.contentEnd(final_row);
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

/// The byte selection from `origin`, the normal-mode offset `result` was
/// resolved from, to its destination. Includes CRLF as a unit. Linewise EOF
/// deletion also consumes the preceding terminator when the final line is
/// unterminated. Change callers keep a linewise replacement's line break when
/// inserting.
pub fn operatorRange(
    buffer: *const Buffer,
    origin: usize,
    result: Result,
    operator: Operator,
) Selection {
    const low = @min(origin, result.destination);
    var high = @max(origin, result.destination);
    var shape = result.shape;
    const low_row = buffer.rowAt(low);
    var high_row = buffer.rowAt(high);
    if (shape == .exclusive and high_row > low_row and high == buffer.lineStart(high_row)) {
        if (low <= first(buffer, low_row)) {
            shape = .linewise;
            high_row -= 1;
        } else {
            high = buffer.contentEnd(high_row - 1);
        }
    }
    // Vim's delete promotes a cross-line range when only indentation precedes
    // it and only whitespace follows it, avoiding a leftover blank line.
    if (operator == .delete and shape != .linewise and high_row > low_row and low <= first(buffer, low_row)) {
        const content_end = buffer.contentEnd(high_row);
        const after = @min(content_end, high + @intFromBool(shape == .inclusive and high < content_end));
        if (std.mem.trim(u8, buffer.bytes()[after..content_end], " \t").len == 0) shape = .linewise;
    }
    if (shape == .linewise) return lines(buffer, low_row, high_row, operator);
    if (shape == .inclusive and high < buffer.contentEnd(high_row)) {
        high = next(buffer, high);
    }
    const range: Range = .{ .start = low, .end = high };
    return .{ .range = range, .copied = range, .linewise = false };
}

/// The byte selection of a visual selection between `anchor` and `cursor`,
/// both normal-mode offsets, for `operator`, or for drawing when null. A
/// characterwise selection includes both ends; an end on an empty line
/// selects its line break, CRLF as a unit. None of the motion rules of
/// `operatorRange` apply.
pub fn visualRange(
    buffer: *const Buffer,
    anchor: usize,
    cursor: usize,
    kind: Visual,
    operator: ?Operator,
) Selection {
    const low = @min(anchor, cursor);
    const high = @max(anchor, cursor);
    switch (kind) {
        .linewise => return lines(buffer, buffer.rowAt(low), buffer.rowAt(high), operator),
        .characterwise => {
            const range: Range = .{ .start = low, .end = next(buffer, high) };
            return .{ .range = range, .copied = range, .linewise = false };
        },
    }
}

/// Rows `low_row` to `high_row` with their terminators. A delete reaching
/// an unterminated last line also takes the preceding terminator, so no
/// empty line is left behind.
fn lines(buffer: *const Buffer, low_row: usize, high_row: usize, operator: ?Operator) Selection {
    var low = buffer.lineStart(low_row);
    const high = buffer.lineRange(high_row).end;
    const copied: Range = .{ .start = low, .end = high };
    const unterminated = high == 0 or buffer.bytes()[high - 1] != '\n';
    const final = high == buffer.bytes().len and high_row == buffer.lineCount() - 1;
    if (operator == .delete and final and low != 0 and unterminated)
        low = previous(buffer, low);
    return .{ .range = .{ .start = low, .end = high }, .copied = copied, .linewise = true };
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
        const selection = operatorRange(&buffer, buffer.cursor, result, case.operator);
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
    const selection = operatorRange(&buffer, buffer.cursor, result, .delete);
    try std.testing.expectEqualStrings("bc", buffer.bytes()[selection.range.start..selection.range.end]);
    try std.testing.expect(!selection.linewise);
    buffer.cursor = 5;
    try std.testing.expect(resolve(&buffer, 0, .word, null, .delete) == null);
    buffer.cursor = 0;
    const forward = resolve(&buffer, 0, .word, 2, .delete).?;
    try std.testing.expect(operatorRange(&buffer, buffer.cursor, forward, .delete).linewise);
    var leading = try Buffer.fromBytes(std.testing.allocator, "\nabc");
    defer leading.deinit(std.testing.allocator);
    leading.cursor = 2;
    try std.testing.expect(resolve(&leading, 1, .back, 6, .delete) == null);
    leading.cursor = 1;
    const backward = resolve(&leading, 0, .back, 1, .delete).?;
    const line = operatorRange(&leading, leading.cursor, backward, .delete);
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
                const selection = operatorRange(&buffer, buffer.cursor, result, .delete);
                try std.testing.expectEqualDeep(Range{ .start = 0, .end = 0 }, selection.range);
            }
        }
    }
}

test "horizontal steps, line ends and display columns count characters, not bytes" {
    // a, é (2 bytes), 材 (3 bytes, two cells), U+0301 (a placeholder), b.
    var buffer = try Buffer.fromBytes(std.testing.allocator, "a\xc3\xa9\xe6\x9d\x90\xcc\x81b\r\nz");
    defer buffer.deinit(std.testing.allocator);
    const boundaries = [_]usize{ 0, 1, 3, 6, 8 };
    const columns = [_]usize{ 0, 1, 2, 4, 5 };
    for (boundaries[0 .. boundaries.len - 1], boundaries[1..]) |from, to| {
        buffer.cursor = from;
        try expect(to, resolve(&buffer, 0, .right, null, null).?.destination);
        buffer.cursor = to;
        try expect(from, resolve(&buffer, 0, .left, null, null).?.destination);
    }
    for (boundaries, columns) |offset, expected| try expect(expected, column(&buffer, offset));
    const wide = screenCells(&buffer, 3, false);
    try std.testing.expectEqualDeep(Cells{ .column = 2, .width = 2 }, wide);
    const insert = screenCells(&buffer, 3, true);
    try std.testing.expectEqualDeep(Cells{ .column = 2, .width = 1 }, insert);
    buffer.cursor = 0;
    const many = std.math.maxInt(usize);
    try expect(@as(usize, 8), resolve(&buffer, 0, .right, many, null).?.destination);
    try expect(@as(usize, 9), resolve(&buffer, 0, .right, many, .delete).?.destination);
    try expect(@as(usize, 8), resolve(&buffer, 0, .end, null, null).?.destination);
    buffer.cursor = 8;
    try expect(@as(usize, 3), resolve(&buffer, 0, .left, 2, null).?.destination);
    try std.testing.expect(resolve(&buffer, 0, .right, null, null) == null);
    // Offsets inside a sequence, a CRLF or past the end, and where they land.
    const inside = [_][2]usize{
        .{ 2, 1 }, .{ 4, 3 }, .{ 5, 3 }, .{ 7, 6 }, .{ 9, 8 }, .{ 10, 8 }, .{ 12, 11 },
    };
    for (inside) |pair| {
        try expect(pair[1], normal(&buffer, pair[0]));
    }
}

test "vertical goals count display cells and select the wide character they land in" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "\xe6\x9d\x90\xe6\x96\x99x\nabcde\n");
    defer buffer.deinit(std.testing.allocator);
    for ([_][2]usize{ .{ 9, 0 }, .{ 10, 3 }, .{ 11, 3 }, .{ 12, 6 } }) |pair| {
        buffer.cursor = pair[0];
        const goal = screenColumn(&buffer, pair[0], false);
        try expect(pair[1], resolve(&buffer, goal, .up, null, null).?.destination);
    }
    buffer.cursor = 3;
    const result = resolve(&buffer, 0, .right, null, null).?;
    try expect(@as(Goal, 4), result.goal);
    buffer.cursor = 3;
    const down = resolve(&buffer, screenColumn(&buffer, 3, false), .down, null, null).?;
    try expect(@as(usize, 10), down.destination);
}

test "word motions and operators step whole characters with Unicode classes" {
    // foo — bar naïve 材料abc ✅ok: the dash and the emoji are punctuation.
    const text = "foo\xe2\x80\x94bar na\xc3\xafve \xe6\x9d\x90\xe6\x96\x99abc \xe2\x9c\x85ok";
    var buffer = try Buffer.fromBytes(std.testing.allocator, text);
    defer buffer.deinit(std.testing.allocator);
    const steps = [_]struct { motion: Motion, from: usize, to: usize }{
        .{ .motion = .word, .from = 0, .to = 3 },
        .{ .motion = .word, .from = 3, .to = 6 },
        .{ .motion = .word, .from = 6, .to = 10 },
        .{ .motion = .word, .from = 10, .to = 17 },
        .{ .motion = .word, .from = 17, .to = 27 },
        .{ .motion = .word, .from = 27, .to = 30 },
        .{ .motion = .back, .from = 30, .to = 27 },
        .{ .motion = .back, .from = 27, .to = 17 },
        .{ .motion = .back, .from = 6, .to = 3 },
        .{ .motion = .word_end, .from = 0, .to = 2 },
        .{ .motion = .word_end, .from = 2, .to = 3 },
        .{ .motion = .word_end, .from = 10, .to = 15 },
        .{ .motion = .word_end, .from = 16, .to = 25 },
        .{ .motion = .word_end, .from = 25, .to = 27 },
    };
    for (steps) |step| {
        buffer.cursor = step.from;
        try expect(step.to, resolve(&buffer, 0, step.motion, null, null).?.destination);
    }
    const Case = struct { cursor: usize, motion: Motion, operator: Operator, expected: []const u8 };
    const cases = [_]Case{
        .{ .cursor = 3, .motion = .word, .operator = .delete, .expected = "\xe2\x80\x94" },
        .{ .cursor = 10, .motion = .word, .operator = .change, .expected = "na\xc3\xafve" },
        .{ .cursor = 10, .motion = .word_end, .operator = .delete, .expected = "na\xc3\xafve" },
        .{ .cursor = 17, .motion = .right, .operator = .delete, .expected = "\xe6\x9d\x90" },
        .{ .cursor = 27, .motion = .left, .operator = .delete, .expected = " " },
        .{ .cursor = 30, .motion = .back, .operator = .delete, .expected = "\xe2\x9c\x85" },
        .{ .cursor = 27, .motion = .end, .operator = .delete, .expected = "\xe2\x9c\x85ok" },
    };
    for (cases) |case| {
        buffer.cursor = case.cursor;
        const result = resolve(&buffer, 0, case.motion, null, case.operator).?;
        const range = operatorRange(&buffer, buffer.cursor, result, case.operator).range;
        try std.testing.expectEqualStrings(case.expected, buffer.bytes()[range.start..range.end]);
    }
}

test "read-only invalid bytes step and occupy one cell each" {
    // A lone continuation byte and a truncated sequence are single characters.
    var buffer = try Buffer.fromBytes(std.testing.allocator, "a\x80\xc3\xa9\xe2\x82");
    defer buffer.deinit(std.testing.allocator);
    var destinations: [5]usize = undefined;
    for (&destinations) |*destination| {
        destination.* = buffer.cursor;
        if (resolve(&buffer, 0, .right, null, null)) |result| buffer.cursor = result.destination;
    }
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2, 4, 5 }, &destinations);
    try expect(@as(usize, 4), column(&buffer, 5));
    try expect(@as(usize, 5), resolve(&buffer, 0, .end, null, null).?.destination);
}

test "a visual selection includes both ends, or whole lines, whichever end leads" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "ab\r\n\r\nc\u{20ac}\nlast");
    defer buffer.deinit(std.testing.allocator);
    const Case = struct { anchor: usize, cursor: usize, kind: Visual, start: usize, end: usize };
    const cases = [_]Case{
        // The last character's line break stays unselected.
        .{ .anchor = 0, .cursor = 1, .kind = .characterwise, .start = 0, .end = 2 },
        .{ .anchor = 1, .cursor = 0, .kind = .characterwise, .start = 0, .end = 2 },
        // An empty line's character is its line break, CRLF as one.
        .{ .anchor = 4, .cursor = 4, .kind = .characterwise, .start = 4, .end = 6 },
        .{ .anchor = 1, .cursor = 4, .kind = .characterwise, .start = 1, .end = 6 },
        // A multi-byte last character is taken whole.
        .{ .anchor = 6, .cursor = 7, .kind = .characterwise, .start = 6, .end = 10 },
        .{ .anchor = 7, .cursor = 1, .kind = .linewise, .start = 0, .end = 11 },
        .{ .anchor = 4, .cursor = 4, .kind = .linewise, .start = 4, .end = 6 },
    };
    for (cases) |case| {
        for ([_]?Operator{ null, .delete, .change, .yank }) |operator| {
            const selected = visualRange(&buffer, case.anchor, case.cursor, case.kind, operator);
            const expected: Range = .{ .start = case.start, .end = case.end };
            try expect(expected, selected.range);
            try expect(expected, selected.copied);
            try expect(case.kind == .linewise, selected.linewise);
        }
    }
}

test "a visual line delete of an unterminated last line takes the terminator before it" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "one\r\ntwo");
    defer buffer.deinit(std.testing.allocator);
    const deleted = visualRange(&buffer, 5, 6, .linewise, .delete);
    try expect(Range{ .start = 3, .end = 8 }, deleted.range);
    try expect(Range{ .start = 5, .end = 8 }, deleted.copied);
    for ([_]?Operator{ null, .change, .yank }) |operator| {
        const selected = visualRange(&buffer, 5, 6, .linewise, operator);
        try expect(Range{ .start = 5, .end = 8 }, selected.range);
    }
    // The whole file leaves nothing before it to take.
    try expect(Range{ .start = 0, .end = 8 }, visualRange(&buffer, 0, 7, .linewise, .delete).range);
}
