// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const file = @import("file.zig");
const motion = @import("../text/motion.zig");
const Viewport = @import("../text/viewport.zig").Viewport;
const Disk = @import("disk.zig").Disk;

/// A document's identity for the whole session; never reused.
pub const Id = enum(u64) { _ };

/// One open file and the editing state that belongs to it alone.
pub const Entry = struct {
    id: Id,
    document: file.Document,
    viewport: Viewport = .{},
    /// Last known disk status. Only the active entry's watch is armed.
    disk: Disk = .{},
    /// Activation order; larger is more recent.
    used: u64 = 0,

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.disk.deinit(allocator);
        self.document.deinit(allocator);
    }
};

/// What `open` did: the document it activated, and how activating it
/// reloaded it, if it did.
pub const Opened = struct {
    id: Id,
    activation: ?Disk.Reload,
};

/// What `travel` did: how activating the entry's document reloaded it, if
/// it did.
pub const Travelled = struct { activation: ?Disk.Reload };

/// What `saveAndClose` did. `activation` is how activating the next document
/// reloaded it, if it did.
pub const Closing = struct {
    report: file.Report,
    closed: bool,
    activation: ?Disk.Reload = null,
};

/// A place jumped from: a document and a line, with the byte column in it.
pub const Jump = struct { id: Id, line: usize, column: usize };

/// The jump list, as Neovim's `jumpoptions=stack` keeps it. `index` is the
/// entry Ctrl-O or Ctrl-I last reached, or `len` while not travelling.
pub const Jumps = struct {
    items: [capacity]Jump = undefined,
    len: usize = 0,
    index: usize = 0,

    pub const capacity = 100;

    /// Records a departure. Travelling part way back keeps the entry reached
    /// and drops the ones after it.
    pub fn record(self: *Jumps, departure: Jump) void {
        if (self.index < self.len) self.len = self.index + 1;
        self.add(departure);
        self.index = self.len;
    }

    /// Ctrl-O: the entry `count` older, or null when there is none. Leaving
    /// the newest end first records `current`, so Ctrl-I returns to it; a
    /// null then has at most moved the newest entry's column, as in Neovim.
    pub fn back(self: *Jumps, current: Jump, count: usize) ?Jump {
        if (count > self.index) return null;
        if (self.index == self.len) {
            self.add(current);
            self.index = self.len - 1;
            if (count > self.index) return null;
        }
        self.index -= count;
        return self.items[self.index];
    }

    /// Ctrl-I: the entry `count` newer, or null, changing nothing.
    pub fn forward(self: *Jumps, count: usize) ?Jump {
        if (self.index == self.len or count >= self.len - self.index) return null;
        self.index += count;
        return self.items[self.index];
    }

    /// Drops every entry in document `id`, keeping `index` on the same entry
    /// or, if that one went, on the next.
    pub fn remove(self: *Jumps, id: Id) void {
        var kept: usize = 0;
        var index = self.index;
        for (self.items[0..self.len], 0..) |jump, position| {
            if (jump.id == id) {
                if (position < self.index) index -= 1;
                continue;
            }
            self.items[kept] = jump;
            kept += 1;
        }
        self.len = kept;
        self.index = @min(index, kept);
    }

    /// Appends, replacing the newest entry when it is the same line, and
    /// dropping the oldest when full.
    fn add(self: *Jumps, jump: Jump) void {
        if (self.len != 0) {
            const newest = &self.items[self.len - 1];
            if (newest.id == jump.id and newest.line == jump.line) {
                newest.* = jump;
                return;
            }
        }
        if (self.len == capacity) {
            std.mem.copyForwards(Jump, self.items[0 .. capacity - 1], self.items[1..]);
            self.len -= 1;
        }
        self.items[self.len] = jump;
        self.len += 1;
    }
};

pub const Direction = enum { older, newer };

