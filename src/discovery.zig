// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Child = std.process.Child;

pub const Error = Allocator.Error || error{
    Canceled,
    FileNotFound,
    AccessDenied,
    NotADirectory,
    OpenFailed,
    GitUnavailable,
    HelperFailed,
    UnexpectedOutput,
};

/// Cooperative cancellation for one job at a time. A job polls `fd` while it
/// waits on a helper and checks the flag between filesystem steps.
pub const Cancel = struct {
    fd: posix.fd_t,
    requested: std.atomic.Value(bool) = .init(false),

    pub fn init() error{SystemResources}!Cancel {
        const result = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (posix.errno(result) != .SUCCESS) return error.SystemResources;
        return .{ .fd = @intCast(result) };
    }

    pub fn deinit(self: *Cancel) void {
        _ = linux.close(self.fd);
    }

    /// Safe from any thread while a job runs.
    pub fn request(self: *Cancel) void {
        self.requested.store(true, .release);
        signal(self.fd);
    }

    /// Only while no job uses this value.
    pub fn reset(self: *Cancel) void {
        self.requested.store(false, .release);
        drain(self.fd);
    }

    pub fn check(self: *const Cancel) error{Canceled}!void {
        if (self.requested.load(.acquire)) return error.Canceled;
    }
};

/// Raw relative paths, each followed by a NUL. Owns its memory.
pub const Inventory = struct {
    bytes: []u8 = &.{},
    /// Offset of the NUL that ends each path.
    ends: []usize = &.{},

    pub fn count(self: *const Inventory) usize {
        return self.ends.len;
    }

    /// Borrowed until `deinit`.
    pub fn path(self: *const Inventory, index: usize) []const u8 {
        const start = if (index == 0) 0 else self.ends[index - 1] + 1;
        return self.bytes[start..self.ends[index]];
    }

    pub fn deinit(self: *Inventory, gpa: Allocator) void {
        gpa.free(self.bytes);
        gpa.free(self.ends);
        self.* = .{};
    }

    /// Takes ownership of NUL-terminated `bytes`, even on failure. Entries
    /// ending in `/` name nested repositories rather than files; they are
    /// kept only when `directories` is set.
    fn fromNulTerminated(
        gpa: Allocator,
        bytes: []u8,
        directories: bool,
    ) Allocator.Error!Inventory {
        errdefer gpa.free(bytes);
        var ends: std.ArrayList(usize) = .empty;
        errdefer ends.deinit(gpa);
        var kept: usize = 0;
        var start: usize = 0;
        while (std.mem.indexOfScalarPos(u8, bytes, start, 0)) |end| : (start = end + 1) {
            const entry = bytes[start..end];
            if (entry.len == 0) continue;
            if (!directories and entry[entry.len - 1] == '/') continue;
            std.mem.copyForwards(u8, bytes[kept..], bytes[start .. end + 1]);
            kept += entry.len + 1;
            try ends.append(gpa, kept - 1);
        }
        const offsets = try ends.toOwnedSlice(gpa);
        errdefer gpa.free(offsets);
        // Last: once `bytes` moves, the errdefer above would free a stale slice.
        const owned = if (kept == bytes.len) bytes else try gpa.realloc(bytes, kept);
        return .{ .bytes = owned, .ends = offsets };
    }
};

/// The fixed project root. `dir` is an open descriptor, so later discovery is
/// unaffected by renames of the path it was found through.
pub const Root = struct {
    dir: Io.Dir,
    /// Absolute path for display.
    path: []u8,
    git: bool,
    /// Why Git filtering is unavailable; empty when `git` is set.
    reason: []u8,

    pub fn deinit(self: *Root, gpa: Allocator, io: Io) void {
        self.dir.close(io);
        gpa.free(self.path);
        gpa.free(self.reason);
    }
};

/// How Nib was started. Paths are borrowed for the duration of the call.
pub const Start = union(enum) {
    /// `nib <dir>` uses that directory, narrowed even inside a worktree.
    directory: []const u8,
    /// `nib <file>` uses the enclosing worktree, else the file's directory.
    /// The directory is the path as typed, so a symlinked file belongs to the
    /// project it was named from.
    file: []const u8,
    /// `nib` alone uses the worktree containing cwd, else cwd.
    working,
};

/// Runs `git rev-parse --show-toplevel` without a shell. Missing or failing Git
/// yields an unfiltered root with the reason, not an error.
pub fn resolveRoot(gpa: Allocator, io: Io, start: Start, cancel: *const Cancel) Error!Root {
    const start_path = switch (start) {
        .directory => |path| path,
        .file => |path| std.fs.path.dirname(path) orelse ".",
        .working => ".",
    };
    var dir = try openDirectory(linux.AT.FDCWD, start_path);
    errdefer dir.close(io);
    var git = true;
    var reason: []u8 = &.{};
    errdefer gpa.free(reason);
    const arguments = [_][]const u8{ "rev-parse", "--show-toplevel" };
    const run = runGit(gpa, io, dir, &arguments, cancel);
    const output: ?Output = run catch |err| switch (err) {
        error.GitUnavailable => null,
        else => |e| return e,
    };
    if (output == null) {
        git = false;
        reason = try gpa.dupe(u8, "Git not found");
    }
    if (output) |result| {
        defer gpa.free(result.stdout);
        if (!result.succeeded()) {
            git = false;
            reason = try gpa.dupe(u8, result.diagnostic());
        } else if (start != .directory) {
            const top = std.mem.trimEnd(u8, result.stdout, "\n");
            if (top.len == 0 or top[0] != '/') return error.UnexpectedOutput;
            const worktree = try openDirectory(linux.AT.FDCWD, top);
            dir.close(io);
            dir = worktree;
        }
    }
    var buffer: [linux.PATH_MAX]u8 = undefined;
    const length = dir.realPath(io, &buffer) catch return error.OpenFailed;
    const path = try gpa.dupe(u8, buffer[0..length]);
    return .{ .dir = dir, .path = path, .git = git, .reason = reason };
}

