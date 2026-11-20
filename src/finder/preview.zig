// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Cancel = @import("discovery.zig").Cancel;
const max_file_bytes = @import("../text/buffer.zig").max_file_bytes;

/// Bytes read for one preview.
pub const limit = 64 * 1024;

/// Lines shown above a location's line, from a file or an open document.
pub const lines_above = 3;

/// Bytes read before a location's line to find the lines above it.
const lead = 4 * 1024;

/// Why a file could not be read.
pub const Failure = Allocator.Error || error{
    FileNotFound,
    AccessDenied,
    /// A directory, FIFO, socket or device.
    UnsupportedFileType,
    ReadFailed,
};

pub const Error = Failure || error{Canceled};

/// A bounded part of a file, read for display only.
pub const Snapshot = struct {
    /// At most `limit` bytes. Owned.
    bytes: []u8,
    /// The file held more than `bytes` when it was read.
    truncated: bool,
    /// The file offset of `bytes`; nonzero only when read near a line.
    start: u64 = 0,

    pub fn deinit(self: *Snapshot, gpa: Allocator) void {
        gpa.free(self.bytes);
        self.* = undefined;
    }
};

/// Reads at most `limit` bytes of `path`, relative to `root`, following
/// symlinks, from the start of the line `lines_above` lines before the line
/// starting at file offset `at`. Lines above that are cut short by the read
/// are left out. Only a regular file is read: the type is checked before
/// opening, so a device is normally never opened, and again on the open
/// descriptor, so one swapped in between is never read. Opening never blocks,
/// whatever the file turns out to be. This is not the editable loader and
/// validates nothing about the bytes; a file changing during the read may be
/// torn.
pub fn read(
    gpa: Allocator,
    root: Io.Dir,
    path: [*:0]const u8,
    at: u64,
    cancel: *const Cancel,
) Error!Snapshot {
    const fd = try open(root, path);
    defer _ = linux.close(fd);
    const first = at -| lead;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    const truncated = while (bytes.items.len < limit) {
        try cancel.check();
        const wanted = chunk[0..@min(chunk.len, limit - bytes.items.len)];
        const count = try retried(fd, wanted, first + bytes.items.len);
        if (count == 0) break false;
        try bytes.appendSlice(gpa, chunk[0..count]);
    } else more: {
        // At the limit, one more byte says whether the file goes on.
        break :more try retried(fd, chunk[0..1], first + limit) != 0;
    };
    const target: usize = @intCast(@min(at - first, bytes.items.len));
    const cut = linesBefore(bytes.items, target, first == 0);
    bytes.replaceRangeAssumeCapacity(0, cut, &.{});
    return .{ .bytes = try bytes.toOwnedSlice(gpa), .truncated = truncated, .start = first + cut };
}

/// Where in `bytes` the line `lines_above` lines before `target` starts.
/// `whole` says `bytes` start the file; otherwise their first line may be
/// partial and is never included.
fn linesBefore(bytes: []const u8, target: usize, whole: bool) usize {
    var cut = target;
    for (0..lines_above) |_| {
        if (cut == 0) break;
        const end = std.mem.lastIndexOfScalar(u8, bytes[0 .. cut - 1], '\n') orelse {
            if (whole) cut = 0;
            break;
        };
        cut = end + 1;
    }
    return cut;
}

/// Reads all of `path`, relative to `root`, as `read` opens it. Refuses a
/// file over `max_file_bytes`, the most Nib opens. The caller frees the bytes.
/// This blocks until the whole file is read.
pub fn readAll(
    gpa: Allocator,
    root: Io.Dir,
    path: [*:0]const u8,
) (Failure || error{FileTooLarge})![]u8 {
    const fd = try open(root, path);
    defer _ = linux.close(fd);
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(gpa);
    while (true) {
        try bytes.ensureUnusedCapacity(gpa, 16 * 1024);
        const room = bytes.unusedCapacitySlice();
        // One byte past the bound tells a file at it from a larger one.
        const wanted = room[0..@min(room.len, max_file_bytes + 1 - bytes.items.len)];
        const count = try retried(fd, wanted, bytes.items.len);
        if (count == 0) return bytes.toOwnedSlice(gpa);
        bytes.items.len += count;
        if (bytes.items.len > max_file_bytes) return error.FileTooLarge;
    }
}

