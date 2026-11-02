// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;

// Temporary viewer resource bounds, not a future editing/storage contract.
pub const max_file_bytes = 8 * 1024 * 1024;
pub const max_lines = 256 * 1024;

/// Owns immutable bytes and their line offsets. Release both with deinit using
/// the same allocator. Empty files have one empty line; a final LF terminates
/// the last line rather than creating an additional line.
pub const Snapshot = struct {
    bytes: []const u8,
    line_starts: []const usize,
    max_columns: usize,

    pub const LoadError = std.posix.OpenError || std.Io.File.StatError || std.Io.File.Reader.Error || Allocator.Error || error{
        UnsupportedFileType,
        FileTooLarge,
        TooManyLines,
    };

    /// Opens read-only, follows symlinks, and rejects non-regular files. The
    /// nonblocking open prevents a FIFO without a writer from hanging startup.
    /// Limits apply to bytes actually read as well as the initial stat size.
    /// The result is detached from subsequent file changes, not an atomic read
    /// transaction against concurrent writers.
    pub fn load(allocator: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) LoadError!Snapshot {
        const handle = try std.posix.openat(dir.handle, path, .{
            .ACCMODE = .RDONLY,
            .CLOEXEC = true,
            .NOCTTY = true,
            .NONBLOCK = true,
        }, 0);
        const file: std.Io.File = .{ .handle = handle, .flags = .{ .nonblocking = true } };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.UnsupportedFileType;
        if (stat.size > max_file_bytes) return error.FileTooLarge;
        var reader = file.reader(io, &.{});
        const bytes = reader.interface.allocRemaining(allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.ReadFailed => return reader.err.?,
            error.StreamTooLong => return error.FileTooLarge,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer allocator.free(bytes);
        return index(allocator, bytes);
    }

    /// Copies bytes into a detached snapshot. The caller retains the input.
    pub fn fromBytes(allocator: Allocator, bytes: []const u8) (Allocator.Error || error{ FileTooLarge, TooManyLines })!Snapshot {
        if (bytes.len > max_file_bytes) return error.FileTooLarge;
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        return index(allocator, owned);
    }

    fn index(allocator: Allocator, bytes: []const u8) (Allocator.Error || error{TooManyLines})!Snapshot {
        var count: usize = 1;
        // Exclude the final byte so a terminating LF adds no phantom line.
        const prefix = bytes[0..bytes.len -| 1];
        for (prefix) |byte| {
            if (byte == '\n') {
                if (count == max_lines) return error.TooManyLines;
                count += 1;
            }
        }
        const starts = try allocator.alloc(usize, count);
        starts[0] = 0;
        var row: usize = 1;
        for (prefix, 0..) |byte, offset| {
            if (byte == '\n') {
                starts[row] = offset + 1;
                row += 1;
            }
        }
        var snapshot: Snapshot = .{ .bytes = bytes, .line_starts = starts, .max_columns = 0 };
        for (starts, 0..) |_, line_number| {
            var columns: usize = 0;
            for (snapshot.line(line_number)) |byte| columns += cellWidth(byte, columns);
            snapshot.max_columns = @max(snapshot.max_columns, columns);
        }
        return snapshot;
    }

    pub fn deinit(self: *Snapshot, allocator: Allocator) void {
        allocator.free(self.line_starts);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    /// Borrows a source line with its LF or CRLF terminator removed. A lone CR
    /// remains content and is rendered as an unsupported byte.
    pub fn line(self: Snapshot, row: usize) []const u8 {
        const start = self.line_starts[row];
        var end = if (row + 1 < self.line_starts.len) self.line_starts[row + 1] else self.bytes.len;
        if (end > start and self.bytes[end - 1] == '\n') {
            end -= 1;
            if (end > start and self.bytes[end - 1] == '\r') end -= 1;
        }
        return self.bytes[start..end];
    }
};

pub fn cellWidth(byte: u8, column: usize) usize {
    return if (byte == '\t') 8 - column % 8 else 1;
}

test "line boundaries preserve empty lines and strip only LF or CRLF" {
    const Case = struct { text: []const u8, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .text = "", .lines = &.{""} },
        .{ .text = "\n", .lines = &.{""} },
        .{ .text = "\n\n", .lines = &.{ "", "" } },
        .{ .text = "abc", .lines = &.{"abc"} },
        .{ .text = "abc\n", .lines = &.{"abc"} },
        .{ .text = "a\n\nb", .lines = &.{ "a", "", "b" } },
        .{ .text = "a\r\n\r\nb\r", .lines = &.{ "a", "", "b\r" } },
        .{ .text = "\r\r\n", .lines = &.{"\r"} },
    };
    for (cases) |case| {
        var snapshot = try Snapshot.fromBytes(std.testing.allocator, case.text);
        defer snapshot.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.lines.len, snapshot.line_starts.len);
        for (case.lines, 0..) |expected, row| try std.testing.expectEqualStrings(expected, snapshot.line(row));
    }
}