pub const Listing = struct {
    paths: Inventory,
    /// Some directories could not be read, so paths may be missing.
    partial: bool = false,
    /// Git did not filter this listing.
    unfiltered: bool,
    /// Why the listing is unfiltered or partial. Owned; may be empty.
    reason: []u8 = &.{},
    /// All in a worktree: the untracked paths Git ignores, with wholly
    /// ignored directories and ignored nested repositories ending in `/`.
    /// Null when not asked or unknown.
    ignored: ?Inventory = null,
    /// Walks only: directories beneath the root holding a `.git`, each
    /// ending in `/`. Git's listing never answers for what lies inside them.
    repositories: Inventory = .{},
    /// Why Git could not say which paths it ignores, or which ones it could
    /// not answer for. Owned; may be empty.
    ignore_reason: []u8 = &.{},

    pub fn deinit(self: *Listing, gpa: Allocator) void {
        self.paths.deinit(gpa);
        gpa.free(self.reason);
        if (self.ignored) |*ignored| ignored.deinit(gpa);
        self.repositories.deinit(gpa);
        gpa.free(self.ignore_reason);
    }
};

/// Ordinary project files. Inside a worktree Git lists tracked and unignored
/// untracked files; otherwise, or if Git fails, the walk is unfiltered.
pub fn listProject(
    gpa: Allocator,
    io: Io,
    root: Io.Dir,
    git: bool,
    cancel: *const Cancel,
) Error!Listing {
    if (!git) return walk(gpa, root, cancel, "Not a Git worktree; listing unfiltered");
    const arguments = [_][]const u8{
        "ls-files", "--cached", "--others", "--exclude-standard", "--deduplicate", "-z", "--", ".",
    };
    var output = runGit(gpa, io, root, &arguments, cancel) catch |err| switch (err) {
        error.GitUnavailable => return walk(gpa, root, cancel, "Git not found; listing unfiltered"),
        else => |e| return e,
    };
    if (!output.succeeded()) {
        gpa.free(output.stdout);
        var prefix: [64 + max_diagnostic]u8 = undefined;
        const why = std.fmt.bufPrint(&prefix, "Git listing failed ({s}); listing unfiltered", .{
            output.diagnostic(),
        }) catch unreachable;
        return walk(gpa, root, cancel, why);
    }
    return .{ .paths = try .fromNulTerminated(gpa, output.stdout, false), .unfiltered = false };
}

/// Every regular file under `root`, including hidden and ignored ones. In a
/// worktree, Git then lists the ignored ones, a wholly ignored directory as
/// one `dir/` entry; tracked files are never ignored, and nested repositories
/// and submodules are not looked into. The walk comes first, so a path it
/// found and Git missed was removed in between, not ignored.
pub fn listAll(gpa: Allocator, io: Io, root: Io.Dir, git: bool, cancel: *const Cancel) Error!Listing {
    var listing = try walk(gpa, root, cancel, "");
    errdefer listing.deinit(gpa);
    listing.unfiltered = false;
    if (!git) return listing;
    const arguments = [_][]const u8{
        "ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--", ".",
    };
    const why: []const u8 = why: {
        var output = runGit(gpa, io, root, &arguments, cancel) catch |err| switch (err) {
            error.Canceled, error.OutOfMemory => |e| return e,
            error.GitUnavailable => break :why "Git not found",
            else => break :why "Git failed",
        };
        if (output.succeeded()) {
            listing.ignored = try .fromNulTerminated(gpa, output.stdout, true);
            const nested = listing.repositories.count();
            if (nested == 0) return listing;
            const text = "Ignore status unknown in {d} nested repositor{s}";
            listing.ignore_reason = try std.fmt.allocPrint(gpa, text, .{
                nested,
                if (nested == 1) "y" else "ies",
            });
            return listing;
        }
        gpa.free(output.stdout);
        listing.ignore_reason = try std.fmt.allocPrint(gpa, "Ignore status unknown: {s}", .{
            output.diagnostic(),
        });
        return listing;
    };
    listing.ignore_reason = try std.fmt.allocPrint(gpa, "Ignore status unknown: {s}", .{why});
    return listing;
}

const max_diagnostic = 200;

const Output = struct {
    /// Owned.
    stdout: []u8,
    term: Child.Term,
    stderr: [max_diagnostic]u8 = undefined,
    stderr_len: usize = 0,

    fn succeeded(self: *const Output) bool {
        return self.term == .exited and self.term.exited == 0;
    }

    /// First line of Git's error output, or the exit status.
    fn diagnostic(self: *const Output) []const u8 {
        const text = self.stderr[0..self.stderr_len];
        const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
        const line = std.mem.trim(u8, first, " ");
        return if (line.len != 0) line else "Git failed";
    }
};

