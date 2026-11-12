// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("../terminal/terminal.zig");
const Frame = @import("../terminal/frame.zig").Frame;
const Line = @import("../terminal/frame.zig").Line;
const Buffer = @import("../text/buffer.zig").Buffer;
const view = @import("../text/viewport.zig");
const jobs = @import("../finder/jobs.zig");
const match = @import("../finder/match.zig");
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
    documents: *Session,
    status: []const u8,
    command_line: ?[]const u8,
    browsing: bool,
) terminal.Error!void {
    const width: usize = size.columns -| 1;
    if (size.rows == 0 or width == 0) return;
    const selected = selection(finder);
    const rows = layout(finder, size);
    const header_rows = rows.header;
    const progress_rows = rows.progress;
    const query_rows = rows.query;
    const result_rows = rows.results;
    const path_rows = rows.path;

    if (header_rows != 0) {
        var line: Line = .init(try frame.reserve(width));
        for ([_]Category{ .project, .all, .open }) |category| {
            const name = switch (category) {
                .project => "Project",
                .all => "All",
                .open => "Open",
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

fn selection(finder: *const Finder) []const u8 {
    if (finder.matches.len == 0) return "";
    return finder.row(finder.matches[finder.selected]).label;
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
    rows.path = @min(budget, (selection(finder).len + width - 1) / width);
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
    const list = finder.lists.getPtrConst(finder.category);
    const total = if (list.catalog) |catalog| catalog.entries.len else 0;
    const counts = "{d}/{d} files";
    const shown = std.fmt.bufPrint(&number, counts, .{ finder.matches.len, total });
    line.put(shown catch unreachable);
    if (list.discovering) line.put(" | scanning");
    if (finder.filtering) line.put(" | searching");
    if (list.failure) |err| {
        line.put(" | Listing failed: ");
        line.put(jobFailure(err));
    }
    if (finder.filter_failure) |err| {
        line.put(" | Search failed: ");
        line.put(jobFailure(err));
    }
    if (list.partial) {
        line.put(" | Partial: ");
        line.put(list.reason);
    } else if (list.unfiltered) {
        line.put(" | Unfiltered: ");
        line.put(list.reason);
    }
    const root = finder.root orelse return;
    if (!root.git) return;
    // Open takes ignore status from All's listing.
    const all = finder.lists.getPtrConst(.all);
    if (finder.category == .project) return;
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
    documents: *Session,
    rows: usize,
    width: usize,
) terminal.Error!void {
    const page = finder.page(rows);
    const first = finder.selected - finder.selected % rows;
    const split = width >= 60;
    const list_width = if (split) (width - 1) / 2 else width;
    var title: [96]u8 = undefined;
    var pane: Pane = if (split) previewPane(finder, documents, &title) else .{ .title = "" };
    const marks = finder.category != .project and
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
fn previewPane(finder: *const Finder, documents: *Session, title: *[96]u8) Pane {
    return switch (finder.preview()) {
        .none => .{ .title = "" },
        .loading => .{ .title = "Loading preview" },
        .unavailable => |err| .{
            .title = std.fmt.bufPrint(title, "No preview: {s}", .{
                previewFailure(err),
            }) catch unreachable,
        },
        .file => |snapshot| .{
            .title = if (snapshot.truncated) "Preview: first 64 KiB" else "Preview",
            .text = snapshot.bytes,
        },
        .document => |id| document: {
            // The finder lists documents again whenever they close.
            const entry = opened(documents, id) orelse break :document .{ .title = "" };
            const buffer = &entry.document.buffer;
            break :document .{
                .title = if (buffer.modified()) "Open file, unsaved edits" else "Open file",
                .buffer = buffer,
                .viewport = .{ .top = entry.viewport.top },
            };
        },
    };
}

/// The open document the finder lists as `id`.
fn opened(documents: *Session, id: DocumentId) ?*session.Entry {
    return documents.get(@fromBackingInt(@backingInt(id)));
}

/// One result row: selection, modified and unknown-status marks, then the
/// label with matched bytes highlighted. Ignored files are dimmed, which
/// never hides the selection, a highlight or a mark. Unsaved edits are read
/// from the session, so the mark is current after any file command.
fn drawResult(
    frame: *Frame,
    finder: *const Finder,
    documents: *Session,
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
    viewport: view.Viewport = .{},
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
        return view.renderText(line, 0, columns, output);
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
        const viewport: view.Viewport = .{};
        const used = viewport.renderRow(&buffer, number, 12, &editor);
        try std.testing.expectEqualStrings(expected, editor[0..used]);
        try std.testing.expectEqualStrings(expected, row[0..snapshot.render(12, &row)]);
        try std.testing.expectEqualStrings(expected, row[0..document.render(12, &row)]);
    }
}
