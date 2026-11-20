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
const Location = @import("finder/finder.zig").Location;
const Place = @import("finder/finder.zig").Place;
const preview = @import("finder/preview.zig");
const Frame = @import("terminal/frame.zig").Frame;
const setClipboard = @import("terminal/frame.zig").setClipboard;
const editor_view = @import("views/editor_view.zig");
const finder_view = @import("views/finder_view.zig");
const client = @import("lsp/client.zig");
const protocol = @import("lsp/protocol.zig");
const position = @import("lsp/position.zig");
const format = @import("text/format.zig");
const linux = std.os.linux;

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
    defer for (&app.servers) |*server| server.deinit(init.gpa, init.io);
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
    servers: [client.servers.len]client.Client = clients: {
        var all: [client.servers.len]client.Client = undefined;
        for (&all, &client.servers) |*one, *server| one.* = .{ .server = server };
        break :clients all;
    },
    /// The navigation key awaiting its server's answer.
    waiting: ?Waiting = null,

    fn loop(self: *App) !u8 {
        var suspension_count = self.terminal.suspension_count;
        var resumption_count = self.terminal.resumption_count;
        var decoder: input.Decoder = .{};
        while (true) {
            var bytes: []const u8 = &.{};
            var expired = false;
            const watch_fd = if (self.documents.current()) |entry| entry.disk.watch.fd else -1;
            // The watch, the jobs' wakeup, then each server's output and input.
            var descriptors: [2 + 2 * client.servers.len]linux.pollfd = undefined;
            descriptors[0] = .{ .fd = watch_fd, .events = linux.POLL.IN, .revents = 0 };
            const wake_fd = self.background.wake_fd;
            descriptors[1] = .{ .fd = wake_fd, .events = linux.POLL.IN, .revents = 0 };
            for (&self.servers, 0..) |*server, index| {
                descriptors[2 + 2 * index ..][0..2].* = server.descriptors();
            }
            const event = try self.terminal.next(decoder.deadline, &descriptors);
            switch (event) {
                .ready => {
                    if (descriptors[0].revents != 0) self.watched();
                    if (descriptors[1].revents != 0) self.collect();
                    for (&self.servers, 0..) |*server, index| {
                        const polled = descriptors[2 + 2 * index ..][0..2].*;
                        if (polled[0].revents | polled[1].revents == 0) continue;
                        self.serverChanged(index, server.ready(self.gpa, self.io, polled));
                    }
                },
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
            try self.present();
            self.startServer();
            // A request whose server just failed to start says so.
            try self.present();
        }
    }

    /// Draws a frame if anything changed since the last one.
    fn present(self: *App) terminal.Error!void {
        if (!self.redraw) return;
        self.redraw = false;
        self.draw() catch |err| {
            if (err != error.Interrupted) return err;
        };
    }

    fn startServer(self: *App) void {
        if (self.waiting) |waiting| {
            if (self.documents.get(waiting.document)) |entry| {
                const path = entry.document.source.path;
                self.startIdle(waiting.server, path) catch {
                    self.waiting = null;
                    self.failedStart(&self.servers[waiting.server]);
                    self.redraw = true;
                };
            }
        }
        const entry = self.documents.current() orelse return;
        const path = entry.document.source.path;
        // With no request waiting, a failure is reported by the next key.
        self.startIdle(client.serverFor(path) orelse return, path) catch {};
    }

    /// Starts server `index` for `path` if it is idle and the root is known.
    fn startIdle(self: *App, index: usize, path: []const u8) error{StartFailed}!void {
        const server = &self.servers[index];
        if (server.state != .idle) return;
        server.start(self.gpa, self.io, self.serverRoot(path) orelse return);
        if (server.state != .running) return error.StartFailed;
    }

    /// Where a server for `path` runs: the finder's root, else the file's
    /// directory once the root is known to have failed; null until then.
    fn serverRoot(self: *const App, path: []const u8) ?[]const u8 {
        if (self.finder.root) |root| return root.path;
        if (self.finder.root_failure == null) return null;
        return std.fs.path.dirname(path) orelse "/";
    }

    /// Acts on what server `index` just did: reports once, by name, a server
    /// that exited or refused to start, sends a request that waited for
    /// initialization, and applies an answer. Nothing else is drawn.
    fn serverChanged(self: *App, index: usize, change: client.Change) void {
        const server = &self.servers[index];
        const asked = if (self.waiting) |waiting| waiting.server == index else false;
        if (change.exited) {
            if (asked) self.waiting = null;
            self.unavailable(server);
            self.redraw = true;
            return;
        }
        if (!asked) return;
        // A server initializes once per start, before any request is sent.
        if (change.initialized) {
            self.send();
            self.redraw = true;
        }
        if (change.answered) {
            self.arrive(server);
            self.redraw = true;
        }
    }

    /// Says why `server` can't be asked: gone, never found or refused.
    fn unavailable(self: *App, server: *const client.Client) void {
        const name = server.server.name;
        switch (server.state) {
            .unavailable => self.failedStart(server),
            else => self.status.print("{s} exited", .{name}),
        }
    }

    /// Says why starting `server` just failed, or why it never can.
    fn failedStart(self: *App, server: *const client.Client) void {
        const name = server.server.name;
        const missing = server.state == .unavailable and server.state.unavailable == error.FileNotFound;
        if (missing) return self.status.print("{s} not found", .{name});
        self.status.print("{s} failed to start", .{name});
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
        // Whatever else they do, Escape and Ctrl-C cancel a waiting request.
        if (event == .escape or (event == .key and event.key == 3)) self.cancel();
        const entry = self.documents.current().?;
        const buffer = &entry.document.buffer;
        const request = self.editor.feed(
            self.gpa,
            buffer,
            &entry.viewport,
            &self.status,
            event,
        );
        if (self.editor.departure) |cursor| {
            self.documents.recordJump(self.documents.place(cursor));
        }
        switch (request orelse return) {
            .find => {
                self.browsing = false;
                self.find(self.finder.category);
            },
            .command_line => self.command_line.begin(),
            .travel => |requested| self.travel(switch (requested.direction) {
                .older => .older,
                .newer => .newer,
            }, requested.count),
            .navigate => |navigation| self.navigate(switch (navigation) {
                .definition => .definition,
                .declaration => .declaration,
                .type_definition => .type_definition,
                .implementation => .implementation,
                .references => .references,
            }),
        }
    }

    /// `gd` and the `gr` keys: asks the active document's server, replacing
    /// a waiting request. Until the server is started and initialized the
    /// request waits. The answer applies in `arrive`.
    fn navigate(self: *App, navigation: protocol.Navigation) void {
        self.cancel();
        const entry = self.documents.current().?;
        const path = entry.document.source.path;
        const index = client.serverFor(path) orelse {
            return self.status.set("No language server for this file");
        };
        const server = &self.servers[index];
        const name = server.server.name;
        // A server sees only editable text (see `syncDocuments`).
        if (!entry.document.buffer.editable) {
            return self.status.print("Read-only file not sent to {s}", .{name});
        }
        if (server.state == .unavailable) return self.unavailable(server);
        // Started again after this key's frame, as at launch (`startServer`).
        if (server.state == .exited) server.state = .idle;
        self.waiting = .{
            .server = index,
            .navigation = navigation,
            .document = entry.id,
            .cursor = entry.document.buffer.cursor,
            .changes = entry.document.buffer.changes,
        };
        self.status.print("Asking {s}...", .{name});
        if (server.capabilities != null) self.send();
    }

    /// Escape, Ctrl-C or another navigation key: forgets the waiting
    /// request, asking its server to drop it if it was sent.
    fn cancel(self: *App) void {
        const waiting = self.waiting orelse return;
        self.waiting = null;
        self.servers[waiting.server].cancel(self.gpa, self.io);
    }

    /// Sends the waiting request to its initialized server, after bringing
    /// the server's documents up to date. A missing provider, a stale request
    /// or a server that dies on the write gets a notice instead.
    fn send(self: *App) void {
        const waiting = self.waiting.?;
        const server = &self.servers[waiting.server];
        const name = server.server.name;
        const capabilities = server.capabilities.?;
        if (!capabilities.offers.contains(waiting.navigation)) {
            const sought = noun(waiting.navigation, 2);
            self.waiting = null;
            return self.status.print("{s} has no {s}", .{ name, sought });
        }
        if (!self.fresh()) return self.stale();
        const entry = self.documents.current().?;
        const buffer = &entry.document.buffer;
        const at = position.position(buffer, buffer.cursor, capabilities.encoding);
        const path = entry.document.source.path;
        var sent = self.syncDocuments(waiting.server);
        if (sent and server.state != .exited) {
            server.navigate(self.gpa, self.io, waiting.navigation, path, at) catch {
                sent = false;
            };
        }
        if (server.state == .exited) {
            self.waiting = null;
            return self.unavailable(server);
        }
        if (!sent) {
            self.waiting = null;
            return self.status.print("Not enough memory; {s} not asked", .{name});
        }
    }

    /// Brings server `index` up to date with the open editable documents of
    /// its language: closes those closed, replaced or made read-only since,
    /// then opens or resends the rest. False when memory ran out; stops early
    /// if the server dies.
    fn syncDocuments(self: *App, index: usize) bool {
        const server = &self.servers[index];
        var kept: usize = 0;
        while (kept < server.documents.items.len and server.state != .exited) {
            const synced = server.documents.items[kept];
            if (self.documents.get(@fromBackingInt(synced.key))) |entry| {
                const document = &entry.document;
                const same = std.mem.eql(u8, document.source.path, synced.path);
                if (document.buffer.editable and same) {
                    kept += 1;
                    continue;
                }
            }
            server.forget(self.gpa, self.io, kept) catch return false;
        }
        for (self.documents.entries.items) |*entry| {
            if (server.state == .exited) return true;
            const document = &entry.document;
            const path = document.source.path;
            if (!document.buffer.editable or client.serverFor(path) != index) continue;
            const buffer = &document.buffer;
            const key = @backingInt(entry.id);
            server.sync(self.gpa, self.io, key, path, buffer.changes, buffer.bytes()) catch {
                return false;
            };
        }
        return true;
    }

    /// Whether the waiting request may still apply: its document is active
    /// with the same cursor and text, and the editor is idle on it, so a jump
    /// may switch and reload documents.
    fn fresh(self: *App) bool {
        const waiting = self.waiting.?;
        if (self.finding or self.command_line.open or !self.editor.idle()) return false;
        const entry = self.documents.current() orelse return false;
        const buffer = &entry.document.buffer;
        return entry.id == waiting.document and buffer.cursor == waiting.cursor and
            buffer.changes == waiting.changes;
    }

    fn stale(self: *App) void {
        const name = self.servers[self.waiting.?.server].server.name;
        self.waiting = null;
        self.status.print("Dropped {s} request; the cursor, text or file changed", .{name});
    }

    /// Applies the answer to the waiting request: one location jumps there,
    /// recording the departure, and several are listed in Locations.
    fn arrive(self: *App, server: *const client.Client) void {
        const name = server.server.name;
        if (!self.fresh()) return self.stale();
        const waiting = self.waiting.?;
        self.waiting = null;
        const locations = switch (server.answer.?) {
            .failed => |message| return self.status.print("{s} failed: {s}", .{ name, message }),
            .locations => |locations| locations,
        };
        if (locations.len == 0) {
            return self.status.print("No {s} found", .{noun(waiting.navigation, 1)});
        }
        if (locations.len > 1) return self.list(server, waiting.navigation, locations);
        const target = locations[0];
        const path = target.path orelse {
            return self.status.print("{s} answered with a location outside local files", .{name});
        };
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        var files: Files = .empty;
        const encoding = server.capabilities.?.encoding;
        const converted = self.locationRow(arena.allocator(), &files, path, target.at, encoding);
        const row = converted catch |err| {
            return self.status.print("Cannot open: {s}", .{openFailure(err)});
        };
        const departure = self.documents.here().?;
        const activation = self.goTo(row.place) catch |err| {
            return self.status.print("Cannot open: {s}", .{openFailure(err)});
        };
        const moved = self.recordDeparture(departure);
        var text: [Status.capacity]u8 = undefined;
        var notice: std.Io.Writer = .fixed(&text);
        if (!moved) {
            notice.print("Already at the {s}", .{noun(waiting.navigation, 1)}) catch unreachable;
        }
        if (activation) |reload| {
            if (notice.end != 0) notice.writeAll("; ") catch unreachable;
            const opened = self.named(self.documents.current().?);
            reloaded(&notice, reload, false, opened) catch unreachable;
        }
        if (notice.end != 0) text[0] = std.ascii.toUpper(text[0]);
        self.status.set(notice.buffered());
    }

    /// Opens Locations, searching, on the answer's locations in local files,
    /// in the server's order. The editor stays where it is. Running out of
    /// memory leaves the finder shut and any earlier rows as they were.
    fn list(
        self: *App,
        server: *const client.Client,
        navigation: protocol.Navigation,
        locations: []const protocol.Location,
    ) void {
        var arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena.deinit();
        const listed = self.locate(arena.allocator(), server, locations) catch {
            return self.status.print("Not enough memory; {s} not listed", .{noun(navigation, 2)});
        };
        if (!listed) {
            const name = server.server.name;
            return self.status.print("{s} answered with locations outside local files", .{name});
        }
        self.showFinder();
        self.browsing = false;
    }

    /// Fills Locations with the answer's locations in local files, with the
    /// open documents, unless none are local. False when none are.
    fn locate(
        self: *App,
        arena: Allocator,
        server: *const client.Client,
        locations: []const protocol.Location,
    ) Allocator.Error!bool {
        const encoding = server.capabilities.?.encoding;
        const rows = try self.locationRows(arena, locations, encoding);
        if (rows.len == 0) return false;
        const omitted = locations.len - rows.len;
        const open = try self.openFiles(arena);
        try self.finder.locate(self.gpa, self.io, self.background, rows, omitted, open);
        return true;
    }

    /// A row for each location in a local file, with its line's text and
    /// its column converted to bytes against that text. Allocated in `arena`,
    /// borrowing paths from `locations` and text from open documents.
    fn locationRows(
        self: *const App,
        arena: Allocator,
        locations: []const protocol.Location,
        encoding: position.Encoding,
    ) Allocator.Error![]Location {
        const listed = try arena.alloc(Location, locations.len);
        var files: Files = .empty;
        var count: usize = 0;
        for (locations) |location| {
            const path = location.path orelse continue;
            listed[count] = try self.locationRow(arena, &files, path, location.at, encoding);
            count += 1;
        }
        return listed[0..count];
    }

    /// The row for position `at` in the file at absolute `path`, with its
    /// line's text from `lineAt` and its column converted to bytes against
    /// that text. Borrows `path`.
    fn locationRow(
        self: *const App,
        arena: Allocator,
        files: *Files,
        path: []const u8,
        at: position.Position,
        encoding: position.Encoding,
    ) Allocator.Error!Location {
        const found = try self.lineAt(arena, files, path, at.line);
        const column = position.column(found.text, at.character, encoding);
        return .{
            .place = .{ .path = path, .line = at.line, .column = @intCast(column) },
            .text = found.text,
            .start = found.start,
        };
    }

    /// The text of each file a row was read from, by absolute path, so each
    /// is read once per answer. Empty when the file couldn't be read.
    const Files = std.StringHashMapUnmanaged([]const u8);

    /// Line `number` of the file at absolute `path`: from its open document,
    /// unsaved edits included, or else from its text in `files`, read into
    /// `arena` on first use. Empty, starting at 0, when there is no such line
    /// or the file can't be read.
    fn lineAt(
        self: *const App,
        arena: Allocator,
        files: *Files,
        path: []const u8,
        number: u32,
    ) Allocator.Error!preview.Line {
        const none: preview.Line = .{ .text = "", .start = 0 };
        for (self.documents.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.document.source.path, path)) continue;
            const buffer = &entry.document.buffer;
            if (number >= buffer.insertionRows()) return none;
            return .{ .text = buffer.line(number), .start = buffer.lineStart(number) };
        }
        const cached = try files.getOrPut(arena, path);
        if (!cached.found_existing) {
            const terminated = try arena.dupeSentinel(u8, path, 0);
            const read = preview.readAll(arena, .cwd(), terminated);
            cached.value_ptr.* = read catch |err| switch (err) {
                error.OutOfMemory => |e| return e,
                else => "",
            };
        }
        return preview.lineOf(cached.value_ptr.*, number) orelse none;
    }

    /// Ctrl-O or Ctrl-I, from an idle editor, so activation may reload.
    fn travel(self: *App, direction: session.Direction, count: usize) void {
        std.debug.assert(self.editor.idle());
        const travelled = self.documents.travel(self.gpa, self.io, direction, count) orelse {
            self.status.set(if (direction == .older) "No older jump" else "No newer jump");
            return;
        };
        self.status.clear();
        self.announce(travelled.activation, false);
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
                '\t' => return self.find(self.finder.next()),
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
        self.showFinder();
        const open = self.openFiles(self.gpa) catch {
            self.status.set("Not enough memory; finder not refreshed");
            return;
        };
        defer self.gpa.free(open);
        self.finder.focus(self.gpa, self.io, self.background, category, open) catch {
            self.status.set("Not enough memory; finder results may be incomplete");
        };
    }

    /// Puts the finder on screen in place of the editor.
    fn showFinder(self: *App) void {
        self.status.clear();
        self.finding = true;
        self.redraw = true;
    }

    /// The open documents as the finder lists them, borrowing their paths.
    /// Allocated in `allocator`.
    fn openFiles(self: *const App, allocator: Allocator) Allocator.Error![]OpenFile {
        const open = try allocator.alloc(OpenFile, self.documents.entries.items.len);
        for (self.documents.entries.items, open) |*entry, *listed| listed.* = .{
            .id = @fromBackingInt(@backingInt(entry.id)),
            .path = entry.document.source.path,
            .used = entry.used,
        };
        return open;
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

    /// Opens the selection, or activates it when it is already open, and
    /// for a location puts the cursor there.
    fn choose(self: *App) void {
        std.debug.assert(self.editor.idle());
        const choice = self.finder.choice() orelse return;
        const departure = self.documents.here();
        defer if (departure) |jump| {
            _ = self.recordDeparture(jump);
        };
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
            .location => |place| {
                const activation = self.goTo(place) catch |err| {
                    self.status.print("Cannot open: {s}", .{openFailure(err)});
                    return;
                };
                self.announce(activation, false);
            },
        }
        self.finder.leave(self.gpa, self.io, self.background);
        self.finding = false;
    }

    /// Opens the file at `place`'s absolute path and puts the cursor on its
    /// line and column, clamped to the text as it is now. Returns how opening
    /// reloaded the file, as `Session.open` does; changes nothing when it
    /// can't be opened. The caller records the departure.
    fn goTo(self: *App, place: Place) file.Error!?Disk.Reload {
        const opened = try self.documents.open(self.gpa, self.io, .cwd(), place.path);
        self.documents.moveTo(place.line, place.column);
        return opened.activation;
    }

    /// Records `departure` as a jump when the cursor is now somewhere else.
    /// True when it is.
    fn recordDeparture(self: *App, departure: session.Jump) bool {
        if (std.meta.eql(self.documents.here().?, departure)) return false;
        self.documents.recordJump(departure);
        return true;
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
            .format => {
                if (self.documents.current() == null) return self.refuse();
                switch (self.formatActive()) {
                    .formatted => self.status.set("Formatted"),
                    .unchanged => self.status.set("Already formatted"),
                    .no_formatter => self.status.set("No formatter for this file"),
                    else => |failure| self.notFormatted("Not formatted", failure),
                }
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

    /// What formatting the active document did, for the caller to word.
    const Formatting = union(enum) {
        formatted,
        unchanged,
        no_formatter,
        read_only,
        /// The file changed on disk, or can't be checked: formatting the
        /// text would dirty a buffer that should reload.
        diverged,
        syntax_error: format.Position,
        too_large,
        out_of_memory,
        not_editable,
    };

    /// Formats the active document with its formatter, if it has one, as one
    /// undoable edit, after checking its file is unchanged on disk. A failure
    /// changes no text; a changed file is marked for reloading.
    fn formatActive(self: *App) Formatting {
        const entry = self.documents.current().?;
        const document = &entry.document;
        const formatter = format.formatterFor(document.source.path) orelse return .no_formatter;
        if (!document.buffer.editable) return .read_only;
        entry.disk.inspect(self.gpa, document, false);
        if (entry.disk.diverged) return .diverged;
        const outcome = format.format(self.gpa, formatter, document.buffer.bytes()) catch {
            return .out_of_memory;
        };
        const formatted = switch (outcome) {
            .formatted => |text| text,
            .unchanged => return .unchanged,
            .syntax_error => |at| return .{ .syntax_error = at },
        };
        defer self.gpa.free(formatted);
        const goal = &entry.viewport.goal;
        self.editor.applyFormatted(self.gpa, &document.buffer, goal, formatted) catch |err| {
            return switch (err) {
                error.OutOfMemory => .out_of_memory,
                error.FileTooLarge, error.TooManyLines => .too_large,
                error.UnsupportedText => .not_editable,
            };
        };
        return .formatted;
    }

    /// Says why `failure` left the text unformatted, after `lead`.
    fn notFormatted(self: *App, lead: []const u8, failure: Formatting) void {
        const reason = switch (failure) {
            .syntax_error => |at| {
                const arguments = .{ lead, at.line, at.column };
                return self.status.print("{s}: syntax error at {d}:{d}", arguments);
            },
            .read_only => "read-only",
            .diverged => "source changed or missing",
            .too_large => "result exceeds temporary 8 MiB or 262,144-line limit",
            .out_of_memory => "not enough memory",
            .not_editable => "result is not editable text",
            .formatted, .unchanged, .no_formatter => unreachable,
        };
        self.status.print("{s}: {s}", .{ lead, reason });
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

/// A navigation key's request, and what must be unchanged for its answer to
/// apply.
const Waiting = struct {
    /// Index in `App.servers`.
    server: usize,
    navigation: protocol.Navigation,
    document: session.Id,
    cursor: usize,
    /// The document's `Buffer.changes` when asked.
    changes: u64,
};

/// What `navigation` looks for, as a lowercase noun for `count` of them.
fn noun(navigation: protocol.Navigation, count: usize) []const u8 {
    const one = count == 1;
    return switch (navigation) {
        .definition => if (one) "definition" else "definitions",
        .declaration => if (one) "declaration" else "declarations",
        .type_definition => if (one) "type definition" else "type definitions",
        .implementation => if (one) "implementation" else "implementations",
        .references => if (one) "reference" else "references",
    };
}

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

test "a selection is drawn with its label instead of search matches until Escape" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "ab x\nab\n" });
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
        .size = .{ .rows = 4, .columns = 21 },
    };
    defer app.editor.deinit(testing.allocator);
    defer app.documents.deinit(testing.allocator);
    _ = try app.documents.open(testing.allocator, testing.io, temp.dir, "a");
    var frame: Frame = .{ .screen = undefined };
    for ("/ab\rlv") |byte| app.editorEvent(.{ .key = byte });
    try app.compose(&frame);
    const characters = frame.bytes[0..frame.len];
    try testing.expect(std.mem.indexOf(u8, characters, "\x1b[7mVISUAL | 2:2 | ") != null);
    const character = "\x1b[2;2H\x1b[7mb\x1b[27m";
    try testing.expect(std.mem.endsWith(u8, characters, character ++ "\x1b[2;2H\x1b[?25h"));
    // Lines, each with its line break cell; the matches stay hidden.
    for ("Vk") |byte| app.editorEvent(.{ .key = byte });
    frame.len = 0;
    try app.compose(&frame);
    const lines = frame.bytes[0..frame.len];
    try testing.expect(std.mem.indexOf(u8, lines, "\x1b[7mVISUAL LINE | 1:2 | ") != null);
    const selected = "\x1b[1;1H\x1b[7mab x \x1b[27m\x1b[2;1H\x1b[7mab \x1b[27m";
    try testing.expect(std.mem.endsWith(u8, lines, selected ++ "\x1b[1;2H\x1b[?25h"));
    // Escape ends the selection and the matches return.
    app.editorEvent(.escape);
    frame.len = 0;
    try app.compose(&frame);
    const matches = "\x1b[1;1H\x1b[7mab\x1b[27m\x1b[2;1H\x1b[7mab\x1b[27m";
    const ended = frame.bytes[0..frame.len];
    try testing.expect(std.mem.endsWith(u8, ended, matches ++ "\x1b[1;2H\x1b[?25h"));
    try testing.expect(std.mem.indexOf(u8, ended, "NORMAL | 1:2") != null);
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
        .{ .keys = "gr", .close = "\x03" },
        .{ .keys = "\"", .close = "\x03" }, // register name awaited
        .{ .keys = "\"a", .close = "\x03" }, // register chosen
        .{ .keys = "d", .close = "\x03" }, // operator
        .{ .keys = "i", .close = "\x03" }, // insert
        .{ .keys = "/x", .close = "\x03" }, // search prompt
        .{ .keys = "v", .close = "\x03" }, // selection
        .{ .keys = "Vl/x\x03", .close = "\x03" }, // selection after its prompt
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

