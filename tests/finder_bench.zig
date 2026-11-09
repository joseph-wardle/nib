// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const finder_module = @import("finder");
const Finder = finder_module.Finder;
const Category = finder_module.Category;
const jobs = finder_module.jobs;

// Drives the finder and its jobs as the event loop does, without a terminal,
// over generated fixtures of about 1k, 10k and 100k paths, with and without
// Git. Times are from the request to the completion being applied. "UI" is
// time spent on the calling thread, which the event loop would also spend.
// Nothing here is a pass/fail gate.
pub fn main(init: std.process.Init) !void {
    var counting: Counting = .{ .parent = init.gpa };
    const gpa = counting.allocator();
    const io = init.io;
    for ([_]usize{ 1_000, 10_000, 100_000 }) |size| {
        for ([_]bool{ true, false }) |git| {
            var fixture = try Fixture.create(init.gpa, io, size, git);
            defer fixture.remove(io);
            const listing = try measure(gpa, io, &counting, &fixture);
            try cancellation(gpa, io, &fixture, listing);
        }
    }
    var usage: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &usage);
    std.debug.print("process max RSS {d} KiB (all fixtures, excluding Git helpers)\n", .{usage.maxrss});
}

/// Returns how long All took to list.
fn measure(gpa: Allocator, io: Io, counting: *Counting, fixture: *const Fixture) !u64 {
    const base_live = counting.live.load(.monotonic);
    counting.peak.store(base_live, .monotonic);
    var background: jobs.Jobs = try .init();
    var finder: Finder = .{};
    var run: Run = .{ .gpa = gpa, .io = io, .finder = &finder, .background = &background };
    std.debug.print("{s}, {d} files ({d} more ignored), setup {d:.0} ms\n", .{
        if (fixture.git) "Git" else "plain",
        fixture.size,
        fixture.size / 10,
        ms(fixture.setup),
    });

    // As `nib` alone: focus before the root arrives.
    const start = now(io);
    finder.start(gpa, io, &background, .{ .directory = fixture.path() });
    run.ui(start);
    const focused = now(io);
    try finder.focus(gpa, io, &background, .project, &.{});
    run.ui(focused);
    const root = try run.until(rooted);
    const listed = try run.until(projectListed);
    std.debug.print("  root {d:.2} ms; Project listed {d:.2} ms ({d} paths, shown at once)\n", .{
        ms(root - start),
        ms(listed - start),
        finder.lists.get(.project).catalog.?.entries.len,
    });

    // Typing a query a byte at a time, each filtered in a job.
    const typed = "pkg42mod7";
    var latencies: [typed.len]u64 = undefined;
    var counts: [typed.len]usize = undefined;
    for (0..typed.len) |index| {
        const before = now(io);
        try finder.search(gpa, io, &background, typed[0 .. index + 1]);
        run.ui(before);
        latencies[index] = (try run.until(filtered)) - before;
        counts[index] = finder.matches.len;
    }
    std.debug.print("  query \"{s}\" per byte (ms/matches):", .{typed});
    for (latencies, counts) |latency, count| std.debug.print(" {d:.2}/{d}", .{ ms(latency), count });
    std.debug.print("\n", .{});
    // Clearing the query filters inline, on the UI thread.
    const cleared = now(io);
    try finder.search(gpa, io, &background, "");
    const inline_time = now(io) - cleared;
    run.ui(cleared);
    std.debug.print("  empty query inline {d:.2} ms\n", .{ms(inline_time)});

    // All: the walk, then Git's list of ignored paths, marked in the job.
    const all = now(io);
    try finder.focus(gpa, io, &background, .all, &.{});
    run.ui(all);
    const all_listed = try run.until(allListed);
    const catalog = finder.lists.get(.all).catalog.?;
    var ignored: usize = 0;
    var unknown: usize = 0;
    for (catalog.ignored) |status| switch (status) {
        .ignored => ignored += 1,
        .unknown => unknown += 1,
        .visible => {},
    };
    std.debug.print("  All listed with ignores {d:.2} ms ({d} paths, {d} ignored, {d} unknown)\n", .{
        ms(all_listed - all),
        catalog.entries.len,
        ignored,
        unknown,
    });

    // Settled, with the selection's preview read: nothing should wake the loop.
    try run.quiet();
    var before_idle: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &before_idle);
    var fds = [_]linux.pollfd{.{ .fd = background.wake_fd, .events = linux.POLL.IN, .revents = 0 }};
    const wakeups = linux.poll(&fds, 1, 1000);
    var after_idle: linux.rusage = undefined;
    _ = linux.getrusage(linux.rusage.SELF, &after_idle);
    std.debug.print("  idle 1 s: {d} wakeups, {d} us CPU\n", .{ wakeups, cpu(after_idle) - cpu(before_idle) });

    const live = counting.live.load(.monotonic) - base_live;
    const peak = counting.peak.load(.monotonic) - base_live;
    std.debug.print("  memory with Project and All held: live {d} KiB, peak {d} KiB\n", .{
        live / 1024,
        peak / 1024,
    });
    std.debug.print("  UI work per call: max {d:.2} ms over {d} calls\n", .{ ms(run.stall), run.calls });
    background.deinit(gpa, io);
    finder.deinit(gpa, io);
    return all_listed - all;
}