/// Runs Git in `cwd` with argv only, in its own process group, with no
/// terminal access. Every path after a successful spawn kills that group and
/// reaps the direct child exactly once, before returning.
fn runGit(
    gpa: Allocator,
    io: Io,
    cwd: Io.Dir,
    arguments: []const []const u8,
    cancel: *const Cancel,
) Error!Output {
    // Git inherits Nib's blocked signals and passes them on. An fsmonitor
    // daemon it started would leave the group, escape the kill and ignore
    // TERM, so none is started.
    const prefix = [_][]const u8{ "git", "--no-optional-locks", "-c", "core.fsmonitor=false" };
    var argv: [prefix.len + 8][]const u8 = undefined;
    argv[0..prefix.len].* = prefix;
    @memcpy(argv[prefix.len..][0..arguments.len], arguments);
    var child = std.process.spawn(io, .{
        .argv = argv[0 .. prefix.len + arguments.len],
        .cwd = .{ .dir = cwd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch |err| return switch (err) {
        // Zig 0.17's spawn returns an exec failure without reaping the child
        // or closing its pipes, and never gives out the PID, so each failure
        // leaves a zombie and two descriptors. Reaping with P_ALL would take
        // other workers' helpers; without Git, nothing spawns Git again.
        error.FileNotFound => error.GitUnavailable,
        error.Canceled => error.Canceled,
        else => error.HelperFailed,
    };
    var output: Output = .{ .stdout = &.{}, .term = undefined };
    var stdout: std.ArrayList(u8) = .empty;
    const exchanged = exchange(gpa, &child, cancel, &stdout, &output);
    const term = reap(io, &child);
    exchanged catch |err| {
        stdout.deinit(gpa);
        return err;
    };
    output.term = term orelse {
        stdout.deinit(gpa);
        return error.HelperFailed;
    };
    output.stdout = stdout.toOwnedSlice(gpa) catch |err| {
        stdout.deinit(gpa);
        return err;
    };
    return output;
}

/// Collects output and waits for the child to exit, returning early on
/// cancellation. Leaves the child unreaped.
fn exchange(
    gpa: Allocator,
    child: *Child,
    cancel: *const Cancel,
    stdout: *std.ArrayList(u8),
    output: *Output,
) Error!void {
    const pidfd_result = linux.pidfd_open(child.id.?, 0);
    if (posix.errno(pidfd_result) != .SUCCESS) return error.HelperFailed;
    const pidfd: posix.fd_t = @intCast(pidfd_result);
    defer _ = linux.close(pidfd);
    for ([_]?Io.File{ child.stdout, child.stderr }) |pipe| if (pipe) |end| {
        const flags = linux.fcntl(end.handle, linux.F.GETFL, 0);
        if (posix.errno(flags) != .SUCCESS) return error.HelperFailed;
        const nonblocking = flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
        if (posix.errno(linux.fcntl(end.handle, linux.F.SETFL, nonblocking)) != .SUCCESS)
            return error.HelperFailed;
    };
    var discard: [4096]u8 = undefined;
    while (child.stdout != null or child.stderr != null) {
        var fds = [_]linux.pollfd{
            .{ .fd = cancel.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = handle(child.stdout), .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = handle(child.stderr), .events = linux.POLL.IN, .revents = 0 },
        };
        try wait(&fds);
        if (fds[0].revents != 0) return error.Canceled;
        if (fds[1].revents != 0) {
            try stdout.ensureUnusedCapacity(gpa, 64 * 1024);
            const spare = stdout.unusedCapacitySlice();
            const count = linux.read(fds[1].fd, spare.ptr, spare.len);
            switch (posix.errno(count)) {
                .SUCCESS => if (count == 0) closePipe(&child.stdout) else {
                    stdout.items.len += count;
                },
                .AGAIN, .INTR => {},
                else => return error.HelperFailed,
            }
        }
        if (fds[2].revents != 0) {
            const count = linux.read(fds[2].fd, &discard, discard.len);
            switch (posix.errno(count)) {
                .SUCCESS => if (count == 0) closePipe(&child.stderr) else {
                    const kept = @min(count, output.stderr.len - output.stderr_len);
                    @memcpy(output.stderr[output.stderr_len..][0..kept], discard[0..kept]);
                    output.stderr_len += kept;
                },
                .AGAIN, .INTR => {},
                else => return error.HelperFailed,
            }
        }
    }
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = cancel.fd, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = pidfd, .events = linux.POLL.IN, .revents = 0 },
        };
        try wait(&fds);
        if (fds[0].revents != 0) return error.Canceled;
        if (fds[1].revents != 0) return;
    }
}

/// Kills whatever remains of the helper's group, then reaps the direct child.
/// The leader is unreaped until here, so its group ID cannot have been reused.
fn reap(io: Io, child: *Child) ?Child.Term {
    _ = linux.kill(-child.id.?, .KILL);
    // Cancelling the wait would release the handles without reaping.
    const protection = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(protection);
    return child.wait(io) catch null;
}

fn wait(fds: []linux.pollfd) Error!void {
    while (true) switch (posix.errno(linux.poll(fds.ptr, fds.len, -1))) {
        .SUCCESS => return,
        .INTR => continue,
        else => return error.HelperFailed,
    };
}

fn handle(pipe: ?Io.File) posix.fd_t {
    return if (pipe) |end| end.handle else -1;
}

fn closePipe(pipe: *?Io.File) void {
    if (pipe.*) |end| _ = linux.close(end.handle);
    pipe.* = null;
}

fn signal(fd: posix.fd_t) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one), @sizeOf(u64));
}

