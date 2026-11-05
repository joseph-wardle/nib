// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const terminal = @import("terminal.zig");
const file = @import("file.zig");
const Buffer = @import("buffer.zig").Buffer;
const motion = @import("motion.zig");
const view = @import("view.zig");
const input = @import("input.zig");
const command = @import("command.zig");
const discovery = @import("discovery.zig");
const jobs = @import("jobs.zig");
const match = @import("match.zig");
const Editor = @import("editor.zig").Editor;
const Session = @import("session.zig").Session;
const Finder = @import("finder.zig").Finder;
const Category = @import("finder.zig").Category;
const OpenFile = @import("finder.zig").OpenFile;

pub fn main(init: std.process.Init) u8 {
    var args = init.minimal.args.iterate();
    _ = args.next();
    const path = args.next();
    if (path != null and args.next() != null) {
        diagnostic("usage: nib [path] (one file or directory)");
        return 1;
    }
    const how: discovery.Start = if (path) |named|
        if (directory(named)) .{ .directory = named } else .{ .file = named }
    else
        .working;
    // Establish the signal mask before file I/O can start runtime workers.
    // open validates the terminal but does not enter the alternate screen.
    var screen = terminal.Terminal.open() catch |err| {
        report(err);
        return 1;
    };
    // Workers inherit the blocked mask, so jobs start after the terminal.
    var background = jobs.Jobs.init() catch |err| {
        screen.close() catch {};
        report(err);
        return 1;
    };
    var finder: Finder = .{};
    const outcome = run(init, &screen, &background, &finder, how);
    const cleanup = screen.close();
    // Joining workers can wait on helpers, so the terminal is restored first.
    background.deinit(init.gpa, init.io);
    finder.deinit(init.gpa, init.io);
    // Diagnostics follow cleanup so they remain visible in the shell.
    var code = outcome catch |err| code: {
        report(err);
        break :code @as(u8, 1);
    };
    cleanup catch |err| {
        report(err);
        code = 1;
    };
    return code;
}

fn directory(path: [*:0]const u8) bool {
    var status: linux.Statx = undefined;
    const result = linux.statx(linux.AT.FDCWD, path, 0, .{ .TYPE = true }, &status);
    return posix.errno(result) == .SUCCESS and status.mode & linux.S.IFMT == linux.S.IFDIR;
}

fn run(
    init: std.process.Init,
    screen: *terminal.Terminal,
    background: *jobs.Jobs,
    finder: *Finder,
    how: discovery.Start,
) !u8 {
    var app: App = .{
        .gpa = init.gpa,
        .io = init.io,
        .screen = screen,
        .background = background,
        .finder = finder,
    };
    defer app.editor.deinit(init.gpa);
    defer app.documents.deinit(init.gpa);
    // A named file must open before the screen is taken over.
    if (how == .file) _ = try app.documents.open(init.gpa, init.io, .cwd(), how.file, &app.editor);
    finder.start(init.gpa, init.io, background, how);
    if (app.documents.current() == null) app.find(.project);
    return app.loop();
}

