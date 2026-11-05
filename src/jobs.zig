// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const discovery = @import("discovery.zig");
const match = @import("match.zig");
const preview = @import("preview.zig");

pub const Error = discovery.Error || preview.Error || Io.ConcurrentError;

/// Background work the UI thread hands off. A request owns what it carries,
/// except the borrowed root descriptor, which must outlive `Jobs`.
pub const Request = union(enum) {
    /// The start path is borrowed and must outlive the job, as argv does.
    root: discovery.Start,
    project: struct { root: Io.Dir, git: bool },
    all: struct { root: Io.Dir, git: bool },
    /// Holds a reference to the catalog, which the job only reads.
    filter: struct { catalog: *match.Catalog, query: []u8 },
    /// A path relative to the borrowed root. Owned.
    preview: struct { root: Io.Dir, path: [:0]u8 },

    pub fn deinit(self: *Request, gpa: Allocator) void {
        switch (self.*) {
            .filter => |job| {
                job.catalog.release(gpa);
                gpa.free(job.query);
            },
            .preview => |job| gpa.free(job.path),
            else => {},
        }
    }
};

/// A discovered listing, sorted and labelled for searching.
pub const Found = struct {
    catalog: *match.Catalog,
    partial: bool,
    unfiltered: bool,
    /// Why the listing is unfiltered or partial. Owned; may be empty.
    reason: []u8,
    /// Why ignore status is unknown in a worktree. Owned; may be empty.
    ignore_reason: []u8 = &.{},

    pub fn deinit(self: *Found, gpa: Allocator) void {
        self.catalog.release(gpa);
        gpa.free(self.reason);
        gpa.free(self.ignore_reason);
    }
};

/// Owned, immutable results published by a finished job.
pub const Outcome = union(enum) {
    root: Error!discovery.Root,
    listing: Error!Found,
    /// Indices into the request's catalog, best first. Owned.
    matches: Error![]match.Match,
    preview: Error!preview.Snapshot,

    pub fn deinit(self: *Outcome, gpa: Allocator, io: Io) void {
        switch (self.*) {
            .root => |*result| if (result.*) |*root| root.deinit(gpa, io) else |_| {},
            .listing => |*result| if (result.*) |*found| found.deinit(gpa) else |_| {},
            .matches => |result| if (result) |matches| gpa.free(matches) else |_| {},
            .preview => |*result| if (result.*) |*snapshot| snapshot.deinit(gpa) else |_| {},
        }
    }
};

/// Each lane runs at most one job and holds at most one pending request, so
/// threads and memory stay bounded however often the UI asks.
pub const Lane = enum { discovery, filter, preview };

pub const Completion = struct {
    lane: Lane,
    request: Request,
    outcome: Outcome,

    pub fn deinit(self: *Completion, gpa: Allocator, io: Io) void {
        self.request.deinit(gpa);
        self.outcome.deinit(gpa, io);
    }
};

