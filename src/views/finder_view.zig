// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const Frame = @import("../terminal/frame.zig").Frame;
const Line = @import("../terminal/frame.zig").Line;
const Buffer = @import("../text/buffer.zig").Buffer;
const Viewport = @import("../text/viewport.zig").Viewport;
const renderText = @import("../text/viewport.zig").renderText;
const jobs = @import("../finder/jobs.zig");
const match = @import("../finder/match.zig");
const preview = @import("../finder/preview.zig");
const Finder = @import("../finder/finder.zig").Finder;
const Category = @import("../finder/finder.zig").Category;
const DocumentId = @import("../finder/finder.zig").DocumentId;
const session = @import("../files/session.zig");
const Session = session.Session;

/// Rows top to bottom: categories and root, progress, query, results
/// beside the preview, the selected path in full, then status. Small
/// terminals drop rows from the top and the preview first, keeping the
/// status, query and selected path. `command_line` is the `:` line's text
/// while it is open; `browsing` means keys move through the list.
pub fn draw(
    frame: *Frame,
    size: terminal.Size,
    finder: *const Finder,
    documents: *const Session,
    status: []const u8,
    command_line: ?[]const u8,
    browsing: bool,
) terminal.Error!void {
    const width: usize = size.columns -| 1;
    if (size.rows == 0 or width == 0) return;
    const selected = finder.selectedPath();
    const rows = layout(finder, size);
    const header_rows = rows.header;
    const progress_rows = rows.progress;
    const query_rows = rows.query;
    const result_rows = rows.results;
    const path_rows = rows.path;

    if (header_rows != 0) {
        var line: Line = .init(try frame.reserve(width));
        // Locations is present once an answer has filled it.
        const located = finder.locations.filled();
        for ([_]Category{ .project, .all, .open, .locations }) |category| {
            const name = switch (category) {
                .project => "Project",
                .all => "All",
                .open => "Open",
                .locations => if (located) "Locations" else continue,
            };
            const focused = category == finder.category;
            line.put(if (focused) "[" else " ");
            line.put(name);
            line.put(if (focused) "]" else " ");
        }
        line.put(" | ");
        if (finder.root) |root| {
            line.put(root.path);
        } else if (finder.root_failure) |err| {
            line.put("Root unavailable: ");
            line.put(jobFailure(err));
        } else line.put("Finding root");
        try frame.append("\r\n");
    }
    if (progress_rows != 0) {
        progress(finder, try frame.reserve(width));
        try frame.append("\r\n");
    }
    const query = finder.query.items;
    if (query_rows != 0) {
        var line: Line = .init(try frame.reserve(width));
        line.put("> ");
        line.put(query[query.len -| (line.left() -| 1)..]);
        try frame.append("\r\n");
    }
    if (result_rows != 0) try drawResults(frame, finder, documents, result_rows, width);
    for (0..path_rows) |index| {
        const start = index * width;
        var line: Line = .init(try frame.reserve(width));
        line.put(selected[start..@min(start + width, selected.len)]);
        try frame.append("\r\n");
    }
    try frame.append("\x1b[7m");
    var line: Line = .init(try frame.reserve(width));
    if (command_line) |text| {
        line.put(":");
        // Leave the last cell for the cursor.
        line.put(text[text.len -| (line.left() -| 1)..]);
    } else if (status.len != 0) {
        line.put(status);
    } else if (browsing) {
        line.put("LIST | j/k move | Enter open | / search | ");
        line.put(if (documents.current() == null) ":q quit" else "Esc editor");
        line.put(" | Tab category | : command");
    } else {
        line.put("SEARCH | Enter open | Esc list | ^N/^P move | Tab category | ");
        line.put("^X command | ^R refresh");
    }
    try frame.append("\x1b[27m");
    if (command_line) |text| {
        const column = 1 + text.len;
        try frame.cursor(size.rows - 1, @min(column, width - 1));
    } else if (query_rows != 0 and !browsing) {
        try frame.cursor(header_rows + progress_rows, @min(2 + query.len, width - 1));
    }
}

/// The finder's rows, top to bottom, above the status row. The query and
/// the selected path come first, then the header and progress.
pub fn layout(finder: *const Finder, size: terminal.Size) Layout {
    const width: usize = size.columns -| 1;
    if (size.rows == 0 or width == 0) return .{};
    var budget: usize = size.rows - 1;
    var rows: Layout = .{};
    rows.query = @min(budget, 1);
    budget -= rows.query;
    rows.path = @min(budget, (finder.selectedPath().len + width - 1) / width);
    budget -= rows.path;
    rows.header = @min(budget, 1);
    budget -= rows.header;
    rows.progress = @min(budget, 1);
    budget -= rows.progress;
    rows.results = budget;
    return rows;
}