pub fn drain(fd: posix.fd_t) void {
    var count: u64 = undefined;
    _ = linux.read(fd, std.mem.asBytes(&count), @sizeOf(u64));
}

/// Breadth-first walk of regular files and symlinks to them, skipping `.git`.
/// Directories are opened beneath `root` without following any symlink, so a
/// concurrent rename cannot redirect the walk outside the project. Special
/// files are never opened. Unreadable directories make the listing partial.
fn walk(gpa: Allocator, root: Io.Dir, cancel: *const Cancel, why: []const u8) Error!Listing {
    var files: Builder = .{};
    defer files.deinit(gpa);
    var directories: Builder = .{};
    defer directories.deinit(gpa);
    try directories.append(gpa, "", "");
    var repositories: Builder = .{};
    defer repositories.deinit(gpa);
    var unreadable: usize = 0;
    var next: usize = 0;
    var prefix: [linux.PATH_MAX]u8 = undefined;
    var entries: [16 * 1024]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (next < directories.ends.items.len) : (next += 1) {
        try cancel.check();
        const relative = directories.path(next);
        if (relative.len >= prefix.len) {
            unreadable += 1;
            continue;
        }
        @memcpy(prefix[0..relative.len], relative);
        prefix[relative.len] = 0;
        const target = if (relative.len == 0) "." else prefix[0..relative.len :0];
        const dir = openBeneath(root.handle, target) orelse {
            unreadable += 1;
            continue;
        };
        defer _ = linux.close(dir);
        // `relative` may move as directories are appended; `here` cannot.
        const here = prefix[0..relative.len];
        while (true) {
            const length = linux.getdents64(dir, &entries, entries.len);
            if (posix.errno(length) != .SUCCESS) {
                unreadable += 1;
                break;
            }
            if (length == 0) break;
            var offset: usize = 0;
            while (offset < length) {
                const entry: *align(1) const linux.dirent64 = @ptrCast(&entries[offset]);
                const name_offset = offset + @offsetOf(linux.dirent64, "name");
                const name_z: [*:0]const u8 = @ptrCast(&entries[name_offset]);
                offset += entry.reclen;
                const name = std.mem.span(name_z);
                if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
                if (std.mem.eql(u8, name, ".git")) {
                    // A directory for a nested repository, a file for a
                    // submodule; the root's own is not nested.
                    if (here.len != 0) try repositories.append(gpa, here, "");
                    continue;
                }
                switch (kind(dir, name_z, entry.type)) {
                    .directory => try directories.append(gpa, here, name),
                    .file => try files.append(gpa, here, name),
                    .other => {},
                }
            }
            try cancel.check();
        }
    }
    var reason: []u8 = &.{};
    if (unreadable != 0) {
        reason = try std.fmt.allocPrint(gpa, "{s}{s}{d} unreadable director{s}; listing partial", .{
            why,
            if (why.len != 0) "; " else "",
            unreadable,
            if (unreadable == 1) "y" else "ies",
        });
    } else if (why.len != 0) reason = try gpa.dupe(u8, why);
    errdefer gpa.free(reason);
    var nested = try repositories.toInventory(gpa);
    errdefer nested.deinit(gpa);
    return .{
        .repositories = nested,
        .paths = try files.toInventory(gpa),
        .partial = unreadable != 0,
        .unfiltered = true,
        .reason = reason,
    };
}

const Kind = enum { directory, file, other };

/// Symlinks count as files only when they resolve to a regular file;
/// directory symlinks are never followed.
fn kind(dir: posix.fd_t, name: [*:0]const u8, dirent_type: u8) Kind {
    switch (dirent_type) {
        linux.DT.DIR => return .directory,
        linux.DT.REG => return .file,
        linux.DT.LNK => return if (isType(dir, name, 0, linux.S.IFREG)) .file else .other,
        linux.DT.UNKNOWN => {
            if (isType(dir, name, linux.AT.SYMLINK_NOFOLLOW, linux.S.IFDIR)) return .directory;
            return if (isType(dir, name, 0, linux.S.IFREG)) .file else .other;
        },
        else => return .other,
    }
}

fn isType(dir: posix.fd_t, name: [*:0]const u8, flags: u32, file_type: u32) bool {
    var status: linux.Statx = undefined;
    const all_flags = flags | linux.AT.NO_AUTOMOUNT;
    const result = linux.statx(dir, name, all_flags, .{ .TYPE = true }, &status);
    return posix.errno(result) == .SUCCESS and status.mode & linux.S.IFMT == file_type;
}

const OpenHow = extern struct { flags: u64, mode: u64, resolve: u64 };
const resolve_no_magiclinks = 0x02;
const resolve_no_symlinks = 0x04;
const resolve_beneath = 0x08;

fn openBeneath(root: posix.fd_t, path: [*:0]const u8) ?posix.fd_t {
    const flags: linux.O = .{
        .DIRECTORY = true,
        .NOFOLLOW = true,
        .NONBLOCK = true,
        .CLOEXEC = true,
    };
    var how: OpenHow = .{
        .flags = @as(u32, @bitCast(flags)),
        .mode = 0,
        .resolve = resolve_beneath | resolve_no_symlinks | resolve_no_magiclinks,
    };
    const result = linux.syscall4(
        .openat2,
        @bitCast(@as(isize, root)),
        @intFromPtr(path),
        @intFromPtr(&how),
        @sizeOf(OpenHow),
    );
    if (posix.errno(result) != .SUCCESS) return null;
    return @intCast(result);
}

