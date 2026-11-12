// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const terminal = @import("terminal/terminal.zig");
const file = @import("files/file.zig");
const input = @import("terminal/input.zig");
const command_line = @import("command_line.zig");
const discovery = @import("finder/discovery.zig");
const jobs = @import("finder/jobs.zig");
const match = @import("finder/match.zig");
const Editor = @import("edit/editor.zig").Editor;
const Status = @import("edit/editor.zig").Status;
const Disk = @import("files/disk.zig").Disk;
const session = @import("files/session.zig");
const Session = session.Session;
const Finder = @import("finder/finder.zig").Finder;
const Category = @import("finder/finder.zig").Category;
const OpenFile = @import("finder/finder.zig").OpenFile;
const Frame = @import("terminal/frame.zig").Frame;
const setClipboard = @import("terminal/frame.zig").setClipboard;
const editor_view = @import("views/editor_view.zig");
const finder_view = @import("views/finder_view.zig");

/// Runs Nib on `device` until a command quits, opening a named file first.
pub fn run(
    init: std.process.Init,
    device: *terminal.Terminal,
    background: *jobs.Jobs,
    finder: *Finder,
    how: discovery.Start,
) !u8 {
    var app: App = .{
        .gpa = init.gpa,
        .io = init.io,
        .terminal = device,
        .background = background,
        .finder = finder,
    };
    defer app.editor.deinit(init.gpa);
    defer app.documents.deinit(init.gpa);
    // A named file must open before the screen is taken over.
    if (how == .file) {
        const opened = try app.documents.open(init.gpa, init.io, .cwd(), how.file);
        app.announce(opened.activation, false);
    }
    finder.start(init.gpa, init.io, background, how);
    if (app.documents.current() == null) app.find(.project);
    return app.loop();
}

