// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const file = @import("file.zig");
const motion = @import("motion.zig");
const view = @import("view.zig");
const Editor = @import("editor.zig").Editor;
const External = @import("external.zig").External;

/// A document's identity for the whole session; never reused.
pub const Id = enum(u64) { _ };

/// One open file and the editing state that belongs to it alone.
pub const Entry = struct {
    id: Id,
    document: file.Document,
    goal: motion.Goal = 0,
    viewport: view.Viewport = .{},
    /// Last known disk status. Only the active entry's watch is armed.
    disk: External = .{},
    /// Activation order; larger is more recent.
    used: u64 = 0,

    fn deinit(self: *Entry, allocator: Allocator) void {
        self.disk.deinit(allocator);
        self.document.deinit(allocator);
    }
};

pub const Closing = struct { report: file.Report, closed: bool };

/// Owns every open document and the active selection. `open` and `close`
/// move entries, so hold an `Id` across them, never an `*Entry`. Activation
/// requires the editor at a safe boundary (`External.safe`).
pub const Session = struct {
    entries: std.ArrayList(Entry) = .empty,
    active: ?Id = null,
    next_id: u64 = 0,
    clock: u64 = 0,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn get(self: *Session, id: Id) ?*Entry {
        for (self.entries.items) |*entry| if (entry.id == id) return entry;
        return null;
    }

    pub fn current(self: *Session) ?*Entry {
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
        editor: *Editor,
    ) file.Error!Id {
        const spelling = try file.absolutePath(allocator, io, dir, path);
        defer allocator.free(spelling);
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.document.source.path, spelling)) continue;
            self.activate(allocator, io, entry.id, editor);
            return entry.id;
        }
        try self.entries.ensureUnusedCapacity(allocator, 1);
        var document = try file.Source.load(allocator, io, .cwd(), spelling);
        errdefer document.deinit(allocator);
        // Compare where each open path leads now, not the inode it last
        // loaded: a retargeted link must not claim its old target.
        for (self.entries.items) |*entry| {
            if (!try entry.document.source.names(document.source.version)) continue;
            document.deinit(allocator);
            self.activate(allocator, io, entry.id, editor);
            return entry.id;
        }
        const id: Id = @fromBackingInt(@intCast(self.next_id));
        self.next_id += 1;
        self.entries.appendAssumeCapacity(.{ .id = id, .document = document });
        self.activate(allocator, io, id, editor);
        return id;
    }

    /// Disarms the previous entry's watch, then rearms and revalidates `id`,
    /// reloading it if it is clean and changed on disk. Dirty documents keep
    /// their text, base and history.
    pub fn activate(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        id: Id,
        editor: *Editor,
    ) void {
        std.debug.assert(External.safe(editor));
        if (self.active == id) return;
        if (self.current()) |previous| previous.disk.watch.deinit(allocator);
        const entry = self.get(id).?;
        self.active = id;
        self.clock += 1;
        entry.used = self.clock;
        entry.disk.inspect(allocator, &entry.document, true);
        _ = entry.disk.automatic(allocator, io, &entry.document, &entry.goal, editor);
    }

    /// Refuses unsaved edits unless `discard`. Closing the active document
    /// activates the most recently used one left, if any.
    pub fn close(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        id: Id,
        discard: bool,
        editor: *Editor,
    ) error{Unsaved}!void {
        const entry = self.get(id).?;
        if (!discard and entry.document.buffer.modified()) return error.Unsaved;
        entry.deinit(allocator);
        _ = self.entries.orderedRemove(entry - self.entries.items.ptr);
        if (self.active != id) return;
        self.active = null;
        var recent: ?*Entry = null;
        for (self.entries.items) |*other| {
            if (recent == null or other.used > recent.?.used) recent = other;
        }
        if (recent) |next| self.activate(allocator, io, next.id, editor);
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
        editor: *Editor,
        options: file.Options,
    ) Closing {
        const id = self.active.?;
        const report = self.save(allocator, options);
        const confirmed = report.publication == .installed and report.verified and
            report.durable and report.failure == null and !report.cleanup_failure;
        if (!confirmed) return .{ .report = report, .closed = false };
        self.close(allocator, io, id, false, editor) catch {
            return .{ .report = report, .closed = false };
        };
        return .{ .report = report, .closed = true };
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

fn keys(session: *Session, editor: *Editor, bytes: []const u8) void {
    const entry = session.current().?;
    for (bytes) |byte| {
        _ = editor.feed(testing.allocator, &entry.document.buffer, &entry.goal, .{ .key = byte });
    }
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
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const a = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor);
    keys(&session, &editor, "iZ\x03$j");
    session.current().?.viewport = .{ .top = 1, .left = 3 };
    try testing.expectEqual(@as(usize, 23), session.current().?.document.buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, null), session.current().?.goal);
    const b = try session.open(testing.allocator, testing.io, temp.dir, "b", &editor);
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.get(a).?.disk.watch.fd < 0);
    keys(&session, &editor, "iB\x03");
    try testing.expect(session.save(testing.allocator, .{}).verified);
    try expectDisk(temp.dir, "b", "Bbee\n");
    session.activate(testing.allocator, testing.io, a, &editor);
    const after = session.get(a).?;
    try testing.expect(session.get(b).?.disk.watch.fd < 0 and after.disk.watch.fd >= 0);
    try testing.expectEqualStrings("Za long first line\nshort\n", after.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 23), after.document.buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, null), after.goal);
    try testing.expectEqual(view.Viewport{ .top = 1, .left = 3 }, after.viewport);
    try testing.expectEqual(@as(usize, 1), after.document.buffer.history.items.len);
    try testing.expect(after.document.buffer.modified());
    // The end-of-line goal survives the switch: up lands on the longer line's end.
    keys(&session, &editor, "k");
    try testing.expectEqual(@as(usize, 17), after.document.buffer.cursor);
    keys(&session, &editor, "u");
    try testing.expectEqualStrings("a long first line\nshort\n", after.document.buffer.bytes());
    try testing.expect(!session.get(b).?.document.buffer.modified());
    try testing.expectEqual(@as(usize, 1), session.get(b).?.document.buffer.history.items.len);
}

