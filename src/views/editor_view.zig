// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const Frame = @import("../terminal/frame.zig").Frame;
const Line = @import("../terminal/frame.zig").Line;
const Buffer = @import("../text/buffer.zig").Buffer;
const motion = @import("../text/motion.zig");
const Viewport = @import("../text/viewport.zig").Viewport;
const Highlights = @import("../text/viewport.zig").Highlights;
const Span = @import("../text/viewport.zig").Span;
const Range = @import("../text/buffer.zig").Range;
const Editor = @import("../edit/editor.zig").Editor;
const session = @import("../files/session.zig");
const theme = @import("theme.zig");

/// Draws the active document's rows behind their line numbers, its selection
/// or search highlights, then the status row: the disk status,
/// then the open `:` line, the search prompt, the operator hint, `status`
/// or a summary of the document. `command_line` is the `:` line's text
/// while it is open.
pub fn draw(
    frame: *Frame,
    size: terminal.Size,
    entry: *const session.Entry,
    editor: *const Editor,
    status: []const u8,
    command_line: ?[]const u8,
) terminal.Error!void {
    const buffer = &entry.document.buffer;
    const mode = editor.mode();
    const selection = editor.selection(buffer);
    const rows = size.rows;
    // Reserve the last column on every row to avoid autowrap, including the
    // bottom-right cell.
    const width = size.columns -| 1;
    const content = contentWidth(size, buffer);
    const gutter = width - content;
    // The status-row cell after a search prompt's query, when drawn.
    var prompt: ?usize = null;
    if (rows != 0 and width != 0) {
        const current = buffer.rowAt(buffer.cursor);
        for (0..rows - 1) |number| {
            try lineNumber(frame, buffer, entry.viewport.top +| number, current, gutter);
            const output = try frame.room(3 * content);
            frame.commit(entry.viewport.renderRow(buffer, number, content, output));
            try frame.append("\r\n");
        }
        try theme.set(frame, &.{.status});
        var line: Line = .init(try frame.reserve(width));
        // The persistent disk/monitor status fills tiny status rows.
        line.put(entry.disk.status());
        // Keep the end of a long line visible in the reserved status row,
        // with a cell after a search query for the prompt's cursor.
        if (command_line) |text| {
            line.put(":");
            line.put(text[text.len -| line.left()..]);
        } else if (editor.searchPrompt()) |search_prompt| {
            line.put(if (search_prompt.direction == .forward) "/" else "?");
            const text = search_prompt.text;
            line.put(text[text.len -| (line.left() -| 1)..]);
            prompt = line.used;
        } else if (mode == .operator) {
            line.put("OPERATOR pending | Escape/Ctrl-C cancel");
        } else if (status.len != 0) {
            line.put(status);
        } else {
            var summary: [128]u8 = undefined;
            const flags = if (buffer.modified())
                " [+]"
            else if (!buffer.editable)
                " [read-only: invalid UTF-8 or control bytes]"
            else
                "";
            const label = if (mode == .insert)
                "INSERT"
            else if (selection) |selected|
                (if (selected.linewise) "VISUAL LINE" else "VISUAL")
            else
                "NORMAL";
            line.put(std.fmt.bufPrint(&summary, "{s}{s} | {d}:{d} | ", .{
                label,
                flags,
                buffer.rowAt(buffer.cursor) + 1,
                motion.screenColumn(buffer, buffer.cursor, mode == .insert) + 1,
            }) catch unreachable);
            line.put(entry.document.source.path);
            line.put(" | Ctrl-P files | :qa quit");
        }
        try frame.append(theme.plain);
        if (editor.highlighted()) |query| {
            try highlight(frame, buffer, entry.viewport, query, rows - 1, gutter, content);
        }
        if (selection) |selected| {
            const range = selected.range;
            try select(frame, buffer, entry.viewport, range, rows - 1, gutter, content);
        }
    }
    if (mode == .search) {
        if (prompt) |column| try frame.cursor(rows - 1, @min(column, width - 1));
        return;
    }
    if (entry.viewport.cursor(buffer, rows -| 1, content, mode == .insert)) |cell| {
        try frame.cursor(cell.row, gutter + cell.column);
    }
}

