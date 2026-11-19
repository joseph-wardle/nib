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

/// One line of a file.
pub const Line = struct {
    /// The line without its LF or CRLF. Owned.
    text: []u8,
    /// The file offset where the line starts.
    start: u64,

    pub fn deinit(self: *Line, gpa: Allocator) void {
        gpa.free(self.text);
        self.* = undefined;
    }
};

/// Reads zero-based line `number` of `path`, relative to `root`, as `read`
/// opens it. Lines are split at LF, so a file ending in one has an empty
/// last line. Null when the file has fewer lines or the line doesn't end
/// within its first `max_file_bytes`, the most Nib opens. This blocks until
/// the bytes before the line are read.
pub fn line(gpa: Allocator, root: Io.Dir, path: [*:0]const u8, number: u32) Failure!?Line {
    const fd = try open(root, path);
    defer _ = linux.close(fd);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    var chunk: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    var start: ?u64 = if (number == 0) 0 else null;
    var breaks: u32 = 0;
    while (offset < max_file_bytes) {
        const wanted = chunk[0..@intCast(@min(chunk.len, max_file_bytes - offset))];
        const count = try retried(fd, wanted, offset);
        if (count == 0) break;
        var rest = chunk[0..count];
        if (start == null) {
            for (rest, 0..) |byte, index| {
                if (byte != '\n') continue;
                breaks += 1;
                if (breaks < number) continue;
                start = offset + index + 1;
                rest = rest[index + 1 ..];
                break;
            } else rest = rest[rest.len..];
        }
        offset += count;
        if (start == null) continue;
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            try text.appendSlice(gpa, rest);
            continue;
        };
        try text.appendSlice(gpa, rest[0..end]);
        return try finished(gpa, &text, start.?);
    } else {
        // The line goes on past the bound, or the file is larger still.
        if (try retried(fd, chunk[0..1], offset) != 0) return null;
    }
    return if (start) |found| try finished(gpa, &text, found) else null;
}

fn finished(gpa: Allocator, text: *std.ArrayList(u8), start: u64) Allocator.Error!Line {
    if (std.mem.endsWith(u8, text.items, "\r")) text.items.len -= 1;
    return .{ .text = try text.toOwnedSlice(gpa), .start = start };
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

fn expectLine(dir: Io.Dir, path: [*:0]const u8, number: u32, text: []const u8, start: u64) !void {
    var found = (try line(testing.allocator, dir, path, number)).?;
    defer found.deinit(testing.allocator);
    try testing.expectEqualStrings(text, found.text);
    try testing.expectEqual(start, found.start);
}

test "a line is read whole, without its break, with where it starts" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "mixed", .data = "one\r\n  two\nlast" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "ended", .data = "a\n" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "empty", .data = "" });
    try expectLine(temp.dir, "mixed", 0, "one", 0);
    try expectLine(temp.dir, "mixed", 1, "  two", 5);
    try expectLine(temp.dir, "mixed", 2, "last", 11);
    try testing.expectEqual(null, try line(testing.allocator, temp.dir, "mixed", 3));
    try expectLine(temp.dir, "ended", 1, "", 2);
    try testing.expectEqual(null, try line(testing.allocator, temp.dir, "ended", 2));
    try expectLine(temp.dir, "empty", 0, "", 0);
    try testing.expectEqual(null, try line(testing.allocator, temp.dir, "empty", 1));
    const largest = std.math.maxInt(u32);
    try testing.expectEqual(null, try line(testing.allocator, temp.dir, "mixed", largest));
}

test "a line is found across reads, and only within 8 MiB" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes = try testing.allocator.alloc(u8, max_file_bytes + 1);
    defer testing.allocator.free(bytes);
    @memset(bytes, 'y');
    // A 100 KiB line after 40,000 short ones, then one longer than the bound.
    for (0..40_000) |index| bytes[index * 2 ..][0..2].* = "x\n".*;
    bytes[80_000 + 100 * 1024] = '\n';
    try temp.dir.writeFile(testing.io, .{ .sub_path = "big", .data = bytes });
    try expectLine(temp.dir, "big", 39_999, "x", 79_998);
    try expectLine(temp.dir, "big", 40_000, bytes[80_000..][0 .. 100 * 1024], 80_000);
    try testing.expectEqual(null, try line(testing.allocator, temp.dir, "big", 40_001));
    // The same line ending exactly at the bound is read.
    bytes[max_file_bytes - 1] = '\n';
    try temp.dir.writeFile(testing.io, .{ .sub_path = "edge", .data = bytes[0..max_file_bytes] });
    const rest = bytes[80_000 + 100 * 1024 + 1 .. max_file_bytes - 1];
    try expectLine(temp.dir, "edge", 40_001, rest, 80_000 + 100 * 1024 + 1);
    try expectLine(temp.dir, "edge", 40_002, "", max_file_bytes);
}

test "a line is read only from a regular file, and a FIFO never blocks" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(testing.io, "dir");
    const fifo = linux.mknodat(temp.dir.handle, "fifo", linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fifo));
    const gpa = testing.allocator;
    try testing.expectError(error.UnsupportedFileType, line(gpa, temp.dir, "fifo", 0));
    try testing.expectError(error.UnsupportedFileType, line(gpa, temp.dir, "dir", 0));
    try testing.expectError(error.FileNotFound, line(gpa, temp.dir, "missing", 0));
    try testing.expectError(error.UnsupportedFileType, line(gpa, Io.Dir.cwd(), "/dev/null", 0));
}

test "allocation failure while reading a line or a preview at a line leaks nothing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const bytes: [3 * limit]u8 = @splat('z');
    try temp.dir.writeFile(testing.io, .{ .sub_path = "long", .data = &bytes });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: Allocator, dir: Io.Dir, flag: *const Cancel) !void {
            var found = (try line(gpa, dir, "long", 0)).?;
            defer found.deinit(gpa);
            try testing.expectEqual(3 * limit, found.text.len);
            var snapshot = try read(gpa, dir, "long", limit, flag);
            defer snapshot.deinit(gpa);
            try testing.expectEqual(@as(u64, limit), snapshot.start);
        }
    }.run, .{ temp.dir, &cancel });
}