/// The session's interactive state. Focus is on the finder or on the active
/// document; the editor exists only while a document is open.
const App = struct {
    gpa: Allocator,
    io: std.Io,
    screen: *terminal.Terminal,
    background: *jobs.Jobs,
    finder: *Finder,
    editor: Editor = .{},
    documents: Session = .{},
    /// The finder has focus. Always set when no document is open.
    finding: bool = false,
    /// The finder's keys move through the list rather than edit the query.
    browsing: bool = false,
    /// A `g` in the list awaits a second `g`.
    pending_g: bool = false,
    size: terminal.Size = .{ .rows = 0, .columns = 0 },
    redraw: bool = false,
    exit: ?u8 = null,
    /// Storage for composed notices, which `editor.notice` may borrow.
    notice: [512]u8 = undefined,
    /// Storage for the preview's title while a frame is drawn.
    title: [96]u8 = undefined,

    fn loop(self: *App) !u8 {
        var suspension_count = self.screen.suspension_count;
        var resumption_count = self.screen.resumption_count;
        var decoder: input.Decoder = .{};
        while (true) {
            var bytes: []const u8 = &.{};
            var expired = false;
            const watch_fd = if (self.documents.current()) |entry| entry.disk.watch.fd else -1;
            const event = try self.screen.next(decoder.deadline, watch_fd, self.background.wake_fd);
            switch (event) {
                .watch => self.watched(),
                .background => self.collect(),
                .redraw => |size| {
                    self.size = size;
                    self.redraw = true;
                },
                .input => |chunk| bytes = chunk,
                .timeout => expired = true,
                .quit => |code| return code,
            }
            const suspended = suspension_count != self.screen.suspension_count;
            if (suspended or resumption_count != self.screen.resumption_count) {
                suspension_count = self.screen.suspension_count;
                resumption_count = self.screen.resumption_count;
                self.editor.interruptPaste();
                if (self.documents.current()) |entry| {
                    entry.disk.inspect(self.gpa, &entry.document, true);
                }
                self.redraw = true;
            }
            // One read can hold many keys or a large paste; they share a timestamp.
            const now = if (bytes.len != 0 or expired) try terminal.milliseconds() else 0;
            var fed: usize = 0;
            while (expired or fed < bytes.len) {
                const events = if (expired) decoder.expire(now) else decoder.feed(bytes[fed], now);
                if (expired) expired = false else fed += 1;
                for (events.items[0..events.len]) |decoded| {
                    if (decoded == .key and decoded.key == 26) {
                        self.screen.requestSuspend();
                        continue;
                    }
                    if (self.finding) self.finderEvent(decoded) else self.editorEvent(decoded);
                    if (self.exit) |code| return code;
                }
            }
            if (self.documents.current()) |entry| {
                self.redraw = entry.disk.automatic(
                    self.gpa,
                    self.io,
                    &entry.document,
                    &entry.goal,
                    &self.editor,
                ) or self.redraw;
                // The finder never scrolls the document behind it.
                if (!self.finding) entry.viewport.follow(
                    &entry.document.buffer,
                    self.size.rows -| 1,
                    self.size.columns -| 1,
                    self.editor.inserting(),
                );
            }
            if (self.redraw) {
                self.redraw = false;
                self.draw() catch |err| {
                    if (err != error.Interrupted) return err;
                };
            }
        }
    }

    fn watched(self: *App) void {
        const entry = self.documents.current() orelse return;
        const old_status = entry.disk.status();
        if (!entry.disk.watch.drain()) return;
        entry.disk.inspect(self.gpa, &entry.document, true);
        if (!std.mem.eql(u8, old_status, entry.disk.status())) self.redraw = true;
    }

    /// Applies every finished job. Only the finder shows their results.
    fn collect(self: *App) void {
        while (self.background.collect(self.gpa, self.io)) |completion| {
            self.finder.receive(self.gpa, self.io, self.background, completion) catch {
                self.editor.notice = "Not enough memory; finder results may be incomplete";
                self.redraw = true;
            };
            if (self.finding) self.redraw = true;
        }
    }

    fn editorEvent(self: *App, event: input.Event) void {
        const entry = self.documents.current().?;
        const buffer = &entry.document.buffer;
        const old_mode = self.editor.parser.mode;
        const old_length = self.editor.parser.line_len;
        const old_cursor = buffer.cursor;
        const old_position = buffer.position;
        const old_text_length = buffer.bytes().len;
        const old_notice = self.editor.notice;
        if (self.editor.feed(self.gpa, buffer, &entry.goal, event)) |action| {
            self.fileAction(action);
            self.redraw = true;
            return;
        }
        const changed = old_mode != self.editor.parser.mode or
            old_length != self.editor.parser.line_len or
            old_cursor != buffer.cursor or
            old_position != buffer.position or
            old_text_length != buffer.bytes().len or
            !std.mem.eql(u8, old_notice, self.editor.notice);
        if (changed) self.redraw = true;
    }

    fn finderEvent(self: *App, event: input.Event) void {
        const parser = &self.editor.parser;
        if (parser.mode == .command_line) {
            // Command entry borrows the editor's idle command line, so the
            // same commands mean the same thing on either screen.
            self.redraw = true;
            const action = parser.feed(event) orelse return;
            switch (action) {
                .file => |requested| self.fileAction(requested),
                .invalid => self.editor.notice = "Unsupported command",
                // A command line yields only commands.
                else => unreachable,
            }
            return;
        }
        switch (event) {
            // A paste never reaches the query.
            .ignored, .paste_begin, .paste_byte, .paste_end => return,
            else => {},
        }
        self.editor.notice = "";
        self.redraw = true;
        const pending_g = self.pending_g;
        self.pending_g = false;
        // Keys that mean the same while searching and browsing.
        switch (event) {
            .key => |byte| switch (byte) {
                '\r', '\n' => return self.choose(),
                '\t' => return self.find(self.finder.category.next()),
                0x0e => return self.move(1),
                0x10 => return self.move(-1),
                // Ctrl-R refreshes the category; Ctrl-X enters a command.
                0x12 => return self.find(self.finder.category),
                0x18 => {
                    parser.mode = .command_line;
                    return;
                },
                else => {},
            },
            .arrow => |direction| return switch (direction) {
                .up => self.move(-1),
                .down => self.move(1),
                .left, .right => {},
            },
            .escape => {},
            else => unreachable,
        }
        if (!self.browsing) return switch (event) {
            // Escape and Ctrl-C leave the query for the list.
            .escape => self.browse(),
            .key => |byte| switch (byte) {
                3 => self.browse(),
                0x08, 0x7f => self.edit(null),
                0x20...0x7e => self.edit(byte),
                else => {},
            },
            else => unreachable,
        };
        const byte = switch (event) {
            .escape => return self.dismiss(),
            .key => |byte| byte,
            else => unreachable,
        };
        const extreme = std.math.maxInt(isize);
        const half: isize = @intCast(@max(self.layout().results / 2, 1));
        switch (byte) {
            3, 'q' => self.dismiss(),
            'j' => self.move(1),
            'k' => self.move(-1),
            'g' => if (pending_g) self.move(-extreme) else {
                self.pending_g = true;
            },
            'G' => self.move(extreme),
            0x04 => self.move(half),
            0x15 => self.move(-half),
            '/', 'i' => self.browsing = false,
            ':' => parser.mode = .command_line,
            else => {},
        }
    }

    fn browse(self: *App) void {
        self.browsing = true;
    }

    fn move(self: *App, delta: isize) void {
        self.finder.move(self.gpa, self.io, self.background, delta);
    }

    /// Focuses the finder on `category`, which discovers it again.
    fn find(self: *App, category: Category) void {
        self.editor.notice = "";
        self.finding = true;
        self.redraw = true;
        const open = self.gpa.alloc(OpenFile, self.documents.entries.items.len) catch {
            self.editor.notice = "Not enough memory; finder not refreshed";
            return;
        };
        defer self.gpa.free(open);
        for (self.documents.entries.items, open) |*entry, *listed| listed.* = .{
            .id = entry.id,
            .path = entry.document.source.path,
            .modified = entry.document.buffer.modified(),
            .used = entry.used,
        };
        self.finder.focus(self.gpa, self.io, self.background, category, open) catch {
            self.editor.notice = "Not enough memory; finder results may be incomplete";
        };
    }

    /// Leaves the list for the editor; without a document there is nowhere to go.
    fn dismiss(self: *App) void {
        if (self.documents.current() == null) {
            self.editor.notice = "No file open; :q quits";
            return;
        }
        self.finder.leave(self.gpa, self.io, self.background);
        self.finding = false;
    }

    /// Appends `byte` to the query, or removes the last byte when null.
    fn edit(self: *App, byte: ?u8) void {
        var text: [match.max_query]u8 = undefined;
        const old = self.finder.query.items;
        if (byte) |typed| {
            if (old.len == text.len) {
                self.editor.notice = "Query exceeds 256 bytes";
                return;
            }
            @memcpy(text[0..old.len], old);
            text[old.len] = typed;
            return self.search(text[0 .. old.len + 1]);
        }
        if (old.len == 0) return;
        @memcpy(text[0 .. old.len - 1], old[0 .. old.len - 1]);
        self.search(text[0 .. old.len - 1]);
    }

    fn search(self: *App, text: []const u8) void {
        self.finder.search(self.gpa, self.io, self.background, text) catch |err| {
            self.editor.notice = switch (err) {
                error.QueryTooLong => "Query exceeds 256 bytes",
                error.OutOfMemory => "Not enough memory; results may not match the query",
            };
        };
    }

    /// Opens the selection, or activates it when it is already open.
    fn choose(self: *App) void {
        const choice = self.finder.choice() orelse return;
        switch (choice) {
            .document => |id| {
                // A close whose relisting ran out of memory leaves its row.
                if (self.documents.get(id) == null) {
                    self.find(self.finder.category);
                    if (self.editor.notice.len == 0) self.editor.notice = "File no longer open";
                    return;
                }
                self.documents.activate(self.gpa, self.io, id, &self.editor);
            },
            .path => |path| {
                // Only discovered listings offer paths, and they need the root.
                const root = self.finder.root.?.dir;
                const opened = self.documents.open(self.gpa, self.io, root, path, &self.editor);
                _ = opened catch |err| {
                    self.editor.notice = std.fmt.bufPrint(
                        &self.notice,
                        "Cannot open: {s}",
                        .{openFailure(err)},
                    ) catch unreachable;
                    return;
                };
            },
        }
        self.finder.leave(self.gpa, self.io, self.background);
        self.finding = false;
    }

    /// Runs a file command from either screen. Closing the last document
    /// exits, as does quitting without one; the other commands need one.
    fn fileAction(self: *App, action: command.File) void {
        switch (action) {
            .find => {
                self.browsing = false;
                self.find(self.finder.category);
            },
            .quit => |discard| {
                const entry = self.documents.current() orelse {
                    self.exit = 0;
                    return;
                };
                self.documents.close(self.gpa, self.io, entry.id, discard, &self.editor) catch {
                    self.editor.notice = "Unsaved changes; use :q! to discard";
                    return;
                };
                self.editor.notice = "";
                self.closed();
            },
            .quit_all => |discard| {
                if (discard or self.documents.unsaved() == 0) {
                    self.exit = 0;
                    return;
                }
                self.editor.notice = self.blockers();
            },
            .write => |copy_path| {
                const entry = self.documents.current() orelse return self.refuse();
                const result = if (copy_path.len == 0)
                    self.documents.save(self.gpa, .{})
                else
                    file.copy(self.gpa, self.io, .cwd(), copy_path, &entry.document.buffer, .{});
                self.saved(result, copy_path.len != 0);
            },
            .write_quit => {
                if (self.documents.current() == null) return self.refuse();
                const closing = self.documents.saveAndClose(self.gpa, self.io, &self.editor, .{});
                self.saved(closing.report, false);
                if (closing.closed) self.closed();
            },
            .reload => {
                const entry = self.documents.current() orelse return self.refuse();
                _ = entry.disk.reload(
                    self.gpa,
                    self.io,
                    &entry.document,
                    &entry.goal,
                    &self.editor,
                    true,
                );
            },
        }
    }

    fn refuse(self: *App) void {
        self.editor.notice = "No file open";
    }

    /// Closing the last document exits; otherwise a focused finder lists
    /// what remains.
    fn closed(self: *App) void {
        if (self.documents.current() == null) {
            self.exit = 0;
            return;
        }
        if (!self.finding) return;
        const notice = self.editor.notice;
        self.find(self.finder.category);
        if (self.editor.notice.len == 0) self.editor.notice = notice;
    }

    fn saved(self: *App, result: file.Report, copy: bool) void {
        self.editor.notice = saveNotice(result, copy);
        if (!result.cleanup_failure) return;
        const text = "{s}; cleanup failed";
        self.editor.notice = std.fmt.bufPrint(&self.notice, text, .{self.editor.notice}) catch
            unreachable;
    }

    /// Names every file with unsaved edits, as the finder lists them.
    fn blockers(self: *App) []const u8 {
        const suffix = "; :qa! discards them";
        const more = " ...";
        const count = self.documents.unsaved();
        const start = std.fmt.bufPrint(&self.notice, "Unsaved changes in {d} file{s}:", .{
            count,
            if (count == 1) "" else "s",
        }) catch unreachable;
        var used = start.len;
        const limit = self.notice.len - suffix.len - more.len;
        var separator: []const u8 = " ";
        for (self.documents.entries.items) |*entry| {
            if (!entry.document.buffer.modified()) continue;
            const name = self.finder.display(entry.document.source.path);
            if (used + separator.len + name.len > limit) {
                @memcpy(self.notice[used..][0..more.len], more);
                used += more.len;
                break;
            }
            @memcpy(self.notice[used..][0..separator.len], separator);
            used += separator.len;
            @memcpy(self.notice[used..][0..name.len], name);
            used += name.len;
            separator = ", ";
        }
        @memcpy(self.notice[used..][0..suffix.len], suffix);
        return self.notice[0 .. used + suffix.len];
    }

    fn draw(self: *App) terminal.Error!void {
        var frame: Frame = .{ .screen = self.screen };
        try frame.append("\x1b[?25l\x1b[H\x1b[2J");
        if (self.finding) try self.drawFinder(&frame) else try self.drawEditor(&frame);
        // The reset ends every frame and nothing else; tests synchronise on it.
        try frame.append("\x1b[0m");
        try frame.flush();
    }

    fn drawEditor(self: *App, frame: *Frame) terminal.Error!void {
        const entry = self.documents.current().?;
        const buffer = &entry.document.buffer;
        const parser = &self.editor.parser;
        const rows = self.size.rows;
        // Reserve the last column on every row to avoid autowrap, including the
        // bottom-right cell.
        const width = self.size.columns -| 1;
        if (rows != 0 and width != 0) {
            for (0..rows - 1) |number| {
                entry.viewport.renderRow(buffer, number, try frame.reserve(width));
                try frame.append("\r\n");
            }
            try frame.append("\x1b[7m");
            var line: Line = .init(try frame.reserve(width));
            // The persistent disk/monitor status fills tiny status rows.
            line.put(entry.disk.status());
            if (parser.mode == .command_line) {
                line.put(":");
                // Keep the end of a long command visible in the reserved status row.
                const text = parser.line[0..parser.line_len];
                line.put(text[text.len -| line.left()..]);
            } else if (parser.mode == .operator) {
                line.put("OPERATOR pending | Escape/Ctrl-C cancel");
            } else if (self.editor.notice.len != 0) {
                line.put(self.editor.notice);
            } else {
                var status: [96]u8 = undefined;
                const flags = if (buffer.modified())
                    " [+]"
                else if (!buffer.editable)
                    " [read-only: unsupported bytes]"
                else
                    "";
                line.put(std.fmt.bufPrint(&status, "{s}{s} | {d}:{d} | ", .{
                    if (parser.mode == .insert) "INSERT" else "NORMAL",
                    flags,
                    buffer.rowAt(buffer.cursor) + 1,
                    motion.screenColumn(buffer, buffer.cursor, parser.mode == .insert) + 1,
                }) catch unreachable);
                line.put(entry.document.source.path);
                line.put(" | Ctrl-P files | :qa quit");
            }
            try frame.append("\x1b[27m");
        }
        const insert = parser.mode == .insert;
        if (entry.viewport.cursor(buffer, rows -| 1, width, insert)) |cell| {
            try frame.cursor(cell.row, cell.column);
        }
    }

    /// Rows top to bottom: categories and root, progress, query, results
    /// beside the preview, the selected path in full, then status. Small
    /// terminals drop rows from the top and the preview first, keeping the
    /// status, query and selected path.
    fn drawFinder(self: *App, frame: *Frame) terminal.Error!void {
        const finder = self.finder;
        const width: usize = self.size.columns -| 1;
        if (self.size.rows == 0 or width == 0) return;
        const selected = self.selection();
        const rows = self.layout();
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
            self.progress(try frame.reserve(width));
            try frame.append("\r\n");
        }
        const query = finder.query.items;
        if (query_rows != 0) {
            var line: Line = .init(try frame.reserve(width));
            line.put("> ");
            line.put(query[query.len -| (line.left() -| 1)..]);
            try frame.append("\r\n");
        }
        if (result_rows != 0) try self.drawResults(frame, result_rows, width);
        for (0..path_rows) |index| {
            const start = index * width;
            var line: Line = .init(try frame.reserve(width));
            line.put(selected[start..@min(start + width, selected.len)]);
            try frame.append("\r\n");
        }
        try frame.append("\x1b[7m");
        var status: Line = .init(try frame.reserve(width));
        const parser = &self.editor.parser;
        if (parser.mode == .command_line) {
            status.put(":");
            // Leave the last cell for the cursor.
            const text = parser.line[0..parser.line_len];
            status.put(text[text.len -| (status.left() -| 1)..]);
        } else if (self.editor.notice.len != 0) {
            status.put(self.editor.notice);
        } else if (self.browsing) {
            status.put("LIST | j/k move | Enter open | / search | ");
            status.put(if (self.documents.current() == null) ":q quit" else "Esc editor");
            status.put(" | Tab category | : command");
        } else {
            status.put("SEARCH | Enter open | Esc list | ^N/^P move | Tab category | ");
            status.put("^X command | ^R refresh");
        }
        try frame.append("\x1b[27m");
        if (parser.mode == .command_line) {
            try frame.cursor(self.size.rows - 1, @min(1 + parser.line_len, width - 1));
        } else if (query_rows != 0 and !self.browsing) {
            try frame.cursor(header_rows + progress_rows, @min(2 + query.len, width - 1));
        }
    }

    fn selection(self: *const App) []const u8 {
        const finder = self.finder;
        if (finder.matches.len == 0) return "";
        return finder.row(finder.matches[finder.selected]).label;
    }

    /// The finder's rows, top to bottom, above the status row. The query and
    /// the selected path come first, then the header and progress.
    fn layout(self: *const App) Layout {
        const width: usize = self.size.columns -| 1;
        if (self.size.rows == 0 or width == 0) return .{};
        var budget: usize = self.size.rows - 1;
        var rows: Layout = .{};
        rows.query = @min(budget, 1);
        budget -= rows.query;
        rows.path = @min(budget, (self.selection().len + width - 1) / width);
        budget -= rows.path;
        rows.header = @min(budget, 1);
        budget -= rows.header;
        rows.progress = @min(budget, 1);
        budget -= rows.progress;
        rows.results = budget;
        return rows;
    }

    const Layout = struct {
        header: usize = 0,
        progress: usize = 0,
        query: usize = 0,
        results: usize = 0,
        path: usize = 0,
    };

    /// Match counts, discovery state, failures and unknown ignore status.
    fn progress(self: *App, row: []u8) void {
        const finder = self.finder;
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
    fn drawResults(self: *App, frame: *Frame, rows: usize, width: usize) terminal.Error!void {
        const finder = self.finder;
        const page = finder.page(rows);
        const first = finder.selected - finder.selected % rows;
        const split = width >= 60;
        const list_width = if (split) (width - 1) / 2 else width;
        var pane: Pane = if (split) self.previewPane() else .{ .title = "" };
        const marks = finder.category != .project and
            if (finder.root) |root| root.git else false;
        for (0..rows) |index| {
            if (index < page.len) {
                const chosen = first + index == finder.selected;
                try drawResult(frame, finder, page[index], chosen, marks, list_width);
            } else @memset(try frame.reserve(list_width), ' ');
            if (split) {
                try frame.append("|");
                pane.render(try frame.reserve(width - list_width - 1));
            }
            try frame.append("\r\n");
        }
    }

    fn previewPane(self: *App) Pane {
        return switch (self.finder.preview()) {
            .none => .{ .title = "" },
            .loading => .{ .title = "Loading preview" },
            .unavailable => |err| .{
                .title = std.fmt.bufPrint(&self.title, "No preview: {s}", .{
                    previewFailure(err),
                }) catch unreachable,
            },
            .file => |snapshot| .{
                .title = if (snapshot.truncated) "Preview: first 64 KiB" else "Preview",
                .text = snapshot.bytes,
            },
            .document => |id| document: {
                // The finder lists documents again whenever they close.
                const entry = self.documents.get(id) orelse break :document .{ .title = "" };
                const buffer = &entry.document.buffer;
                break :document .{
                    .title = if (buffer.modified()) "Open file, unsaved edits" else "Open file",
                    .buffer = buffer,
                    .viewport = .{ .top = entry.viewport.top },
                };
            },
        };
    }
};