test "Ctrl-O and Tab say when there is no jump and name a file they reload" {
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
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqualStrings("No older jump", app.status.text());
    app.editorEvent(.{ .key = '\t' });
    try testing.expectEqualStrings("No newer jump", app.status.text());
    app.documents.recordJump(app.documents.place(0));
    const b = (try app.documents.open(testing.allocator, testing.io, temp.dir, "b")).id;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "changed\n" });
    app.editorEvent(.{ .key = '2' });
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqualStrings("No older jump", app.status.text());
    try testing.expectEqual(b, app.documents.active.?);
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqual(a, app.documents.active.?);
    try expectNotice(&app, "Reloaded external changes to {s}; history cleared", .{a_name});
    app.editorEvent(.{ .key = '\t' });
    try testing.expectEqual(b, app.documents.active.?);
    try testing.expectEqualStrings("", app.status.text());
}

test "G and switching files in the finder record jumps that Ctrl-O and Tab retrace" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a", .data = "alpha\n" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "b", .data = "beta\nbeta two\n" });
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
    const jumps = &app.documents.jumps;
    app.editorEvent(.{ .key = 'G' });
    try testing.expectEqual(@as(usize, 1), jumps.len);
    // Choosing the document already shown is no switch.
    app.find(.open);
    try testing.expectEqual(b, chosen(&finder));
    app.choose();
    try testing.expectEqual(@as(usize, 1), jumps.len);
    app.find(.open);
    app.move(1);
    app.choose();
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(session.Jump{ .id = b, .line = 1, .column = 0 }, jumps.items[1]);
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqual(b, app.documents.active.?);
    try testing.expectEqual(@as(usize, 5), app.documents.current().?.document.buffer.cursor);
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqual(@as(usize, 0), app.documents.current().?.document.buffer.cursor);
    app.editorEvent(.{ .key = 0x0f });
    try testing.expectEqualStrings("No older jump", app.status.text());
    // Forward to b's last line, then to a, where the first Ctrl-O left.
    app.editorEvent(.{ .key = '2' });
    app.editorEvent(.{ .key = '\t' });
    try testing.expectEqual(a, app.documents.active.?);
    app.editorEvent(.{ .key = '\t' });
    try testing.expectEqualStrings("No newer jump", app.status.text());
}

