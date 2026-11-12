// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const file = @import("file.zig");
const motion = @import("../text/motion.zig");
const Watch = @import("watch.zig").Watch;

/// Disk status is independent of local modified state and transient notices.
/// Owns notifications; replacement documents are prepared before any state swap.
pub const Disk = struct {
    watch: Watch = .{},
    diverged: bool = false,
    missing: bool = false,
    pending: bool = false,

    /// What a reload attempt did, for the caller to word.
    pub const Reload = enum { reloaded, failed, out_of_memory };

    pub fn deinit(self: *Disk, allocator: std.mem.Allocator) void {
        self.watch.deinit(allocator);
    }

    pub fn inspect(self: *Disk, allocator: std.mem.Allocator, document: *const file.Document, rearm: bool) void {
        if (rearm) document.source.monitor(allocator, &self.watch);
        document.source.validate(document.buffer.base) catch |err| {
            self.diverged = true;
            self.missing = err == error.FileNotFound;
            self.pending = true;
            return;
        };
        self.diverged = false;
        self.missing = false;
        self.pending = false;
    }

    /// Reloads a clean document that changed on disk. Null when nothing was
    /// attempted. The caller calls it only between edits: a reload replaces
    /// the text under any edit in progress.
    pub fn automatic(
        self: *Disk,
        allocator: std.mem.Allocator,
        io: std.Io,
        document: *file.Document,
        goal: *motion.Goal,
    ) ?Reload {
        if (!self.pending or document.buffer.modified()) return null;
        self.pending = false;
        if (self.missing) return null;
        return self.reload(allocator, io, document, goal);
    }

    /// Replaces the document only once its replacement has loaded, then resets
    /// the goal column for the clamped cursor.
    pub fn reload(
        self: *Disk,
        allocator: std.mem.Allocator,
        io: std.Io,
        document: *file.Document,
        goal: *motion.Goal,
    ) Reload {
        var replacement = file.Source.load(allocator, io, .cwd(), document.source.path) catch |err| {
            return if (err == error.OutOfMemory) .out_of_memory else .failed;
        };
        replacement.buffer.cursor = motion.normal(&replacement.buffer, @min(document.buffer.cursor, replacement.buffer.bytes().len));
        document.deinit(allocator);
        document.* = replacement;
        goal.* = motion.screenColumn(&document.buffer, document.buffer.cursor, false);
        self.inspect(allocator, document, true);
        return .reloaded;
    }

    pub fn status(self: *const Disk) []const u8 {
        if (self.missing) return if (self.watch.degraded) "SOURCE MISSING | MONITORING DEGRADED | " else "SOURCE MISSING | ";
        if (self.diverged) return if (self.watch.degraded) "DISK CONFLICT | MONITORING DEGRADED | " else "DISK CONFLICT | ";
        if (self.watch.degraded) return "MONITORING DEGRADED | ";
        return "";
    }
};

const testing = std.testing;
const linux = std.os.linux;
const posix = std.posix;

fn changed(disk: *Disk) !void {
    var fds = [_]linux.pollfd{.{ .fd = disk.watch.fd, .events = linux.POLL.IN, .revents = 0 }};
    try testing.expect(linux.poll(&fds, 1, 1000) > 0);
    try testing.expect(disk.watch.drain());
}