/// The session's interactive state. Focus is on the `:` line when it is open,
/// otherwise on the finder or on the active document; the editor exists only
/// while a document is open.
const App = struct {
    gpa: Allocator,
    io: std.Io,
    terminal: *terminal.Terminal,
    background: *jobs.Jobs,
    finder: *Finder,
    editor: Editor = .{},
    documents: Session = .{},
    /// The finder is shown. Always set when no document is open.
    finding: bool = false,
    /// Open over either screen, with the same commands on both.
    command_line: command_line.CommandLine = .{},
    /// The finder's keys move through the list rather than edit the query.
    browsing: bool = false,
    /// A `g` in the list awaits a second `g`.
    pending_g: bool = false,
    size: terminal.Size = .{ .rows = 0, .columns = 0 },
    redraw: bool = false,
    exit: ?u8 = null,
    /// The status line's message, on either screen.
    status: Status = .{},

    fn loop(self: *App) !u8 {
        var suspension_count = self.terminal.suspension_count;
        var resumption_count = self.terminal.resumption_count;
        var decoder: input.Decoder = .{};
        while (true) {
            var bytes: []const u8 = &.{};
            var expired = false;
            const watch_fd = if (self.documents.current()) |entry| entry.disk.watch.fd else -1;
            const event = try self.terminal.next(
                decoder.deadline,
                watch_fd,
                self.background.wake_fd,
            );
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
            const suspended = suspension_count != self.terminal.suspension_count;
            if (suspended or resumption_count != self.terminal.resumption_count) {
                suspension_count = self.terminal.suspension_count;
                resumption_count = self.terminal.resumption_count;
                self.editor.interruptPaste(&self.status);
                if (self.documents.current()) |entry| {
                    entry.disk.inspect(self.gpa, &entry.document, true);
                }
                self.redraw = true;
            }
            // One read can hold many keys or a large paste; they share a timestamp.
            const now = if (bytes.len != 0 or expired) try terminal.milliseconds() else 0;
            if (self.step(&decoder, bytes, expired, now)) |code| return code;
            if (self.redraw) {
                self.redraw = false;
                self.draw() catch |err| {
                    if (err != error.Interrupted) return err;
                };
            }
        }
    }

    /// Feeds one read, or an expired Escape deadline, through `decoder`; then
    /// reloads the active document if it is clean and changed on disk, the
    /// editor is idle and the `:` line is closed, and keeps its viewport on
    /// the cursor. Any delivered event sets `redraw`, unless a bracketed paste
    /// is still arriving. Returns the exit code once a command quits.
    fn step(self: *App, decoder: *input.Decoder, bytes: []const u8, expired: bool, now: i64) ?u8 {
        var fed: usize = 0;
        var pending = expired;
        var delivered = false;
        while (pending or fed < bytes.len) {
            const events = if (pending) decoder.expire(now) else decoder.feed(bytes[fed], now);
            if (pending) pending = false else fed += 1;
            for (events.items[0..events.len]) |decoded| {
                if (decoded == .key and decoded.key == 26) {
                    self.terminal.requestSuspend();
                    continue;
                }
                delivered = true;
                if (self.command_line.open)
                    self.commandLineEvent(decoded)
                else if (self.finding)
                    self.finderEvent(decoded)
                else
                    self.editorEvent(decoded);
                if (self.exit) |code| return code;
            }
        }
        if (delivered and decoder.state != .paste) self.redraw = true;
        if (self.documents.current()) |entry| {
            if (self.editor.idle() and !self.command_line.open) {
                const document = &entry.document;
                const reload = entry.disk.automatic(
                    self.gpa,
                    self.io,
                    document,
                    &entry.viewport.goal,
                );
                self.announce(reload, false);
                self.redraw = reload != null or self.redraw;
            }
            // The finder never scrolls the document behind it.
            if (!self.finding) entry.viewport.follow(
                &entry.document.buffer,
                self.size.rows -| 1,
                self.size.columns -| 1,
                self.editor.mode() == .insert,
            );
        }
        return null;
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
                self.status.set("Not enough memory; finder results may be incomplete");
                self.redraw = true;
            };
            if (self.finding) self.redraw = true;
        }
    }

    fn editorEvent(self: *App, event: input.Event) void {
        const entry = self.documents.current().?;
        const buffer = &entry.document.buffer;
        const request = self.editor.feed(
            self.gpa,
            buffer,
            &entry.viewport,
            &self.status,
            event,
        );
        switch (request orelse return) {
            .find => {
                self.browsing = false;
                self.find(self.finder.category);
            },
            .command_line => self.command_line.begin(),
        }
    }

    fn commandLineEvent(self: *App, event: input.Event) void {
        switch (self.command_line.feed(event) orelse return) {
            .run => |requested| self.fileAction(requested),
            .invalid => self.status.set("Unsupported command"),
            .cancel => self.status.clear(),
        }
    }

    fn finderEvent(self: *App, event: input.Event) void {
        switch (event) {
            // A paste never reaches the query.
            .ignored, .paste_begin, .paste_byte, .paste_end => return,
            else => {},
        }
        self.status.clear();
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
                0x18 => return self.command_line.begin(),
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
            .escape => self.browsing = true,
            .key => |byte| switch (byte) {
                3 => self.browsing = true,
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
        const results = finder_view.layout(self.finder, self.size).results;
        const half: isize = @intCast(@max(results / 2, 1));
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
            ':' => self.command_line.begin(),
            else => {},
        }
    }

    fn move(self: *App, delta: isize) void {
        self.finder.move(self.gpa, self.io, self.background, delta);
    }

    /// Focuses the finder on `category`, which discovers it again.
    fn find(self: *App, category: Category) void {
        self.status.clear();
        self.finding = true;
        self.redraw = true;
        const open = self.gpa.alloc(OpenFile, self.documents.entries.items.len) catch {
            self.status.set("Not enough memory; finder not refreshed");
            return;
        };
        defer self.gpa.free(open);
        for (self.documents.entries.items, open) |*entry, *listed| listed.* = .{
            .id = @fromBackingInt(@backingInt(entry.id)),
            .path = entry.document.source.path,
            .used = entry.used,
        };
        self.finder.focus(self.gpa, self.io, self.background, category, open) catch {
            self.status.set("Not enough memory; finder results may be incomplete");
        };
    }

    /// Leaves the list for the editor; without a document there is nowhere to go.
    fn dismiss(self: *App) void {
        if (self.documents.current() == null) {
            self.status.set("No file open; :q quits");
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
                self.status.set("Query exceeds 256 bytes");
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
            self.status.set(switch (err) {
                error.QueryTooLong => "Query exceeds 256 bytes",
                error.OutOfMemory => "Not enough memory; results may not match the query",
            });
        };
    }

    /// Opens the selection, or activates it when it is already open.
    fn choose(self: *App) void {
        std.debug.assert(self.editor.idle());
        const choice = self.finder.choice() orelse return;
        switch (choice) {
            .document => |listed| {
                const id: session.Id = @fromBackingInt(@backingInt(listed));
                // A close whose relisting ran out of memory leaves its row.
                if (self.documents.get(id) == null) {
                    self.find(self.finder.category);
                    if (self.status.len == 0) self.status.set("File no longer open");
                    return;
                }
                self.announce(self.documents.activate(self.gpa, self.io, id), false);
            },
            .path => |path| {
                // Only discovered listings offer paths, and they need the root.
                const root = self.finder.root.?.dir;
                const opened = self.documents.open(self.gpa, self.io, root, path) catch |err| {
                    self.status.print("Cannot open: {s}", .{openFailure(err)});
                    return;
                };
                self.announce(opened.activation, false);
            },
        }
        self.finder.leave(self.gpa, self.io, self.background);
        self.finding = false;
    }

    /// Runs a file command from either screen. Closing the last document
    /// exits, as does quitting without one; the other commands need one.
    fn fileAction(self: *App, action: command_line.File) void {
        std.debug.assert(self.editor.idle());
        switch (action) {
            .quit => |discard| {
                const entry = self.documents.current() orelse {
                    self.exit = 0;
                    return;
                };
                const name = self.named(entry);
                // Written before closing frees the path.
                var text: [Status.capacity]u8 = undefined;
                var notice: std.Io.Writer = .fixed(&text);
                const modified = entry.document.buffer.modified();
                const verb = if (modified) "Discarded edits and closed" else "Closed";
                notice.print("{s} {f}", .{ verb, name }) catch unreachable;
                const id = entry.id;
                const closing = self.documents.close(self.gpa, self.io, id, discard);
                const activation = closing catch {
                    self.status.print("Unsaved changes in {f}; use :q! to discard", .{name});
                    return;
                };
                self.closed(&notice, activation);
            },
            .quit_all => |discard| {
                if (discard or self.documents.unsaved() == 0) {
                    self.exit = 0;
                    return;
                }
                var text: [Status.capacity]u8 = undefined;
                self.status.set(self.blockers(&text));
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
                const entry = self.documents.current() orelse return self.refuse();
                const name = self.named(entry);
                // Written before closing frees the path. A close follows only
                // a save that `saveNotice` reports as plain `Written`.
                var text: [Status.capacity]u8 = undefined;
                var notice: std.Io.Writer = .fixed(&text);
                notice.print("Written and closed {f}", .{name}) catch unreachable;
                const closing = self.documents.saveAndClose(self.gpa, self.io, .{});
                if (!closing.closed) return self.saved(closing.report, false);
                self.closed(&notice, closing.activation);
            },
            .reload => {
                const entry = self.documents.current() orelse return self.refuse();
                const reload = entry.disk.reload(
                    self.gpa,
                    self.io,
                    &entry.document,
                    &entry.viewport.goal,
                );
                self.announce(reload, true);
            },
        }
    }

    /// `entry`'s path as a notice names it, borrowed from the entry.
    fn named(self: *const App, entry: *const session.Entry) NoticePath {
        return .{ .path = self.finder.display(entry.document.source.path) };
    }

    fn refuse(self: *App) void {
        self.status.set("No file open");
    }

    /// Says what reloading the active document did, naming it; nothing when
    /// no reload was attempted. `explicit` is `:e!`.
    fn announce(self: *App, reload: ?Disk.Reload, explicit: bool) void {
        const attempt = reload orelse return;
        // Named only now: a successful reload replaces the path.
        const name = self.named(self.documents.current().?);
        var text: [Status.capacity]u8 = undefined;
        var notice: std.Io.Writer = .fixed(&text);
        reloaded(&notice, attempt, explicit, name) catch unreachable;
        text[0] = std.ascii.toUpper(text[0]);
        self.status.set(notice.buffered());
    }

    /// Closing the last document exits. Otherwise `notice`, which says what
    /// was closed, goes on to name the next document if activating it
    /// reloaded it, and a focused finder lists what remains.
    fn closed(self: *App, notice: *std.Io.Writer, activation: ?Disk.Reload) void {
        const next = self.documents.current() orelse {
            self.exit = 0;
            return;
        };
        if (activation) |reload| {
            const name = self.named(next);
            notice.writeAll("; ") catch unreachable;
            reloaded(notice, reload, false, name) catch unreachable;
        }
        if (self.finding) {
            self.find(self.finder.category);
            // A relisting failure follows the close notice rather than hiding
            // it, cut short if it would not fit.
            const failure = self.status.text();
            if (failure.len != 0) {
                const first = std.ascii.toLower(failure[0]);
                notice.print("; {c}{s}", .{ first, failure[1..] }) catch {};
            }
        }
        self.status.set(notice.buffered());
    }

    fn saved(self: *App, result: file.Report, copy: bool) void {
        const notice = saveNotice(result, copy);
        if (!result.cleanup_failure) return self.status.set(notice);
        self.status.print("{s}; cleanup failed", .{notice});
    }

    /// Names every file with unsaved edits, as the finder lists them, in
    /// `text`.
    fn blockers(self: *App, text: *[Status.capacity]u8) []const u8 {
        const suffix = "; :qa! discards them";
        const more = " ...";
        const count = self.documents.unsaved();
        const start = std.fmt.bufPrint(text, "Unsaved changes in {d} file{s}:", .{
            count,
            if (count == 1) "" else "s",
        }) catch unreachable;
        var used = start.len;
        const limit = text.len - suffix.len - more.len;
        var separator: []const u8 = " ";
        for (self.documents.entries.items) |*entry| {
            if (!entry.document.buffer.modified()) continue;
            const name = self.finder.display(entry.document.source.path);
            if (used + separator.len + name.len > limit) {
                @memcpy(text[used..][0..more.len], more);
                used += more.len;
                break;
            }
            @memcpy(text[used..][0..separator.len], separator);
            used += separator.len;
            @memcpy(text[used..][0..name.len], name);
            used += name.len;
            separator = ", ";
        }
        @memcpy(text[used..][0..suffix.len], suffix);
        return text[0 .. used + suffix.len];
    }

    fn draw(self: *App) terminal.Error!void {
        var frame: Frame = .{ .screen = self.terminal };
        // A pending clipboard write leads the frame, whichever screen it shows.
        if (self.editor.clipboard) try setClipboard(&frame, self.editor.register('"').text);
        try self.compose(&frame);
        // The reset ends every frame and nothing else; tests synchronise on it.
        try frame.append("\x1b[0m");
        try frame.flush();
        // Only now has the whole write reached the terminal. An interrupted
        // frame leaves it pending, so the next frame sends it again in full.
        self.editor.clipboard = false;
    }

    /// Clears the terminal and draws the focused screen into `frame`.
    fn compose(self: *App, frame: *Frame) terminal.Error!void {
        try frame.append("\x1b[?25l\x1b[H\x1b[2J");
        const status = self.status.text();
        const line = if (self.command_line.open) self.command_line.line.text() else null;
        if (self.finding) return finder_view.draw(
            frame,
            self.size,
            self.finder,
            &self.documents,
            status,
            line,
            self.browsing,
        );
        const entry = self.documents.current().?;
        try editor_view.draw(frame, self.size, entry, &self.editor, status, line);
    }
};