fn openDirectory(dir: posix.fd_t, path: []const u8) Error!Io.Dir {
    var buffer: [linux.PATH_MAX]u8 = undefined;
    if (path.len >= buffer.len) return error.OpenFailed;
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    const flags: linux.O = .{ .DIRECTORY = true, .CLOEXEC = true };
    const result = linux.openat(dir, buffer[0..path.len :0], flags, 0);
    return switch (posix.errno(result)) {
        .SUCCESS => .{ .handle = @intCast(result) },
        .NOENT => error.FileNotFound,
        .ACCES, .PERM => error.AccessDenied,
        .NOTDIR => error.NotADirectory,
        else => error.OpenFailed,
    };
}

/// Accumulates NUL-terminated `prefix/name` paths.
const Builder = struct {
    bytes: std.ArrayList(u8) = .empty,
    ends: std.ArrayList(usize) = .empty,

    fn append(
        self: *Builder,
        gpa: Allocator,
        prefix: []const u8,
        name: []const u8,
    ) Allocator.Error!void {
        const separator: usize = @intFromBool(prefix.len != 0);
        try self.ends.ensureUnusedCapacity(gpa, 1);
        try self.bytes.ensureUnusedCapacity(gpa, prefix.len + separator + name.len + 1);
        self.bytes.appendSliceAssumeCapacity(prefix);
        if (separator != 0) self.bytes.appendAssumeCapacity('/');
        self.bytes.appendSliceAssumeCapacity(name);
        self.ends.appendAssumeCapacity(self.bytes.items.len);
        self.bytes.appendAssumeCapacity(0);
    }

    fn path(self: *const Builder, index: usize) []const u8 {
        const start = if (index == 0) 0 else self.ends.items[index - 1] + 1;
        return self.bytes.items[start..self.ends.items[index]];
    }

    fn toInventory(self: *Builder, gpa: Allocator) Allocator.Error!Inventory {
        const ends = try self.ends.toOwnedSlice(gpa);
        errdefer gpa.free(ends);
        return .{ .bytes = try self.bytes.toOwnedSlice(gpa), .ends = ends };
    }

    fn deinit(self: *Builder, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        self.ends.deinit(gpa);
    }
};

const testing = std.testing;

/// A directory outside any worktree, for tests here and in `finder.zig`.
/// `testing.tmpDir` lives inside the repository's cache, where Git would find
/// Nib's own worktree.
pub const Scratch = struct {
    dir: Io.Dir,
    path_buffer: [64]u8,
    path_len: usize,

    pub fn init() !Scratch {
        var random: [12]u8 = undefined;
        testing.io.random(&random);
        var name: [16]u8 = undefined;
        _ = std.base64.url_safe.Encoder.encode(&name, &random);
        var self: Scratch = .{ .dir = undefined, .path_buffer = undefined, .path_len = 0 };
        self.path_len = (try std.fmt.bufPrint(&self.path_buffer, "/tmp/nib-test-{s}", .{name})).len;
        self.dir = try Io.Dir.cwd().createDirPathOpen(testing.io, self.path(), .{});
        return self;
    }

    pub fn deinit(self: *Scratch) void {
        self.dir.close(testing.io);
        Io.Dir.cwd().deleteTree(testing.io, self.path()) catch {};
    }

    pub fn path(self: *const Scratch) []const u8 {
        return self.path_buffer[0..self.path_len];
    }

    pub fn join(self: *const Scratch, buffer: []u8, relative: []const u8) []const u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.path(), relative }) catch unreachable;
    }

    pub fn put(self: *const Scratch, relative: []const u8) !void {
        if (std.fs.path.dirname(relative)) |parent| try self.dir.createDirPath(testing.io, parent);
        try self.dir.writeFile(testing.io, .{ .sub_path = relative, .data = "" });
    }

    pub fn link(self: *const Scratch, target: [*:0]const u8, relative: [*:0]const u8) !void {
        const result = linux.symlinkat(target, self.dir.handle, relative);
        try testing.expectEqual(posix.E.SUCCESS, posix.errno(result));
    }

    pub fn git(self: *const Scratch, arguments: []const []const u8) !void {
        var argv: [12][]const u8 = undefined;
        argv[0..3].* = .{ "git", "-C", self.path() };
        @memcpy(argv[3..][0..arguments.len], arguments);
        const options: std.process.RunOptions = .{ .argv = argv[0 .. 3 + arguments.len] };
        const result = try std.process.run(testing.allocator, testing.io, options);
        defer testing.allocator.free(result.stdout);
        defer testing.allocator.free(result.stderr);
        try testing.expect(result.term.success());
    }
};

/// A worktree with tracked, untracked, ignored, nested and oddly named files.
fn repository(scratch: *const Scratch) !void {
    try scratch.git(&.{ "init", "-q", "repo" });
    const ignore_file = "ign*\n*.log\nbuild/\n";
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "repo/.gitignore", .data = ignore_file });
    for ([_][]const u8{
        "repo/a",       "repo/sub/b", "repo/x.log",    "repo/ign1",        "repo/build/out",
        "repo/.hidden", "repo/-dash", "repo/nl\nname", "repo/bad\xffbyte", "repo/sub/new.log",
    }) |relative| try scratch.put(relative);
    try scratch.git(&.{ "-C", "repo", "add", ".gitignore", "a", "sub/b" });
    // Tracked files are never ignored, even when a pattern matches them.
    try scratch.git(&.{ "-C", "repo", "add", "-f", "x.log" });
    try scratch.git(&.{ "init", "-q", "repo/nested" });
    try scratch.put("repo/nested/n");
}