/// How long quitting waits for outstanding work: `Jobs.deinit` cancels every
/// lane, kills any Git helper's group and joins the workers.
fn cancellation(gpa: Allocator, io: Io, fixture: *const Fixture, listing: u64) !void {
    var times: [2]u64 = undefined;
    for (&times, [_]u64{ 0, listing / 2 }) |*time, delay| {
        var background: jobs.Jobs = try .init();
        var finder: Finder = .{};
        var run: Run = .{ .gpa = gpa, .io = io, .finder = &finder, .background = &background };
        finder.start(gpa, io, &background, .{ .directory = fixture.path() });
        try finder.focus(gpa, io, &background, .all, &.{});
        _ = try run.until(rooted);
        // At once, and halfway through All's usual listing time, which in a
        // worktree may be the walk or Git's ignored list.
        const pause: linux.timespec = .{
            .sec = @intCast(delay / std.time.ns_per_s),
            .nsec = @intCast(delay % std.time.ns_per_s),
        };
        _ = linux.nanosleep(&pause, null);
        const before = now(io);
        background.deinit(gpa, io);
        time.* = now(io) - before;
        finder.deinit(gpa, io);
    }
    std.debug.print("  quit as All starts {d:.2} ms; halfway through {d:.2} ms\n", .{
        ms(times[0]),
        ms(times[1]),
    });
}

const Run = struct {
    gpa: Allocator,
    io: Io,
    finder: *Finder,
    background: *jobs.Jobs,
    /// The longest single call on the UI thread.
    stall: u64 = 0,
    calls: usize = 0,

    fn ui(self: *Run, since: u64) void {
        self.stall = @max(self.stall, now(self.io) - since);
        self.calls += 1;
    }

    /// Applies completions as the event loop does until `done`, returning the
    /// time it first held.
    fn until(self: *Run, comptime done: fn (*const Finder) bool) !u64 {
        while (true) {
            while (true) {
                const before = now(self.io);
                const completion = self.background.collect(self.gpa, self.io) orelse break;
                try self.finder.receive(self.gpa, self.io, self.background, completion);
                self.ui(before);
            }
            if (done(self.finder)) return now(self.io);
            try self.wait();
        }
    }

    /// Applies completions until every lane is idle.
    fn quiet(self: *Run) !void {
        while (true) {
            while (self.background.collect(self.gpa, self.io)) |completion| {
                try self.finder.receive(self.gpa, self.io, self.background, completion);
            }
            const busy = self.background.busy(.discovery) or
                self.background.busy(.filter) or self.background.busy(.preview);
            if (!busy) return;
            try self.wait();
        }
    }

    fn wait(self: *const Run) !void {
        var fds = [_]linux.pollfd{
            .{ .fd = self.background.wake_fd, .events = linux.POLL.IN, .revents = 0 },
        };
        if (linux.poll(&fds, 1, 600_000) == 0) return error.Timeout;
    }
};

fn rooted(finder: *const Finder) bool {
    return !finder.resolving();
}

fn discovered(finder: *const Finder, category: Category) bool {
    const list = finder.lists.getPtrConst(category);
    return list.catalog != null and !list.discovering and !finder.filtering;
}

fn projectListed(finder: *const Finder) bool {
    return discovered(finder, .project);
}

fn allListed(finder: *const Finder) bool {
    return discovered(finder, .all);
}

fn filtered(finder: *const Finder) bool {
    return !finder.filtering;
}