/// One line of a text, borrowed from it.
pub const Line = struct {
    /// The line without its LF or CRLF.
    text: []const u8,
    /// Where the line starts in the text.
    start: usize,
};

/// Zero-based line `number` of `bytes`, split at LF, so a text ending in one
/// has an empty last line, as in `Buffer.line`. Null when the text has fewer
/// lines.
pub fn lineOf(bytes: []const u8, number: u32) ?Line {
    var start: usize = 0;
    for (0..number) |_| {
        start = 1 + (std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse return null);
    }
    const lf = std.mem.indexOfScalarPos(u8, bytes, start, '\n') orelse {
        return .{ .text = bytes[start..], .start = start };
    };
    const end = if (lf > start and bytes[lf - 1] == '\r') lf - 1 else lf;
    return .{ .text = bytes[start..end], .start = start };
}

fn open(root: Io.Dir, path: [*:0]const u8) Failure!posix.fd_t {
    try regular(root.handle, path, 0);
    const flags: linux.O = .{
        .ACCMODE = .RDONLY,
        .NONBLOCK = true,
        .NOCTTY = true,
        .CLOEXEC = true,
    };
    const fd: posix.fd_t = @intCast(try checked(linux.openat(root.handle, path, flags, 0)));
    errdefer _ = linux.close(fd);
    try regular(fd, "", linux.AT.EMPTY_PATH);
    return fd;
}

fn regular(dir: posix.fd_t, path: [*:0]const u8, flags: u32) Failure!void {
    var status: linux.Statx = undefined;
    _ = try checked(linux.statx(dir, path, flags, .{ .TYPE = true }, &status));
    if (!status.mask.TYPE) return error.ReadFailed;
    if (status.mode & linux.S.IFMT != linux.S.IFREG) return error.UnsupportedFileType;
}

fn retried(fd: posix.fd_t, buffer: []u8, offset: u64) Failure!usize {
    while (true) {
        const result = linux.pread(fd, buffer.ptr, buffer.len, @intCast(offset));
        if (posix.errno(result) == .INTR) continue;
        return checked(result);
    }
}

fn checked(result: usize) Failure!usize {
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
    var snapshot = try read(testing.allocator, dir, path, 0, &cancel);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, expected, snapshot.bytes);
    try testing.expectEqual(truncated, snapshot.truncated);
}

fn expectRefused(dir: Io.Dir, path: [*:0]const u8, expected: Error) !void {
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    try testing.expectError(expected, read(testing.allocator, dir, path, 0, &cancel));
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
    try testing.expectError(error.Canceled, read(testing.allocator, temp.dir, "file", 0, &cancel));
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
            var snapshot = try read(gpa, dir, "over", 0, flag);
            defer snapshot.deinit(gpa);
            try testing.expect(snapshot.truncated and snapshot.bytes.len == limit);
        }
    }.run, .{ temp.dir, &cancel });
}

/// Reads `path` at `at` and checks the snapshot's bytes and where they start.
fn expectNear(dir: Io.Dir, path: [*:0]const u8, at: u64, expected: []const u8, start: u64) !void {
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var snapshot = try read(testing.allocator, dir, path, at, &cancel);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqualSlices(u8, expected, snapshot.bytes);
    try testing.expectEqual(start, snapshot.start);
}

test "a preview at a line starts three whole lines above it, past 64 KiB too" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    // 10,000 lines of 10 bytes: "line 0042\n".
    var lines: [100_000]u8 = undefined;
    for (0..10_000) |index| _ = std.fmt.bufPrint(lines[index * 10 ..][0..10], "line {d:0>4}\n", .{
        index,
    }) catch unreachable;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "lines", .data = &lines });
    // Line 9000 starts past 64 KiB; the snapshot starts at line 8997.
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var far = try read(testing.allocator, temp.dir, "lines", 90_000, &cancel);
    defer far.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 89_970), far.start);
    try testing.expectEqualStrings("line 8997\n", far.bytes[0..10]);
    try testing.expectEqualStrings("line 9000\n", far.bytes[30..40]);
    try testing.expectEqual(@as(usize, 10_030), far.bytes.len);
    try testing.expect(!far.truncated);
    // Near the start, the lines above stop at the file's first line.
    try expectNear(temp.dir, "lines", 20, lines[0..limit], 0);
    try expectNear(temp.dir, "lines", 0, lines[0..limit], 0);
    // Two lines in one file each get their own snapshot.
    try expectNear(temp.dir, "lines", 50, lines[20..limit], 20);
    // Past the end, as after the file shrank, the snapshot is empty.
    try expectNear(temp.dir, "lines", 200_000, "", 200_000 - lead);
}