/// One result row: selection, modified and unknown-status marks, then the
/// label with matched bytes highlighted. Ignored files are dimmed, which
/// never hides the selection, a highlight or a mark.
fn drawResult(
    frame: *Frame,
    finder: *const Finder,
    result: match.Match,
    chosen: bool,
    marks: bool,
    width: usize,
) terminal.Error!void {
    const shown = finder.row(result);
    var positions: [match.max_query]usize = undefined;
    const lit = finder.highlight(result, &positions);
    var prefix = "    ".*;
    if (chosen) prefix[0] = '>';
    if (shown.modified) prefix[1] = '+';
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

    fn render(self: *Pane, output: []u8) void {
        defer self.row += 1;
        if (self.row == 0) return view.renderText(self.title, 0, output);
        if (self.buffer) |buffer| return self.viewport.renderRow(buffer, self.row - 1, output);
        const text = self.text orelse return @memset(output, ' ');
        const end = std.mem.indexOfScalar(u8, text, '\n');
        var line = text[0 .. end orelse text.len];
        self.text = if (end) |newline| text[newline + 1 ..] else null;
        // CR before LF ends the line; it is not shown.
        if (end != null and line.len != 0 and line[line.len - 1] == '\r') line.len -= 1;
        view.renderText(line, 0, output);
    }
};