/// Owns every open document and the active selection. `open` and `close`
/// move entries, so hold an `Id` across them, never an `*Entry`. Activation
/// may reload a clean document, so callers activate only between edits.
pub const Session = struct {
    entries: std.ArrayList(Entry) = .empty,
    active: ?Id = null,
    next_id: u64 = 0,
    clock: u64 = 0,
    jumps: Jumps = .{},

    pub fn deinit(self: *Session, allocator: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn get(self: *const Session, id: Id) ?*Entry {
        for (self.entries.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn current(self: *const Session) ?*Entry {
        return self.get(self.active orelse return null);
    }

    /// Opens `path`, relative to `dir`, and activates it. An open document
    /// whose path is spelled the same, or currently resolves to the same file,
    /// is reused with its first spelling. Fails without changing any document,
    /// including when an open document's identity cannot be checked.
    pub fn open(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        path: []const u8,
    ) file.Error!Opened {
        const spelling = try file.absolutePath(allocator, io, dir, path);
        defer allocator.free(spelling);
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.document.source.path, spelling)) continue;
            return .{ .id = entry.id, .activation = self.activate(allocator, io, entry.id) };
        }
        try self.entries.ensureUnusedCapacity(allocator, 1);
        var document = try file.Source.load(allocator, io, .cwd(), spelling);
        errdefer document.deinit(allocator);
        // Compare where each open path leads now, not the inode it last
        // loaded: a retargeted link must not claim its old target.
        for (self.entries.items) |*entry| {
            if (!try entry.document.source.names(document.source.version)) continue;
            document.deinit(allocator);
            return .{ .id = entry.id, .activation = self.activate(allocator, io, entry.id) };
        }
        const id: Id = @fromBackingInt(@intCast(self.next_id));
        self.next_id += 1;
        self.entries.appendAssumeCapacity(.{ .id = id, .document = document });
        return .{ .id = id, .activation = self.activate(allocator, io, id) };
    }

    /// Disarms the previous entry's watch, then rearms and revalidates `id`,
    /// reloading it if it is clean and changed on disk, and says how that
    /// reload went. Dirty documents keep their text, base and history.
    pub fn activate(self: *Session, allocator: Allocator, io: std.Io, id: Id) ?Disk.Reload {
        if (self.active == id) return null;
        if (self.current()) |previous| previous.disk.watch.deinit(allocator);
        const entry = self.get(id).?;
        self.active = id;
        self.clock += 1;
        entry.used = self.clock;
        entry.disk.inspect(allocator, &entry.document, true);
        return entry.disk.automatic(allocator, io, &entry.document, &entry.viewport.goal);
    }

    /// Records the active document's `cursor` as a place jumped from.
    pub fn recordJump(self: *Session, cursor: usize) void {
        self.jumps.record(self.place(cursor));
    }

    /// The active document's cursor as a jump entry, if one is active.
    pub fn here(self: *const Session) ?Jump {
        const entry = self.current() orelse return null;
        return self.place(entry.document.buffer.cursor);
    }

    /// Ctrl-O or Ctrl-I: activates the entry `count` away, which may reload
    /// it as `activate` does, then puts the cursor on the entry's line and
    /// column, clamped to the text as it is now. Null, changing nothing, when
    /// there is no such entry. Call only between edits.
    pub fn travel(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        direction: Direction,
        count: usize,
    ) ?Travelled {
        const target = switch (direction) {
            .older => self.jumps.back(self.here().?, count),
            .newer => self.jumps.forward(count),
        } orelse return null;
        const activation = self.activate(allocator, io, target.id);
        const entry = self.current().?;
        const buffer = &entry.document.buffer;
        const row = @min(target.line, buffer.lineCount() - 1);
        const offset = @min(buffer.lineStart(row) + target.column, buffer.contentEnd(row));
        buffer.cursor = motion.normal(buffer, offset);
        entry.viewport.goal = motion.screenColumn(buffer, buffer.cursor, false);
        return .{ .activation = activation };
    }

    fn place(self: *const Session, cursor: usize) Jump {
        const entry = self.current().?;
        const buffer = &entry.document.buffer;
        const line = @min(buffer.rowAt(cursor), buffer.lineCount() - 1);
        return .{ .id = entry.id, .line = line, .column = cursor - buffer.lineStart(line) };
    }

    /// Refuses unsaved edits unless `discard`. Closing the active document
    /// activates the most recently used one left, if any, and returns how
    /// activating it reloaded it, as `activate` does.
    pub fn close(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        id: Id,
        discard: bool,
    ) error{Unsaved}!?Disk.Reload {
        const entry = self.get(id).?;
        if (!discard and entry.document.buffer.modified()) return error.Unsaved;
        entry.deinit(allocator);
        _ = self.entries.orderedRemove(entry - self.entries.items.ptr);
        self.jumps.remove(id);
        if (self.active != id) return null;
        self.active = null;
        var recent: ?*Entry = null;
        for (self.entries.items) |*other| {
            if (recent == null or other.used > recent.?.used) recent = other;
        }
        const next = recent orelse return null;
        return self.activate(allocator, io, next.id);
    }

    /// Saves the active document, then rechecks its disk status.
    pub fn save(self: *Session, allocator: Allocator, options: file.Options) file.Report {
        const entry = self.current().?;
        const report = entry.document.source.save(allocator, &entry.document.buffer, options);
        entry.disk.inspect(allocator, &entry.document, true);
        return report;
    }

    /// Saves the active document and closes it only when the bytes were
    /// installed, verified and made durable with nothing reported wrong.
    pub fn saveAndClose(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        options: file.Options,
    ) Closing {
        const id = self.active.?;
        const report = self.save(allocator, options);
        const confirmed = report.publication == .installed and report.verified and
            report.durable and report.failure == null and !report.cleanup_failure;
        if (!confirmed) return .{ .report = report, .closed = false };
        const activation = self.close(allocator, io, id, false) catch {
            return .{ .report = report, .closed = false };
        };
        return .{ .report = report, .closed = true, .activation = activation };
    }

    /// Open documents with unsaved edits, which block quitting without discard.
    pub fn unsaved(self: *const Session) usize {
        var count: usize = 0;
        for (self.entries.items) |*entry| count += @intFromBool(entry.document.buffer.modified());
        return count;
    }
};