fn expectPaths(expected: []const []const u8, paths: *const Inventory) !void {
    var actual: std.ArrayList([]const u8) = .empty;
    defer actual.deinit(testing.allocator);
    for (0..paths.count()) |index| try actual.append(testing.allocator, paths.path(index));
    const lessThan = struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan;
    std.mem.sort([]const u8, actual.items, {}, lessThan);
    const sorted = try testing.allocator.dupe([]const u8, expected);
    defer testing.allocator.free(sorted);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    try testing.expectEqual(sorted.len, actual.items.len);
    for (sorted, actual.items) |want, have| try testing.expectEqualSlices(u8, want, have);
}

fn expectRoot(start: Start, scratch: *const Scratch, expected: []const u8, git: bool) !void {
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var root = try resolveRoot(testing.allocator, testing.io, start, &cancel);
    defer root.deinit(testing.allocator, testing.io);
    var buffer: [linux.PATH_MAX]u8 = undefined;
    const length = try scratch.dir.realPathFile(testing.io, expected, &buffer);
    try testing.expectEqualStrings(buffer[0..length], root.path);
    try testing.expectEqual(git, root.git);
    try testing.expectEqual(git, root.reason.len == 0);
}

test "root is the worktree for a file, the directory given, or a plain folder" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.put("plain/f");
    try scratch.link("../repo/sub/b", "plain/linked");
    var buffer: [256]u8 = undefined;
    try expectRoot(.{ .file = scratch.join(&buffer, "repo/sub/b") }, &scratch, "repo", true);
    try expectRoot(.{ .directory = scratch.join(&buffer, "repo/sub") }, &scratch, "repo/sub", true);
    try expectRoot(.{ .directory = scratch.join(&buffer, "repo") }, &scratch, "repo", true);
    try expectRoot(.{ .directory = scratch.join(&buffer, "plain") }, &scratch, "plain", false);
    try expectRoot(.{ .file = scratch.join(&buffer, "plain/f") }, &scratch, "plain", false);
    // A symlinked file belongs to the project it was named from.
    try expectRoot(.{ .file = scratch.join(&buffer, "plain/linked") }, &scratch, "plain", false);
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    const missing = scratch.join(&buffer, "missing");
    const result = resolveRoot(testing.allocator, testing.io, .{ .directory = missing }, &cancel);
    try testing.expectError(error.FileNotFound, result);
}

test "project listing is Git's tracked and unignored files with raw names" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var repo = try scratch.dir.openDir(testing.io, "repo", .{});
    defer repo.close(testing.io);
    var listing = try listProject(testing.allocator, testing.io, repo, true, &cancel);
    defer listing.deinit(testing.allocator);
    try testing.expect(!listing.unfiltered and !listing.partial);
    // The nested repository is not descended into, and its marker is dropped.
    const expected = [_][]const u8{
        ".gitignore", "a", "sub/b", "x.log", ".hidden", "-dash", "nl\nname", "bad\xffbyte",
    };
    try expectPaths(&expected, &listing.paths);
    // A narrowed root lists only beneath it, relative to it.
    var sub = try repo.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    var narrowed = try listProject(testing.allocator, testing.io, sub, true, &cancel);
    defer narrowed.deinit(testing.allocator);
    try expectPaths(&.{"b"}, &narrowed.paths);
}

test "a Git listing that runs out of memory frees everything it held" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var repo = try scratch.dir.openDir(testing.io, "repo", .{});
    defer repo.close(testing.io);
    const List = struct {
        // Project drops the nested repository's marker, so its bytes shrink.
        fn project(gpa: Allocator, root: Io.Dir, flag: *const Cancel) !void {
            var listing = try listProject(gpa, testing.io, root, true, flag);
            listing.deinit(gpa);
        }
        // All walks into a nested repository, which Git's listing skips.
        fn all(gpa: Allocator, root: Io.Dir, flag: *const Cancel) !void {
            var listing = try listAll(gpa, testing.io, root, true, flag);
            listing.deinit(gpa);
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, List.project, .{ repo, &cancel });
    try testing.checkAllAllocationFailures(testing.allocator, List.all, .{ repo, &cancel });
}

test "the walk lists hidden and ignored files, skips .git and never follows directory links" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    const created = [_][]const u8{
        "f",        ".hidden",  "d/g",     "d/e/h",    ".git/config", "nested/.git/HEAD",
        "nested/n", "nl\nname", "bad\xff", "locked/x",
    };
    for (created) |relative| try scratch.put(relative);
    try scratch.link("f", "link");
    try scratch.link("d", "dirlink");
    try scratch.link("missing", "dangling");
    const fifo = linux.mknodat(scratch.dir.handle, "fifo", linux.S.IFIFO | 0o600, 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(fifo));
    const privileged = linux.geteuid() == 0;
    const locked = linux.fchmodat(scratch.dir.handle, "locked", 0);
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(locked));
    defer _ = linux.fchmodat(scratch.dir.handle, "locked", 0o700);
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    const expected = [_][]const u8{
        "f", ".hidden", "d/g", "d/e/h", "nested/n", "nl\nname", "bad\xff", "link",
    };
    var all = try listAll(testing.allocator, testing.io, scratch.dir, false, &cancel);
    defer all.deinit(testing.allocator);
    if (privileged) return error.SkipZigTest;
    try expectPaths(&expected, &all.paths);
    try testing.expect(all.partial and !all.unfiltered);
    try testing.expectEqualStrings("1 unreadable directory; listing partial", all.reason);
    // Without Git, the project falls back to the same walk and says so.
    var project = try listProject(testing.allocator, testing.io, scratch.dir, false, &cancel);
    defer project.deinit(testing.allocator);
    try expectPaths(&expected, &project.paths);
    try testing.expect(project.unfiltered and project.partial);
    const why = "Not a Git worktree; listing unfiltered; 1 unreadable";
    try testing.expect(std.mem.startsWith(u8, project.reason, why));
    cancel.request();
    const canceled = listAll(testing.allocator, testing.io, scratch.dir, false, &cancel);
    try testing.expectError(error.Canceled, canceled);
}