/// Fills a row left to right with printable ASCII, then spaces.
const Line = struct {
    output: []u8,
    used: usize = 0,

    fn init(output: []u8) Line {
        @memset(output, ' ');
        return .{ .output = output };
    }

    fn left(self: *const Line) usize {
        return self.output.len - self.used;
    }

    fn put(self: *Line, text: []const u8) void {
        const count = @min(text.len, self.left());
        for (self.output[self.used..][0..count], text[0..count]) |*cell, byte| {
            cell.* = if (byte >= 0x20 and byte <= 0x7e) byte else '?';
        }
        self.used += count;
    }
};

/// Why a file could not be opened, as a lowercase fragment.
fn openFailure(err: file.Error) []const u8 {
    return switch (err) {
        error.FileNotFound => "file not found; check the path",
        error.AccessDenied => "permission denied while opening the file",
        error.UnsupportedFileType => "not a regular file",
        error.FileTooLarge => "file exceeds the temporary 8 MiB limit",
        error.TooManyLines => "file exceeds the temporary 262,144-line limit",
        error.OutOfMemory => "not enough memory to open the file",
        error.UnstableSource, error.SourceChanged => "file changed while loading; try again",
        else => @errorName(err),
    };
}

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

fn saveNotice(result: file.Report, copy: bool) []const u8 {
    if (result.publication == .uncertain) return "Save outcome uncertain; inspect disk before retrying";
    if (result.publication == .installed and !result.verified) return "Bytes installed but changed/unverified; local edits retained";
    if (result.publication == .installed and !result.durable) return "Bytes installed and verified; durability not confirmed";
    if (result.publication == .installed and result.failure != null) return "Bytes installed and verified; save reported an error";
    if (result.failure) |err| return switch (err) {
        error.SourceChanged, error.FileNotFound, error.UnstableSource => "Source changed or missing; save refused; :e! reloads; :w <new-path> copies",
        error.MultiplyLinked => "Hard-linked source; use :w <new-path>",
        error.AccessDenied => "Write permission denied; save refused",
        error.PathAlreadyExists => "Copy destination exists; choose a new path",
        error.MetadataUnavailable, error.UnsupportedFlags => "Cannot preserve source metadata; save refused",
        error.OutOfMemory => "Not enough memory; save refused",
        else => @errorName(err),
    };
    return if (copy) "Copy written; source association and unsaved status retained" else "Written";
}

