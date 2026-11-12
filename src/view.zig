// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");
const search = @import("search.zig");
const char = @import("char.zig");

/// Logical rows and display columns; the caller reserves terminal margins/status.
pub const Viewport = struct {
    top: usize = 0,
    left: usize = 0,
    /// The display column vertical motions aim for; null means line ends.
    goal: motion.Goal = 0,

    pub fn follow(self: *Viewport, buffer: *const Buffer, rows: usize, columns: usize, insert: bool) void {
        const count = if (insert) buffer.insertionRows() else buffer.lineCount();
        const row = @min(buffer.rowAt(buffer.cursor), count - 1);
        const cells = motion.screenCells(buffer, buffer.cursor, insert);
        self.top = @min(self.top, count -| @max(rows, 1));
        if (row < self.top) self.top = row else if (row - self.top >= @max(rows, 1)) self.top = row - (@max(rows, 1) - 1);
        // The whole cursor character is shown, or only its first cell when it
        // is wider than the view.
        const visible = @max(columns, 1);
        if (cells.column < self.left) {
            self.left = cells.column;
        } else if (cells.column + cells.width - self.left > visible) {
            self.left = @min(cells.column, cells.column + cells.width - visible);
        }
    }

    /// null when no content cell exists, including a one-row terminal. Returned
    /// coordinates are zero-based, relative to the content area, never status.
    pub fn cursor(self: Viewport, buffer: *const Buffer, rows: usize, columns: usize, insert: bool) ?struct { row: usize, column: usize } {
        const row = buffer.rowAt(buffer.cursor);
        const col = motion.screenColumn(buffer, buffer.cursor, insert);
        if (row < self.top or col < self.left or row - self.top >= rows or col - self.left >= columns) return null;
        return .{ .row = row - self.top, .column = col - self.left };
    }

    /// Draws content row `row` into `columns` cells; see `renderText`. A row
    /// past the text is blank. Returns the bytes used.
    pub fn renderRow(
        self: Viewport,
        buffer: *const Buffer,
        row: usize,
        columns: usize,
        output: []u8,
    ) usize {
        if (self.top >= buffer.insertionRows() or row >= buffer.insertionRows() - self.top) {
            @memset(output[0..columns], ' ');
            return columns;
        }
        return renderText(buffer.line(self.top + row), self.left, columns, output);
    }
};

/// Draws one line of text, without its terminator, from display column `left`
/// into exactly `columns` cells. Allowlisted characters are copied as they are,
/// a tab is spaces to the next eight-column stop from the start of `text`, and
/// anything else (controls, invalid bytes, unlisted characters) is one `?`
/// cell. A wide character cut by either edge shows its visible cell as a space.
/// `output` holds at least `3 * columns` bytes, which bounds any row because no
/// drawn character takes more than 3 bytes per cell. Returns the bytes used.
pub fn renderText(text: []const u8, left: usize, columns: usize, output: []u8) usize {
    std.debug.assert(output.len >= 3 * columns);
    const right = left +| columns;
    var used: usize = 0;
    var column: usize = 0;
    var position: usize = 0;
    while (position < text.len and column < right) {
        const byte = text[position];
        var len: usize = 1;
        var cells: usize = 1;
        // Spaces when null.
        var glyph: ?[]const u8 = "?";
        if (byte < 0x80) {
            if (byte == '\t') {
                cells = char.cells('\t', column);
                glyph = null;
            } else if (byte >= 0x20 and byte < 0x7f) glyph = text[position..][0..1];
        } else {
            const character = char.decode(text, position);
            len = character.len;
            if (character.code) |code| if (char.width(code)) |width| {
                cells = width;
                glyph = text[position..][0..len];
            };
        }
        const end = column + cells;
        if (end > left) {
            const whole = column >= left and end <= right;
            if (whole and glyph != null) {
                @memcpy(output[used..][0..glyph.?.len], glyph.?);
                used += glyph.?.len;
            } else {
                const visible = @min(end, right) - @max(column, left);
                @memset(output[used..][0..visible], ' ');
                used += visible;
            }
        }
        column = end;
        position += len;
    }
    const drawn = @min(column, right) -| left;
    @memset(output[used..][0 .. columns - drawn], ' ');
    return used + columns - drawn;
}