/// A path in a notice, keeping its end when longer than `limit` bytes. Two
/// paths and the longest close and reload text fit in a `Status`.
const NoticePath = struct {
    path: []const u8,

    const limit = 160;

    pub fn format(self: NoticePath, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.path.len <= limit) return writer.writeAll(self.path);
        try writer.writeAll("...");
        try writer.writeAll(self.path[self.path.len - (limit - 3) ..]);
    }
};

/// Writes what reloading `name` did, as a lowercase clause; `explicit` is `:e!`.
fn reloaded(
    writer: *std.Io.Writer,
    reload: Disk.Reload,
    explicit: bool,
    name: NoticePath,
) std.Io.Writer.Error!void {
    switch (reload) {
        .reloaded => if (explicit)
            try writer.print("reloaded {f}; local edits and history discarded", .{name})
        else
            try writer.print("reloaded external changes to {f}; history cleared", .{name}),
        .failed => try writer.print("reload of {f} failed; local state retained", .{name}),
        .out_of_memory => {
            const text = "reload of {f} failed: not enough memory; local state retained";
            try writer.print(text, .{name});
        },
    }
}

/// Why a file could not be opened, as a lowercase fragment.
pub fn openFailure(err: file.Error) []const u8 {
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
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
    const b = (try app.documents.open(testing.allocator, testing.io, temp.dir, "b")).id;
    app.find(.open);
    try testing.expectEqual(b, chosen(&finder));
    // As when relisting after the close runs out of memory.
    _ = try app.documents.close(testing.allocator, testing.io, b, false);
    app.choose();
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expect(app.finding);
    try testing.expectEqualStrings("File no longer open", app.status.text());
    try testing.expectEqual(a, chosen(&finder));
    try testing.expectEqual(@as(usize, 1), finder.matches.len);
}