test "explicit and automatic reload keep vertical movement aligned with a normal tab cursor" {
    for ([_]bool{ false, true }) |explicit| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "\tfirst\n0123456789\n" });
        var document = try file.Source.load(testing.allocator, testing.io, temp.dir, "source");
        defer document.deinit(testing.allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var viewport: view.Viewport = .{};
        defer editor.deinit(testing.allocator);
        var disk: Disk = .{};
        defer disk.deinit(testing.allocator);
        for ("lh") |byte| _ = editor.feed(
            testing.allocator,
            &document.buffer,
            &viewport,
            &status,
            .{ .key = byte },
        );
        try testing.expectEqual(@as(usize, 0), document.buffer.cursor);
        try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "\tother\n0123456789\n" });
        if (explicit) {
            const outcome = disk.reload(
                testing.allocator,
                testing.io,
                &document,
                &viewport.goal,
            );
            try testing.expect(outcome == .reloaded);
        } else {
            disk.inspect(testing.allocator, &document, true);
            const outcome = disk.automatic(
                testing.allocator,
                testing.io,
                &document,
                &viewport.goal,
            );
            try testing.expect(outcome != null);
        }
        _ = editor.feed(
            testing.allocator,
            &document.buffer,
            &viewport,
            &status,
            .{ .key = 'j' },
        );
        try testing.expectEqual(@as(usize, 14), document.buffer.cursor);
        try testing.expectEqual(@as(u8, '7'), document.buffer.bytes()[document.buffer.cursor]);
        _ = editor.feed(
            testing.allocator,
            &document.buffer,
            &viewport,
            &status,
            .{ .key = 'k' },
        );
        try testing.expectEqual(@as(usize, 0), document.buffer.cursor);
    }
}

const Editor = @import("../edit/editor.zig").Editor;
const Status = @import("../edit/editor.zig").Status;
const view = @import("../text/viewport.zig");

test "reload recomputes the vertical goal after clamping to shorter or empty text" {
    const cases = [_]struct { text: []const u8, cursor: usize, up: usize, goal: usize }{
        .{ .text = "ab\n0123456789\n", .cursor = 12, .up = 1, .goal = 9 },
        .{ .text = "\t\n", .cursor = 0, .up = 0, .goal = 7 },
        .{ .text = "", .cursor = 0, .up = 0, .goal = 0 },
    };
    for ([_]bool{ false, true }) |explicit| {
        for (cases) |case| {
            var temp = testing.tmpDir(.{});
            defer temp.cleanup();
            try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "abcdefghijklmnopqrstuvwxyz\nlast\n" });
            var document = try file.Source.load(testing.allocator, testing.io, temp.dir, "source");
            defer document.deinit(testing.allocator);
            var editor: Editor = .{};
            var status: Status = .{};
            var viewport: view.Viewport = .{};
            defer editor.deinit(testing.allocator);
            var disk: Disk = .{};
            defer disk.deinit(testing.allocator);
            _ = editor.feed(
                testing.allocator,
                &document.buffer,
                &viewport,
                &status,
                .{ .key = '$' },
            );
            try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = case.text });
            if (explicit) {
                const outcome = disk.reload(
                    testing.allocator,
                    testing.io,
                    &document,
                    &viewport.goal,
                );
                try testing.expect(outcome == .reloaded);
            } else {
                disk.inspect(testing.allocator, &document, true);
                const outcome = disk.automatic(
                    testing.allocator,
                    testing.io,
                    &document,
                    &viewport.goal,
                );
                try testing.expect(outcome != null);
            }
            try testing.expectEqual(case.cursor, document.buffer.cursor);
            try testing.expectEqual(@as(?usize, case.goal), viewport.goal);
            _ = editor.feed(
                testing.allocator,
                &document.buffer,
                &viewport,
                &status,
                .{ .key = 'k' },
            );
            try testing.expectEqual(case.up, document.buffer.cursor);
            _ = editor.feed(
                testing.allocator,
                &document.buffer,
                &viewport,
                &status,
                .{ .key = 'j' },
            );
            try testing.expectEqual(case.cursor, document.buffer.cursor);
        }
    }
}