/// The visible parts of a search query's matches in one line, as `renderText`
/// places that line from display column `left` in `columns` cells. A match is
/// printable ASCII, one cell per byte, because the query is and folding is
/// ASCII only; an ASCII byte never belongs to a longer character, so every
/// match starts on a character boundary. Borrows `text` and `query`.
pub const Highlights = struct {
    spans: search.Spans,
    left: usize,
    right: usize,
    column: usize = 0,
    position: usize = 0,

    /// Requires a printable ASCII query; `text` excludes the line break.
    pub fn init(text: []const u8, query: []const u8, left: usize, columns: usize) Highlights {
        return .{ .spans = .init(text, query), .left = left, .right = left +| columns };
    }

    /// The next visible part: its cell relative to `left`, and its bytes.
    pub fn next(self: *Highlights) ?struct { cell: usize, bytes: []const u8 } {
        const text = self.spans.line;
        while (self.column < self.right) {
            const span = self.spans.next() orelse return null;
            while (self.position < span.start) {
                const character = char.decode(text, self.position);
                self.column += char.cells(character.code, self.column);
                self.position += character.len;
            }
            const start = self.column;
            self.column += span.end - span.start;
            self.position = span.end;
            const first = @max(start, self.left);
            const last = @min(self.column, self.right);
            if (first >= last) continue;
            const bytes = text[span.start + (first - start) ..][0 .. last - first];
            return .{ .cell = first - self.left, .bytes = bytes };
        }
        return null;
    }
};

test "rendering clips inside tabs and pads short rows" {
    var text = try Buffer.fromBytes(std.testing.allocator, "a\tb\tc\nshort\n");
    defer text.deinit(std.testing.allocator);
    var storage: [36]u8 = undefined;
    var viewport: Viewport = .{ .left = 4 };
    try expectRow("    b       ", viewport, &text, 0, 12, &storage);
    viewport.left = 7;
    try expectRow(" b  ", viewport, &text, 0, 4, &storage);
    viewport.left = 8;
    try expectRow("b       c", viewport, &text, 0, 9, &storage);
    viewport.left = 16;
    try expectRow("c   ", viewport, &text, 0, 4, &storage);
    viewport.left = 0;
    try expectRow("short       ", viewport, &text, 1, 12, &storage);
    try expectRow("    ", viewport, &text, 2, 4, &storage);
}

test "rendering draws only allowlisted characters and fills exactly the requested cells" {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @intCast(index);
    var random: [512]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x6e6962);
    prng.random().bytes(&random);
    const hostile = [_][]const u8{
        &bytes,
        &random,
        // C1 CSI, DEL and ESC sequences.
        "\xc2\x9b2J\x7f\x1b[2J\r",
        // Bidi overrides and isolates, zero-width and byte-order marks.
        "a\u{202e}b\u{2066}c\u{200b}d\u{feff}e\u{2060}",
        // Combining marks and an emoji variation selector.
        "e\u{301}\u{20dd}\u{3099}\u{2764}\u{fe0f}",
        // A surrogate, overlong forms, beyond U+10FFFF and truncated sequences.
        "\xed\xa0\x80\xc0\xaf\xe0\x80\xaf\xf4\x90\x80\x80\xe2\x80",
        // Allowlisted characters, wide ones split at every edge below.
        "\t\u{e9}\u{2014}\u{3c3}\u{6750}\u{6599}\u{2705}\u{1f680}\u{2502}",
    };
    var storage: [3 * 40]u8 = undefined;
    for (hostile) |text| {
        for (0..12) |left| {
            for (0..41) |columns| {
                const output = storage[0..renderText(text, left, columns, &storage)];
                try std.testing.expect(std.unicode.utf8ValidateSlice(output));
                var cells: usize = 0;
                var position: usize = 0;
                while (position < output.len) {
                    const character = char.decode(output, position);
                    cells += char.width(character.code.?).?;
                    position += character.len;
                }
                try std.testing.expectEqual(columns, cells);
            }
        }
    }
    // U+009B is one character, so one placeholder.
    try expectText("file?[2J???? ", "file\x1b[2J\n\r\x7f\xc2\x9b", 0, 13);
    try expectText("e??\u{e9}", "e\u{301}\u{feff}\u{e9}", 0, 4);
    try expectText("????", "\xed\xa0\x80\xc0", 0, 4);
}