pub const Layout = struct {
    header: usize = 0,
    progress: usize = 0,
    query: usize = 0,
    results: usize = 0,
    path: usize = 0,
};

/// Match counts, discovery state, failures and unknown ignore status.
fn progress(finder: *const Finder, row: []u8) void {
    var line: Line = .init(row);
    var number: [64]u8 = undefined;
    const total = if (finder.catalogOf(finder.category)) |catalog| catalog.entries.len else 0;
    const noun = if (finder.category == .locations) "rows" else "files";
    const counts = .{ finder.matches.len, total, noun };
    line.put(std.fmt.bufPrint(&number, "{d}/{d} {s}", counts) catch unreachable);
    // Locations has no list: it is never discovered.
    const listed = finder.listOf(finder.category);
    if (listed == null and finder.locations.omitted != 0) {
        const omitted = .{finder.locations.omitted};
        const spelled = std.fmt.bufPrint(&number, " | {d} outside local files", omitted);
        line.put(spelled catch unreachable);
    }
    if (listed) |list| if (list.discovering) line.put(" | scanning");
    if (finder.filtering) line.put(" | searching");
    if (listed) |list| if (list.failure) |err| {
        line.put(" | Listing failed: ");
        line.put(jobFailure(err));
    };
    if (finder.filter_failure) |err| {
        line.put(" | Search failed: ");
        line.put(jobFailure(err));
    }
    const list = listed orelse return;
    if (list.partial) {
        line.put(" | Partial: ");
        line.put(list.reason);
    } else if (list.unfiltered) {
        line.put(" | Unfiltered: ");
        line.put(list.reason);
    }
    const root = finder.root orelse return;
    if (!root.git or finder.category == .project) return;
    // Open takes ignore status from All's listing.
    const all = finder.lists.getPtrConst(.all);
    if (all.ignore_reason.len != 0) {
        line.put(" | ");
        line.put(all.ignore_reason);
    } else if (finder.category == .open and all.catalog == null) {
        line.put(" | Ignore status unknown until All is listed");
    }
}

/// The page of results holding the selection and, on wide terminals, the
/// selection's preview beside it.
fn drawResults(
    frame: *Frame,
    finder: *const Finder,
    documents: *const Session,
    rows: usize,
    width: usize,
) terminal.Error!void {
    const page = finder.page(rows);
    const first = finder.selected - finder.selected % rows;
    const split = width >= 60;
    const list_width = if (split) (width - 1) / 2 else width;
    var title: [96]u8 = undefined;
    var pane: Pane = if (split) previewPane(finder, documents, &title) else .{ .title = "" };
    const marks = (finder.category == .all or finder.category == .open) and
        if (finder.root) |root| root.git else false;
    for (0..rows) |index| {
        if (index < page.len) {
            const chosen = first + index == finder.selected;
            const result = page[index];
            try drawResult(frame, finder, documents, result, chosen, marks, list_width);
        } else @memset(try frame.reserve(list_width), ' ');
        if (split) {
            try frame.append("|");
            const pane_width = width - list_width - 1;
            frame.commit(pane.render(pane_width, try frame.room(3 * pane_width)));
        }
        try frame.append("\r\n");
    }
}

/// The selection's preview, its title formatted into `title` when needed.
fn previewPane(finder: *const Finder, documents: *const Session, title: *[96]u8) Pane {
    return switch (finder.preview()) {
        .none => .{ .title = "" },
        .loading => .{ .title = "Loading preview" },
        .unavailable => |err| .{
            .title = std.fmt.bufPrint(title, "No preview: {s}", .{
                previewFailure(err),
            }) catch unreachable,
        },
        .file => |snapshot| .{ .title = snapshotTitle(snapshot), .text = snapshot.bytes },
        .document => |shown| document: {
            // The finder lists documents again whenever they close.
            const entry = opened(documents, shown.id) orelse break :document .{ .title = "" };
            const buffer = &entry.document.buffer;
            const top = if (shown.line) |line| above(buffer, line) else entry.viewport.top;
            break :document .{
                .title = if (buffer.modified()) "Open file, unsaved edits" else "Open file",
                .buffer = buffer,
                .viewport = .{ .top = top },
            };
        },
    };
}