const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;

fn put(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(testing.io, .{ .sub_path = path, .data = data });
}

fn expectDisk(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    var storage: [64]u8 = undefined;
    try testing.expectEqualStrings(expected, try dir.readFile(testing.io, path, &storage));
}

test "switching keeps each document's text, history, cursor, goal and viewport exact" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "a", "a long first line\nshort\n");
    try put(temp.dir, "b", "bee\n");
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const a = (try session.open(testing.allocator, testing.io, temp.dir, "a")).id;
    keys(&session, &editor, &status, "iZ\x03$j");
    session.current().?.viewport.top = 1;
    session.current().?.viewport.left = 3;
    try testing.expectEqual(@as(usize, 23), session.current().?.document.buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, null), session.current().?.viewport.goal);
    const b = (try session.open(testing.allocator, testing.io, temp.dir, "b")).id;
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.get(a).?.disk.watch.fd < 0);
    keys(&session, &editor, &status, "iB\x03");
    try testing.expect(session.save(testing.allocator, .{}).verified);
    try expectDisk(temp.dir, "b", "Bbee\n");
    _ = session.activate(testing.allocator, testing.io, a);
    const after = session.get(a).?;
    try testing.expect(session.get(b).?.disk.watch.fd < 0 and after.disk.watch.fd >= 0);
    try testing.expectEqualStrings("Za long first line\nshort\n", after.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 23), after.document.buffer.cursor);
    try testing.expectEqual(Viewport{ .top = 1, .left = 3, .goal = null }, after.viewport);
    try testing.expectEqual(@as(usize, 1), after.document.buffer.history.items.len);
    try testing.expect(after.document.buffer.modified());
    // The end-of-line goal survives the switch: up lands on the longer line's end.
    keys(&session, &editor, &status, "k");
    try testing.expectEqual(@as(usize, 17), after.document.buffer.cursor);
    keys(&session, &editor, &status, "u");
    try testing.expectEqualStrings("a long first line\nshort\n", after.document.buffer.bytes());
    try testing.expect(!session.get(b).?.document.buffer.modified());
    try testing.expectEqual(@as(usize, 1), session.get(b).?.document.buffer.history.items.len);
}