const linux = std.os.linux;
const posix = std.posix;

test "save notices distinguish failure, uncertain publication and installed durability" {
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .failure = error.SourceChanged }, false), "Source changed"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .uncertain, .failure = error.PublishFailed }, false), "Save outcome uncertain"));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .failure = error.SourceChanged }, false), "Bytes installed but changed/unverified"));
    try std.testing.expectEqualStrings("Bytes installed and verified; durability not confirmed", saveNotice(.{ .publication = .installed, .verified = true, .failure = error.SyncFailed }, false));
    try std.testing.expect(std.mem.startsWith(u8, saveNotice(.{ .publication = .installed, .verified = true, .durable = true, .failure = error.InjectedFailure }, false), "Bytes installed and verified"));
    try std.testing.expectEqualStrings("Written", saveNotice(.{ .publication = .installed, .verified = true, .durable = true }, false));
}

test "the search prompt and its matches are drawn until Escape in normal mode hides them" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "ab x\nAB\tab\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
        .size = .{ .rows = 4, .columns = 11 },
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    // Three content rows and the status row, ten columns wide.
    const matches = "\x1b[1;1H\x1b[7mab\x1b[27m" ++
        "\x1b[2;1H\x1b[7mAB\x1b[27m" ++
        "\x1b[2;9H\x1b[7mab\x1b[27m";
    for ("/ab") |byte| app.editorEvent(.{ .key = byte });
    var frame: Frame = .{ .screen = undefined };
    try app.compose(&frame);
    const prompt = frame.bytes[0..frame.len];
    try testing.expect(std.mem.indexOf(u8, prompt, "\x1b[7m/ab       \x1b[27m") != null);
    try testing.expect(std.mem.endsWith(u8, prompt, matches ++ "\x1b[4;4H\x1b[?25h"));
    app.editorEvent(.{ .key = '\r' });
    frame.len = 0;
    try app.compose(&frame);
    const kept = frame.bytes[0..frame.len];
    try testing.expect(std.mem.endsWith(u8, kept, matches ++ "\x1b[2;1H\x1b[?25h"));
    app.editorEvent(.escape);
    frame.len = 0;
    try app.compose(&frame);
    // Only the status row is in reverse video.
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, frame.bytes[0..frame.len], "\x1b[7m"));
    app.editorEvent(.{ .key = 'n' });
    frame.len = 0;
    try app.compose(&frame);
    const repeated = frame.bytes[0..frame.len];
    try testing.expect(std.mem.endsWith(u8, repeated, matches ++ "\x1b[2;9H\x1b[?25h"));
    // A long query keeps its end visible and a cell after it for the cursor.
    for ("?abcdefghijk") |byte| app.editorEvent(.{ .key = byte });
    frame.len = 0;
    try app.compose(&frame);
    const long = frame.bytes[0..frame.len];
    try testing.expect(std.mem.indexOf(u8, long, "\x1b[7m?defghijk \x1b[27m") != null);
    try testing.expect(std.mem.endsWith(u8, long, "\x1b[4;10H\x1b[?25h"));
}