test "All asks Git once for its ignored paths and never lists tracked ones" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.git(&.{ "init", "-q", "repo/build/inner" });
    try scratch.put("repo/build/inner/f");
    try scratch.put("repo/ignored/kept");
    try scratch.put("repo/ignored/dropped");
    try scratch.git(&.{ "-C", "repo", "add", "-f", "ignored/kept" });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var repo = try scratch.dir.openDir(testing.io, "repo", .{});
    defer repo.close(testing.io);
    var all = try listAll(testing.allocator, testing.io, repo, true, &cancel);
    defer all.deinit(testing.allocator);
    try testing.expect(!all.unfiltered);
    // Tracked files match a pattern but are not ignored, so their directory
    // is listed file by file; a wholly ignored one, nested repository and
    // all, is one entry.
    const ignored = [_][]const u8{ "build/", "ign1", "ignored/dropped", "sub/new.log" };
    try expectPaths(&ignored, &all.ignored.?);
    // The walk notes every nested repository, since Git answers for none.
    try expectPaths(&.{ "build/inner/", "nested/" }, &all.repositories);
    const why = "Ignore status unknown in 2 nested repositories";
    try testing.expectEqualStrings(why, all.ignore_reason);
    // A narrowed root gets paths relative to itself.
    var sub = try repo.openDir(testing.io, "sub", .{});
    defer sub.close(testing.io);
    var narrowed = try listAll(testing.allocator, testing.io, sub, true, &cancel);
    defer narrowed.deinit(testing.allocator);
    try expectPaths(&.{"new.log"}, &narrowed.ignored.?);
    try testing.expectEqual(@as(usize, 0), narrowed.repositories.count());
    try testing.expectEqualStrings("", narrowed.ignore_reason);
    // Without Git the status stays unknown and nothing is asked.
    var plain = try listAll(testing.allocator, testing.io, repo, false, &cancel);
    defer plain.deinit(testing.allocator);
    try testing.expect(plain.ignored == null and plain.ignore_reason.len == 0);
}

test "a submodule is a nested repository to its superproject and a root of its own" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.git(&.{ "init", "-q", "lib" });
    try scratch.dir.writeFile(testing.io, .{ .sub_path = "lib/.gitignore", .data = "junk\n" });
    try scratch.put("lib/a");
    try scratch.git(&.{ "-C", "lib", "add", "." });
    const identity = [_][]const u8{ "-c", "user.name=t", "-c", "user.email=t@t" };
    try scratch.git(&(identity ++ .{ "-C", "lib", "commit", "-qm", "lib" }));
    const file_protocol = [_][]const u8{ "-c", "protocol.file.allow=always", "-C", "repo" };
    try scratch.git(&(file_protocol ++ .{ "submodule", "add", "-q", "../lib", "lib" }));
    try scratch.put("repo/lib/junk");
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var repo = try scratch.dir.openDir(testing.io, "repo", .{});
    defer repo.close(testing.io);
    // The submodule's `.git` is a file; its own ignores are not the
    // superproject's to answer.
    var all = try listAll(testing.allocator, testing.io, repo, true, &cancel);
    defer all.deinit(testing.allocator);
    try expectPaths(&.{ "lib/", "nested/" }, &all.repositories);
    for (0..all.ignored.?.count()) |index| {
        try testing.expect(!std.mem.startsWith(u8, all.ignored.?.path(index), "lib/"));
    }
    // Rooted inside, the submodule is its own worktree and answers fully.
    var buffer: [128]u8 = undefined;
    const inside: Start = .{ .directory = scratch.join(&buffer, "repo/lib") };
    var root = try resolveRoot(testing.allocator, testing.io, inside, &cancel);
    defer root.deinit(testing.allocator, testing.io);
    try testing.expect(root.git and std.mem.endsWith(u8, root.path, "/repo/lib"));
    var own = try listAll(testing.allocator, testing.io, root.dir, true, &cancel);
    defer own.deinit(testing.allocator);
    try expectPaths(&.{"junk"}, &own.ignored.?);
    try testing.expectEqual(@as(usize, 0), own.repositories.count());
    try testing.expectEqualStrings("", own.ignore_reason);
}

test "when Git cannot list ignored paths, All says why and guesses nothing" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.put("plain/a");
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var plain = try scratch.dir.openDir(testing.io, "plain", .{});
    defer plain.close(testing.io);
    // Claiming a worktree where there is none makes Git refuse.
    var all = try listAll(testing.allocator, testing.io, plain, true, &cancel);
    defer all.deinit(testing.allocator);
    try expectPaths(&.{"a"}, &all.paths);
    try testing.expect(all.ignored == null);
    try testing.expect(std.mem.startsWith(u8, all.ignore_reason, "Ignore status unknown: "));
    try testing.expect(all.ignore_reason.len > "Ignore status unknown: ".len);
}