/// An app on a temporary directory holding `a.zig` and `b.zig`, with `a.zig`
/// open and the cursor on the call to `target`. Its zls has no process: it
/// is initialized by assignment, what Nib sends stays queued, and replies
/// are fed to `reply`. Initialize in place; the app points into it.
const Navigating = struct {
    temp: std.testing.TmpDir,
    background: jobs.Jobs,
    finder: Finder,
    app: App,
    storage: [std.fs.max_path_bytes]u8,
    root: []const u8,

    const a = "const b = @import(\"b.zig\");\npub fn main() void {\n    b.target();\n}\n";
    const b = "pub fn target() void {}\n";
    /// Line 2, column 6.
    const call = 55;

    fn init(self: *Navigating) !void {
        const testing = std.testing;
        self.temp = testing.tmpDir(.{});
        errdefer self.temp.cleanup();
        try self.temp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = a });
        try self.temp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = b });
        self.root = self.storage[0..try self.temp.dir.realPath(testing.io, &self.storage)];
        self.background = try .init();
        self.finder = .{};
        self.app = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .terminal = undefined,
            .background = &self.background,
            .finder = &self.finder,
            .size = .{ .rows = 10, .columns = 40 },
        };
        self.app.servers[0].capabilities = .{ .encoding = .utf8, .offers = .full };
        _ = try self.open("a.zig");
        self.buffer().cursor = call;
    }

    fn deinit(self: *Navigating) void {
        const testing = std.testing;
        self.app.editor.deinit(testing.allocator);
        self.app.documents.deinit(testing.allocator);
        for (&self.app.servers) |*server| server.deinit(testing.allocator, testing.io);
        self.finder.deinit(testing.allocator, testing.io);
        self.background.deinit(testing.allocator, testing.io);
        self.temp.cleanup();
    }

    fn open(self: *Navigating, name: []const u8) !session.Id {
        const testing = std.testing;
        return (try self.app.documents.open(testing.allocator, testing.io, self.temp.dir, name)).id;
    }

    fn buffer(self: *Navigating) *@import("text/buffer.zig").Buffer {
        return &self.app.documents.current().?.document.buffer;
    }

    fn keys(self: *Navigating, bytes: []const u8) void {
        for (bytes) |byte| self.app.editorEvent(.{ .key = byte });
    }

    /// Bytes Nib has queued for zls.
    fn sent(self: *Navigating) []const u8 {
        return self.app.servers[0].queue.items;
    }

    /// A location in `name` as JSON, in `storage`.
    fn location(
        self: *const Navigating,
        storage: []u8,
        name: []const u8,
        line: u32,
        character: u32,
    ) ![]const u8 {
        const range = "\"range\":{{\"start\":{{\"line\":{d},\"character\":{d}}}," ++
            "\"end\":{{\"line\":{d},\"character\":{d}}}}}";
        return std.fmt.bufPrint(storage, "{{\"uri\":\"file://{s}/{s}\"," ++ range ++ "}}", .{
            self.root, name, line, character, line, character,
        });
    }

    /// Answers the pending request with `result`, JSON.
    fn reply(self: *Navigating, result: []const u8) !void {
        try self.replyTo(self.app.servers[0].pending.?, result);
    }

    fn replyTo(self: *Navigating, id: u32, result: []const u8) !void {
        var body: [4096]u8 = undefined;
        const text = "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"result\":{s}}}";
        try self.feed(try std.fmt.bufPrint(&body, text, .{ id, result }));
    }

    /// Delivers one message from zls, as `serverChanged` gets it from a read.
    fn feed(self: *Navigating, body: []const u8) !void {
        var message: [4200]u8 = undefined;
        const framed = try std.fmt.bufPrint(&message, "Content-Length: {d}\r\n\r\n{s}", .{
            body.len,
            body,
        });
        const change = try self.app.servers[0].receive(std.testing.allocator, framed);
        self.app.serverChanged(0, change);
    }
};