test "closing names the closed file and the next file when activating it reloads" {
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
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    // Without a root, the finder displays absolute paths.
    var a_path: [std.fs.max_path_bytes]u8 = undefined;
    var b_path: [std.fs.max_path_bytes]u8 = undefined;
    const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
    const a_name = copyPath(&a_path, &app, a);
    const b = (try app.documents.open(testing.allocator, testing.io, temp.dir, "b")).id;
    const b_name = copyPath(&b_path, &app, b);
    // Inactive a changes on disk; closing b activates and reloads it.
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "changed\n" });
    app.fileAction(.{ .quit = false });
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqualStrings("changed\n", app.documents.current().?.document.buffer.bytes());
    const text = "Closed {s}; reloaded external changes to {s}; history cleared";
    try expectNotice(&app, text, .{ b_name, a_name });
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "b");
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "again\n" });
    app.fileAction(.write_quit);
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqualStrings("again\n", app.documents.current().?.document.buffer.bytes());
    const both = "Written and closed {s}; reloaded external changes to {s}; history cleared";
    try expectNotice(&app, both, .{ b_name, a_name });
    // Nothing reloads: the notice names only the closed file.
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "b");
    app.fileAction(.{ .quit = false });
    try expectNotice(&app, "Closed {s}", .{b_name});
    // A next file that fails to reload is named the same way.
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "b");
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "unreadable\n" });
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.fchmodat(temp.dir.handle, "a", 0)));
    defer _ = linux.fchmodat(temp.dir.handle, "a", 0o600);
    app.fileAction(.{ .quit = false });
    const kept = app.documents.current().?.document.buffer.bytes();
    if (std.mem.eql(u8, kept, "again\n")) {
        const failed = "Closed {s}; reload of {s} failed; local state retained";
        try expectNotice(&app, failed, .{ b_name, a_name });
    } // else running as root, which reads the file anyway.
    try testing.expect(app.exit == null);
}