const Editor = @import("../edit/editor.zig").Editor;
const Status = @import("../edit/editor.zig").Status;

fn keys(session: *Session, editor: *Editor, status: *Status, bytes: []const u8) void {
    const entry = session.current().?;
    const buffer = &entry.document.buffer;
    for (bytes) |byte| {
        _ = editor.feed(
            testing.allocator,
            buffer,
            &entry.viewport,
            status,
            .{ .key = byte },
        );
    }
}

test "close refuses unsaved edits, discards on request and falls back to the most recent" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| try put(temp.dir, name, name);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    var ids: [4]Id = undefined;
    for (&ids, [_][]const u8{ "a", "b", "c", "d" }) |*id, name| {
        id.* = (try session.open(testing.allocator, testing.io, temp.dir, name)).id;
    }
    const a, const b, const c, const d = ids;
    // The fallback is neither the first nor the last entry left.
    _ = session.activate(testing.allocator, testing.io, b);
    _ = session.activate(testing.allocator, testing.io, d);
    keys(&session, &editor, &status, "iZ\x03");
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, d, false),
    );
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
    try testing.expectEqualStrings("Zd", session.get(d).?.document.buffer.bytes());
    _ = try session.close(testing.allocator, testing.io, d, true);
    try expectDisk(temp.dir, "d", "d");
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.current().?.disk.watch.fd >= 0);
    _ = try session.close(testing.allocator, testing.io, a, false);
    try testing.expectEqual(b, session.active.?);
    _ = try session.close(testing.allocator, testing.io, b, false);
    try testing.expectEqual(c, session.active.?);
    _ = try session.close(testing.allocator, testing.io, c, false);
    try testing.expectEqual(@as(?Id, null), session.active);
    try testing.expectEqual(@as(?*Entry, null), session.current());
    try testing.expectEqual(@as(usize, 0), session.unsaved());
    const again = (try session.open(testing.allocator, testing.io, temp.dir, "a")).id;
    try testing.expect(again != a);
}

test "spellings, symlinks and hard links reuse one document with its first path" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "sub", .default_dir);
    try put(temp.dir, "sub/a", "a");
    try temp.dir.symLink(testing.io, "sub/a", "link", .{});
    const handle = temp.dir.handle;
    const linked = linux.linkat(handle, "sub/a", handle, "hard", 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linked));
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const first = (try session.open(testing.allocator, testing.io, temp.dir, "link")).id;
    keys(&session, &editor, &status, "iZ\x03");
    for ([_][]const u8{ "link", "./link", "sub/../link", "sub/a", "hard" }) |alias| {
        const reused = (try session.open(testing.allocator, testing.io, temp.dir, alias)).id;
        try testing.expectEqual(first, reused);
    }
    try testing.expectEqual(@as(usize, 1), session.entries.items.len);
    try testing.expect(std.mem.endsWith(u8, session.current().?.document.source.path, "/link"));
    try testing.expectEqualStrings("Za", session.current().?.document.buffer.bytes());
}

test "a retargeted link never claims its old target, which opens as its own document" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "A", "alpha");
    try put(temp.dir, "B", "beta");
    try temp.dir.symLink(testing.io, "A", "S", .{});
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const s = (try session.open(testing.allocator, testing.io, temp.dir, "S")).id;
    try temp.dir.deleteFile(testing.io, "S");
    try temp.dir.symLink(testing.io, "B", "S", .{});
    const a = (try session.open(testing.allocator, testing.io, temp.dir, "A")).id;
    try testing.expect(a != s);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("alpha", session.get(s).?.document.buffer.bytes());
    try testing.expect(std.mem.endsWith(u8, session.get(a).?.document.source.path, "/A"));
    // S follows its own path when it is next activated, and only because it is clean.
    _ = session.activate(testing.allocator, testing.io, s);
    try testing.expectEqualStrings("beta", session.get(s).?.document.buffer.bytes());
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
}