/// Runs jobs with `Io.concurrent` and reports completion through `wake_fd`,
/// which the UI polls; the UI never waits on a running job except in `deinit`.
/// A newer request on a lane cancels the running job and replaces any pending
/// request; superseded results are freed without being reported. Workers hold
/// pointers into this value, so it must not move after the first `submit`.
pub const Jobs = struct {
    /// Readable when `collect` may have something to report. Owned.
    wake_fd: posix.fd_t,
    lanes: std.EnumArray(Lane, Slot),

    pub fn init() error{SystemResources}!Jobs {
        const wake = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (posix.errno(wake) != .SUCCESS) return error.SystemResources;
        errdefer _ = linux.close(@intCast(wake));
        var jobs: Jobs = .{ .wake_fd = @intCast(wake), .lanes = undefined };
        var initialized: usize = 0;
        errdefer for (jobs.lanes.values[0..initialized]) |*slot| slot.cancel.deinit();
        for (&jobs.lanes.values) |*slot| {
            slot.* = .{ .cancel = try .init() };
            initialized += 1;
        }
        return jobs;
    }

    /// Cancels running jobs and waits for each to kill and reap its helpers.
    /// Restore the terminal first: storage that never responds can stall this.
    pub fn deinit(self: *Jobs, gpa: Allocator, io: Io) void {
        for (&self.lanes.values) |*slot| slot.cancel.request();
        for (&self.lanes.values) |*slot| {
            if (slot.pending) |*request| request.deinit(gpa);
            if (slot.running) |*request| {
                if (slot.future) |*future| future.await(io);
                request.deinit(gpa);
                slot.outcome.deinit(gpa, io);
            }
            slot.cancel.deinit();
        }
        _ = linux.close(self.wake_fd);
    }

    /// Takes ownership of `request`.
    pub fn submit(self: *Jobs, gpa: Allocator, io: Io, lane: Lane, request: Request) void {
        const slot = self.lanes.getPtr(lane);
        if (slot.running == null) return self.start(gpa, io, slot, request);
        slot.superseded = true;
        slot.cancel.request();
        if (slot.pending) |*old| old.deinit(gpa);
        slot.pending = request;
    }

    /// Abandons the lane's pending and running work; nothing is reported.
    pub fn cancel(self: *Jobs, gpa: Allocator, lane: Lane) void {
        const slot = self.lanes.getPtr(lane);
        if (slot.pending) |*old| old.deinit(gpa);
        slot.pending = null;
        if (slot.running == null) return;
        slot.superseded = true;
        slot.cancel.request();
    }

    pub fn busy(self: *const Jobs, lane: Lane) bool {
        return self.lanes.getPtrConst(lane).running != null;
    }

    /// Call after `wake_fd` polls readable, and repeat until null. The caller
    /// owns each completion.
    pub fn collect(self: *Jobs, gpa: Allocator, io: Io) ?Completion {
        discovery.drain(self.wake_fd);
        for (&self.lanes.values, 0..) |*slot, index| {
            if (slot.running == null or !slot.done.load(.acquire)) continue;
            // The job has published; awaiting only joins its finished task.
            if (slot.future) |*future| future.await(io);
            slot.future = null;
            var completion: Completion = .{
                .lane = @fromBackingInt(@intCast(index)),
                .request = slot.running.?,
                .outcome = slot.outcome,
            };
            slot.running = null;
            const superseded = slot.superseded;
            if (slot.pending) |request| {
                slot.pending = null;
                self.start(gpa, io, slot, request);
            }
            if (!superseded) return completion;
            completion.deinit(gpa, io);
        }
        return null;
    }

    fn start(self: *Jobs, gpa: Allocator, io: Io, slot: *Slot, request: Request) void {
        slot.cancel.reset();
        slot.done.store(false, .release);
        slot.superseded = false;
        slot.running = request;
        slot.future = io.concurrent(run, .{ gpa, io, slot, self.wake_fd }) catch |err| {
            slot.outcome = failure(request, err);
            publish(slot, self.wake_fd);
            return;
        };
    }
};

const Slot = struct {
    cancel: discovery.Cancel,
    future: ?Io.Future(void) = null,
    running: ?Request = null,
    pending: ?Request = null,
    /// The running job's result is unwanted.
    superseded: bool = false,
    /// Written by the job before `done`; read by the UI after it.
    outcome: Outcome = undefined,
    done: std.atomic.Value(bool) = .init(false),
};

fn run(gpa: Allocator, io: Io, slot: *Slot, wake_fd: posix.fd_t) void {
    const cancel = &slot.cancel;
    slot.outcome = switch (slot.running.?) {
        .root => |start| .{ .root = discovery.resolveRoot(gpa, io, start, cancel) },
        .project => |job| listing: {
            const listed = discovery.listProject(gpa, io, job.root, job.git, cancel);
            break :listing .{ .listing = catalogued(gpa, listed, cancel) };
        },
        .all => |job| listing: {
            const listed = discovery.listAll(gpa, io, job.root, job.git, cancel);
            break :listing .{ .listing = catalogued(gpa, listed, cancel) };
        },
        .filter => |job| .{ .matches = match.filter(gpa, job.catalog, job.query, cancel) },
        .preview => |job| .{ .preview = preview.read(gpa, job.root, job.path, cancel) },
    };
    publish(slot, wake_fd);
}

/// Sorts, labels and marks ignored paths in a listing off the UI thread.
fn catalogued(
    gpa: Allocator,
    listed: Error!discovery.Listing,
    cancel: *const discovery.Cancel,
) Error!Found {
    var listing = try listed;
    defer if (listing.ignored) |*ignored| ignored.deinit(gpa);
    defer listing.repositories.deinit(gpa);
    errdefer gpa.free(listing.reason);
    errdefer gpa.free(listing.ignore_reason);
    const catalog: *match.Catalog = try .create(gpa, listing.paths, cancel);
    errdefer catalog.release(gpa);
    if (listing.ignored) |*ignored| {
        try catalog.classify(gpa, ignored, &listing.repositories, cancel);
    }
    return .{
        .catalog = catalog,
        .partial = listing.partial,
        .unfiltered = listing.unfiltered,
        .reason = listing.reason,
        .ignore_reason = listing.ignore_reason,
    };
}