/// Collects output so an ordinary frame reaches the terminal in one write.
/// Larger frames flush whenever the buffer fills; the capacity holds the
/// widest possible row, so a reserved row is never split.
const Frame = struct {
    screen: *terminal.Terminal,
    bytes: [std.math.maxInt(u16) + 1]u8 = undefined,
    len: usize = 0,

    fn append(self: *Frame, data: []const u8) terminal.Error!void {
        @memcpy(try self.reserve(data.len), data);
    }

    /// The caller fills the returned bytes before the next append or reserve.
    fn reserve(self: *Frame, count: usize) terminal.Error![]u8 {
        std.debug.assert(count <= self.bytes.len);
        if (self.bytes.len - self.len < count) try self.flush();
        defer self.len += count;
        return self.bytes[self.len..][0..count];
    }

    /// Shows the cursor at a zero-based cell.
    fn cursor(self: *Frame, row: usize, column: usize) terminal.Error!void {
        var position: [48]u8 = undefined;
        const text = "\x1b[{d};{d}H\x1b[?25h";
        const sequence = std.fmt.bufPrint(&position, text, .{ row + 1, column + 1 });
        try self.append(sequence catch unreachable);
    }

    fn flush(self: *Frame) terminal.Error!void {
        defer self.len = 0;
        try self.screen.write(self.bytes[0..self.len]);
    }
};