test "a preview at a line reads 64 KiB and leaves out a line above cut short" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try testing.allocator.alloc(u8, 2 * limit);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'x');
    // A line above longer than the bytes read before the target.
    bytes[100] = '\n';
    bytes[100 + lead + 50] = '\n';
    const at = 100 + lead + 51;
    try temp.dir.writeFile(testing.io, .{ .sub_path = "long", .data = bytes });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var snapshot = try read(testing.allocator, temp.dir, "long", at, &cancel);
    defer snapshot.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, at), snapshot.start);
    try testing.expectEqual(limit - lead, snapshot.bytes.len);
    try testing.expect(snapshot.truncated);
}

fn expectLine(bytes: []const u8, number: u32, text: []const u8, start: usize) !void {
    const found = lineOf(bytes, number).?;
    try testing.expectEqualStrings(text, found.text);
    try testing.expectEqual(start, found.start);
}

test "a line is taken whole, without its break, with where it starts" {
    const mixed = "one\r\n  two\nlast\r";
    try expectLine(mixed, 0, "one", 0);
    try expectLine(mixed, 1, "  two", 5);
    try expectLine(mixed, 2, "last\r", 11);
    try testing.expectEqual(null, lineOf(mixed, 3));
    try testing.expectEqual(null, lineOf(mixed, std.math.maxInt(u32)));
    try expectLine("a\n", 1, "", 2);
    try testing.expectEqual(null, lineOf("a\n", 2));
    try expectLine("", 0, "", 0);
    try testing.expectEqual(null, lineOf("", 1));
}

test "a whole file is read up to 8 MiB, and a larger one refused" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @truncate(index);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "edge", .data = bytes[0..max_file_bytes] });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "big", .data = bytes });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "empty", .data = "" });
    const edge = try readAll(testing.allocator, temp.dir, "edge");
    defer testing.allocator.free(edge);
    try testing.expectEqualSlices(u8, bytes[0..max_file_bytes], edge);
    const empty = try readAll(testing.allocator, temp.dir, "empty");
    defer testing.allocator.free(empty);
    try testing.expectEqual(0, empty.len);
    try testing.expectError(error.FileTooLarge, readAll(testing.allocator, temp.dir, "big"));
}

test "a whole file is read only from a regular file, and a FIFO never blocks" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(testing.io, "dir");
    const fifo = linux.mknodat(temp.dir.handle, "fifo", linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fifo));
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedFileType, readAll(gpa, temp.dir, "fifo"));
    try testing.expectError(error.UnsupportedFileType, readAll(gpa, temp.dir, "dir"));
    try testing.expectError(error.FileNotFound, readAll(gpa, temp.dir, "missing"));
    try testing.expectError(error.UnsupportedFileType, readAll(gpa, Io.Dir.cwd(), "/dev/null"));
}

test "allocation failure while reading a whole file or a preview at a line leaks nothing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes: [3 * limit]u8 = @splat('z');
    try temp.dir.writeFile(testing.io, .{ .sub_path = "long", .data = &bytes });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, dir: Io.Dir, flag: *const Cancel) !void {
            const whole = try readAll(gpa, dir, "long");
            defer gpa.free(whole);
            try testing.expectEqual(3 * limit, whole.len);
            var snapshot = try read(gpa, dir, "long", limit, flag);
            defer snapshot.deinit(gpa);
            try testing.expectEqual(@as(u64, limit), snapshot.start);
        }
    }.run, .{ temp.dir, &cancel });
}