/// `size` source files, 100 per directory, plus a tenth as many build outputs
/// that `.gitignore` excludes. With `git`, the sources are committed to the
/// index; otherwise the directory is plain and is walked.
const Fixture = struct {
    buffer: [64]u8,
    len: usize,
    size: usize,
    git: bool,
    setup: u64,

    fn create(gpa: Allocator, io: Io, size: usize, git: bool) !Fixture {
        const start = now(io);
        var random: [6]u8 = undefined;
        io.random(&random);
        var self: Fixture = .{ .buffer = undefined, .len = 0, .size = size, .git = git, .setup = 0 };
        const name = std.fmt.bytesToHex(random, .lower);
        self.len = (try std.fmt.bufPrint(&self.buffer, "/tmp/nib-bench-{s}", .{&name})).len;
        var dir = try Io.Dir.cwd().createDirPathOpen(io, self.path(), .{});
        defer dir.close(io);
        errdefer self.remove(io);
        try dir.writeFile(io, .{ .sub_path = ".gitignore", .data = "zig-out/\n" });
        const text = "const std = @import(\"std\");\n";
        for (0..size) |index| {
            var buffer: [64]u8 = undefined;
            const directory = try std.fmt.bufPrint(&buffer, "src/pkg{d}", .{index / 100});
            if (index % 100 == 0) try dir.createDirPath(io, directory);
            var file_buffer: [64]u8 = undefined;
            const file = try std.fmt.bufPrint(&file_buffer, "{s}/mod{d}.zig", .{ directory, index % 100 });
            try dir.writeFile(io, .{ .sub_path = file, .data = text });
        }
        for (0..size / 10) |index| {
            var buffer: [64]u8 = undefined;
            const directory = try std.fmt.bufPrint(&buffer, "zig-out/obj{d}", .{index / 100});
            if (index % 100 == 0) try dir.createDirPath(io, directory);
            var file_buffer: [64]u8 = undefined;
            const file = try std.fmt.bufPrint(&file_buffer, "{s}/out{d}.o", .{ directory, index % 100 });
            try dir.writeFile(io, .{ .sub_path = file, .data = "" });
        }
        if (git) {
            try self.runGit(gpa, io, &.{ "init", "-q" });
            try self.runGit(gpa, io, &.{ "add", "-A" });
        }
        self.setup = now(io) - start;
        return self;
    }

    fn path(self: *const Fixture) []const u8 {
        return self.buffer[0..self.len];
    }

    fn runGit(self: *const Fixture, gpa: Allocator, io: Io, arguments: []const []const u8) !void {
        var argv: [8][]const u8 = undefined;
        argv[0..3].* = .{ "git", "-C", self.path() };
        @memcpy(argv[3..][0..arguments.len], arguments);
        const result = try std.process.run(gpa, io, .{ .argv = argv[0 .. 3 + arguments.len] });
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (!result.term.success()) return error.GitFailed;
    }

    fn remove(self: *const Fixture, io: Io) void {
        Io.Dir.cwd().deleteTree(io, self.path()) catch {};
    }
};

/// Counts live and peak bytes across threads.
const Counting = struct {
    parent: Allocator,
    live: std.atomic.Value(usize) = .init(0),
    peak: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *Counting) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn grow(self: *Counting, bytes: usize) void {
        const live = self.live.fetchAdd(bytes, .monotonic) + bytes;
        var peak = self.peak.load(.monotonic);
        while (live > peak) {
            peak = self.peak.cmpxchgWeak(peak, live, .monotonic, .monotonic) orelse break;
        }
    }

    fn change(self: *Counting, old: usize, new: usize) void {
        if (new > old) self.grow(new - old) else _ = self.live.fetchSub(old - new, .monotonic);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        const memory = self.parent.rawAlloc(len, alignment, ret) orelse return null;
        self.grow(len);
        return memory;
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *Counting = @ptrCast(@alignCast(context));
        if (!self.parent.rawResize(memory, alignment, len, ret)) return false;
        self.change(memory.len, len);
        return true;
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) ?[*]u8 {
        const self: *Counting = @ptrCast(@alignCast(context));
        const moved = self.parent.rawRemap(memory, alignment, len, ret) orelse return null;
        self.change(memory.len, len);
        return moved;
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *Counting = @ptrCast(@alignCast(context));
        self.parent.rawFree(memory, alignment, ret);
        _ = self.live.fetchSub(memory.len, .monotonic);
    }
};

fn now(io: Io) u64 {
    const stamp = Io.Timestamp.now(io, .awake);
    return @intCast(stamp.toNanoseconds());
}

fn ms(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / std.time.ns_per_ms;
}

fn cpu(usage: linux.rusage) i64 {
    const user = usage.utime.sec * std.time.us_per_s + usage.utime.usec;
    const system = usage.stime.sec * std.time.us_per_s + usage.stime.usec;
    return @intCast(user + system);
}