fn report(err: anyerror) void {
    const message = switch (err) {
        error.NotATerminal => "stdin and stdout must be the controlling terminal",
        error.NotForeground => "run Nib as a foreground terminal job",
        error.OutputBlocked => "screen cleanup blocked by terminal output",
        error.SystemResources => "cannot start background work",
        error.FileNotFound,
        error.AccessDenied,
        error.UnsupportedFileType,
        error.FileTooLarge,
        error.TooManyLines,
        error.OutOfMemory,
        error.UnstableSource,
        error.SourceChanged,
        => openFailure(@errorCast(err)),
        else => @errorName(err),
    };
    diagnostic(message);
}

fn diagnostic(message: []const u8) void {
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "nib: {s}\n", .{message}) catch unreachable;
    terminal.writeDiagnostic(text);
}

test {
    _ = @import("external.zig");
    _ = @import("editor.zig");
    _ = @import("file.zig");
    _ = @import("buffer.zig");
    _ = @import("terminal.zig");
    _ = @import("view.zig");
    _ = @import("input.zig");
    _ = @import("command.zig");
    _ = @import("jobs.zig");
    _ = @import("session.zig");
    _ = @import("finder.zig");
    _ = @import("match.zig");
    _ = @import("preview.zig");
}

test "Enter on an Open row whose file has closed relists rather than activating it" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = "beta\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .screen = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    const a = try app.documents.open(testing.allocator, testing.io, temp.dir, "a", &app.editor);
    const b = try app.documents.open(testing.allocator, testing.io, temp.dir, "b", &app.editor);
    app.find(.open);
    try testing.expectEqual(b, finder.choice().?.document);
    // As when relisting after the close runs out of memory.
    try app.documents.close(testing.allocator, testing.io, b, false, &app.editor);
    app.choose();
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expect(app.finding);
    try testing.expectEqualStrings("File no longer open", app.editor.notice);
    try testing.expectEqual(a, finder.choice().?.document);
    try testing.expectEqual(@as(usize, 1), finder.matches.len);
}