test "reload snaps a cursor inside shifted multi-byte text or a CRLF to a character start" {
    const cases = [_]struct { text: []const u8, cursor: usize, goal: usize }{
        .{ .text = "\xc3\xa9\xe2\x82\xacx\n", .cursor = 2, .goal = 1 },
        .{ .text = "\xe6\x9d\x90\xe6\x96\x99\n", .cursor = 3, .goal = 2 },
        .{ .text = "abc\r\n", .cursor = 2, .goal = 2 },
    };
    for (cases) |case| {
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "abcdefgh\n" });
        var document = try file.Source.load(testing.allocator, testing.io, temp.dir, "source");
        defer document.deinit(testing.allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var viewport: view.Viewport = .{};
        defer editor.deinit(testing.allocator);
        var disk: Disk = .{};
        defer disk.deinit(testing.allocator);
        for ("llll") |byte| {
            const buffer = &document.buffer;
            _ = editor.feed(testing.allocator, buffer, &viewport, &status, .{ .key = byte });
        }
        try testing.expectEqual(@as(usize, 4), document.buffer.cursor);
        try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = case.text });
        disk.inspect(testing.allocator, &document, true);
        const outcome = disk.automatic(
            testing.allocator,
            testing.io,
            &document,
            &viewport.goal,
        );
        try testing.expect(outcome != null);
        try testing.expectEqual(case.cursor, document.buffer.cursor);
        try testing.expectEqual(@as(?usize, case.goal), viewport.goal);
    }
}

test "notifications reload clean documents and keep dirty history until explicit reload" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "original\nlast" });
    var document = try file.Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer document.deinit(testing.allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var viewport: view.Viewport = .{};
    defer editor.deinit(testing.allocator);
    var disk: Disk = .{};
    defer disk.deinit(testing.allocator);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(!disk.watch.degraded);
    document.buffer.cursor = 10;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "new" });
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.diverged);
    try testing.expect(disk.automatic(
        testing.allocator,
        testing.io,
        &document,
        &viewport.goal,
    ) != null);
    try testing.expectEqualStrings("new", document.buffer.bytes());
    try testing.expectEqual(@as(usize, 2), document.buffer.cursor);
    try testing.expectEqual(@as(usize, 0), document.buffer.history.items.len);
    try testing.expect(!disk.diverged);
    _ = editor.feed(
        testing.allocator,
        &document.buffer,
        &viewport,
        &status,
        .{ .key = 'i' },
    );
    _ = editor.feed(
        testing.allocator,
        &document.buffer,
        &viewport,
        &status,
        .{ .key = 'X' },
    );
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "disk" });
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.automatic(
        testing.allocator,
        testing.io,
        &document,
        &viewport.goal,
    ) == null);
    _ = editor.feed(testing.allocator, &document.buffer, &viewport, &status, .{ .key = 3 });
    try testing.expect(disk.automatic(
        testing.allocator,
        testing.io,
        &document,
        &viewport.goal,
    ) == null);
    try testing.expectEqualStrings("neXw", document.buffer.bytes());
    try testing.expectEqualStrings("new", document.buffer.base);
    try testing.expectEqual(@as(usize, 1), document.buffer.position);
    try testing.expectEqual(error.SourceChanged, document.source.save(testing.allocator, &document.buffer, .{}).failure.?);
    // Failed explicit reload, including allocation failure, retains the document.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const exhausted = disk.reload(failing.allocator(), testing.io, &document, &viewport.goal);
    try testing.expect(exhausted == .out_of_memory);
    try testing.expectEqualStrings("neXw", document.buffer.bytes());
    try testing.expectEqual(@as(usize, 1), document.buffer.position);
    try temp.dir.deleteFile(testing.io, "source");
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.missing);
    try testing.expect(disk.reload(
        testing.allocator,
        testing.io,
        &document,
        &viewport.goal,
    ) == .failed);
    try testing.expectEqualStrings("new", document.buffer.base);
    try testing.expect(try document.buffer.undo(testing.allocator));
    try testing.expectEqualStrings("new", document.buffer.bytes());
    try testing.expect(disk.automatic(
        testing.allocator,
        testing.io,
        &document,
        &viewport.goal,
    ) == null);
    try testing.expect(try document.buffer.redo(testing.allocator));
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "recreated" });
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    const outcome = disk.reload(testing.allocator, testing.io, &document, &viewport.goal);
    try testing.expect(outcome == .reloaded);
    try testing.expectEqualStrings("recreated", document.buffer.bytes());
    try testing.expect(!document.buffer.modified());
    try testing.expectEqual(@as(usize, 0), document.buffer.history.items.len);
    try testing.expectEqualStrings("", disk.status());
    // An ordinary save's queued directory/inode events compare equal to its new base.
    _ = editor.feed(
        testing.allocator,
        &document.buffer,
        &viewport,
        &status,
        .{ .key = 'i' },
    );
    _ = editor.feed(
        testing.allocator,
        &document.buffer,
        &viewport,
        &status,
        .{ .key = 'Y' },
    );
    _ = editor.feed(testing.allocator, &document.buffer, &viewport, &status, .{ .key = 3 });
    const report = document.source.save(testing.allocator, &document.buffer, .{});
    try testing.expect(report.verified);
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(!disk.diverged);
    try testing.expectEqual(@as(usize, 1), document.buffer.history.items.len);
}