test "one location jumps to another file, recording the departure Ctrl-O returns to" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    fixture.keys("gd");
    try testing.expectEqualStrings("Asking zls...", app.status.text());
    // The text goes first, then the request at the cursor.
    const sent = fixture.sent();
    const opened = std.mem.indexOf(u8, sent, "\"method\":\"textDocument/didOpen\"").?;
    const asked = std.mem.indexOf(u8, sent, "\"method\":\"textDocument/definition\"").?;
    try testing.expect(opened < asked);
    const at = "\"position\":{\"line\":2,\"character\":6}";
    try testing.expect(std.mem.indexOf(u8, sent, at) != null);
    var storage: [4096]u8 = undefined;
    app.redraw = false;
    try fixture.reply(try fixture.location(&storage, "b.zig", 0, 7));
    try testing.expect(app.redraw);
    try testing.expect(app.documents.active.? != a);
    try testing.expectEqual(@as(usize, 7), fixture.buffer().cursor);
    try testing.expectEqualStrings("", app.status.text());
    const departure: session.Jump = .{ .id = a, .line = 2, .column = 6 };
    try testing.expectEqual(departure, app.documents.jumps.items[0]);
    fixture.keys("\x0f");
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
}

/// The labels of the finder's current results, in order.
fn expectListed(fixture: *Navigating, expected: []const []const u8) !void {
    const testing = std.testing;
    const finder = fixture.app.finder;
    try testing.expectEqual(expected.len, finder.matches.len);
    for (expected, finder.matches) |label, result| {
        var spelled: [1024]u8 = undefined;
        const full = try std.fmt.bufPrint(&spelled, "{s}/{s}", .{ fixture.root, label });
        try testing.expectEqualStrings(full, finder.row(result).label);
    }
}