test "inactive documents are revalidated on activation: clean ones reload, dirty ones keep edits" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "clean", "dirty", "other" }) |name| try put(temp.dir, name, "before");
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const clean = (try session.open(testing.allocator, testing.io, temp.dir, "clean")).id;
    const dirty = (try session.open(testing.allocator, testing.io, temp.dir, "dirty")).id;
    keys(&session, &editor, &status, "iZ\x03");
    _ = try session.open(testing.allocator, testing.io, temp.dir, "other");
    // Atomic replacement, as an agent's editor would do it.
    for ([_][]const u8{ "clean", "dirty" }) |name| {
        try put(temp.dir, "replacement", "after");
        try std.Io.Dir.rename(temp.dir, "replacement", temp.dir, name, testing.io);
    }
    try testing.expectEqualStrings("before", session.get(clean).?.document.buffer.bytes());
    // Reopening by path activates it and says how that reloaded it.
    const reopened = try session.open(testing.allocator, testing.io, temp.dir, "clean");
    try testing.expectEqual(clean, reopened.id);
    try testing.expectEqual(Disk.Reload.reloaded, reopened.activation.?);
    try testing.expectEqualStrings("after", session.get(clean).?.document.buffer.bytes());
    try testing.expect(!session.get(clean).?.disk.diverged);
    try testing.expectEqual(null, session.activate(testing.allocator, testing.io, dirty));
    const entry = session.get(dirty).?;
    try testing.expectEqualStrings("Zbefore", entry.document.buffer.bytes());
    try testing.expectEqualStrings("before", entry.document.buffer.base);
    try testing.expectEqual(@as(usize, 1), entry.document.buffer.history.items.len);
    try testing.expect(entry.disk.diverged);
    try testing.expectEqual(error.SourceChanged, session.save(testing.allocator, .{}).failure.?);
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, dirty, false),
    );
}

const Failure = struct {
    stage: file.Stage,
    dir: ?std.Io.Dir = null,
    fn hook(context: ?*anyopaque, stage: file.Stage) file.Error!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (stage != self.stage) return;
        const dir = self.dir orelse return error.InjectedFailure;
        put(dir, "a", "external") catch return error.WriteFailed;
    }
};

test "save-and-close closes only on a verified durable save and keeps truthful state otherwise" {
    const cases = [_]struct { stage: ?file.Stage, external: bool = false, modified: bool }{
        .{ .stage = .created, .modified = true },
        .{ .stage = .validated, .modified = true },
        .{ .stage = .published, .modified = false },
        .{ .stage = .directory_sync, .modified = false },
        .{ .stage = .verified, .modified = false },
        .{ .stage = .published, .external = true, .modified = true },
        .{ .stage = null, .modified = false },
    };
    for (cases) |case| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        try put(temp.dir, "a", "a");
        try put(temp.dir, "b", "b");
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(testing.allocator);
        var session: Session = .{};
        defer session.deinit(testing.allocator);
        const b = (try session.open(testing.allocator, testing.io, temp.dir, "b")).id;
        const a = (try session.open(testing.allocator, testing.io, temp.dir, "a")).id;
        keys(&session, &editor, &status, "iX\x03");
        var failure: Failure = .{ .stage = case.stage orelse .loaded };
        if (case.external) failure.dir = temp.dir;
        const options: file.Options = .{ .context = &failure, .hook = Failure.hook };
        const result = session.saveAndClose(testing.allocator, testing.io, options);
        const succeeded = case.stage == null;
        try testing.expectEqual(succeeded, result.closed);
        if (succeeded) {
            try testing.expectEqual(b, session.active.?);
            try testing.expectEqual(@as(?*Entry, null), session.get(a));
            try expectDisk(temp.dir, "a", "Xa");
            continue;
        }
        const entry = session.get(a).?;
        try testing.expectEqual(a, session.active.?);
        try testing.expectEqual(case.modified, entry.document.buffer.modified());
        try testing.expectEqualStrings("Xa", entry.document.buffer.bytes());
        try testing.expectEqual(@as(usize, 1), entry.document.buffer.history.items.len);
        try testing.expectEqual(case.external, entry.disk.diverged);
    }
}