test "closing from the finder names the file whose edits it refuses or discards" {
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
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    var b_path: [std.fs.max_path_bytes]u8 = undefined;
    const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
    const b = (try app.documents.open(testing.allocator, testing.io, temp.dir, "b")).id;
    const b_name = copyPath(&b_path, &app, b);
    for ("iZ") |byte| app.editorEvent(.{ .key = byte });
    app.editorEvent(.escape);
    // The finder highlights a while its commands act on the active b.
    app.find(.open);
    app.finderEvent(.{ .key = 0x0e });
    try testing.expectEqual(a, chosen(&finder));
    app.fileAction(.{ .quit = false });
    const refused = "Unsaved changes in {s}; use :q! to discard";
    try expectNotice(&app, refused, .{b_name});
    try testing.expectEqual(b, app.documents.active.?);
    app.fileAction(.{ .quit = true });
    const discarded = "Discarded edits and closed {s}";
    try expectNotice(&app, discarded, .{b_name});
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expect(app.finding);
}

test "a close whose relisting runs out of memory still names the closed file" {
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
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    var b_path: [std.fs.max_path_bytes]u8 = undefined;
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    var failures: usize = 0;
    var index: usize = 0;
    while (true) : (index += 1) {
        const b = (try app.documents.open(testing.allocator, testing.io, temp.dir, "b")).id;
        const b_name = copyPath(&b_path, &app, b);
        // Open starts no job, so only this thread uses the failing allocator.
        app.find(.open);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        app.gpa = failing.allocator();
        app.fileAction(.{ .quit = false });
        app.gpa = testing.allocator;
        var expected: [512]u8 = undefined;
        const closed = try std.fmt.bufPrint(&expected, "Closed {s}", .{b_name});
        try testing.expect(std.mem.startsWith(u8, app.status.text(), closed));
        if (!failing.has_induced_failure) break;
        const rest = app.status.text()[closed.len..];
        if (std.mem.startsWith(u8, rest, "; not enough memory; finder")) failures += 1;
    }
    try testing.expect(failures != 0);
}

test "a long path in a notice keeps its end" {
    const testing = std.testing;
    var long: [409]u8 = undefined;
    for (0..200) |index| @memcpy(long[index * 2 ..][0..2], "/d");
    @memcpy(long[400..], "/name.zig");
    const path: []const u8 = &long;
    var storage: [512]u8 = undefined;
    var notice: std.Io.Writer = .fixed(&storage);
    try notice.print("Discarded edits and closed {f}", .{NoticePath{ .path = path }});
    const shown = notice.buffered()["Discarded edits and closed ".len..];
    try testing.expectEqual(NoticePath.limit, shown.len);
    try testing.expect(std.mem.startsWith(u8, shown, "..."));
    try testing.expect(std.mem.endsWith(u8, shown, "/d/name.zig"));
    // The longest close notice, with two long names, fits the notice buffer.
    try notice.writeAll("; ");
    try reloaded(&notice, .out_of_memory, false, .{ .path = path });
}