/// `grr` answered with `items`, JSON, in a list.
fn answerAll(fixture: *Navigating, items: []const []const u8) !void {
    var several: [4096]u8 = undefined;
    var list: std.Io.Writer = .fixed(&several);
    try list.writeAll("[");
    for (items, 0..) |item, index| {
        if (index != 0) try list.writeAll(",");
        try list.writeAll(item);
    }
    try list.writeAll("]");
    fixture.keys("grr");
    try fixture.reply(list.buffered());
}

const outside_location =
    \\{"uri":"untitled:x","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}
;

test "several locations open Locations with each line's text and leave the editor where it was" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    // An unsaved last line of a.zig, which its row shows.
    const buffer = fixture.buffer();
    const end = buffer.bytes().len;
    try buffer.replace(testing.allocator, .{ .start = end, .end = end }, "// unsaved\n", end);
    buffer.cursor = Navigating.call;
    var storage: [3][1024]u8 = undefined;
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "b.zig", 0, 7),
        try fixture.location(&storage[1], "a.zig", 4, 3),
        try fixture.location(&storage[2], "a.zig", 2, 6),
        outside_location,
    });
    // References include the declaration.
    try testing.expect(std.mem.indexOf(u8, fixture.sent(), "\"includeDeclaration\":true") != null);
    try testing.expect(app.finding and !app.browsing);
    try testing.expectEqual(Category.locations, app.finder.category);
    try testing.expectEqualStrings("", app.status.text());
    try testing.expectEqual(@as(usize, 1), app.finder.locations.omitted);
    try expectListed(&fixture, &.{
        "b.zig:1:8  pub fn target() void {}",
        "a.zig:5:4  // unsaved",
        "a.zig:3:7  b.target();",
    });
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    try testing.expectEqual(@as(usize, 0), app.documents.jumps.len);
    // Enter opens the file at the place and records the departure.
    app.finderEvent(.{ .key = '\r' });
    try testing.expect(!app.finding);
    try testing.expect(app.documents.active.? != a);
    try testing.expectEqual(@as(usize, 7), fixture.buffer().cursor);
    const departure: session.Jump = .{ .id = a, .line = 2, .column = 6 };
    try testing.expectEqual(departure, app.documents.jumps.items[0]);
    fixture.keys("\x0f");
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    // Ctrl-P reopens Locations as it was left; a place in the same file is
    // a jump too, and Ctrl-O comes back from it.
    fixture.keys("\x10");
    try testing.expect(app.finding);
    try testing.expectEqual(Category.locations, app.finder.category);
    app.finderEvent(.{ .key = 0x0e });
    app.finderEvent(.{ .key = '\r' });
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(fixture.buffer().lineStart(4) + 3, fixture.buffer().cursor);
    fixture.keys("\x0f");
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    // Choosing where the cursor already is records nothing.
    const recorded = app.documents.jumps.len;
    fixture.keys("\x10");
    app.finderEvent(.{ .key = 0x0e });
    app.finderEvent(.{ .key = 0x0e });
    app.finderEvent(.{ .key = '\r' });
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    try testing.expectEqual(recorded, app.documents.jumps.len);
    // The next answer replaces the rows; one with no local file opens nothing.
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "a.zig", 1, 4),
        try fixture.location(&storage[1], "a.zig", 2, 6),
    });
    try expectListed(&fixture, &.{ "a.zig:2:5  pub fn main() void {", "a.zig:3:7  b.target();" });
    app.dismiss();
    try answerAll(&fixture, &.{ outside_location, outside_location });
    try testing.expect(!app.finding);
    const nothing = "zls answered with locations outside local files";
    try testing.expectEqualStrings(nothing, app.status.text());
}