test "watch paths cover intermediate symlinks, directory replacement, inode aliases and restored mtime" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "a", .default_dir);
    try temp.dir.createDir(testing.io, "b", .default_dir);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "a/source", .data = "before" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "b/source", .data = "second" });
    try temp.dir.symLink(testing.io, "a", "middle", .{});
    try temp.dir.symLink(testing.io, "middle/source", "outer", .{});
    var document = try file.Source.load(testing.allocator, testing.io, temp.dir, "outer");
    defer document.deinit(testing.allocator);
    var disk: Disk = .{};
    var goal: motion.Goal = 0;
    defer disk.deinit(testing.allocator);
    disk.inspect(testing.allocator, &document, true);
    // Alias writes produce target-inode notifications, even outside watched parents.
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.linkat(temp.dir.handle, "a/source", temp.dir.handle, "alias", 0)));
    _ = disk.watch.drain();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "alias", .data = "after!" });
    const fd: posix.fd_t = @intCast(linux.openat(temp.dir.handle, "alias", .{ .ACCMODE = .RDWR }, 0));
    defer _ = linux.close(fd);
    const times = [2]linux.timespec{ .{ .sec = document.source.version.atime.sec, .nsec = document.source.version.atime.nsec }, .{ .sec = document.source.version.mtime.sec, .nsec = document.source.version.mtime.nsec } };
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.futimens(fd, &times)));
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.automatic(testing.allocator, testing.io, &document, &goal) != null);
    try testing.expectEqualStrings("after!", document.buffer.bytes());
    try temp.dir.deleteFile(testing.io, "middle");
    try temp.dir.symLink(testing.io, "b", "middle", .{});
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.automatic(testing.allocator, testing.io, &document, &goal) != null);
    try testing.expectEqualStrings("second", document.buffer.bytes());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.renameat(temp.dir.handle, "b", temp.dir.handle, "moved")));
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(disk.missing);
    try testing.expect(disk.automatic(testing.allocator, testing.io, &document, &goal) == null);
    try testing.expectEqualStrings("second", document.buffer.bytes());
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.renameat(temp.dir.handle, "moved", temp.dir.handle, "b")));
    try changed(&disk);
    disk.inspect(testing.allocator, &document, true);
    try testing.expect(!disk.diverged);
    // Failed watch bookkeeping is visible; independent source checks still work.
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    disk.inspect(failing.allocator(), &document, true);
    try testing.expect(disk.watch.degraded);
    try testing.expectEqualStrings("MONITORING DEGRADED | ", disk.status());
    try temp.dir.writeFile(testing.io, .{ .sub_path = "b/source", .data = "latest" });
    disk.inspect(testing.allocator, &document, false);
    try testing.expect(disk.diverged);
    try testing.expect(disk.automatic(testing.allocator, testing.io, &document, &goal) != null);
    try testing.expectEqualStrings("latest", document.buffer.bytes());
    try testing.expect(!disk.watch.degraded);
}