fn snapshotTitle(snapshot: preview.Snapshot) []const u8 {
    if (snapshot.start != 0) return "Preview: near the line";
    return if (snapshot.truncated) "Preview: first 64 KiB" else "Preview";
}

/// The preview's first row for a location on `line`, which may be past the
/// text since edits after the answer.
fn above(buffer: *const Buffer, line: u32) usize {
    return @min(line, buffer.insertionRows() - 1) -| preview.lines_above;
}

/// The open document the finder lists as `id`.
fn opened(documents: *const Session, id: DocumentId) ?*const session.Entry {
    return documents.get(@fromBackingInt(@backingInt(id)));
}

/// One result row: selection, modified and unknown-status marks, then the
/// label with matched bytes highlighted. Ignored files are dimmed, which
/// never hides the selection, a highlight or a mark. Unsaved edits are read
/// from the session, so the mark is current after any file command.
fn drawResult(
    frame: *Frame,
    finder: *const Finder,
    documents: *const Session,
    result: match.Match,
    chosen: bool,
    marks: bool,
    width: usize,
) terminal.Error!void {
    const shown = finder.row(result);
    const open = if (shown.document) |id| opened(documents, id) else null;
    const modified = if (open) |entry| entry.document.buffer.modified() else false;
    var positions: [match.max_query]usize = undefined;
    const lit = finder.highlight(result, &positions);
    var prefix = "    ".*;
    if (chosen) prefix[0] = '>';
    if (modified) prefix[1] = '+';
    if (marks and shown.ignore == .unknown) prefix[2] = '?';
    if (chosen) try frame.append("\x1b[7m");
    const lead = @min(prefix.len, width);
    try frame.append(prefix[0..lead]);
    if (shown.ignore == .ignored) try frame.append("\x1b[2m");
    var next: usize = 0;
    const label = shown.label[0..@min(shown.label.len, width - lead)];
    for (label, 0..) |byte, offset| {
        const highlighted = next < lit.len and lit[next] == offset;
        if (highlighted) try frame.append("\x1b[4;33m");
        try frame.append(&.{if (byte >= 0x20 and byte <= 0x7e) byte else '?'});
        if (highlighted) {
            try frame.append("\x1b[24;39m");
            next += 1;
        }
    }
    @memset(try frame.reserve(width - lead - label.len), ' ');
    try frame.append("\x1b[22;27m");
}

/// The preview beside the results: a title row, then text rows.
const Pane = struct {
    title: []const u8,
    /// A file snapshot's remaining lines.
    text: ?[]const u8 = null,
    /// An open document, drawn from its own scroll position.
    buffer: ?*const Buffer = null,
    viewport: Viewport = .{},
    row: usize = 0,

    /// Draws the next row into `columns` cells: the title as escaped ASCII,
    /// text as the editor draws it. `output` holds `3 * columns` bytes.
    /// Returns the bytes used.
    fn render(self: *Pane, columns: usize, output: []u8) usize {
        defer self.row += 1;
        if (self.row == 0) {
            var line: Line = .init(output[0..columns]);
            line.put(self.title);
            return columns;
        }
        if (self.buffer) |buffer| {
            return self.viewport.renderRow(buffer, self.row - 1, columns, output);
        }
        const text = self.text orelse {
            @memset(output[0..columns], ' ');
            return columns;
        };
        const end = std.mem.indexOfScalar(u8, text, '\n');
        var line = text[0 .. end orelse text.len];
        self.text = if (end) |newline| text[newline + 1 ..] else null;
        // CR before LF ends the line; it is not shown.
        if (end != null and line.len != 0 and line[line.len - 1] == '\r') line.len -= 1;
        return renderText(line, 0, columns, output);
    }
};

fn previewFailure(err: jobs.Error) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found",
        error.AccessDenied => "permission denied",
        error.UnsupportedFileType => "not a regular file",
        error.OutOfMemory => "not enough memory",
        else => jobFailure(err),
    };
}

fn jobFailure(err: jobs.Error) []const u8 {
    return switch (err) {
        error.FileNotFound => "not found",
        error.AccessDenied => "permission denied",
        error.NotADirectory => "not a directory",
        error.OutOfMemory => "not enough memory",
        error.GitUnavailable => "Git not found",
        error.HelperFailed => "Git failed",
        error.ConcurrencyUnavailable => "background work unavailable",
        else => @errorName(err),
    };
}