/// Waits for a helper's process to disappear; reparenting makes the final
/// reap asynchronous, so a zombie also counts as gone.
fn expectGone(dir: Io.Dir, pid_file: []const u8) !void {
    var buffer: [32]u8 = undefined;
    const text = try dir.readFile(testing.io, pid_file, &buffer);
    const pid = try std.fmt.parseInt(posix.pid_t, std.mem.trim(u8, text, "\n"), 10);
    var stat_path: [64]u8 = undefined;
    const proc = try std.fmt.bufPrint(&stat_path, "/proc/{d}/stat", .{pid});
    for (0..500) |_| {
        var stat: [512]u8 = undefined;
        const line = Io.Dir.cwd().readFile(testing.io, proc, &stat) catch return;
        const state = line[std.mem.lastIndexOfScalar(u8, line, ')').? + 2];
        if (state == 'Z' or state == 'X') return;
        pause(10);
    }
    return error.HelperSurvived;
}

fn pause(milliseconds: u32) void {
    const nanoseconds = @as(isize, milliseconds) * std.time.ns_per_ms;
    const duration: linux.timespec = .{ .sec = 0, .nsec = nanoseconds };
    _ = linux.nanosleep(&duration, null);
}

test "cancellation kills a helper that ignores TERM while its output is unread" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.git(&.{ "init", "-q", "." });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    const Runner = struct {
        fn run(dir: Io.Dir, flag: *const Cancel) Error!void {
            // The background process can only be stopped by the group kill.
            const alias = "alias.spin=!trap '' TERM PIPE; " ++
                "yes >/dev/null & echo $! > spin.pid; exec yes";
            const arguments = [_][]const u8{ "-c", alias, "spin" };
            const output = try runGit(testing.allocator, testing.io, dir, &arguments, flag);
            testing.allocator.free(output.stdout);
        }
    };
    var result: Error!void = {};
    const thread = try std.Thread.spawn(.{}, struct {
        fn call(dir: Io.Dir, flag: *const Cancel, out: *Error!void) void {
            out.* = Runner.run(dir, flag);
        }
    }.call, .{ scratch.dir, &cancel, &result });
    var buffer: [32]u8 = undefined;
    for (0..500) |_| {
        if (scratch.dir.readFile(testing.io, "spin.pid", &buffer)) |text| {
            if (std.mem.endsWith(u8, text, "\n")) break;
        } else |_| {}
        pause(10);
    }
    cancel.request();
    thread.join();
    try testing.expectError(error.Canceled, result);
    try expectGone(scratch.dir, "spin.pid");
}

test "Git never starts an fsmonitor daemon that would outlive the helper's group" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try repository(&scratch);
    try scratch.git(&.{ "-C", "repo", "config", "core.fsmonitor", "true" });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    var buffer: [128]u8 = undefined;
    const path = scratch.join(&buffer, "repo");
    var root = try resolveRoot(testing.allocator, testing.io, .{ .directory = path }, &cancel);
    defer root.deinit(testing.allocator, testing.io);
    var project = try listProject(testing.allocator, testing.io, root.dir, true, &cancel);
    project.deinit(testing.allocator);
    var all = try listAll(testing.allocator, testing.io, root.dir, true, &cancel);
    all.deinit(testing.allocator);
    const daemon = [_][]const u8{ "git", "-C", path, "fsmonitor--daemon" };
    const status = try std.process.run(testing.allocator, testing.io, .{ .argv = &(daemon ++ .{"status"}) });
    testing.allocator.free(status.stdout);
    testing.allocator.free(status.stderr);
    if (status.term.success()) {
        const stop = try std.process.run(testing.allocator, testing.io, .{ .argv = &(daemon ++ .{"stop"}) });
        testing.allocator.free(stop.stdout);
        testing.allocator.free(stop.stderr);
        return error.DaemonStarted;
    }
}

test "a finished helper's group is killed, so stragglers do not outlive it" {
    var scratch = try Scratch.init();
    defer scratch.deinit();
    try scratch.git(&.{ "init", "-q", "." });
    var cancel: Cancel = try .init();
    defer cancel.deinit();
    const alias = "alias.leave=!sleep 1000 </dev/null >/dev/null 2>&1 & echo $! > straggler.pid";
    const arguments = [_][]const u8{ "-c", alias, "leave" };
    const run = runGit(testing.allocator, testing.io, scratch.dir, &arguments, &cancel);
    const output = try run;
    defer testing.allocator.free(output.stdout);
    try testing.expect(output.succeeded());
    try expectGone(scratch.dir, "straggler.pid");
}

test "inventories drop empty entries and, unless asked, nested repository markers" {
    const bytes = try testing.allocator.dupe(u8, "a\x00nested/\x00\x00dir/b\x00");
    var inventory = try Inventory.fromNulTerminated(testing.allocator, bytes, false);
    defer inventory.deinit(testing.allocator);
    try expectPaths(&.{ "a", "dir/b" }, &inventory);
    try testing.expectEqualSlices(u8, "a\x00dir/b\x00", inventory.bytes);
    const kept_bytes = try testing.allocator.dupe(u8, "a\x00nested/\x00\x00dir/b\x00");
    var kept = try Inventory.fromNulTerminated(testing.allocator, kept_bytes, true);
    defer kept.deinit(testing.allocator);
    try expectPaths(&.{ "a", "nested/", "dir/b" }, &kept);
}