test "a location in a missing file or past the text is listed and opens like any choice" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    var storage: [2][1024]u8 = undefined;
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "missing.zig", 0, 4),
        try fixture.location(&storage[1], "b.zig", 99, 3),
    });
    try expectListed(&fixture, &.{ "missing.zig:1:1  ", "b.zig:100:1  " });
    app.finderEvent(.{ .key = '\r' });
    const missing = "Cannot open: file not found; check the path";
    try testing.expectEqualStrings(missing, app.status.text());
    try testing.expect(app.finding);
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, 0), app.documents.jumps.len);
    // Past the text, the cursor is clamped to the last line.
    app.finderEvent(.{ .key = 0x0e });
    app.finderEvent(.{ .key = '\r' });
    try testing.expect(app.documents.active.? != a);
    try testing.expectEqual(@as(usize, 0), fixture.buffer().cursor);
    try testing.expectEqual(@as(usize, 1), app.documents.jumps.len);
}

test "rows in a file that isn't open each take their own line of it, in the server's order" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const text = "first\r\nsecond\nthird";
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "c.zig", .data = text });
    var storage: [4][1024]u8 = undefined;
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "c.zig", 2, 1),
        try fixture.location(&storage[1], "a.zig", 1, 0),
        try fixture.location(&storage[2], "c.zig", 0, 0),
        try fixture.location(&storage[3], "c.zig", 1, 0),
    });
    try expectListed(&fixture, &.{
        "c.zig:3:2  third",
        "a.zig:2:1  pub fn main() void {",
        "c.zig:1:1  first",
        "c.zig:2:1  second",
    });
    const starts = [_]u64{ 14, 28, 0, 7 };
    for (starts, fixture.app.finder.locations.rows) |start, row| {
        try testing.expectEqual(start, row.start);
    }
}

test "one location in a missing file or past the text lands as its Locations row would" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    var storage: [1024]u8 = undefined;
    fixture.keys("gd");
    try fixture.reply(try fixture.location(&storage, "missing.zig", 0, 4));
    const missing = "Cannot open: file not found; check the path";
    try testing.expectEqualStrings(missing, app.status.text());
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    try testing.expectEqual(@as(usize, 0), app.documents.jumps.len);
    // Past the text, the cursor is clamped to the last line's column.
    fixture.keys("gd");
    try fixture.reply(try fixture.location(&storage, "b.zig", 99, 3));
    try testing.expect(app.documents.active.? != a);
    try testing.expectEqual(@as(usize, 0), fixture.buffer().cursor);
    try testing.expectEqual(@as(usize, 1), app.documents.jumps.len);
}

test "running out of memory while listing locations keeps the earlier rows and the editor" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    var storage: [3][1024]u8 = undefined;
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "a.zig", 1, 4),
        try fixture.location(&storage[1], "a.zig", 2, 6),
    });
    app.dismiss();
    var index: usize = 0;
    while (true) : (index += 1) {
        const config: std.testing.FailingAllocator.Config = .{ .fail_index = index };
        var failing: std.testing.FailingAllocator = .init(testing.allocator, config);
        fixture.keys("grr");
        app.gpa = failing.allocator();
        var several: [4096]u8 = undefined;
        try fixture.reply(try std.fmt.bufPrint(&several, "[{s},{s},{s}]", .{
            try fixture.location(&storage[0], "a.zig", 1, 4),
            try fixture.location(&storage[1], "b.zig", 0, 7),
            try fixture.location(&storage[2], "a.zig", 2, 6),
        }));
        app.gpa = testing.allocator;
        if (app.finding) break;
        const refused = "Not enough memory; references not listed";
        try testing.expectEqualStrings(refused, app.status.text());
        const kept = [_][]const u8{ "a.zig:2:5  pub fn main() void {", "a.zig:3:7  b.target();" };
        try expectListed(&fixture, &kept);
        try testing.expectEqual(a, app.documents.active.?);
        try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    }
    try testing.expect(index > 2);
    try expectListed(&fixture, &.{
        "a.zig:2:5  pub fn main() void {",
        "b.zig:1:8  pub fn target() void {}",
        "a.zig:3:7  b.target();",
    });
}

test "none, one here, a location outside local files or an error says so" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    var storage: [1024]u8 = undefined;
    fixture.keys("gd");
    try fixture.reply("null");
    try testing.expectEqualStrings("No definition found", app.status.text());
    fixture.keys("grt");
    try fixture.reply("[]");
    try testing.expectEqualStrings("No type definition found", app.status.text());
    // The only reference is where the cursor is: no jump is recorded.
    fixture.keys("grr");
    try fixture.reply(try fixture.location(&storage, "a.zig", 2, 6));
    try testing.expectEqualStrings("Already at the reference", app.status.text());
    try testing.expectEqual(@as(usize, 0), app.documents.jumps.len);
    // A location outside local files, or an error, changes nothing.
    fixture.keys("gri");
    try fixture.reply(outside_location);
    const outside = "zls answered with a location outside local files";
    try testing.expectEqualStrings(outside, app.status.text());
    fixture.keys("grD");
    var failure: [256]u8 = undefined;
    const id = app.servers[0].pending.?;
    const refused = "{{\"jsonrpc\":\"2.0\",\"id\":{d}," ++
        "\"error\":{{\"code\":-32603,\"message\":\"no index\"}}}}";
    try fixture.feed(try std.fmt.bufPrint(&failure, refused, .{id}));
    try testing.expectEqualStrings("zls failed: no index", app.status.text());
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    try testing.expect(!app.finding);
}

test "an answer after the cursor, the text or the document changed is dropped" {
    const testing = std.testing;
    const Disturbance = enum { cursor, edit, undo, redo, paste, reload, other_document };
    for (std.enums.values(Disturbance)) |disturbance| {
        var fixture: Navigating = undefined;
        try fixture.init();
        defer fixture.deinit();
        const app = &fixture.app;
        // Undo and redo need an edit to replay, made before asking.
        switch (disturbance) {
            .undo => fixture.keys("dl"),
            .redo => fixture.keys("dlu"),
            else => {},
        }
        fixture.buffer().cursor = Navigating.call;
        const before = fixture.buffer().changes;
        fixture.keys("gd");
        switch (disturbance) {
            .cursor => fixture.keys("l"),
            .edit => fixture.keys("dl"),
            .undo => fixture.keys("u"),
            .redo => fixture.keys("\x12"),
            .paste => {
                fixture.keys("i");
                for ([_]input.Event{ .paste_begin, .{ .paste_byte = 'x' }, .paste_end }) |event| {
                    app.editorEvent(event);
                }
            },
            .reload => {
                const changed = Navigating.a ++ "// more\n";
                const dir = fixture.temp.dir;
                try dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = changed });
                app.watched();
                var decoder: input.Decoder = .{};
                _ = app.step(&decoder, "", false, 0);
                try testing.expect(fixture.buffer().changes != before);
            },
            .other_document => _ = try fixture.open("b.zig"),
        }
        const active = app.documents.active.?;
        const cursor = fixture.buffer().cursor;
        var storage: [1024]u8 = undefined;
        try fixture.reply(try fixture.location(&storage, "b.zig", 0, 7));
        const dropped = "Dropped zls request; the cursor, text or file changed";
        try testing.expectEqualStrings(dropped, app.status.text());
        try testing.expectEqual(active, app.documents.active.?);
        try testing.expectEqual(cursor, fixture.buffer().cursor);
        try testing.expectEqual(@as(usize, 0), app.documents.jumps.len);
    }
}