test "every clipping boundary agrees with a fully expanded line" {
    const Cell = struct { glyph: []const u8, half: enum { whole, first, second } = .whole };
    const space: Cell = .{ .glyph = " " };
    const wide = "\u{6750}";
    const check = "\u{2705}";
    const tab: [8]Cell = @splat(space);
    const expanded = tab ++ [_]Cell{.{ .glyph = "A" }} ++ tab[1..].* ++ [_]Cell{
        .{ .glyph = wide, .half = .first },
        .{ .glyph = wide, .half = .second },
        .{ .glyph = "\u{e9}" },
        .{ .glyph = check, .half = .first },
        .{ .glyph = check, .half = .second },
        .{ .glyph = "?" },
        .{ .glyph = "\u{2014}" },
    };
    const text = "\tA\t" ++ wide ++ "\u{e9}" ++ check ++ "\u{301}\u{2014}";
    var expected: [3 * 30]u8 = undefined;
    var storage: [3 * 30]u8 = undefined;
    for (0..expanded.len + 2) |left| {
        for (0..30) |columns| {
            var len: usize = 0;
            var cell = left;
            while (cell < left + columns) : (cell += 1) {
                const shown = if (cell < expanded.len) expanded[cell] else space;
                const whole = switch (shown.half) {
                    .whole => true,
                    .first => cell + 1 < left + columns,
                    .second => false,
                };
                const glyph = if (whole) shown.glyph else " ";
                @memcpy(expected[len..][0..glyph.len], glyph);
                len += glyph.len;
                if (shown.half == .first and whole) cell += 1;
            }
            try std.testing.expectEqualStrings(
                expected[0..len],
                storage[0..renderText(text, left, columns, &storage)],
            );
        }
    }
}

test "the cursor's column is the cell where rendering draws its character" {
    const text = "a\t\u{6750}e\u{301}\u{2705}\xffz";
    var buffer = try Buffer.fromBytes(std.testing.allocator, text);
    defer buffer.deinit(std.testing.allocator);
    const cases = [_]struct { offset: usize, column: usize, glyph: []const u8 }{
        .{ .offset = 0, .column = 0, .glyph = "a" },
        .{ .offset = 1, .column = 1, .glyph = "       " },
        .{ .offset = 2, .column = 8, .glyph = "\u{6750}" },
        .{ .offset = 5, .column = 10, .glyph = "e" },
        .{ .offset = 6, .column = 11, .glyph = "?" },
        .{ .offset = 8, .column = 12, .glyph = "\u{2705}" },
        .{ .offset = 11, .column = 14, .glyph = "?" },
        .{ .offset = 12, .column = 15, .glyph = "z" },
    };
    for (cases) |case| {
        const cells = motion.screenCells(&buffer, case.offset, true);
        try std.testing.expectEqual(case.column, cells.column);
        const columns = motion.screenCells(&buffer, char.next(text, case.offset), true).column;
        try expectText(case.glyph, text, case.column, columns - case.column);
    }
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
    var storage: [9]u8 = undefined;
    try expectRow("   ", viewport, &buffer, std.math.maxInt(usize), 3, &storage);
    try expectRow("   ", .{ .left = std.math.maxInt(usize) }, &buffer, 0, 3, &storage);
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
    var storage: [12]u8 = undefined;
    try expectRow("tail", viewport, &text, 0, 4, &storage);
    try std.testing.expectEqualSlices(u8, bytes, text.bytes());
}