test "allocation failure while opening or switching leaves every document intact" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "a", "a\n");
    try put(temp.dir, "b", "b\n");
    try testing.checkAllAllocationFailures(testing.allocator, allocationWorkflow, .{temp.dir});
}

fn allocationWorkflow(allocator: Allocator, dir: std.Io.Dir) !void {
    var session: Session = .{};
    defer session.deinit(allocator);
    const a = (try session.open(allocator, testing.io, dir, "a")).id;
    try armed(&session);
    try session.current().?.document.buffer.replace(allocator, .{ .start = 0, .end = 0 }, "X", 0);
    const b = (session.open(allocator, testing.io, dir, "b") catch |err| {
        try testing.expectEqual(@as(usize, 1), session.entries.items.len);
        try testing.expectEqual(a, session.active.?);
        try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
        return err;
    }).id;
    try armed(&session);
    _ = session.activate(allocator, testing.io, a);
    try armed(&session);
    try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    _ = try session.close(allocator, testing.io, a, true);
    try testing.expectEqual(b, session.active.?);
    try armed(&session);
}

/// Watch registration absorbs allocation failure as degraded monitoring, which
/// the allocation harness must still see as a failure.
fn armed(session: *Session) error{OutOfMemory}!void {
    if (session.current().?.disk.watch.degraded) return error.OutOfMemory;
}

test "an open path that no longer reaches a file never blocks opening another" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "A", "alpha");
    try put(temp.dir, "B", "beta");
    try temp.dir.symLink(testing.io, "A", "L", .{});
    try temp.dir.createDir(testing.io, "locked", .default_dir);
    try temp.dir.symLink(testing.io, "../B", "locked/M", .{});
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const l = (try session.open(testing.allocator, testing.io, temp.dir, "L")).id;
    keys(&session, &editor, &status, "iZ\x03");
    // L now loops: it names nothing, so A opens as its own document.
    try temp.dir.deleteFile(testing.io, "L");
    try temp.dir.symLink(testing.io, "L", "L", .{});
    const a = (try session.open(testing.allocator, testing.io, temp.dir, "A")).id;
    try testing.expect(a != l);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("Zalpha", session.get(l).?.document.buffer.bytes());
    // Behind a directory it may not search, M names nothing either.
    if (linux.geteuid() == 0) return;
    const m = (try session.open(testing.allocator, testing.io, temp.dir, "locked/M")).id;
    const locked = linux.openat(temp.dir.handle, "locked", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(locked));
    const fd: std.posix.fd_t = @intCast(locked);
    defer _ = linux.close(fd);
    defer _ = linux.fchmod(fd, 0o700);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(linux.fchmod(fd, 0)));
    const b = (try session.open(testing.allocator, testing.io, temp.dir, "B")).id;
    try testing.expect(b != m and b != a and b != l);
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
}

fn at(line: usize) Jump {
    return .{ .id = @fromBackingInt(@intCast(0)), .line = line, .column = 0 };
}

fn expectJumps(jumps: *const Jumps, lines: []const usize, index: usize) !void {
    var actual: [Jumps.capacity]usize = undefined;
    for (jumps.items[0..jumps.len], 0..) |jump, position| actual[position] = jump.line;
    try testing.expectEqualSlices(usize, lines, actual[0..jumps.len]);
    try testing.expectEqual(index, jumps.index);
}

