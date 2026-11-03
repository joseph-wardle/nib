// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

/// Owns one nonblocking inotify queue and the names relevant to the opened path.
/// Events only invalidate: callers must independently validate actual disk state.
pub const Watch = struct {
    fd: posix.fd_t = -1,
    degraded: bool = false,
    entries: std.ArrayList(Entry) = .empty,
    const Entry = struct { wd: i32, name: []const u8 };
    const changes = linux.IN.MODIFY | linux.IN.ATTRIB | linux.IN.CLOSE_WRITE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO | linux.IN.CREATE | linux.IN.DELETE | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;

    pub fn deinit(self: *Watch, allocator: std.mem.Allocator) void {
        if (self.fd >= 0) _ = linux.close(self.fd);
        for (self.entries.items) |entry| allocator.free(entry.name);
        self.entries.deinit(allocator);
        self.* = .{};
    }

    pub fn reset(self: *Watch, allocator: std.mem.Allocator) void {
        self.deinit(allocator);
        const result = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        if (posix.errno(result) != .SUCCESS) {
            self.degraded = true;
            return;
        }
        self.fd = @intCast(result);
    }

    pub fn add(self: *Watch, allocator: std.mem.Allocator, path: []const u8, name: []const u8) void {
        if (self.fd < 0) return;
        var path_buffer: [4096]u8 = undefined;
        const terminated = std.fmt.bufPrintSentinel(&path_buffer, "{s}", .{path}, 0) catch {
            self.degraded = true;
            return;
        };
        const result = linux.inotify_add_watch(self.fd, terminated, changes | linux.IN.MASK_ADD);
        if (posix.errno(result) != .SUCCESS) {
            self.degraded = true;
            return;
        }
        const wd: i32 = @intCast(result);
        for (self.entries.items) |entry| if (entry.wd == wd and std.mem.eql(u8, entry.name, name)) return;
        const owned = allocator.dupe(u8, name) catch {
            self.degraded = true;
            return;
        };
        self.entries.append(allocator, .{ .wd = wd, .name = owned }) catch {
            allocator.free(owned);
            self.degraded = true;
        };
    }

    /// Bounded draining keeps a busy writer from starving keyboard/lifecycle work.
    pub fn drain(self: *Watch) bool {
        if (self.fd < 0) return false;
        var changed = false;
        var bytes: [8192]u8 align(@alignOf(linux.inotify_event)) = undefined;
        for (0..64) |_| {
            const count = linux.read(self.fd, &bytes, bytes.len);
            switch (posix.errno(count)) {
                .AGAIN => return changed,
                .INTR => continue,
                .SUCCESS => if (count == 0) {
                    self.degraded = true;
                    return true;
                },
                else => {
                    self.degraded = true;
                    return true;
                },
            }
            changed = self.consume(bytes[0..count]) or changed;
        }
        return changed;
    }

    fn consume(self: *Watch, bytes: []const u8) bool {
        var offset: usize = 0;
        var changed = false;
        while (offset + @sizeOf(linux.inotify_event) <= bytes.len) {
            const event: *align(1) const linux.inotify_event = @ptrCast(bytes.ptr + offset);
            const end = offset + @sizeOf(linux.inotify_event) + event.len;
            if (end > bytes.len) {
                self.degraded = true;
                return true;
            }
            if (event.mask & (linux.IN.Q_OVERFLOW | linux.IN.IGNORED | linux.IN.UNMOUNT) != 0) {
                self.degraded = true;
                changed = true;
            }
            const raw = bytes[offset + @sizeOf(linux.inotify_event) .. end];
            const name = raw[0 .. std.mem.indexOfScalar(u8, raw, 0) orelse raw.len];
            for (self.entries.items) |entry| {
                if (entry.wd == event.wd and (name.len == 0 or entry.name.len == 0 or std.mem.eql(u8, entry.name, name))) changed = true;
            }
            offset = end;
        }
        if (offset != bytes.len) self.degraded = true;
        return changed or offset != bytes.len;
    }
};

test "overflow and invalidated watches require validation and expose degradation" {
    var watch: Watch = .{};
    for ([_]u32{ linux.IN.Q_OVERFLOW, linux.IN.IGNORED, linux.IN.UNMOUNT }) |mask| {
        watch.degraded = false;
        const event: linux.inotify_event = .{ .wd = -1, .mask = mask, .cookie = 0, .len = 0 };
        try std.testing.expect(watch.consume(std.mem.asBytes(&event)));
        try std.testing.expect(watch.degraded);
    }
}

test "failed watch registration exposes degraded monitoring without losing its queue" {
    var watch: Watch = .{};
    defer watch.deinit(std.testing.allocator);
    watch.reset(std.testing.allocator);
    try std.testing.expect(watch.fd >= 0);
    watch.add(std.testing.allocator, "/dev/null/not-a-directory", "source");
    try std.testing.expect(watch.degraded);
    try std.testing.expect(!watch.drain());
}