/// The cells each content row has for text in a terminal of `size`: its
/// width less the reserved last column and the line-number gutter. The view
/// draws, and the caller follows the cursor, in this width.
pub fn contentWidth(size: terminal.Size, buffer: *const Buffer) usize {
    const width = size.columns -| 1;
    return width - gutterWidth(buffer, width);
}

/// The gutter's cells: the digits of the largest line number, at least 3,
/// and a space. A terminal without room for it and one cell of text has none.
/// The empty row after a final line break counts, so entering insert mode
/// there never moves the text.
fn gutterWidth(buffer: *const Buffer, width: usize) usize {
    const digits = @max(3, std.math.log10_int(buffer.insertionRows()) + 1);
    return if (digits + 1 < width) digits + 1 else 0;
}

/// Draws the gutter of the row showing line `number` (zero-based) with the
/// cursor on line `current`: the cursor line's own number, left-aligned, or
/// the distance to it, right-aligned. Rows past the text, and the empty row
/// after a final line break unless the cursor is on it, are blank.
fn lineNumber(
    frame: *Frame,
    buffer: *const Buffer,
    number: usize,
    current: usize,
    gutter: usize,
) terminal.Error!void {
    if (gutter == 0) return;
    if (number >= buffer.lineCount() and number != current) {
        @memset(try frame.reserve(gutter), ' ');
        return;
    }
    const distance = @max(number, current) - @min(number, current);
    const shown = if (number == current) number + 1 else distance;
    var digits: [20]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{shown}) catch unreachable;
    try theme.set(frame, &.{if (number == current) .current_line_number else .line_number});
    const cells = try frame.reserve(gutter - 1);
    @memset(cells, ' ');
    if (number == current) {
        @memcpy(cells[0..text.len], text);
    } else {
        @memcpy(cells[cells.len - text.len ..], text);
    }
    try frame.append(theme.plain ++ " ");
}

/// Redraws the visible matches of `query` in the search style over content
/// rows already drawn `gutter` cells from the left, leaving every other cell
/// as drawn.
fn highlight(
    frame: *Frame,
    buffer: *const Buffer,
    viewport: Viewport,
    query: []const u8,
    rows: usize,
    gutter: usize,
    width: usize,
) terminal.Error!void {
    const shown = buffer.insertionRows() -| viewport.top;
    for (0..@min(rows, shown)) |row| {
        const text = buffer.line(viewport.top + row);
        var highlights: Highlights = .init(text, query, viewport.left, width);
        while (highlights.next()) |part| {
            try restyle(frame, row, gutter + part.cell, .search_match);
            try frame.append(part.bytes);
            try frame.append(theme.plain);
        }
    }
}

/// Redraws the visible part of `range` in the selection style over content
/// rows already drawn `gutter` cells from the left, with one cell for each
/// line break it takes.
fn select(
    frame: *Frame,
    buffer: *const Buffer,
    viewport: Viewport,
    range: Range,
    rows: usize,
    gutter: usize,
    width: usize,
) terminal.Error!void {
    if (range.start == range.end) return;
    const first = @max(buffer.rowAt(range.start), viewport.top);
    const last = @min(buffer.rowAt(range.end - 1) + 1, viewport.top +| rows);
    for (first..@max(first, last)) |number| {
        const start = buffer.lineStart(number);
        const end = buffer.contentEnd(number);
        const span = Span.init(
            buffer.line(number),
            @max(range.start, start) - start,
            @min(range.end, end) - start,
            range.end > end,
            viewport.left,
            width,
        ) orelse continue;
        try restyle(frame, number - viewport.top, gutter + span.cell, .selection);
        frame.commit(span.render(try frame.room(3 * width)));
        try frame.append(theme.plain);
    }
}

