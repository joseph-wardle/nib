// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const file = @import("file.zig");
const motion = @import("motion.zig");
const view = @import("view.zig");
const Editor = @import("editor.zig").Editor;
const Status = @import("editor.zig").Status;
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

/// What `saveAndClose` did. `activation` is how activating the next document
/// reloaded it, if it did.
pub const Closing = struct {
    report: file.Report,
    closed: bool,
    activation: ?External.Reload = null,
};

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
        status: *Status,
    ) file.Error!Id {
        const spelling = try file.absolutePath(allocator, io, dir, path);
        defer allocator.free(spelling);
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.document.source.path, spelling)) continue;
            _ = self.activate(allocator, io, entry.id, editor, status);
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
            _ = self.activate(allocator, io, entry.id, editor, status);
            return entry.id;
        }
        const id: Id = @fromBackingInt(@intCast(self.next_id));
        self.next_id += 1;
        self.entries.appendAssumeCapacity(.{ .id = id, .document = document });
        _ = self.activate(allocator, io, id, editor, status);
        return id;
    }

    /// Disarms the previous entry's watch, then rearms and revalidates `id`,
    /// reloading it if it is clean and changed on disk, and says how that
    /// reload went. Dirty documents keep their text, base and history.
    pub fn activate(
        self: *Session,
        allocator: Allocator,
        io: std.Io,
        id: Id,
        editor: *Editor,
        status: *Status,
    ) ?External.Reload {
        std.debug.assert(External.safe(editor));
        if (self.active == id) return null;
        if (self.current()) |previous| previous.disk.watch.deinit(allocator);
        const entry = self.get(id).?;
        self.active = id;
        self.clock += 1;
        entry.used = self.clock;
        entry.disk.inspect(allocator, &entry.document, true);
        return entry.disk.automatic(allocator, io, &entry.document, &entry.goal, editor, status);
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
        editor: *Editor,
        status: *Status,
    ) error{Unsaved}!?External.Reload {
        const entry = self.get(id).?;
        if (!discard and entry.document.buffer.modified()) return error.Unsaved;
        entry.deinit(allocator);
        _ = self.entries.orderedRemove(entry - self.entries.items.ptr);
        if (self.active != id) return null;
        self.active = null;
        var recent: ?*Entry = null;
        for (self.entries.items) |*other| {
            if (recent == null or other.used > recent.?.used) recent = other;
        }
        const next = recent orelse return null;
        return self.activate(allocator, io, next.id, editor, status);
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
        status: *Status,
        options: file.Options,
    ) Closing {
        const id = self.active.?;
        const report = self.save(allocator, options);
        const confirmed = report.publication == .installed and report.verified and
            report.durable and report.failure == null and !report.cleanup_failure;
        if (!confirmed) return .{ .report = report, .closed = false };
        const activation = self.close(allocator, io, id, false, editor, status) catch {
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

fn keys(session: *Session, editor: *Editor, status: *Status, bytes: []const u8) void {
    const entry = session.current().?;
    const buffer = &entry.document.buffer;
    for (bytes) |byte| {
        _ = editor.feed(
            testing.allocator,
            buffer,
            &entry.goal,
            &entry.viewport,
            status,
            .{ .key = byte },
        );
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
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const a = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor, &status);
    keys(&session, &editor, &status, "iZ\x03$j");
    session.current().?.viewport = .{ .top = 1, .left = 3 };
    try testing.expectEqual(@as(usize, 23), session.current().?.document.buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, null), session.current().?.goal);
    const b = try session.open(testing.allocator, testing.io, temp.dir, "b", &editor, &status);
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.get(a).?.disk.watch.fd < 0);
    keys(&session, &editor, &status, "iB\x03");
    try testing.expect(session.save(testing.allocator, .{}).verified);
    try expectDisk(temp.dir, "b", "Bbee\n");
    _ = session.activate(testing.allocator, testing.io, a, &editor, &status);
    const after = session.get(a).?;
    try testing.expect(session.get(b).?.disk.watch.fd < 0 and after.disk.watch.fd >= 0);
    try testing.expectEqualStrings("Za long first line\nshort\n", after.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 23), after.document.buffer.cursor);
    try testing.expectEqual(@as(motion.Goal, null), after.goal);
    try testing.expectEqual(view.Viewport{ .top = 1, .left = 3 }, after.viewport);
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
        id.* = try session.open(testing.allocator, testing.io, temp.dir, name, &editor, &status);
    }
    const a, const b, const c, const d = ids;
    // The fallback is neither the first nor the last entry left.
    _ = session.activate(testing.allocator, testing.io, b, &editor, &status);
    _ = session.activate(testing.allocator, testing.io, d, &editor, &status);
    keys(&session, &editor, &status, "iZ\x03");
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, d, false, &editor, &status),
    );
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
    try testing.expectEqualStrings("Zd", session.get(d).?.document.buffer.bytes());
    _ = try session.close(testing.allocator, testing.io, d, true, &editor, &status);
    try expectDisk(temp.dir, "d", "d");
    try testing.expectEqual(b, session.active.?);
    try testing.expect(session.current().?.disk.watch.fd >= 0);
    _ = try session.close(testing.allocator, testing.io, a, false, &editor, &status);
    try testing.expectEqual(b, session.active.?);
    _ = try session.close(testing.allocator, testing.io, b, false, &editor, &status);
    try testing.expectEqual(c, session.active.?);
    _ = try session.close(testing.allocator, testing.io, c, false, &editor, &status);
    try testing.expectEqual(@as(?Id, null), session.active);
    try testing.expectEqual(@as(?*Entry, null), session.current());
    try testing.expectEqual(@as(usize, 0), session.unsaved());
    const again = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor, &status);
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
    const first = try session.open(
        testing.allocator,
        testing.io,
        temp.dir,
        "link",
        &editor,
        &status,
    );
    keys(&session, &editor, &status, "iZ\x03");
    for ([_][]const u8{ "link", "./link", "sub/../link", "sub/a", "hard" }) |alias| {
        const reused = try session.open(
            testing.allocator,
            testing.io,
            temp.dir,
            alias,
            &editor,
            &status,
        );
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
    var status: Status = .{};
    defer editor.deinit(testing.allocator);
    var session: Session = .{};
    defer session.deinit(testing.allocator);
    const s = try session.open(testing.allocator, testing.io, temp.dir, "S", &editor, &status);
    try temp.dir.deleteFile(testing.io, "S");
    try temp.dir.symLink(testing.io, "B", "S", .{});
    const a = try session.open(testing.allocator, testing.io, temp.dir, "A", &editor, &status);
    try testing.expect(a != s);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("alpha", session.get(s).?.document.buffer.bytes());
    try testing.expect(std.mem.endsWith(u8, session.get(a).?.document.source.path, "/A"));
    // S follows its own path when it is next activated, and only because it is clean.
    _ = session.activate(testing.allocator, testing.io, s, &editor, &status);
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
    const clean = try session.open(
        testing.allocator,
        testing.io,
        temp.dir,
        "clean",
        &editor,
        &status,
    );
    const dirty = try session.open(
        testing.allocator,
        testing.io,
        temp.dir,
        "dirty",
        &editor,
        &status,
    );
    keys(&session, &editor, &status, "iZ\x03");
    _ = try session.open(testing.allocator, testing.io, temp.dir, "other", &editor, &status);
    // Atomic replacement, as an agent's editor would do it.
    for ([_][]const u8{ "clean", "dirty" }) |name| {
        try put(temp.dir, "replacement", "after");
        try std.Io.Dir.rename(temp.dir, "replacement", temp.dir, name, testing.io);
    }
    try testing.expectEqualStrings("before", session.get(clean).?.document.buffer.bytes());
    const reload = session.activate(testing.allocator, testing.io, clean, &editor, &status);
    try testing.expectEqual(External.Reload.reloaded, reload.?);
    try testing.expectEqualStrings("after", session.get(clean).?.document.buffer.bytes());
    try testing.expect(!session.get(clean).?.disk.diverged);
    try testing.expectEqual(null, session.activate(
        testing.allocator,
        testing.io,
        dirty,
        &editor,
        &status,
    ));
    const entry = session.get(dirty).?;
    try testing.expectEqualStrings("Zbefore", entry.document.buffer.bytes());
    try testing.expectEqualStrings("before", entry.document.buffer.base);
    try testing.expectEqual(@as(usize, 1), entry.document.buffer.history.items.len);
    try testing.expect(entry.disk.diverged);
    try testing.expectEqual(error.SourceChanged, session.save(testing.allocator, .{}).failure.?);
    try testing.expectError(
        error.Unsaved,
        session.close(testing.allocator, testing.io, dirty, false, &editor, &status),
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
        const b = try session.open(testing.allocator, testing.io, temp.dir, "b", &editor, &status);
        const a = try session.open(testing.allocator, testing.io, temp.dir, "a", &editor, &status);
        keys(&session, &editor, &status, "iX\x03");
        var failure: Failure = .{ .stage = case.stage orelse .loaded };
        if (case.external) failure.dir = temp.dir;
        const options: file.Options = .{ .context = &failure, .hook = Failure.hook };
        const result = session.saveAndClose(
            testing.allocator,
            testing.io,
            &editor,
            &status,
            options,
        );
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
    var status: Status = .{};
    defer editor.deinit(allocator);
    var session: Session = .{};
    defer session.deinit(allocator);
    const a = try session.open(allocator, testing.io, dir, "a", &editor, &status);
    try armed(&session);
    try session.current().?.document.buffer.replace(allocator, .{ .start = 0, .end = 0 }, "X", 0);
    const b = session.open(allocator, testing.io, dir, "b", &editor, &status) catch |err| {
        try testing.expectEqual(@as(usize, 1), session.entries.items.len);
        try testing.expectEqual(a, session.active.?);
        try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
        return err;
    };
    try armed(&session);
    _ = session.activate(allocator, testing.io, a, &editor, &status);
    try armed(&session);
    try testing.expectEqualStrings("Xa\n", session.current().?.document.buffer.bytes());
    try testing.expectEqual(@as(usize, 1), session.unsaved());
    _ = try session.close(allocator, testing.io, a, true, &editor, &status);
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
    const l = try session.open(testing.allocator, testing.io, temp.dir, "L", &editor, &status);
    keys(&session, &editor, &status, "iZ\x03");
    // L now loops: it names nothing, so A opens as its own document.
    try temp.dir.deleteFile(testing.io, "L");
    try temp.dir.symLink(testing.io, "L", "L", .{});
    const a = try session.open(testing.allocator, testing.io, temp.dir, "A", &editor, &status);
    try testing.expect(a != l);
    try testing.expectEqualStrings("alpha", session.get(a).?.document.buffer.bytes());
    try testing.expectEqualStrings("Zalpha", session.get(l).?.document.buffer.bytes());
    // Behind a directory it may not search, M names nothing either.
    if (linux.geteuid() == 0) return;
    const m = try session.open(
        testing.allocator,
        testing.io,
        temp.dir,
        "locked/M",
        &editor,
        &status,
    );
    const locked = linux.openat(temp.dir.handle, "locked", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(locked));
    const fd: std.posix.fd_t = @intCast(locked);
    defer _ = linux.close(fd);
    defer _ = linux.fchmod(fd, 0o700);
    try testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(linux.fchmod(fd, 0)));
    const b = try session.open(testing.allocator, testing.io, temp.dir, "B", &editor, &status);
    try testing.expect(b != m and b != a and b != l);
    try testing.expectEqual(@as(usize, 4), session.entries.items.len);
}
