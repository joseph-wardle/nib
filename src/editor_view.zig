// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");
const Frame = @import("frame.zig").Frame;
const Line = @import("frame.zig").Line;
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");
const view = @import("view.zig");
const Editor = @import("editor.zig").Editor;
const session = @import("session.zig");

/// Draws the active document's rows, then the status row: the disk status,
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
    const rows = size.rows;
    // Reserve the last column on every row to avoid autowrap, including the
    // bottom-right cell.
    const width = size.columns -| 1;
    // The status-row cell after a search prompt's query, when drawn.
    var prompt: ?usize = null;
    if (rows != 0 and width != 0) {
        for (0..rows - 1) |number| {
            const output = try frame.room(3 * width);
            frame.commit(entry.viewport.renderRow(buffer, number, width, output));
            try frame.append("\r\n");
        }
        try frame.append("\x1b[7m");
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
            line.put(std.fmt.bufPrint(&summary, "{s}{s} | {d}:{d} | ", .{
                if (mode == .insert) "INSERT" else "NORMAL",
                flags,
                buffer.rowAt(buffer.cursor) + 1,
                motion.screenColumn(buffer, buffer.cursor, mode == .insert) + 1,
            }) catch unreachable);
            line.put(entry.document.source.path);
            line.put(" | Ctrl-P files | :qa quit");
        }
        try frame.append("\x1b[27m");
        if (editor.highlighted()) |query| {
            try highlight(frame, buffer, entry.viewport, query, rows - 1, width);
        }
    }
    if (mode == .search) {
        if (prompt) |column| try frame.cursor(rows - 1, @min(column, width - 1));
        return;
    }
    if (entry.viewport.cursor(buffer, rows -| 1, width, mode == .insert)) |cell| {
        try frame.cursor(cell.row, cell.column);
    }
}

/// Redraws the visible matches of `query` in reverse video over content rows
/// already drawn, leaving every other cell as drawn.
fn highlight(
    frame: *Frame,
    buffer: *const Buffer,
    viewport: view.Viewport,
    query: []const u8,
    rows: usize,
    width: usize,
) terminal.Error!void {
    const shown = buffer.insertionRows() -| viewport.top;
    for (0..@min(rows, shown)) |row| {
        const text = buffer.line(viewport.top + row);
        var highlights: view.Highlights = .init(text, query, viewport.left, width);
        while (highlights.next()) |part| {
            var position: [32]u8 = undefined;
            const move = "\x1b[{d};{d}H\x1b[7m";
            const sequence = std.fmt.bufPrint(&position, move, .{ row + 1, part.cell + 1 });
            try frame.append(sequence catch unreachable);
            try frame.append(part.bytes);
            try frame.append("\x1b[27m");
        }
    }
}

test "a whole row of matches at the widest terminal fits the frame unsplit" {
    const columns = std.math.maxInt(u16);
    const text = try std.testing.allocator.alloc(u8, columns);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');
    var buffer = try Buffer.fromBytes(std.testing.allocator, text);
    defer buffer.deinit(std.testing.allocator);
    var frame: Frame = .{ .screen = undefined };
    try highlight(&frame, &buffer, .{}, "a", columns, columns);
    const drawn = frame.bytes[0..frame.len];
    try std.testing.expect(std.mem.startsWith(u8, drawn, "\x1b[1;1H\x1b[7maaa"));
    try std.testing.expect(std.mem.endsWith(u8, drawn, "aaa\x1b[27m"));
    try std.testing.expectEqual(columns + "\x1b[1;1H\x1b[7m\x1b[27m".len, drawn.len);
}