test "close refuses unsaved edits, discards on request and falls back to the most recent" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }) |name| try put(temp.dir, name, name);
    var editor: Editor = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    var ids: [4]Id = undefined;
    for (&ids, [_][]const u8{ "a", "b", "c", "d" }) |*id, name| {
        id.* = try session.open(testing.allocator, testing.io, temp.dir, name, &editor);
    }
    const a, const b, const c, const d = ids;
    // The fallback is neither the first nor the last entry left.
    session.activate(testing.allocator, testing.io, b, &editor);
    session.activate(testing.allocator, testing.io, d, &editor);
    keys(&session, &editor, "iZ\x03");
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, d, false, &editor),
    );
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
    try testing.expectEqualStrings("Zd", session.get(d).?.document.buffer.bytes());
    try session.close(testing.allocator, testing.io, d, true, &editor);
    try expectDisk(temp.dir, "d", "d");
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.current().?.disk.watch.fd >= 0);
    try session.close(testing.allocator, testing.io, a, false, &editor);
    try testing.expectEqual(b, session.active.?);
    try session.close(testing.allocator, testing.io, b, false, &editor);
    try testing.expectEqual(c, session.active.?);
    try session.close(testing.allocator, testing.io, c, false, &editor);
    try testing.expectEqual(@as(?Id, null), session.active);
    try testing.expectEqual(@as(?*Entry, null), session.current());
    try testing.expectEqual(@as(usize, 0), session.unsaved());
    const again = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor);
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
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const first = try session.open(testing.allocator, testing.io, temp.dir, "link", &editor);
    keys(&session, &editor, "iZ\x03");
    for ([_][]const u8{ "link", "./link", "sub/../link", "sub/a", "hard" }) |alias| {
        const reused = try session.open(testing.allocator, testing.io, temp.dir, alias, &editor);
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
    var editor: Editor = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const s = try session.open(testing.allocator, testing.io, temp.dir, "S", &editor);
    try temp.dir.deleteFile(testing.io, "S");
    try temp.dir.symLink(testing.io, "B", "S", .{});
    const a = try session.open(testing.allocator, testing.io, temp.dir, "A", &editor);
    try testing.expect(a != s);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("alpha", session.get(s).?.document.buffer.bytes());
    try testing.expect(std.mem.endsWith(u8, session.get(a).?.document.source.path, "/A"));
    // S follows its own path when it is next activated, and only because it is clean.
    session.activate(testing.allocator, testing.io, s, &editor);
    try testing.expectEqualStrings("beta", session.get(s).?.document.buffer.bytes());
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
}