test "save notices distinguish failure, uncertain publication and installed durability" {
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .failure = error.SourceChanged }, false), "Source changed"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .uncertain, .failure = error.PublishFailed }, false), "Save outcome uncertain"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .failure = error.SourceChanged }, false), "Bytes installed but changed/unverified"));
    try std.testing.expectEqualStrings("Bytes installed and verified; durability not confirmed", saveNotice(.{ .publication = .installed, .verified = true, .failure = error.SyncFailed }, false));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .verified = true, .durable = true, .failure = error.InjectedFailure }, false), "Bytes installed and verified"));
    try std.testing.expectEqualStrings("Written", saveNotice(.{ .publication = .installed, .verified = true, .durable = true }, false));
}

test "a snapshot preview shows one line per row and hides CR only before LF" {
    var pane: Pane = .{ .title = "Preview", .text = "one\r\ntwo\rx\n\tz" };
    var row: [6]u8 = undefined;
    const expected = [_][]const u8{ "Previe", "one   ", "two?x ", "      ", "      " };
    pane.render(&row);
    try std.testing.expectEqualStrings(expected[0], &row);
    pane.render(&row);
    try std.testing.expectEqualStrings(expected[1], &row);
    pane.render(&row);
    try std.testing.expectEqualStrings(expected[2], &row);
    // A tab expands to the next eight-column stop, beyond this narrow pane.
    pane.render(&row);
    try std.testing.expectEqualStrings(expected[3], &row);
    pane.render(&row);
    try std.testing.expectEqualStrings(expected[4], &row);
}

test "status lines show only printable ASCII and stop at the row's end" {
    var row: [8]u8 = undefined;
    var line: Line = .init(&row);
    line.put("a\x1b[2J");
    line.put("\xffbcdef");
    try std.testing.expectEqualStrings("a?[2J?bc", &row);
    try std.testing.expectEqual(@as(usize, 0), line.left());
}