test "snapshot owns its bytes and computes expanded display width" {
    var original = [_]u8{ 'a', '\t', '\t', 'b', '\r', '\n', 'x', '\n' };
    var snapshot = try Snapshot.fromBytes(std.testing.allocator, &original);
    defer snapshot.deinit(std.testing.allocator);
    @memset(&original, 'z');
    try std.testing.expectEqualStrings("a\t\tb", snapshot.line(0));
    try std.testing.expectEqual(@as(usize, 17), snapshot.max_columns);
}

test "exact resource limits are accepted and excess is rejected" {
    const allocator = std.testing.allocator;
    const bytes = try allocator.alloc(u8, max_file_bytes + 1);
    defer allocator.free(bytes);
    @memset(bytes, 'x');
    {
        var snapshot = try Snapshot.fromBytes(allocator, bytes[0..max_file_bytes]);
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(@as(usize, max_file_bytes), snapshot.max_columns);
    }
    try std.testing.expectError(error.FileTooLarge, Snapshot.fromBytes(allocator, bytes));
    @memset(bytes[0 .. max_lines + 1], '\n');
    {
        var snapshot = try Snapshot.fromBytes(allocator, bytes[0..max_lines]);
        defer snapshot.deinit(allocator);
        try std.testing.expectEqual(@as(usize, max_lines), snapshot.line_starts.len);
    }
    try std.testing.expectError(error.TooManyLines, Snapshot.fromBytes(allocator, bytes[0 .. max_lines + 1]));
}

test "file loading is read-only, detached, and rejects unsupported files" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const content = "first\r\nsecond\tline\n\x1b\x00\xff";
    try temp.dir.writeFile(io, .{ .sub_path = "source", .data = content });
    var snapshot = try Snapshot.load(std.testing.allocator, io, temp.dir, "source");
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(content, snapshot.bytes);
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(content, try temp.dir.readFile(io, "source", &buffer));
    try temp.dir.symLink(io, "source", "link", .{});
    {
        var linked = try Snapshot.load(std.testing.allocator, io, temp.dir, "link");
        defer linked.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(content, linked.bytes);
    }
    try temp.dir.writeFile(io, .{ .sub_path = "source", .data = "changed" });
    try std.testing.expectEqualStrings(content, snapshot.bytes);
    try std.testing.expectError(error.FileNotFound, Snapshot.load(std.testing.allocator, io, temp.dir, "missing"));
    try std.testing.expectError(error.UnsupportedFileType, Snapshot.load(std.testing.allocator, io, temp.dir, "."));
    try std.testing.expectError(error.UnsupportedFileType, Snapshot.load(std.testing.allocator, io, temp.dir, "/dev/null"));
    // A named pipe with no writer must fail promptly rather than block on open.
    const result = std.os.linux.mknodat(temp.dir.handle, "pipe", std.os.linux.S.IFIFO | 0o600, 0);
    try std.testing.expectEqual(std.posix.E.SUCCESS, std.posix.errno(result));
    try std.testing.expectError(error.UnsupportedFileType, Snapshot.load(std.testing.allocator, io, temp.dir, "pipe"));
}

test "on-disk size and line limits are enforced" {
    const io = std.testing.io;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const file = try temp.dir.createFile(io, "large", .{});
    defer file.close(io);
    try file.setLength(io, max_file_bytes);
    {
        var exact = try Snapshot.load(std.testing.allocator, io, temp.dir, "large");
        defer exact.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, max_file_bytes), exact.bytes.len);
    }
    try file.setLength(io, max_file_bytes + 1);
    try std.testing.expectError(error.FileTooLarge, Snapshot.load(std.testing.allocator, io, temp.dir, "large"));
    const newlines = try std.testing.allocator.alloc(u8, max_lines + 1);
    defer std.testing.allocator.free(newlines);
    @memset(newlines, '\n');
    try temp.dir.writeFile(io, .{ .sub_path = "lines", .data = newlines[0..max_lines] });
    {
        var exact = try Snapshot.load(std.testing.allocator, io, temp.dir, "lines");
        defer exact.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, max_lines), exact.line_starts.len);
    }
    try temp.dir.writeFile(io, .{ .sub_path = "lines", .data = newlines });
    try std.testing.expectError(error.TooManyLines, Snapshot.load(std.testing.allocator, io, temp.dir, "lines"));
}

test "allocation failures release snapshot bytes and indexes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, copyWithAllocator, .{});
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(std.testing.io, .{ .sub_path = "source", .data = "first\nsecond\n" });
    try std.testing.checkAllAllocationFailures(std.testing.allocator, loadWithAllocator, .{temp.dir});
}

fn copyWithAllocator(allocator: Allocator) !void {
    var snapshot = try Snapshot.fromBytes(allocator, "first\nsecond\n");
    defer snapshot.deinit(allocator);
}

fn loadWithAllocator(allocator: Allocator, dir: std.Io.Dir) !void {
    var snapshot = try Snapshot.load(allocator, std.testing.io, dir, "source");
    defer snapshot.deinit(allocator);
}