test "a relisting failure that would overflow the close notice is cut short" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    app.find(.open);
    var text: [Status.capacity]u8 = undefined;
    var notice: std.Io.Writer = .fixed(&text);
    try notice.writeAll("Closed ");
    try notice.splatByteAll('x', Status.capacity - notice.end - 8);
    const closed = notice.buffered().len;
    // Open starts no job, so only this thread uses the failing allocator.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    app.gpa = failing.allocator();
    app.closed(&notice, null);
    app.gpa = testing.allocator;
    try testing.expect(failing.has_induced_failure);
    try testing.expectEqual(Status.capacity, app.status.text().len);
    try testing.expect(std.mem.startsWith(u8, app.status.text(), "Closed xxx"));
    try testing.expectEqualStrings("; not en", app.status.text()[closed..]);
}

test "the finder's unsaved mark follows a save made from the finder" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
        .size = .{ .rows = 10, .columns = 40 },
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    for ("iZ") |byte| app.editorEvent(.{ .key = byte });
    app.editorEvent(.escape);
    app.find(.open);
    var frame: Frame = .{ .screen = undefined };
    try app.compose(&frame);
    const row = "\x1b[7m>+  ";
    try testing.expect(std.mem.indexOf(u8, frame.bytes[0..frame.len], row) != null);
    app.fileAction(.{ .write = "" });
    try testing.expectEqualStrings("Written", app.status.text());
    frame.len = 0;
    try app.compose(&frame);
    try testing.expect(std.mem.indexOf(u8, frame.bytes[0..frame.len], "\x1b[7m>   ") != null);
}

test "reloading names the file it reloaded or failed to reload" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    var a_path: [std.fs.max_path_bytes]u8 = undefined;
    const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
    const a_name = copyPath(&a_path, &app, a);
    for ("iZ") |byte| app.editorEvent(.{ .key = byte });
    app.editorEvent(.escape);
    app.fileAction(.reload);
    try testing.expectEqualStrings("alpha\n", app.documents.current().?.document.buffer.bytes());
    const done = "Reloaded {s}; local edits and history discarded";
    try expectNotice(&app, done, .{a_name});
    try temp.dir.deleteFile(testing.io, "a");
    app.fileAction(.reload);
    const failed = "Reload of {s} failed; local state retained";
    try expectNotice(&app, failed, .{a_name});
}

test "choosing an open file that changed on disk names it as it reloads" {
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
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    var a_path: [std.fs.max_path_bytes]u8 = undefined;
    const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
    const a_name = copyPath(&a_path, &app, a);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "b");
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "changed\n" });
    app.find(.open);
    app.move(1);
    try testing.expectEqual(a, chosen(&finder));
    app.choose();
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqualStrings("changed\n", app.documents.current().?.document.buffer.bytes());
    try expectNotice(&app, "Reloaded external changes to {s}; history cleared", .{a_name});
}

test "a clean file changed on disk reloads only after every pending state ends" {
    const testing = std.testing;
    // Each case's keys leave one pending state and its closing keys end it.
    const cases = [_]struct { keys: []const u8, close: []const u8 }{
        .{ .keys = "2", .close = "\x03" }, // count
        .{ .keys = "g", .close = "\x03" },
        .{ .keys = "\"", .close = "\x03" }, // register name awaited
        .{ .keys = "\"a", .close = "\x03" }, // register chosen
        .{ .keys = "d", .close = "\x03" }, // operator
        .{ .keys = "i", .close = "\x03" }, // insert
        .{ .keys = "/x", .close = "\x03" }, // search prompt
        .{ .keys = ":q", .close = "\x03" }, // command line
        .{ .keys = "\x1b[200~x", .close = "\x1b[201~" }, // paste, ignored in normal mode
    };
    for (cases) |case| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
        var background: jobs.Jobs = try .init();
        var finder: Finder = .{};
        defer finder.deinit(testing.allocator, testing.io);
        defer background.deinit(testing.allocator, testing.io);
        var app: App = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .terminal = undefined,
            .background = &background,
            .finder = &finder,
            .size = .{ .rows = 4, .columns = 20 },
        };
        defer app.editor.deinit(testing.allocator);
        defer app.documents.deinit(testing.allocator);
        const a = (try app.documents.open(testing.allocator, testing.io, temp.dir, "a")).id;
        var a_path: [std.fs.max_path_bytes]u8 = undefined;
        const a_name = copyPath(&a_path, &app, a);
        const entry = app.documents.current().?;
        var decoder: input.Decoder = .{};
        try testing.expect(app.step(&decoder, case.keys, false, 0) == null);
        try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "beta\n" });
        app.watched();
        try testing.expectEqualStrings("DISK CONFLICT | ", entry.disk.status());
        try testing.expect(app.step(&decoder, "", false, 0) == null);
        try testing.expectEqualStrings("alpha\n", entry.document.buffer.bytes());
        try testing.expect(app.step(&decoder, case.close, false, 0) == null);
        try testing.expectEqualStrings("beta\n", entry.document.buffer.bytes());
        try expectNotice(&app, "Reloaded external changes to {s}; history cleared", .{a_name});
    }
}