// Each case matches Neovim 0.12.6 with `jumpoptions=stack`, lines as there.
test "the jump list travels, truncates and replaces as Neovim's stack option does" {
    var jumps: Jumps = .{};
    // 1G, 10G, 20G, 30G: three departures; Ctrl-O first records line 30.
    for ([_]usize{ 1, 10, 20 }) |line| jumps.record(at(line));
    try expectJumps(&jumps, &.{ 1, 10, 20 }, 3);
    try testing.expectEqual(@as(usize, 20), jumps.back(at(30), 1).?.line);
    try expectJumps(&jumps, &.{ 1, 10, 20, 30 }, 2);
    try testing.expectEqual(@as(usize, 30), jumps.forward(1).?.line);
    // A count past either end moves nowhere, and so does Ctrl-I at the end.
    try testing.expectEqual(@as(?Jump, null), jumps.back(at(30), 9));
    try testing.expectEqual(@as(?Jump, null), jumps.forward(9));
    try testing.expectEqual(@as(?Jump, null), jumps.forward(1));
    try expectJumps(&jumps, &.{ 1, 10, 20, 30 }, 3);
    // A jump part way back keeps the entry reached and drops the rest; the
    // departure from that same line replaces it.
    try testing.expectEqual(@as(usize, 10), jumps.back(at(30), 2).?.line);
    jumps.record(at(10));
    try expectJumps(&jumps, &.{ 1, 10 }, 2);
    // From the newest end, a current line equal to the newest entry
    // replaces it, and Ctrl-O goes to the one before.
    try testing.expectEqual(@as(usize, 1), jumps.back(at(10), 1).?.line);
    try expectJumps(&jumps, &.{ 1, 10 }, 0);
    // Moving away and pressing Ctrl-I records nothing.
    try testing.expectEqual(@as(usize, 10), jumps.forward(1).?.line);
    try expectJumps(&jumps, &.{ 1, 10 }, 1);
    // Moving away from an entry, then jumping, keeps it and adds the new one.
    _ = jumps.back(at(10), 1);
    jumps.record(at(6));
    try expectJumps(&jumps, &.{ 1, 6 }, 2);
}

test "only adjacent entries on one line merge, and Ctrl-O from the end keeps the current line" {
    var jumps: Jumps = .{};
    // 1G, 10G, 1G, 10G, then Ctrl-O twice.
    for ([_]usize{ 1, 10, 1 }) |line| jumps.record(at(line));
    try testing.expectEqual(@as(usize, 1), jumps.back(at(10), 1).?.line);
    try expectJumps(&jumps, &.{ 1, 10, 1, 10 }, 2);
    try testing.expectEqual(@as(usize, 10), jumps.back(at(1), 1).?.line);
    try expectJumps(&jumps, &.{ 1, 10, 1, 10 }, 1);
    // An empty list has nowhere to go and records nothing.
    var empty: Jumps = .{};
    try testing.expectEqual(@as(?Jump, null), empty.back(at(3), 1));
    try testing.expectEqual(@as(?Jump, null), empty.forward(1));
    try expectJumps(&empty, &.{}, 0);
    // A lone entry on the current line becomes it, then there is nothing older.
    empty.record(at(3));
    try testing.expectEqual(@as(?Jump, null), empty.back(at(3), 1));
    try expectJumps(&empty, &.{3}, 0);
}

test "a full jump list drops its oldest entry and a closed document's entries go" {
    var jumps: Jumps = .{};
    for (0..Jumps.capacity + 5) |line| jumps.record(at(line));
    try testing.expectEqual(Jumps.capacity, jumps.len);
    try testing.expectEqual(@as(usize, 5), jumps.items[0].line);
    try testing.expectEqual(@as(usize, Jumps.capacity + 4), jumps.items[Jumps.capacity - 1].line);
    const a: Id = @fromBackingInt(@intCast(0));
    const b: Id = @fromBackingInt(@intCast(1));
    var mixed: Jumps = .{};
    for ([_]Id{ a, b, a, b, a }, 0..) |id, line| {
        mixed.record(.{ .id = id, .line = line, .column = 0 });
    }
    // Standing on entry 3 (b), removing a keeps it.
    _ = mixed.back(.{ .id = b, .line = 9, .column = 0 }, 2);
    try expectJumps(&mixed, &.{ 0, 1, 2, 3, 4, 9 }, 3);
    mixed.remove(a);
    try expectJumps(&mixed, &.{ 1, 3, 9 }, 1);
    // Removing the entry stood on leaves the next one.
    mixed.remove(b);
    try expectJumps(&mixed, &.{}, 0);
}