test "following keeps a whole wide cursor character visible, or its first cell" {
    // 材 covers cells 2 and 3.
    var buffer = try Buffer.fromBytes(std.testing.allocator, "ab\xe6\x9d\x90c");
    defer buffer.deinit(std.testing.allocator);
    buffer.cursor = 2;
    var viewport: Viewport = .{};
    viewport.follow(&buffer, 1, 3, false);
    try std.testing.expectEqual(@as(usize, 1), viewport.left);
    try std.testing.expectEqual(@as(usize, 1), viewport.cursor(&buffer, 1, 3, false).?.column);
    viewport.follow(&buffer, 1, 1, false);
    try std.testing.expectEqual(@as(usize, 2), viewport.left);
    viewport.left = 3;
    viewport.follow(&buffer, 1, 3, false);
    try std.testing.expectEqual(@as(usize, 2), viewport.left);
    viewport.left = 0;
    viewport.follow(&buffer, 1, 3, true);
    try std.testing.expectEqual(@as(usize, 0), viewport.left);
}

test "highlights cover each visible match where rendering draws it, clipped at both edges" {
    // Tab 0-7, ab 8-9, 材 10-11, ab 12-13, ✅ 14-15, x 16, AB 17-18, an
    // invalid byte 19, ab 20-21. "ab" folds case, so AB matches.
    const text = "\tab\u{6750}ab\u{2705}xAB\xffab";
    const matches = [_]struct { start: usize, end: usize }{
        .{ .start = 8, .end = 10 },
        .{ .start = 12, .end = 14 },
        .{ .start = 17, .end = 19 },
        .{ .start = 20, .end = 22 },
    };
    var storage: [3 * 24]u8 = undefined;
    for (0..24) |left| {
        for (0..24) |columns| {
            var highlights: Highlights = .init(text, "ab", left, columns);
            for (matches) |match| {
                const first = @max(match.start, left);
                const last = @min(match.end, left + columns);
                if (first >= last) continue;
                const part = highlights.next().?;
                try std.testing.expectEqual(first - left, part.cell);
                try std.testing.expectEqual(last - first, part.bytes.len);
                // The highlighted bytes are what rendering draws in those cells.
                const used = renderText(text, first, part.bytes.len, &storage);
                try std.testing.expectEqualStrings(storage[0..used], part.bytes);
            }
            try std.testing.expect(highlights.next() == null);
        }
    }
    var exact: Highlights = .init(text, "AB", 0, 24);
    try std.testing.expectEqual(@as(usize, 17), exact.next().?.cell);
    try std.testing.expect(exact.next() == null);
}

test "highlights merge overlapping matches and stop at the right edge" {
    var merged: Highlights = .init("xaaaay", "aa", 0, 6);
    const part = merged.next().?;
    try std.testing.expectEqual(@as(usize, 1), part.cell);
    try std.testing.expectEqualStrings("aaaa", part.bytes);
    try std.testing.expect(merged.next() == null);
    // Matches beyond the right edge are never measured or returned.
    var clipped: Highlights = .init("ab ab ab", "ab", 0, 4);
    try std.testing.expectEqualStrings("ab", clipped.next().?.bytes);
    try std.testing.expectEqualStrings("a", clipped.next().?.bytes);
    try std.testing.expect(clipped.next() == null);
    try std.testing.expectEqual(@as(usize, 5), clipped.position);
}

fn expectRow(
    expected: []const u8,
    viewport: Viewport,
    buffer: *const Buffer,
    row: usize,
    columns: usize,
    storage: []u8,
) !void {
    const used = viewport.renderRow(buffer, row, columns, storage);
    try std.testing.expectEqualStrings(expected, storage[0..used]);
}

fn expectText(expected: []const u8, text: []const u8, left: usize, columns: usize) !void {
    var storage: [3 * 64]u8 = undefined;
    const used = renderText(text, left, columns, &storage);
    try std.testing.expectEqualStrings(expected, storage[0..used]);
}