/// Moves to a zero-based cell and starts `role`, which the caller
/// ends with `theme.plain` after the cells it redraws.
fn restyle(frame: *Frame, row: usize, cell: usize, role: theme.Role) terminal.Error!void {
    var position: [32]u8 = undefined;
    const sequence = std.fmt.bufPrint(&position, "\x1b[{d};{d}H", .{ row + 1, cell + 1 });
    try frame.append(sequence catch unreachable);
    try theme.set(frame, &.{role});
}

test "a whole row of matches at the widest terminal fits the frame unsplit" {
    const columns = std.math.maxInt(u16);
    const text = try std.testing.allocator.alloc(u8, columns);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    var buffer = try Buffer.fromBytes(std.testing.allocator, text);
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    try highlight(&frame, &buffer, .{}, "a", columns, 0, columns);
    const drawn = frame.bytes[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, drawn, "\x1b[1;1H\x1b[0;33;7maaa"));
    try std.testing.expect(std.mem.endsWith(u8, drawn, "aaa\x1b[m"));
    try std.testing.expectEqual(columns + "\x1b[1;1H\x1b[0;33;7m\x1b[m".len, drawn.len);
}

test "a selection is drawn in the selection style over the rows it covers" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "ab\r\n\r\nc\td\nlast\n");
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    // From b through the empty line's break and c's tab; three rows shown.
    try select(&frame, &buffer, .{}, .{ .start = 1, .end = 8 }, 3, 0, 10);
    try std.testing.expectEqualStrings("\x1b[1;2H\x1b[0;7mb \x1b[m" ++
        "\x1b[2;1H\x1b[0;7m \x1b[m" ++
        "\x1b[3;1H\x1b[0;7mc       \x1b[m", frame.bytes[0..frame.len]);
    // Scrolled down and right: only what remains in view.
    frame.len = 0;
    try select(&frame, &buffer, .{ .top = 2, .left = 3 }, .{ .start = 6, .end = 15 }, 1, 0, 10);
    const scrolled = "\x1b[1;1H\x1b[0;7m     d \x1b[m";
    try std.testing.expectEqualStrings(scrolled, frame.bytes[0..frame.len]);
    frame.len = 0;
    try select(&frame, &buffer, .{ .top = 3 }, .{ .start = 0, .end = 2 }, 2, 0, 10);
    try std.testing.expectEqual(@as(usize, 0), frame.len);
}

/// Draws `buffer` as the active document in a terminal of `size`, following
/// the cursor first as the app does, into `frame`.
fn drawFrame(
    frame: *Frame,
    buffer: *const Buffer,
    size: terminal.Size,
    insert: bool,
) !void {
    var entry: session.Entry = .{
        .id = @fromBackingInt(@intCast(0)),
        .document = .{
            .source = .{ .path = "a", .resolved = undefined, .version = undefined },
            .buffer = buffer.*,
        },
    };
    entry.viewport.follow(buffer, size.rows -| 1, contentWidth(size, buffer), insert);
    var editor: Editor = .{};
    if (insert) editor.parser.mode = .insert;
    frame.len = 0;
    try draw(frame, size, &entry, &editor, "", null);
}

test "rows show their distance to the cursor line, which shows its own number" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "a\nb\nc\n");
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    // Four gutter cells and five of text; the row after the final line break
    // and the row past the text are blank.
    buffer.cursor = 2;
    try drawFrame(&frame, &buffer, .{ .rows = 6, .columns = 10 }, false);
    const drawn = frame.bytes[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, drawn, "\x1b[0;90m  1\x1b[m a    \r\n" ++
        "\x1b[0;1;33m2  \x1b[m b    \r\n" ++
        "\x1b[0;90m  1\x1b[m c    \r\n" ++
        "         \r\n" ++
        "         \r\n" ++
        "\x1b[0;7m"));
    try std.testing.expect(std.mem.endsWith(u8, drawn, "\x1b[2;5H\x1b[?25h"));
    // In insert mode on that empty row, it is the cursor line.
    buffer.cursor = buffer.bytes().len;
    try drawFrame(&frame, &buffer, .{ .rows = 6, .columns = 10 }, true);
    const inserting = frame.bytes[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, inserting, "\x1b[0;90m  3\x1b[m a    \r\n" ++
        "\x1b[0;90m  2\x1b[m b    \r\n" ++
        "\x1b[0;90m  1\x1b[m c    \r\n" ++
        "\x1b[0;1;33m4  \x1b[m      \r\n" ++
        "         \r\n"));
    try std.testing.expect(std.mem.endsWith(u8, inserting, "\x1b[4;5H\x1b[?25h"));
}