test "every read that delivers an event draws, except while a paste is arriving" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "one\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
        .size = .{ .rows = 4, .columns = 20 },
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    var decoder: input.Decoder = .{};
    // A count digit, a register prefix and an unknown sequence change nothing
    // visible, yet each read draws.
    for ([_][]const u8{ "2", "\"a", "\x1b[99~" }) |read| {
        app.redraw = false;
        try testing.expect(app.step(&decoder, read, false, 0) == null);
        try testing.expect(app.redraw);
    }
    // The first byte of an Escape sequence delivers nothing yet.
    app.redraw = false;
    try testing.expect(app.step(&decoder, "\x1b", false, 0) == null);
    try testing.expect(!app.redraw);
    try testing.expect(app.step(&decoder, "", true, 1000) == null);
    try testing.expect(app.redraw);
    // A paste draws only once its end arrives, even when keys preceded it.
    app.redraw = false;
    try testing.expect(app.step(&decoder, "i\x1b[200~ab", false, 0) == null);
    try testing.expect(!app.redraw);
    try testing.expect(app.step(&decoder, "c", false, 0) == null);
    try testing.expect(!app.redraw);
    try testing.expect(app.step(&decoder, "\x1b[201~", false, 0) == null);
    try testing.expect(app.redraw);
    try testing.expectEqualStrings("abcone\n", app.documents.current().?.document.buffer.bytes());
}

test "the command line means the same on either screen and leaves the editor idle" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "one\n" });
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    defer finder.deinit(testing.allocator, testing.io);
    defer background.deinit(testing.allocator, testing.io);
    var app: App = .{
        .gpa = testing.allocator,
        .io = testing.io,
        .terminal = undefined,
        .background = &background,
        .finder = &finder,
        .size = .{ .rows = 4, .columns = 20 },
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    var decoder: input.Decoder = .{};
    try testing.expect(app.step(&decoder, ":x", false, 0) == null);
    try testing.expect(app.command_line.open);
    try testing.expect(app.editor.idle());
    try testing.expect(app.step(&decoder, "\r", false, 0) == null);
    try testing.expectEqualStrings("Unsupported command", app.status.text());
    try testing.expect(app.step(&decoder, ":\x03", false, 0) == null);
    try testing.expectEqualStrings("", app.status.text());
    // Open starts no job, unlike the Ctrl-P that would show it. Ctrl-X opens
    // the line while searching, `:` while browsing the list.
    app.find(.open);
    for ([_][]const u8{ "\x18x\r", "\x1b", ":x\r" }) |keys| {
        try testing.expect(app.step(&decoder, keys, false, 0) == null);
    }
    try testing.expectEqualStrings("Unsupported command", app.status.text());
    try testing.expect(app.browsing);
    try testing.expect(app.step(&decoder, "\x18w\r", false, 0) == null);
    try testing.expectEqualStrings("Written", app.status.text());
    try testing.expect(app.finding);
}

/// Copies document `id`'s path, which closing it frees, into `buffer`.
fn copyPath(buffer: []u8, app: *App, id: session.Id) []const u8 {
    const path = app.documents.get(id).?.document.source.path;
    @memcpy(buffer[0..path.len], path);
    return buffer[0..path.len];
}

fn expectNotice(app: *const App, comptime text: []const u8, arguments: anytype) !void {
    var expected: [512]u8 = undefined;
    const notice = try std.fmt.bufPrint(&expected, text, arguments);
    try std.testing.expectEqualStrings(notice, app.status.text());
}

/// The session's id for the document the finder's selection names.
fn chosen(finder: *const Finder) session.Id {
    return @fromBackingInt(@backingInt(finder.choice().?.document));
}