test "Escape and Ctrl-C cancel a request, a second key replaces it, and late answers are ignored" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    var storage: [1024]u8 = undefined;
    const target = try fixture.location(&storage, "b.zig", 0, 7);
    for ([_]input.Event{ .escape, .{ .key = 3 } }) |cancel| {
        fixture.keys("gd");
        const id = app.servers[0].pending.?;
        app.editorEvent(cancel);
        try testing.expectEqualStrings("", app.status.text());
        var cancelled: [128]u8 = undefined;
        const sent = "\"method\":\"$/cancelRequest\",\"params\":{{\"id\":{d}}}}}";
        const message = try std.fmt.bufPrint(&cancelled, sent, .{id});
        try testing.expect(std.mem.endsWith(u8, fixture.sent(), message));
        app.redraw = false;
        try fixture.replyTo(id, target);
        try testing.expect(!app.redraw);
        try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    }
    fixture.keys("gd");
    const first = app.servers[0].pending.?;
    fixture.keys("grr");
    const second = app.servers[0].pending.?;
    const replaced = "\"$/cancelRequest\",\"params\":{\"id\":";
    try testing.expect(std.mem.indexOf(u8, fixture.sent(), replaced) != null);
    try fixture.replyTo(first, target);
    try testing.expectEqualStrings("Asking zls...", app.status.text());
    try fixture.replyTo(second, "[]");
    try testing.expectEqualStrings("No reference found", app.status.text());
    // A server that exits while asked ends the wait.
    fixture.keys("gd");
    app.servers[0].state = .exited;
    app.serverChanged(0, .{ .exited = true });
    try testing.expectEqualStrings("zls exited", app.status.text());
    try testing.expectEqual(null, app.waiting);
}

test "a request from the server is refused and draws nothing" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    fixture.keys("gd");
    app.redraw = false;
    try fixture.feed(
        \\{"jsonrpc":"2.0","id":5,"method":"workspace/configuration","params":{}}
    );
    try fixture.feed(
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hi"}}
    );
    try testing.expect(!app.redraw);
    try testing.expectEqualStrings("Asking zls...", app.status.text());
    const refusal =
        \\{"jsonrpc":"2.0","id":5,"error":{"code":-32601,"message":"Method not found"}}
    ;
    try testing.expect(std.mem.endsWith(u8, fixture.sent(), refusal));
}

test "a key before initialization waits, then is sent, refused or cancelled unsent" {
    const testing = std.testing;
    const initialize = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"capabilities\":" ++
        "{\"positionEncoding\":\"utf-8\",\"definitionProvider\":true}}}";
    const Case = struct {
        keys: []const u8,
        notice: []const u8,
        method: ?[]const u8,
        cancel: bool = false,
    };
    const cases = [_]Case{
        .{ .keys = "gd", .notice = "Asking zls...", .method = "textDocument/definition" },
        .{ .keys = "grr", .notice = "zls has no references", .method = null },
        .{ .keys = "gd", .notice = "", .method = null, .cancel = true },
    };
    for (cases) |case| {
        var fixture: Navigating = undefined;
        try fixture.init();
        defer fixture.deinit();
        const app = &fixture.app;
        app.servers[0].capabilities = null;
        fixture.keys(case.keys);
        if (case.cancel) app.editorEvent(.escape);
        // Nothing is sent before the reply.
        try testing.expectEqualStrings("", fixture.sent());
        try fixture.feed(initialize);
        try testing.expectEqualStrings(case.notice, app.status.text());
        const sent = fixture.sent();
        try testing.expect(std.mem.indexOf(u8, sent, "\"method\":\"initialized\"") != null);
        try testing.expect(std.mem.indexOf(u8, sent, "cancelRequest") == null);
        if (case.method) |method| {
            try testing.expect(std.mem.indexOf(u8, sent, "textDocument/didOpen") != null);
            try testing.expect(std.mem.indexOf(u8, sent, method) != null);
            app.cancel();
        } else {
            try testing.expect(std.mem.indexOf(u8, sent, "textDocument/didOpen") == null);
            try testing.expectEqual(null, app.waiting);
        }
    }
}

test "only editable documents reach the server, and one made read-only is closed" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "c.zig", .data = "\x01\n" });
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "notes\n" });
    _ = try fixture.open("notes.md");
    fixture.keys("gd");
    try testing.expectEqualStrings("No language server for this file", app.status.text());
    _ = try fixture.open("c.zig");
    fixture.keys("gd");
    try testing.expectEqualStrings("Read-only file not sent to zls", app.status.text());
    try testing.expectEqualStrings("", fixture.sent());
    // a is sent with b's request; c, read-only, is not.
    const a = try fixture.open("a.zig");
    _ = try fixture.open("b.zig");
    fixture.keys("gd");
    try fixture.reply("null");
    const opens = std.mem.count(u8, fixture.sent(), "textDocument/didOpen");
    try testing.expectEqual(@as(usize, 2), opens);
    try testing.expect(std.mem.indexOf(u8, fixture.sent(), "c.zig") == null);
    // A reload makes a read-only; the next request closes it first.
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "\x01\n" });
    _ = app.documents.activate(testing.allocator, testing.io, a);
    try testing.expect(!fixture.buffer().editable);
    _ = try fixture.open("b.zig");
    app.servers[0].queue.clearRetainingCapacity();
    fixture.keys("gd");
    const sent = fixture.sent();
    const closed = std.mem.indexOf(u8, sent, "textDocument/didClose").?;
    try testing.expect(closed < std.mem.indexOf(u8, sent, "textDocument/definition").?);
    try testing.expect(std.mem.indexOf(u8, sent, "a.zig") != null);
    // b is already open and unchanged, so only those two are sent.
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, sent, "\"jsonrpc\""));
}

test "a missing command or provider is reported only at a key, with no request" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const server = &app.servers[0];
    server.capabilities.?.offers.remove(.implementation);
    fixture.keys("gri");
    try testing.expectEqualStrings("zls has no implementations", app.status.text());
    try testing.expectEqualStrings("", fixture.sent());
    server.state = .{ .unavailable = error.FileNotFound };
    fixture.keys("gd");
    try testing.expectEqualStrings("zls not found", app.status.text());
    // Never spawned again.
    app.startServer();
    try testing.expectEqual(error.FileNotFound, server.state.unavailable);
    server.state = .{ .unavailable = error.InitializeRefused };
    fixture.keys("gd");
    try testing.expectEqualStrings("zls failed to start", app.status.text());
    server.state = .idle;
}

test "a dirty target activates without reloading, and a target that fails to open changes nothing" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    const b = try fixture.open("b.zig");
    fixture.keys("dl");
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "changed\n" });
    _ = app.documents.activate(testing.allocator, testing.io, a);
    fixture.buffer().cursor = Navigating.call;
    var storage: [1024]u8 = undefined;
    fixture.keys("gd");
    try fixture.reply(try fixture.location(&storage, "b.zig", 0, 7));
    try testing.expectEqual(b, app.documents.active.?);
    try testing.expectEqualStrings("ub fn target() void {}\n", fixture.buffer().bytes());
    try testing.expectEqualStrings("DISK CONFLICT | ", app.documents.current().?.disk.status());
    _ = app.documents.activate(testing.allocator, testing.io, a);
    fixture.buffer().cursor = Navigating.call;
    const jumps = app.documents.jumps.len;
    fixture.keys("gd");
    try fixture.reply(try fixture.location(&storage, "missing.zig", 0, 0));
    const missing = "Cannot open: file not found; check the path";
    try testing.expectEqualStrings(missing, app.status.text());
    try testing.expectEqual(a, app.documents.active.?);
    try testing.expectEqual(@as(usize, Navigating.call), fixture.buffer().cursor);
    try testing.expectEqual(jumps, app.documents.jumps.len);
}