test "a snapshot preview shows one line per row and hides CR only before LF" {
    var pane: Pane = .{ .title = "Preview", .text = "one\r\ntwo\rx\n\tz" };
    var row: [18]u8 = undefined;
    // A tab expands to the next eight-column stop, beyond this narrow pane.
    const expected = [_][]const u8{ "Previe", "one   ", "two?x ", "      ", "      " };
    for (expected) |text| try std.testing.expectEqualStrings(text, row[0..pane.render(6, &row)]);
}

test "previews of UTF-8 text, from a snapshot or an open buffer, render like the editor" {
    const text = "na\u{ef}ve \u{2014} \u{6750}\u{6599}\r\n\t\u{2705}\xff\u{301}|\n";
    var buffer = try Buffer.fromBytes(std.testing.allocator, text);
    defer buffer.deinit(std.testing.allocator);
    var snapshot: Pane = .{ .title = "Preview \u{e9}", .text = text };
    var document: Pane = .{ .title = "Open file", .buffer = &buffer };
    var editor: [3 * 12]u8 = undefined;
    var row: [3 * 12]u8 = undefined;
    try std.testing.expectEqualStrings("Preview ??  ", row[0..snapshot.render(12, &row)]);
    try std.testing.expectEqualStrings("Open file   ", row[0..document.render(12, &row)]);
    const rows = [_][]const u8{
        "na\u{ef}ve \u{2014} \u{6750}\u{6599}",
        "        \u{2705}??",
        "            ",
    };
    for (rows, 0..) |expected, number| {
        const viewport: Viewport = .{};
        const used = viewport.renderRow(&buffer, number, 12, &editor);
        try std.testing.expectEqualStrings(expected, editor[0..used]);
        try std.testing.expectEqualStrings(expected, row[0..snapshot.render(12, &row)]);
        try std.testing.expectEqualStrings(expected, row[0..document.render(12, &row)]);
    }
}

const testing = std.testing;
const Location = @import("../finder/finder.zig").Location;

test "Locations counts rows and omitted locations, and a long row keeps the results on screen" {
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    var background: jobs.Jobs = try .init();
    defer background.deinit(testing.allocator, testing.io);
    const long: [100 * 1024]u8 = @splat('x');
    const rows = [_]Location{
        .{ .place = .{ .path = "/p/a.zig", .line = 0, .column = 0 }, .text = &long, .start = 0 },
        .{ .place = .{ .path = "/p/b.zig", .line = 4, .column = 2 }, .text = "b();", .start = 0 },
    };
    try finder.locate(testing.allocator, testing.io, &background, &rows, 3, &.{});
    var row: [80]u8 = undefined;
    progress(&finder, &row);
    const counts = "2/2 rows | 3 outside local files";
    try testing.expectEqualStrings(counts, std.mem.trimEnd(u8, &row, " "));
    const size: terminal.Size = .{ .rows = 24, .columns = 80 };
    const rows_shown = layout(&finder, size);
    try testing.expectEqual(@as(usize, 1), rows_shown.path);
    try testing.expectEqual(@as(usize, 19), rows_shown.results);
    try finder.locate(testing.allocator, testing.io, &background, rows[1..], 0, &.{});
    progress(&finder, &row);
    try testing.expectEqualStrings("1/1 rows", std.mem.trimEnd(u8, &row, " "));
}

test "an open document's location preview starts a few lines above its line, within the text" {
    var buffer = try Buffer.fromBytes(testing.allocator, "0\n1\n2\n3\n4\n5\n6\n7");
    defer buffer.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), above(&buffer, 0));
    try testing.expectEqual(@as(usize, 0), above(&buffer, 3));
    try testing.expectEqual(@as(usize, 2), above(&buffer, 5));
    // Edits since the answer may have removed the line.
    try testing.expectEqual(@as(usize, 4), above(&buffer, 4_000_000_000));
}

test "a file preview's title says when it shows only part of the file" {
    var bytes: [1]u8 = "x".*;
    const whole: preview.Snapshot = .{ .bytes = &bytes, .truncated = false };
    const first: preview.Snapshot = .{ .bytes = &bytes, .truncated = true };
    const near: preview.Snapshot = .{ .bytes = &bytes, .truncated = false, .start = 90 };
    const near_cut: preview.Snapshot = .{ .bytes = &bytes, .truncated = true, .start = 90 };
    try testing.expectEqualStrings("Preview", snapshotTitle(whole));
    try testing.expectEqualStrings("Preview: first 64 KiB", snapshotTitle(first));
    try testing.expectEqualStrings("Preview: near the line", snapshotTitle(near));
    try testing.expectEqualStrings("Preview: near the line", snapshotTitle(near_cut));
}
