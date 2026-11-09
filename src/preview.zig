// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cancel = @import("discovery.zig").Cancel;

/// Bytes read for one preview.
pub const limit = 64 * 1024;

pub const Error = Allocator.Error || error{
    Canceled,
    FileNotFound,
    AccessDenied,
    /// A directory, FIFO, socket or device.
    UnsupportedFileType,
    ReadFailed,
};

/// A bounded prefix of a file, read for display only.
pub const Snapshot = struct {
    /// At most `limit` bytes. Owned.
    bytes: []u8,
    /// The file held more than `bytes` when it was read.
    truncated: bool,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Reads the first `limit` bytes of `path`, relative to `root`, following
/// symlinks. Only a regular file is read: the type is checked before opening,
/// so a device is normally never opened, and again on the open descriptor,
/// so one swapped in between is never read. Opening never blocks, whatever
/// the file turns out to be. This is not the editable loader and validates
/// nothing about the bytes; a file changing during the read may be torn.
pub fn read(
    gpa: Allocator,
    root: Io.Dir,
    path: [*:0]const u8,
    cancel: *const Cancel,
) Error!Snapshot {
    try regular(root.handle, path, 0);
    const flags: linux.O = .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOCTTY = true,
        .CLOEXEC = true,
    };
    const fd: posix.fd_t = @intCast(try checked(linux.openat(root.handle, path, flags, 0)));
    defer _ = linux.close(fd);
    try regular(fd, "", linux.AT.EMPTY_PATH);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (bytes.items.len < limit) {
        try cancel.check();
        const count = try retried(fd, chunk[0..@min(chunk.len, limit - bytes.items.len)]);
        if (count == 0) return .{ .bytes = try bytes.toOwnedSlice(gpa), .truncated = false };
        try bytes.appendSlice(gpa, chunk[0..count]);
    }
    // At the limit, one more byte says whether the file goes on.
    const more = try retried(fd, chunk[0..1]);
    return .{ .bytes = try bytes.toOwnedSlice(gpa), .truncated = more != 0 };
}

fn regular(dir: posix.fd_t, path: [*:0]const u8, flags: u32) Error!void {
    var status: linux.Statx = undefined;
    _ = try checked(linux.statx(dir, path, flags, .{ .TYPE = true }, &status));
    if (!status.mask.TYPE) return error.ReadFailed;
    if (status.mode & linux.S.IFMT != linux.S.IFREG) return error.UnsupportedFileType;
}

fn retried(fd: posix.fd_t, buffer: []u8) Error!usize {
    while (true) {
        const result = linux.read(fd, buffer.ptr, buffer.len);
        if (posix.errno(result) == .INTR) continue;
        return checked(result);
    }
}

fn checked(result: usize) Error!usize {
    return switch (posix.errno(result)) {
        .SUCCESS => result,
        .NOENT, .NOTDIR => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .ISDIR, .NXIO, .NODEV => error.UnsupportedFileType,
        .NOMEM => error.OutOfMemory,
        else => error.ReadFailed,
    };
}

const testing = std.testing;

fn expectRead(dir: Io.Dir, path: [*:0]const u8, expected: []const u8, truncated: bool) !void {
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var snapshot = try read(testing.allocator, dir, path, &cancel);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, expected, snapshot.bytes);
    try testing.expectEqual(truncated, snapshot.truncated);
}

fn expectRefused(dir: Io.Dir, path: [*:0]const u8, expected: Error) !void {
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    try testing.expectError(expected, read(testing.allocator, dir, path, &cancel));
}

test "a preview holds a whole file up to 64 KiB and marks a longer one truncated" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try testing.allocator.alloc(u8, limit + 1);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index *% 31);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "empty", .data = "" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "small", .data = "a\r\nb\x00\xff" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "full", .data = bytes[0..limit] });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "over", .data = bytes });
    try expectRead(temp.dir, "empty", "", false);
    try expectRead(temp.dir, "small", "a\r\nb\x00\xff", false);
    try expectRead(temp.dir, "full", bytes[0..limit], false);
    try expectRead(temp.dir, "over", bytes[0..limit], true);
}

test "only regular files are previewed, through symlinks, and a FIFO never blocks" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const handle = temp.dir.handle;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "text" });
    try temp.dir.createDirPath(testing.io, "dir");
    const fifo = linux.mknodat(handle, "fifo", linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fifo));
    for ([_][2][*:0]const u8{
        .{ "file", "to-file" },     .{ "fifo", "to-fifo" }, .{ "/dev/null", "to-device" },
        .{ "missing", "dangling" },
    }) |pair| {
        const linked = linux.symlinkat(pair[0], handle, pair[1]);
        try testing.expectEqual(posix.E.SUCCESS, posix.errno(linked));
    }
    try expectRead(temp.dir, "to-file", "text", false);
    try expectRefused(temp.dir, "dir", error.UnsupportedFileType);
    try expectRefused(temp.dir, "fifo", error.UnsupportedFileType);
    try expectRefused(temp.dir, "to-fifo", error.UnsupportedFileType);
    try expectRefused(temp.dir, "to-device", error.UnsupportedFileType);
    try expectRefused(temp.dir, "missing", error.FileNotFound);
    try expectRefused(temp.dir, "dangling", error.FileNotFound);
    try expectRefused(temp.dir, "file/below", error.FileNotFound);
}

test "an unreadable file is refused" {
    if (linux.geteuid() == 0) return error.SkipZigTest;
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "secret", .data = "x" });
    const hidden = linux.fchmodat(temp.dir.handle, "secret", 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(hidden));
    try expectRefused(temp.dir, "secret", error.AccessDenied);
}

test "a cancelled preview reads nothing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "file", .data = "text" });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    cancel.request();
    try testing.expectError(error.Canceled, read(testing.allocator, temp.dir, "file", &cancel));
}

test "allocation failure while reading a preview leaks nothing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes: [limit + 1]u8 = @splat('x');
    try temp.dir.writeFile(testing.io, .{ .sub_path = "over", .data = &bytes });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, dir: Io.Dir, flag: *const Cancel) !void {
            var snapshot = try read(gpa, dir, "over", flag);
            defer snapshot.deinit(gpa);
            try testing.expect(snapshot.truncated and snapshot.bytes.len == limit);
        }
    }.run, .{ temp.dir, &cancel });
}