test "a key on an exited server waits for it to start after the frame; a failed start drops the request" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    // Without a Git root, servers run in the file's directory.
    fixture.finder.root_failure = error.FileNotFound;
    const server = &app.servers[0];
    server.state = .exited;
    server.capabilities = null;
    fixture.keys("gd");
    try testing.expectEqualStrings("Asking zls...", app.status.text());
    try testing.expect(server.state == .idle);
    try testing.expectEqualStrings("", fixture.sent());
    const limit = try client.NoDescriptors.lower();
    app.startServer();
    limit.restore();
    try testing.expectEqualStrings("zls failed to start", app.status.text());
    try testing.expectEqual(null, app.waiting);
    try testing.expect(server.state == .exited);
    // The next key tries again, even after a switch to a file with no server
    // before the frame.
    fixture.keys("gd");
    try fixture.temp.dir.writeFile(testing.io, .{ .sub_path = "notes.md", .data = "notes\n" });
    _ = try fixture.open("notes.md");
    app.startServer();
    try testing.expect(server.state == .running);
    try testing.expect(app.waiting != null);
    try testing.expectEqualStrings("Asking zls...", app.status.text());
}

const DocumentId = @import("finder/finder.zig").DocumentId;
const Preview = @import("finder/finder.zig").Preview;

test "Locations recognises the documents open when the answer arrives, never a closed one" {
    const testing = std.testing;
    var fixture: Navigating = undefined;
    try fixture.init();
    defer fixture.deinit();
    const app = &fixture.app;
    const a = app.documents.active.?;
    // b.zig is open when the finder last listed documents, then closed.
    _ = try fixture.open("b.zig");
    app.find(.open);
    app.dismiss();
    app.fileAction(.{ .quit = false });
    try testing.expectEqual(a, app.documents.active.?);
    fixture.buffer().cursor = Navigating.call;
    var storage: [2][1024]u8 = undefined;
    try answerAll(&fixture, &.{
        try fixture.location(&storage[0], "a.zig", 1, 4),
        try fixture.location(&storage[1], "b.zig", 0, 7),
    });
    // a.zig, opened before the finder ever listed it, previews its buffer.
    const finder = app.finder;
    const own: DocumentId = @fromBackingInt(@backingInt(a));
    try testing.expectEqual(own, finder.row(finder.matches[0]).document.?);
    const at_line: Preview = .{ .document = .{ .id = own, .line = 1 } };
    try testing.expectEqual(at_line, finder.preview());
    // The closed b.zig is read from disk.
    app.finderEvent(.{ .key = 0x0e });
    try testing.expectEqual(null, finder.row(finder.matches[1]).document);
    try testing.expect(finder.preview() == .loading);
}

/// An app over `temp` with `name` open, holding `text`, for the format tests.
const FormatFixture = struct {
    background: jobs.Jobs,
    finder: Finder = .{},
    app: App,

    fn init(self: *FormatFixture, temp: std.Io.Dir, name: []const u8, text: []const u8) !void {
        const testing = std.testing;
        try temp.writeFile(testing.io, .{ .sub_path = name, .data = text });
        self.* = .{ .background = try .init(), .app = undefined };
        self.app = .{
            .gpa = testing.allocator,
            .io = testing.io,
            .terminal = undefined,
            .background = &self.background,
            .finder = &self.finder,
            .size = .{ .rows = 6, .columns = 40 },
        };
        _ = try self.app.documents.open(testing.allocator, testing.io, temp, name);
    }

    fn deinit(self: *FormatFixture) void {
        const testing = std.testing;
        self.app.editor.deinit(testing.allocator);
        self.app.documents.deinit(testing.allocator);
        self.finder.deinit(testing.allocator, testing.io);
        self.background.deinit(testing.allocator, testing.io);
    }

    fn buffer(self: *FormatFixture) *@import("text/buffer.zig").Buffer {
        return &self.app.documents.current().?.document.buffer;
    }

    fn keys(self: *FormatFixture, typed: []const u8) void {
        for (typed) |byte| self.app.editorEvent(.{ .key = byte });
    }
};

test ":fmt formats as one undo step, keeping the cursor on its token and j/k on its column" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var fixture: FormatFixture = undefined;
    try fixture.init(temp.dir, "a.zig", "const  x=1;\nconst  yy=2;\n");
    defer fixture.deinit();
    const buffer = fixture.buffer();
    // On the `2`, at column 10.
    fixture.keys("jwww");
    try testing.expectEqual(22, buffer.cursor);
    const changes = buffer.changes;
    fixture.app.fileAction(.format);
    try testing.expectEqualStrings("Formatted", fixture.app.status.text());
    try testing.expectEqualStrings("const x = 1;\nconst yy = 2;\n", buffer.bytes());
    try testing.expect(buffer.modified());
    try testing.expectEqual(changes + 1, buffer.changes);
    // The `2` moved to column 11, and `k` keeps that column: the `;`.
    try testing.expectEqual(24, buffer.cursor);
    fixture.keys("k");
    try testing.expectEqual(11, buffer.cursor);
    // One undo restores the text and the cursor on the `2`.
    fixture.keys("ju");
    try testing.expectEqualStrings("const  x=1;\nconst  yy=2;\n", buffer.bytes());
    try testing.expectEqual(22, buffer.cursor);
    try testing.expect(!buffer.modified());
}

test ":fmt says why it changed nothing" {
    const testing = std.testing;
    const cases = [_]struct { name: []const u8, text: []const u8, notice: []const u8 }{
        .{ .name = "a.zig", .text = "const x = 1;\n", .notice = "Already formatted" },
        .{ .name = "a.md", .text = "#  title\n", .notice = "No formatter for this file" },
        .{ .name = "a.zig", .text = "const x = ;\n", .notice = "Not formatted: syntax error at 1:11" },
        .{ .name = "a.zig", .text = "const  x = 1;\x01\n", .notice = "Not formatted: read-only" },
    };
    for (cases) |case| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        var fixture: FormatFixture = undefined;
        try fixture.init(temp.dir, case.name, case.text);
        defer fixture.deinit();
        const changes = fixture.buffer().changes;
        fixture.app.fileAction(.format);
        try testing.expectEqualStrings(case.notice, fixture.app.status.text());
        try testing.expectEqualStrings(case.text, fixture.buffer().bytes());
        try testing.expectEqual(changes, fixture.buffer().changes);
        try testing.expect(!fixture.buffer().modified());
    }
}

test ":fmt leaves a file changed on disk unformatted, so a clean buffer still reloads" {
    const testing = std.testing;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var fixture: FormatFixture = undefined;
    try fixture.init(temp.dir, "a.zig", "const  x=1;\n");
    defer fixture.deinit();
    // An agent rewrites the file before Nib has seen the notification.
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const  y=2;\n" });
    fixture.app.fileAction(.format);
    try testing.expectEqualStrings("Not formatted: source changed or missing", fixture.app.status.text());
    try testing.expectEqualStrings("const  x=1;\n", fixture.buffer().bytes());
    try testing.expect(!fixture.buffer().modified());
    var decoder: input.Decoder = .{};
    try testing.expect(fixture.app.step(&decoder, "", false, 0) == null);
    try testing.expectEqualStrings("const  y=2;\n", fixture.buffer().bytes());
}