test "inactive documents are revalidated on activation: clean ones reload, dirty ones keep edits" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "clean", "dirty", "other" }) |name| try put(temp.dir, name, "before");
    var editor: Editor = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const clean = try session.open(testing.allocator, testing.io, temp.dir, "clean", &editor);
    const dirty = try session.open(testing.allocator, testing.io, temp.dir, "dirty", &editor);
    keys(&session, &editor, "iZ\x03");
    _ = try session.open(testing.allocator, testing.io, temp.dir, "other", &editor);
    // Atomic replacement, as an agent's editor would do it.
    for ([_][]const u8{ "clean", "dirty" }) |name| {
        try put(temp.dir, "replacement", "after");
        try std.Io.Dir.rename(temp.dir, "replacement", temp.dir, name, testing.io);
    }
    try testing.expectEqualStrings("before", session.get(clean).?.document.buffer.bytes());
    session.activate(testing.allocator, testing.io, clean, &editor);
    try testing.expectEqualStrings("after", session.get(clean).?.document.buffer.bytes());
    try testing.expect(!session.get(clean).?.disk.diverged);
    session.activate(testing.allocator, testing.io, dirty, &editor);
    const entry = session.get(dirty).?;
    try testing.expectEqualStrings("Zbefore", entry.document.buffer.bytes());
    try testing.expectEqualStrings("before", entry.document.buffer.base);
    try testing.expectEqual(@as(usize, 1), entry.document.buffer.history.items.len);
    try testing.expect(entry.disk.diverged);
    try testing.expectEqual(error.SourceChanged, session.save(testing.allocator, .{}).failure.?);
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, dirty, false, &editor),
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
        defer editor.deinit(testing.allocator);
        var session: Session = .{};
        defer session.deinit(testing.allocator);
        const b = try session.open(testing.allocator, testing.io, temp.dir, "b", &editor);
        const a = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor);
        keys(&session, &editor, "iX\x03");
        var failure: Failure = .{ .stage = case.stage orelse .loaded };
        if (case.external) failure.dir = temp.dir;
        const options: file.Options = .{ .context = &failure, .hook = Failure.hook };
        const result = session.saveAndClose(testing.allocator, testing.io, &editor, options);
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
    var editor: Editor = .{};
    defer editor.deinit(allocator);
    var session: Session = .{};
    defer session.deinit(allocator);
    const a = try session.open(allocator, testing.io, dir, "a", &editor);
    try armed(&session);
    try session.current().?.document.buffer.replace(allocator, .{ .start = 0, .end = 0 }, "X", 0);
    const b = session.open(allocator, testing.io, dir, "b", &editor) catch |err| {
        try testing.expectEqual(@as(usize, 1), session.entries.items.len);
        try testing.expectEqual(a, session.active.?);
        try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
        return err;
    };
    try armed(&session);
    session.activate(allocator, testing.io, a, &editor);
    try armed(&session);
    try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    try session.close(allocator, testing.io, a, true, &editor);
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
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const l = try session.open(testing.allocator, testing.io, temp.dir, "L", &editor);
    keys(&session, &editor, "iZ\x03");
    // L now loops: it names nothing, so A opens as its own document.
    try temp.dir.deleteFile(testing.io, "L");
    try temp.dir.symLink(testing.io, "L", "L", .{});
    const a = try session.open(testing.allocator, testing.io, temp.dir, "A", &editor);
    try testing.expect(a != l);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("Zalpha", session.get(l).?.document.buffer.bytes());
    // Behind a directory it may not search, M names nothing either.
    if (linux.geteuid() == 0) return;
    const m = try session.open(testing.allocator, testing.io, temp.dir, "locked/M", &editor);
    const locked = linux.openat(temp.dir.handle, "locked", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(locked));
    const fd: std.posix.fd_t = @intCast(locked);
    defer _ = linux.close(fd);
    defer _ = linux.fchmod(fd, 0o700);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(linux.fchmod(fd, 0)));
    const b = try session.open(testing.allocator, testing.io, temp.dir, "B", &editor);
    try testing.expect(b != m and b != a and b != l);
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
}