test "the gutter widens at a thousand rows, counting the row after a final line break" {
    const allocator = std.testing.allocator;
    const text = try allocator.alloc(u8, 2 * 999);
    defer allocator.free(text);
    for (0..999) |line| @memcpy(text[2 * line ..][0..2], "x\n");
    const size: terminal.Size = .{ .rows = 3, .columns = 20 };
    const Case = struct { bytes: []const u8, content: usize };
    // 999 lines and a final line break; 998 and one; 999 without one.
    const cases = [_]Case{
        .{ .bytes = text, .content = 19 - 5 },
        .{ .bytes = text[0 .. text.len - 2], .content = 19 - 4 },
        .{ .bytes = text[0 .. text.len - 1], .content = 19 - 4 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.bytes);
        defer buffer.deinit(allocator);
        try std.testing.expectEqual(case.content, contentWidth(size, &buffer));
    }
    var buffer = try Buffer.fromBytes(allocator, text);
    defer buffer.deinit(allocator);
    var frame: Frame = .{ .screen = undefined };
    // The last line in normal mode, then the row after it in insert mode.
    buffer.cursor = text.len - 2;
    try drawFrame(&frame, &buffer, size, false);
    const last = "\x1b[0;90m   1\x1b[m x             \r\n\x1b[0;1;33m999 \x1b[m x";
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes[0..frame.len], last) != null);
    buffer.cursor = text.len;
    try drawFrame(&frame, &buffer, size, true);
    const inserting = "\x1b[0;90m   1\x1b[m x             \r\n\x1b[0;1;33m1000\x1b[m  ";
    try std.testing.expect(std.mem.indexOf(u8, frame.bytes[0..frame.len], inserting) != null);
}

test "a terminal without room for the gutter and one cell of text has no gutter" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "ab\n");
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    try drawFrame(&frame, &buffer, .{ .rows = 2, .columns = 5 }, false);
    try std.testing.expect(std.mem.startsWith(u8, frame.bytes[0..frame.len], "ab  \r\n"));
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes[0..frame.len], "\x1b[1;1H\x1b[?25h"));
    try drawFrame(&frame, &buffer, .{ .rows = 2, .columns = 6 }, false);
    const narrow = "\x1b[0;1;33m1  \x1b[m a\r\n";
    try std.testing.expect(std.mem.startsWith(u8, frame.bytes[0..frame.len], narrow));
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes[0..frame.len], "\x1b[1;5H\x1b[?25h"));
}

test "following scrolls within the cells the gutter leaves, and the cursor sits after it" {
    var buffer = try Buffer.fromBytes(std.testing.allocator, "abcdefghij\nsecond\n");
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    // One content row of four cells after the gutter.
    buffer.cursor = 9;
    try drawFrame(&frame, &buffer, .{ .rows = 2, .columns = 9 }, false);
    const row = "\x1b[0;1;33m1  \x1b[m ghij\r\n";
    try std.testing.expect(std.mem.startsWith(u8, frame.bytes[0..frame.len], row));
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes[0..frame.len], "\x1b[1;8H\x1b[?25h"));
    buffer.cursor = 11;
    try drawFrame(&frame, &buffer, .{ .rows = 2, .columns = 9 }, false);
    const below = "\x1b[0;1;33m2  \x1b[m seco\r\n";
    try std.testing.expect(std.mem.startsWith(u8, frame.bytes[0..frame.len], below));
    try std.testing.expect(std.mem.endsWith(u8, frame.bytes[0..frame.len], "\x1b[1;5H\x1b[?25h"));
}