test "travelling activates the entry's document and clamps its line and column to the text now" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "a", "first\nsecond line\nthird\n");
    try put(temp.dir, "b", "b\n");
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const a = (try session.open(testing.allocator, testing.io, temp.dir, "a")).id;
    keys(&session, &editor, &status, "j$");
    session.recordJump(session.current().?.document.buffer.cursor);
    try testing.expectEqual(Jump{ .id = a, .line = 1, .column = 10 }, session.jumps.items[0]);
    // The line shrinks to `sé`, its last character two bytes wide.
    keys(&session, &editor, &status, "0d$isé\x03");
    const shrunk = session.current().?.document.buffer.bytes();
    try testing.expectEqualStrings("first\nsé\nthird\n", shrunk);
    const b = (try session.open(testing.allocator, testing.io, temp.dir, "b")).id;
    const travelled = session.travel(testing.allocator, testing.io, .older, 1).?;
    try testing.expectEqual(@as(?Disk.Reload, null), travelled.activation);
    try testing.expectEqual(a, session.active.?);
    const buffer = &session.current().?.document.buffer;
    try testing.expectEqual(@as(usize, 7), buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, 1), session.current().?.viewport.goal);
    // Back to b, where Ctrl-O recorded its cursor.
    _ = session.travel(testing.allocator, testing.io, .newer, 1).?;
    try testing.expectEqual(b, session.active.?);
    const past_end = session.travel(testing.allocator, testing.io, .newer, 1);
    try testing.expectEqual(@as(?Travelled, null), past_end);
    // An entry past the last line lands on the last line; an empty one on 0.
    session.jumps = .{};
    session.jumps.record(.{ .id = a, .line = 7, .column = 3 });
    _ = session.travel(testing.allocator, testing.io, .older, 1).?;
    try testing.expectEqual(@as(usize, 13), session.current().?.document.buffer.cursor);
    keys(&session, &editor, &status, "ggdG");
    try testing.expectEqualStrings("", session.current().?.document.buffer.bytes());
    session.jumps = .{};
    session.jumps.record(.{ .id = a, .line = 1, .column = 4 });
    _ = session.activate(testing.allocator, testing.io, b);
    _ = session.travel(testing.allocator, testing.io, .older, 1).?;
    try testing.expectEqual(@as(usize, 0), session.current().?.document.buffer.cursor);
}

test "travelling reloads a clean changed target, keeps a dirty one, and skips closed files" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try put(temp.dir, "a", "one\ntwo\nthree\n");
    try put(temp.dir, "b", "bee\n");
    try put(temp.dir, "c", "sea\n");
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const a = (try session.open(testing.allocator, testing.io, temp.dir, "a")).id;
    keys(&session, &editor, &status, "G");
    session.recordJump(session.current().?.document.buffer.cursor);
    const b = (try session.open(testing.allocator, testing.io, temp.dir, "b")).id;
    keys(&session, &editor, &status, "iB\x03");
    session.recordJump(session.current().?.document.buffer.cursor);
    const c = (try session.open(testing.allocator, testing.io, temp.dir, "c")).id;
    try put(temp.dir, "a", "only\n");
    try put(temp.dir, "b", "changed\n");
    // The dirty b keeps its edit.
    const to_b = session.travel(testing.allocator, testing.io, .older, 1).?;
    try testing.expectEqual(b, session.active.?);
    try testing.expect(to_b.activation == null or to_b.activation.? != .reloaded);
    try testing.expectEqualStrings("Bbee\n", session.current().?.document.buffer.bytes());
    // The clean a reloads, and its line 2 entry clamps to the one line left.
    const to_a = session.travel(testing.allocator, testing.io, .older, 1).?;
    try testing.expectEqual(a, session.active.?);
    try testing.expect(to_a.activation != null);
    try testing.expectEqualStrings("only\n", session.current().?.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 0), session.current().?.document.buffer.cursor);
    // Closing b drops its entry: forward goes straight to c.
    _ = try session.close(testing.allocator, testing.io, b, true);
    _ = session.travel(testing.allocator, testing.io, .newer, 1).?;
    try testing.expectEqual(c, session.active.?);
}