fn publish(slot: *Slot, wake_fd: posix.fd_t) void {
    slot.done.store(true, .release);
    const one: u64 = 1;
    _ = linux.write(wake_fd, std.mem.asBytes(&one), @sizeOf(u64));
}

fn failure(request: Request, err: Error) Outcome {
    return switch (request) {
        .root => .{ .root = err },
        .project, .all => .{ .listing = err },
        .filter => .{ .matches = err },
        .preview => .{ .preview = err },
    };
}

const testing = std.testing;

/// Waits for the wake descriptor and returns the next reported completion, or
/// null once the lane is idle with nothing to report.
fn next(jobs: *Jobs, lane: Lane) !?Completion {
    while (true) {
        if (jobs.collect(testing.allocator, testing.io)) |completion| return completion;
        if (!jobs.busy(lane)) return null;
        var fds = [_]linux.pollfd{.{ .fd = jobs.wake_fd, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, 10_000);
        try testing.expectEqual(posix.E.SUCCESS, posix.errno(ready));
        if (ready == 0) return error.Timeout;
    }
}

fn fixture(dir: Io.Dir) !void {
    for (0..64) |index| {
        var name: [32]u8 = undefined;
        const path = try std.fmt.bufPrint(&name, "d{d}/e/f{d}", .{ index % 8, index });
        try dir.createDirPath(testing.io, std.fs.path.dirname(path).?);
        try dir.writeFile(testing.io, .{ .sub_path = path, .data = "" });
    }
}

test "a finished job wakes the poll loop and is reported exactly once" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try fixture(temp.dir);
    var jobs: Jobs = try .init();
    const all: Request = .{ .all = .{ .root = temp.dir, .git = false } };
    defer jobs.deinit(testing.allocator, testing.io);
    jobs.submit(testing.allocator, testing.io, .discovery, all);
    var completion = (try next(&jobs, .discovery)).?;
    defer completion.deinit(testing.allocator, testing.io);
    try testing.expect(completion.lane == .discovery and completion.request == .all);
    try testing.expectEqual(@as(usize, 64), (try completion.outcome.listing).catalog.entries.len);
    try testing.expectEqual(@as(?Completion, null), try next(&jobs, .discovery));
}

test "newer requests supersede running and pending ones; only the newest is reported" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try fixture(temp.dir);
    var jobs: Jobs = try .init();
    const all: Request = .{ .all = .{ .root = temp.dir, .git = false } };
    defer jobs.deinit(testing.allocator, testing.io);
    for (0..3) |_| jobs.submit(testing.allocator, testing.io, .discovery, all);
    const project: Request = .{ .project = .{ .root = temp.dir, .git = false } };
    jobs.submit(testing.allocator, testing.io, .discovery, project);
    var completion = (try next(&jobs, .discovery)).?;
    defer completion.deinit(testing.allocator, testing.io);
    try testing.expect(completion.request == .project);
    const listing = try completion.outcome.listing;
    try testing.expect(listing.unfiltered);
    try testing.expectEqual(@as(?Completion, null), try next(&jobs, .discovery));
}

test "cancelled lanes report nothing and owned requests are freed" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try fixture(temp.dir);
    var jobs: Jobs = try .init();
    const all: Request = .{ .all = .{ .root = temp.dir, .git = false } };
    defer jobs.deinit(testing.allocator, testing.io);
    const path = try testing.allocator.dupeSentinel(u8, "d0/e/f0", 0);
    const read: Request = .{ .preview = .{ .root = temp.dir, .path = path } };
    jobs.submit(testing.allocator, testing.io, .preview, read);
    jobs.submit(testing.allocator, testing.io, .discovery, all);
    jobs.cancel(testing.allocator, .discovery);
    jobs.cancel(testing.allocator, .preview);
    try testing.expectEqual(@as(?Completion, null), try next(&jobs, .discovery));
    try testing.expectEqual(@as(?Completion, null), try next(&jobs, .preview));
}

test "shutdown cancels and joins outstanding jobs without leaks" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try fixture(temp.dir);
    var jobs: Jobs = try .init();
    const all: Request = .{ .all = .{ .root = temp.dir, .git = false } };
    jobs.submit(testing.allocator, testing.io, .discovery, all);
    jobs.submit(testing.allocator, testing.io, .discovery, all);
    jobs.deinit(testing.allocator, testing.io);
}
