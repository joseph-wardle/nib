// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const limits = @import("snapshot.zig");

pub const Error = Allocator.Error || error{
    FileNotFound,
    AccessDenied,
    PathAlreadyExists,
    NameTooLong,
    LinkLoop,
    UnsupportedFileType,
    FileTooLarge,
    TooManyLines,
    SourceChanged,
    UnstableSource,
    MultiplyLinked,
    MetadataUnavailable,
    UnsupportedFlags,
    ReadFailed,
    WriteFailed,
    SyncFailed,
    OpenFailed,
    PublishFailed,
    CleanupFailed,
    InjectedFailure,
};

/// A publication error does not imply the destination is unchanged. In
/// particular, an I/O error from rename can have an indeterminate outcome.
pub const Report = struct {
    publication: enum { none, installed, uncertain } = .none,
    durable: bool = false,
    verified: bool = false,
    failure: ?Error = null,
    cleanup_failure: bool = false,
};

/// Narrow stage hooks permit deterministic filesystem failure/race tests. No
/// hook is needed in production; callbacks may also deliver lifecycle signals.
pub const Stage = enum { loaded, created, written, metadata, synced, validated, published, directory_sync, directory_synced, verified };
pub const Options = struct {
    context: ?*anyopaque = null,
    hook: ?*const fn (?*anyopaque, Stage) Error!void = null,

    fn at(self: Options, stage: Stage) Error!void {
        if (self.hook) |hook| try hook(self.context, stage);
    }
};

/// Owns the original absolute spelling (including symlink-sensitive '..'),
/// resolved link identities, and last loaded/saved identity. Text/base/history
/// remain owned by Buffer. Release with the original allocator.
pub const Source = struct {
    path: []const u8,
    resolved: Resolved,
    version: linux.Statx,

    pub fn deinit(self: *Source, allocator: Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn load(allocator: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) Error!Document {
        return loadWith(allocator, io, dir, path, .{});
    }

    pub fn loadWith(allocator: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, options: Options) Error!Document {
        const absolute = try absolutePath(allocator, io, dir, path);
        errdefer allocator.free(absolute);
        for (0..3) |_| {
            const resolved = try resolve(absolute);
            if (resolved.version.mode & linux.S.IFMT != linux.S.IFREG) return error.UnsupportedFileType;
            const fd = try open(resolved.target(), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
            defer _ = linux.close(fd);
            const before = try statFd(fd);
            if (before.mode & linux.S.IFMT != linux.S.IFREG) return error.UnsupportedFileType;
            const bytes = try readAll(allocator, fd, before.size);
            defer allocator.free(bytes);
            try options.at(.loaded);
            const after = try statFd(fd);
            const again = try resolve(absolute);
            if (!sameVersion(before, after) or !resolved.eql(&again) or !sameVersion(after, again.version)) continue;
            return .{
                .source = .{ .path = absolute, .resolved = resolved, .version = after },
                .buffer = try Buffer.fromBytes(allocator, bytes),
            };
        }
        return error.UnstableSource;
    }

    /// Checks actual base bytes, identity and metadata, independently of watches.
    pub fn validate(self: *const Source, base: []const u8) Error!void {
        const current = try resolve(self.path);
        if (!self.resolved.eql(&current) or !sameVersion(self.version, current.version)) return error.SourceChanged;
        const fd = try open(current.target(), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
        defer _ = linux.close(fd);
        try verifyBytes(fd, self.version, base);
    }

    pub fn save(self: *Source, allocator: Allocator, buffer: *Buffer, options: Options) Report {
        return write(allocator, buffer, self, self.resolved.target(), options);
    }
};

pub const Document = struct {
    source: Source,
    buffer: Buffer,

    pub fn deinit(self: *Document, allocator: Allocator) void {
        self.buffer.deinit(allocator);
        self.source.deinit(allocator);
        self.* = undefined;
    }
};

/// A private (0600) copy: atomic no-clobber, no source association/clean change.
pub fn copy(allocator: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, buffer: *Buffer, options: Options) Report {
    if (std.mem.endsWith(u8, path, "/")) return .{ .failure = error.UnsupportedFileType };
    const absolute = absolutePath(allocator, io, dir, path) catch |err| return .{ .failure = err };
    defer allocator.free(absolute);
    return write(allocator, buffer, null, absolute, options);
}

fn write(allocator: Allocator, buffer: *Buffer, source: ?*Source, destination: []const u8, options: Options) Report {
    var report: Report = .{};
    publish(allocator, buffer, source, destination, options, &report) catch |err| {
        report.failure = err;
    };
    return report;
}

fn publish(allocator: Allocator, buffer: *Buffer, source: ?*Source, destination: []const u8, options: Options, report: *Report) Error!void {
    // No accounting allocation may fail after publication.
    var prepared: ?[]u8 = if (source != null) try allocator.dupe(u8, buffer.bytes()) else null;
    defer if (prepared) |base| allocator.free(base);
    if (source) |original| try original.validate(buffer.base);
    const parent_path = std.fs.path.dirname(destination) orelse return error.OpenFailed;
    const basename = std.fs.path.basename(destination);
    const parent = try open(parent_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true });
    defer if (posix.errno(linux.close(parent)) != .SUCCESS) {
        report.cleanup_failure = true;
    };
    const parent_version = try statFd(parent);
    var metadata: ?Metadata = null;
    defer if (metadata) |*attributes| attributes.deinit(allocator);
    if (source) |original| {
        const fd = try open(original.resolved.target(), .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
        defer _ = linux.close(fd);
        const version = try statFd(fd);
        if (!sameVersion(version, original.version)) return error.SourceChanged;
        if (version.nlink != 1) return error.MultiplyLinked;
        try writable(fd);
        metadata = try Metadata.read(allocator, fd, version);
        if (!sameVersion(version, try statFd(fd))) return error.SourceChanged;
    }
    var name: [64]u8 = undefined;
    const temporary = try createTemporary(parent, &name);
    defer if (posix.errno(linux.close(temporary.fd)) != .SUCCESS) {
        report.cleanup_failure = true;
    };
    var exists = true;
    defer if (exists) {
        const err = posix.errno(linux.unlinkat(parent, temporary.name, 0));
        if (err != .SUCCESS and err != .NOENT) report.cleanup_failure = true;
    };
    try options.at(.created);
    if (metadata) |*attributes| try attributes.prepareFlags(temporary.fd);
    try writeAll(temporary.fd, buffer.bytes());
    try options.at(.written);
    if (metadata) |*attributes| {
        try attributes.apply(allocator, temporary.fd);
    } else {
        // Copies have a deliberate private mode, independent of an unusual
        // umask. Strip inherited ACLs as well, rather than retaining extra rules.
        const result = linux.fremovexattr(temporary.fd, "system.posix_acl_access");
        switch (posix.errno(result)) {
            .SUCCESS, .NODATA, .OPNOTSUPP => {},
            else => return error.MetadataUnavailable,
        }
        _ = try checked(linux.fchmod(temporary.fd, 0o600), error.MetadataUnavailable);
    }
    try options.at(.metadata);
    try sync(temporary.fd);
    try options.at(.synced);
    if (source) |original| {
        try original.validate(buffer.base);
        const fd = try open(original.resolved.target(), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
        defer _ = linux.close(fd);
        try writable(fd);
        if (!sameVersion(original.version, try statFd(fd))) return error.SourceChanged;
    }
    // Pinning the parent avoids redirecting the rename through changed parents;
    // also ensure the current spelling still names that directory.
    const parent_now = try statPath(parent_path, false);
    if (!sameIdentity(parent_version, parent_now)) return error.SourceChanged;
    try options.at(.validated);
    const dest_z = try terminated(basename);
    const result = linux.renameat2(parent, temporary.name, parent, dest_z.slice(), .{ .NOREPLACE = source == null });
    switch (posix.errno(result)) {
        .SUCCESS => {},
        .EXIST => return error.PathAlreadyExists,
        else => |err| {
            if (err == .IO or err == .INTR) report.publication = .uncertain;
            return mapError(err, error.PublishFailed);
        },
    }
    exists = false;
    report.publication = .installed;
    // Retain the descriptor through publication; accounting must identify our
    // installed inode rather than accepting an independent writer's replacement.
    const installed = try statFd(temporary.fd);
    var post_error: ?Error = null;
    options.at(.published) catch |err| {
        post_error = err;
    };
    if (syncDirectory(parent, options)) |_| {
        report.durable = true;
    } else |err| {
        if (post_error == null) post_error = err;
    }
    options.at(.directory_synced) catch |err| {
        if (post_error == null) post_error = err;
    };
    // Postpublication errors never pass through ordinary prepublication cleanup.
    verifyInstalled(source, destination, installed, buffer.bytes()) catch |err| {
        return post_error orelse err;
    };
    report.verified = true;
    if (source) |original| {
        original.version = installed;
        original.resolved.version = installed;
        buffer.acceptSaved(allocator, prepared.?);
        prepared = null;
    }
    try options.at(.verified);
    if (post_error) |err| return err;
}

fn verifyInstalled(source: ?*Source, destination: []const u8, installed: linux.Statx, bytes: []const u8) Error!void {
    if (source) |original| {
        const current = try resolve(original.path);
        if (!original.resolved.eql(&current) or !sameVersion(installed, current.version)) return error.SourceChanged;
    } else if (!sameVersion(installed, try statPath(destination, true))) return error.SourceChanged;
    const fd = try open(destination, .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true });
    defer _ = linux.close(fd);
    try verifyBytes(fd, installed, bytes);
}

const required: linux.STATX = .{ .TYPE = true, .MODE = true, .NLINK = true, .UID = true, .GID = true, .MTIME = true, .CTIME = true, .INO = true, .SIZE = true };

fn statAt(dir: posix.fd_t, path: [*:0]const u8, flags: u32) Error!linux.Statx {
    var result: linux.Statx = undefined;
    _ = try checked(linux.statx(dir, path, flags, required, &result), error.ReadFailed);
    const mask: u32 = @bitCast(required);
    if (@as(u32, @bitCast(result.mask)) & mask != mask) return error.MetadataUnavailable;
    return result;
}
fn statFd(fd: posix.fd_t) Error!linux.Statx {
    return statAt(fd, "", linux.AT.EMPTY_PATH);
}
fn statPath(path: []const u8, nofollow: bool) Error!linux.Statx {
    const z = try terminated(path);
    return statAt(linux.AT.FDCWD, z.slice(), if (nofollow) linux.AT.SYMLINK_NOFOLLOW else 0);
}
fn sameIdentity(a: linux.Statx, b: linux.Statx) bool {
    return a.ino == b.ino and a.dev_major == b.dev_major and a.dev_minor == b.dev_minor;
}
fn sameVersion(a: linux.Statx, b: linux.Statx) bool {
    return sameIdentity(a, b) and a.mode == b.mode and a.uid == b.uid and a.gid == b.gid and a.nlink == b.nlink and a.size == b.size and
        a.mtime.sec == b.mtime.sec and a.mtime.nsec == b.mtime.nsec and a.ctime.sec == b.ctime.sec and a.ctime.nsec == b.ctime.nsec and
        @as(u64, @bitCast(a.attributes)) == @as(u64, @bitCast(b.attributes));
}

const Path = struct {
    bytes: [4096:0]u8 = undefined,
    len: usize = 0,
    fn slice(self: *const Path) [:0]const u8 {
        return self.bytes[0..self.len :0];
    }
};
fn terminated(path: []const u8) Error!Path {
    if (path.len >= 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return error.NameTooLong;
    var result: Path = .{ .len = path.len };
    @memcpy(result.bytes[0..path.len], path);
    result.bytes[path.len] = 0;
    return result;
}
const Resolved = struct {
    path: Path,
    links: [40]linux.Statx = undefined,
    link_count: usize = 0,
    version: linux.Statx,
    fn target(self: *const Resolved) []const u8 {
        return self.path.bytes[0..self.path.len];
    }
    // Target identity is checked separately, since successful saving replaces it.
    fn eql(self: *const Resolved, other: *const Resolved) bool {
        if (!std.mem.eql(u8, self.target(), other.target()) or self.link_count != other.link_count) return false;
        for (self.links[0..self.link_count], other.links[0..other.link_count]) |a, b| if (!sameVersion(a, b)) return false;
        return true;
    }
};

/// Resolve one component at a time so directory symlinks and '..' retain Linux
/// meaning. Re-resolution detects link-chain replacement as well as retargeting.
fn resolve(path: []const u8) Error!Resolved {
    var pending = try terminated(path);
    var result: Resolved = .{ .path = try terminated("/"), .version = undefined };
    var offset: usize = 0;
    while (offset < pending.len) {
        while (offset < pending.len and pending.bytes[offset] == '/') offset += 1;
        if (offset == pending.len) break;
        const start = offset;
        while (offset < pending.len and pending.bytes[offset] != '/') offset += 1;
        const component = pending.bytes[start..offset];
        if (std.mem.eql(u8, component, ".")) continue;
        if (std.mem.eql(u8, component, "..")) {
            result.path = try terminated(std.fs.path.dirname(result.target()) orelse "/");
            continue;
        }
        const parent_len = result.path.len;
        if (parent_len != 1) {
            if (result.path.len + 1 >= 4096) return error.NameTooLong;
            result.path.bytes[result.path.len] = '/';
            result.path.len += 1;
        }
        if (result.path.len + component.len >= 4096) return error.NameTooLong;
        @memcpy(result.path.bytes[result.path.len..][0..component.len], component);
        result.path.len += component.len;
        result.path.bytes[result.path.len] = 0;
        const version = try statPath(result.target(), true);
        if (version.mode & linux.S.IFMT == linux.S.IFLNK) {
            if (result.link_count == result.links.len) return error.LinkLoop;
            result.links[result.link_count] = version;
            result.link_count += 1;
            var link: [4096]u8 = undefined;
            const length = try checked(linux.readlinkat(linux.AT.FDCWD, result.path.slice(), &link, link.len), error.ReadFailed);
            if (length == link.len) return error.NameTooLong;
            var next: [4096]u8 = undefined;
            const rest = pending.bytes[offset..pending.len];
            if (length + rest.len >= next.len) return error.NameTooLong;
            @memcpy(next[0..length], link[0..length]);
            @memcpy(next[length..][0..rest.len], rest);
            pending = try terminated(next[0 .. length + rest.len]);
            result.path = try terminated(if (length != 0 and link[0] == '/') "/" else result.path.bytes[0..parent_len]);
            offset = 0;
        } else if (offset < pending.len and version.mode & linux.S.IFMT != linux.S.IFDIR) return error.UnsupportedFileType;
    }
    result.version = try statPath(result.target(), true);
    return result;
}

fn absolutePath(allocator: Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) Error![]const u8 {
    if (path.len == 0) return error.FileNotFound;
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    var root: [4096]u8 = undefined;
    const length = dir.realPath(io, &root) catch return error.OpenFailed;
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ root[0..length], path });
}
fn open(path: []const u8, flags: linux.O) Error!posix.fd_t {
    const z = try terminated(path);
    return @intCast(try checked(linux.openat(linux.AT.FDCWD, z.slice(), flags, 0), error.OpenFailed));
}
fn checked(result: usize, fallback: Error) Error!usize {
    const err = posix.errno(result);
    if (err == .SUCCESS) return result;
    return mapError(err, fallback);
}
fn mapError(err: posix.E, fallback: Error) Error {
    return switch (err) {
        .NOENT => error.FileNotFound,
        .ACCES, .PERM, .ROFS => error.AccessDenied,
        .EXIST => error.PathAlreadyExists,
        .NAMETOOLONG => error.NameTooLong,
        .LOOP => error.LinkLoop,
        .ISDIR, .NOTDIR, .NODEV => error.UnsupportedFileType,
        else => fallback,
    };
}
fn writable(fd: posix.fd_t) Error!void {
    // AT_EACCESS is not named by Zig's Linux constants. Evaluate effective IDs
    // and ACLs against the verified inode, never a truncating probe open.
    _ = try checked(linux.faccessat(fd, "", 2, linux.AT.EMPTY_PATH | 0x200), error.AccessDenied);
}
fn sync(fd: posix.fd_t) Error!void {
    _ = try checked(linux.fsync(fd), error.SyncFailed);
}
fn syncDirectory(fd: posix.fd_t, options: Options) Error!void {
    try options.at(.directory_sync);
    try sync(fd);
}
fn readAll(allocator: Allocator, fd: posix.fd_t, size: u64) Error![]u8 {
    if (size > limits.max_file_bytes) return error.FileTooLarge;
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var chunk: [16384]u8 = undefined;
    while (true) {
        const result = linux.read(fd, &chunk, chunk.len);
        if (posix.errno(result) == .INTR) continue;
        const count = try checked(result, error.ReadFailed);
        if (count == 0) break;
        if (count > limits.max_file_bytes - bytes.items.len) return error.FileTooLarge;
        try bytes.appendSlice(allocator, chunk[0..count]);
    }
    return bytes.toOwnedSlice(allocator);
}
fn verifyBytes(fd: posix.fd_t, version: linux.Statx, bytes: []const u8) Error!void {
    if (!sameVersion(version, try statFd(fd))) return error.SourceChanged;
    var chunk: [16384]u8 = undefined;
    var offset: usize = 0;
    while (true) {
        const result = linux.pread(fd, &chunk, chunk.len, @intCast(offset));
        if (posix.errno(result) == .INTR) continue;
        const count = try checked(result, error.ReadFailed);
        if (count == 0) break;
        if (count > bytes.len - offset or !std.mem.eql(u8, chunk[0..count], bytes[offset..][0..count])) return error.SourceChanged;
        offset += count;
    }
    if (offset != bytes.len or !sameVersion(version, try statFd(fd))) return error.SourceChanged;
}
fn writeAll(fd: posix.fd_t, bytes: []const u8) Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (posix.errno(result) == .INTR) continue;
        const count = try checked(result, error.WriteFailed);
        if (count == 0) return error.WriteFailed;
        offset += count;
    }
}
fn createTemporary(parent: posix.fd_t, storage: *[64]u8) Error!struct { fd: posix.fd_t, name: [:0]const u8 } {
    for (0..16) |_| {
        var random: [16]u8 = undefined;
        var count: usize = 0;
        while (count < random.len) {
            const result = linux.getrandom(random[count..].ptr, random.len - count, 0);
            if (posix.errno(result) == .INTR) continue;
            const read = try checked(result, error.OpenFailed);
            if (read == 0) return error.OpenFailed;
            count += read;
        }
        const name = std.fmt.bufPrintSentinel(storage, ".nib-{x}", .{random}, 0) catch unreachable;
        const result = linux.openat(parent, name, .{ .ACCMODE = .RDWR, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
        if (posix.errno(result) == .EXIST) continue;
        return .{ .fd = @intCast(try checked(result, error.OpenFailed)), .name = name };
    }
    return error.OpenFailed;
}

const Attribute = struct { name: [:0]u8, value: []u8 };
const Metadata = struct {
    version: linux.Statx,
    flags: ?u32,
    attributes: std.ArrayList(Attribute) = .empty,

    fn deinit(self: *Metadata, allocator: Allocator) void {
        for (self.attributes.items) |attribute| {
            allocator.free(attribute.name);
            allocator.free(attribute.value);
        }
        self.attributes.deinit(allocator);
    }
    fn read(allocator: Allocator, fd: posix.fd_t, version: linux.Statx) Error!Metadata {
        var result: Metadata = .{ .version = version, .flags = try inodeFlags(fd) };
        errdefer result.deinit(allocator);
        // Linux limits the complete name list and each value to 64 KiB. Treat
        // enumeration failure as refusal, never as an empty attribute set.
        var names: [65536]u8 = undefined;
        const count = try checked(linux.flistxattr(fd, &names, names.len), error.MetadataUnavailable);
        var iterator = std.mem.splitScalar(u8, names[0..count], 0);
        while (iterator.next()) |name| {
            if (name.len == 0) continue;
            const owned_name = try allocator.dupeSentinel(u8, name, 0);
            errdefer allocator.free(owned_name);
            var storage: [65536]u8 = undefined;
            const length = try checked(linux.fgetxattr(fd, owned_name, &storage, storage.len), error.MetadataUnavailable);
            const value = try allocator.dupe(u8, storage[0..length]);
            errdefer allocator.free(value);
            try result.attributes.append(allocator, .{ .name = owned_name, .value = value });
        }
        return result;
    }
    fn prepareFlags(self: *const Metadata, fd: posix.fd_t) Error!void {
        // Use the Linux UAPI values: Zig 0.17's STATX_ATTR packed field layout
        // misplaces several bits (for example NODUMP appears as APPEND).
        const unsupported_attributes: u64 = 0x10 | 0x20 | 0x800 | 0x100000 | 0x200000;
        if (@as(u64, @bitCast(self.version.attributes)) & unsupported_attributes != 0)
            return error.UnsupportedFlags;
        // Ignore only filesystem-managed storage representation (extent/huge
        // file/inline data). Every unknown policy flag is a refusal.
        const representation: u32 = 0x00080000 | 0x00040000 | 0x10000000;
        const supported: u32 = 0x4 | 0x8 | 0x40 | 0x80 | 0x400 | 0x8000 | 0x800000;
        if (self.flags) |flags| {
            if (flags & ~(representation | supported) != 0) return error.UnsupportedFlags;
            var desired = flags & supported;
            const existing = try inodeFlags(fd) orelse return error.MetadataUnavailable;
            if (existing & ~representation != desired) {
                _ = try checked(linux.ioctl(fd, linux.IOCTL.IOW('f', 2, c_long), @intFromPtr(&desired)), error.MetadataUnavailable);
            }
        } else if (try inodeFlags(fd) != null) return error.MetadataUnavailable;
    }
    fn apply(self: *const Metadata, allocator: Allocator, fd: posix.fd_t) Error!void {
        var current = try statFd(fd);
        if (current.uid != self.version.uid or current.gid != self.version.gid)
            _ = try checked(linux.fchown(fd, self.version.uid, self.version.gid), error.MetadataUnavailable);
        _ = try checked(linux.fchmod(fd, self.version.mode & 0o7777), error.MetadataUnavailable);
        // Remove inherited attributes absent from the source. Refuse when the
        // filesystem/security policy does not allow an exact observable match.
        var inherited = try Metadata.read(allocator, fd, try statFd(fd));
        defer inherited.deinit(allocator);
        for (inherited.attributes.items) |attribute| {
            if (self.find(attribute.name) == null)
                _ = try checked(linux.fremovexattr(fd, attribute.name), error.MetadataUnavailable);
        }
        for (self.attributes.items) |attribute|
            _ = try checked(linux.fsetxattr(fd, attribute.name, attribute.value.ptr, attribute.value.len, 0), error.MetadataUnavailable);
        current = try statFd(fd);
        if (current.mode != self.version.mode or current.uid != self.version.uid or current.gid != self.version.gid) return error.MetadataUnavailable;
        var verified = try Metadata.read(allocator, fd, current);
        defer verified.deinit(allocator);
        if (!self.eql(&verified)) return error.MetadataUnavailable;
    }
    fn find(self: *const Metadata, name: []const u8) ?[]const u8 {
        for (self.attributes.items) |attribute| if (std.mem.eql(u8, attribute.name, name)) return attribute.value;
        return null;
    }
    fn eql(self: *const Metadata, other: *const Metadata) bool {
        const representation: u32 = 0x00080000 | 0x00040000 | 0x10000000;
        if ((self.flags == null) != (other.flags == null)) return false;
        if (self.flags) |flags| if (flags & ~representation != other.flags.? & ~representation) return false;
        if (self.attributes.items.len != other.attributes.items.len) return false;
        for (self.attributes.items) |attribute| {
            const value = other.find(attribute.name) orelse return false;
            if (!std.mem.eql(u8, attribute.value, value)) return false;
        }
        return true;
    }
};
fn inodeFlags(fd: posix.fd_t) Error!?u32 {
    var flags: u32 = undefined;
    const result = linux.ioctl(fd, linux.IOCTL.IOR('f', 1, c_long), @intFromPtr(&flags));
    return switch (posix.errno(result)) {
        .SUCCESS => flags,
        .NOTTY, .OPNOTSUPP => null,
        else => error.MetadataUnavailable,
    };
}

const testing = std.testing;
fn fixture(dir: std.Io.Dir, content: []const u8) !Document {
    try dir.writeFile(testing.io, .{ .sub_path = "source", .data = content });
    return Source.load(testing.allocator, testing.io, dir, "source");
}
fn expectDisk(dir: std.Io.Dir, path: []const u8, expected: []const u8) !void {
    var storage: [4096]u8 = undefined;
    try testing.expectEqualStrings(expected, try dir.readFile(testing.io, path, &storage));
}
fn edit(buffer: *Buffer) !void {
    try buffer.replace(testing.allocator, .{ .start = 0, .end = 0 }, "new\n", 0);
}
fn expectNoTemporary(dir: std.Io.Dir) !void {
    var iterator = dir.iterate();
    while (try iterator.next(testing.io)) |entry| try testing.expect(!std.mem.startsWith(u8, entry.name, ".nib-"));
}

test "saved base, mixed bytes, repeated saves, and undo/redo retain history" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var document = try fixture(temp.dir, "one\r\ntwo\nlast");
    defer document.deinit(testing.allocator);
    try edit(&document.buffer);
    const result = document.source.save(testing.allocator, &document.buffer, .{});
    try testing.expectEqual(@as(?Error, null), result.failure);
    try testing.expect(result.publication == .installed and result.durable and result.verified);
    try testing.expect(!document.buffer.modified());
    try expectDisk(temp.dir, "source", "new\none\r\ntwo\nlast");
    try document.source.validate(document.buffer.base);
    try testing.expect(try document.buffer.undo(testing.allocator));
    try testing.expect(document.buffer.modified());
    try testing.expect(try document.buffer.redo(testing.allocator));
    try testing.expect(!document.buffer.modified());
    try testing.expectEqual(@as(?Error, null), document.source.save(testing.allocator, &document.buffer, .{}).failure);
    try expectNoTemporary(temp.dir);
    var reopened = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer reopened.deinit(testing.allocator);
    try testing.expectEqualStrings(document.buffer.bytes(), reopened.buffer.bytes());
}

test "stable loading retries changing reads and refuses continuously unstable input" {
    const Mutator = struct {
        dir: std.Io.Dir,
        count: usize = 0,
        continuous: bool,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage != .loaded) return;
            self.count += 1;
            if (self.continuous or self.count == 1) {
                const fd = try openSource(self.dir);
                defer _ = linux.close(fd);
                try writeAll(fd, if (self.count % 2 == 1) "after!" else "before");
            }
        }
    };
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "before" });
    var mutation: Mutator = .{ .dir = temp.dir, .continuous = false };
    var doc = try Source.loadWith(testing.allocator, testing.io, temp.dir, "source", .{ .context = &mutation, .hook = Mutator.hook });
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("after!", doc.buffer.bytes());
    try testing.expectEqual(@as(usize, 2), mutation.count);
    mutation.continuous = true;
    mutation.count = 0;
    try testing.expectError(error.UnstableSource, Source.loadWith(testing.allocator, testing.io, temp.dir, "source", .{ .context = &mutation, .hook = Mutator.hook }));
    try testing.expectEqual(@as(usize, 3), mutation.count);
    // A failed replacement load never takes ownership of the old document.
    try testing.expectEqualStrings("after!", doc.buffer.bytes());
}
fn openSource(dir: std.Io.Dir) Error!posix.fd_t {
    return @intCast(try checked(linux.openat(dir.handle, "source", .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0), error.OpenFailed));
}

test "source changes, replacement, deletion, and actual same-identity content comparison" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var doc = try fixture(temp.dir, "before");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "after!" });
    try testing.expectEqual(error.SourceChanged, doc.source.save(testing.allocator, &doc.buffer, .{}).failure.?);
    // Even when the stored stat matches, content must still match the base.
    doc.source.version = try statPath(doc.source.resolved.target(), true);
    try testing.expectError(error.SourceChanged, doc.source.validate(doc.buffer.base));
    try temp.dir.writeFile(testing.io, .{ .sub_path = "replacement", .data = "before" });
    try temp.dir.rename("replacement", temp.dir, "source", testing.io);
    try testing.expectError(error.SourceChanged, doc.source.validate(doc.buffer.base));
    try temp.dir.deleteFile(testing.io, "source");
    try testing.expectEqual(error.FileNotFound, doc.source.save(testing.allocator, &doc.buffer, .{}).failure.?);
    try testing.expect(doc.buffer.modified());
    try testing.expectEqualStrings("before", doc.buffer.base);
    try testing.expectEqualStrings("new\nbefore", doc.buffer.bytes());
}

test "symlink chains, directory symlinks and dotdot preserve Linux path meaning" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDir(testing.io, "nested", .default_dir);
    try temp.dir.createDir(testing.io, "nested/deeper", .default_dir);
    try temp.dir.writeFile(testing.io, .{ .sub_path = "nested/source", .data = "target" });
    try temp.dir.symLink(testing.io, "nested/deeper", "directory", .{});
    try temp.dir.symLink(testing.io, "directory/../source", "link", .{});
    try temp.dir.symLink(testing.io, "link", "outer", .{});
    var doc = try Source.load(testing.allocator, testing.io, temp.dir, "outer");
    defer doc.deinit(testing.allocator);
    try testing.expectEqualStrings("target", doc.buffer.bytes());
    try edit(&doc.buffer);
    const result = doc.source.save(testing.allocator, &doc.buffer, .{});
    try testing.expectEqual(@as(?Error, null), result.failure);
    try expectDisk(temp.dir, "nested/source", "new\ntarget");
    var link: [128]u8 = undefined;
    const link_length = try temp.dir.readLink(testing.io, "outer", &link);
    try testing.expectEqualStrings("link", link[0..link_length]);
    try temp.dir.deleteFile(testing.io, "link");
    try temp.dir.symLink(testing.io, "nested/source", "link", .{});
    try testing.expectEqual(error.SourceChanged, doc.source.save(testing.allocator, &doc.buffer, .{}).failure.?);
}

test "hard links refuse ordinary saving but allow private write-copy" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    _ = try checked(linux.linkat(temp.dir.handle, "source", temp.dir.handle, "alias", 0), error.OpenFailed);
    // Load after creation so refusal is about link policy rather than divergence.
    var linked = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer linked.deinit(testing.allocator);
    try edit(&linked.buffer);
    try testing.expectEqual(error.MultiplyLinked, linked.source.save(testing.allocator, &linked.buffer, .{}).failure.?);
    const result = copy(testing.allocator, testing.io, temp.dir, "copy", &linked.buffer, .{});
    try testing.expectEqual(@as(?Error, null), result.failure);
    try testing.expect(result.verified and result.durable);
    try testing.expect(linked.buffer.modified());
    try testing.expectEqualStrings("original", linked.buffer.base);
    try expectDisk(temp.dir, "alias", "original");
    try expectDisk(temp.dir, "copy", "new\noriginal");
    var storage: [4096]u8 = undefined;
    const length = try temp.dir.realPath(testing.io, &storage);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/copy", .{storage[0..length]});
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(u16, 0o600), (try statPath(path, true)).mode & 0o7777);
}

test "write protection changed after loading is respected without chmod bypass" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    const fd = try openSource(temp.dir);
    defer _ = linux.close(fd);
    _ = try checked(linux.fchmod(fd, 0o444), error.MetadataUnavailable);
    var protected = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer protected.deinit(testing.allocator);
    try edit(&protected.buffer);
    try testing.expectEqual(error.AccessDenied, protected.source.save(testing.allocator, &protected.buffer, .{}).failure.?);
    try testing.expectEqual(error.SourceChanged, doc.source.save(testing.allocator, &doc.buffer, .{}).failure.?);
    try expectDisk(temp.dir, "source", "original");
    try testing.expectEqual(@as(u16, 0o444), (try statFd(fd)).mode & 0o7777);
    try testing.expect(protected.buffer.modified());
}

test "mode ownership ACL and binary user attributes survive replacement" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var original = try fixture(temp.dir, "original");
    defer original.deinit(testing.allocator);
    const fd = try openSource(temp.dir);
    defer _ = linux.close(fd);
    _ = try checked(linux.fchmod(fd, 0o6750), error.MetadataUnavailable);
    _ = try checked(linux.fsetxattr(fd, "user.nib.test", "\x00\xffvalue", 7, 0), error.MetadataUnavailable);
    // Linux POSIX ACL binary format, explicitly little endian on every host.
    var acl: [44]u8 = undefined;
    const words = [_]u32{ 2, 0x00070001, 0xffffffff, 0x00040002, 65534, 0x00000004, 0xffffffff, 0x00050010, 0xffffffff, 0x00000020, 0xffffffff };
    for (words, 0..) |word, i| std.mem.writeInt(u32, acl[i * 4 ..][0..4], word, .little);
    _ = try checked(linux.fsetxattr(fd, "system.posix_acl_access", &acl, acl.len, 0), error.MetadataUnavailable);
    const before = try statFd(fd);
    var doc = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    try testing.expectEqual(@as(?Error, null), doc.source.save(testing.allocator, &doc.buffer, .{}).failure);
    const saved = try open(doc.source.resolved.target(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = linux.close(saved);
    const after = try statFd(saved);
    try testing.expectEqual(before.mode, after.mode);
    try testing.expectEqual(before.uid, after.uid);
    try testing.expectEqual(before.gid, after.gid);
    try testing.expect(!sameIdentity(before, after));
    var storage: [128]u8 = undefined;
    var count = try checked(linux.fgetxattr(saved, "user.nib.test", &storage, storage.len), error.MetadataUnavailable);
    try testing.expectEqualSlices(u8, "\x00\xffvalue", storage[0..count]);
    count = try checked(linux.fgetxattr(saved, "system.posix_acl_access", &storage, storage.len), error.MetadataUnavailable);
    try testing.expectEqualSlices(u8, &acl, storage[0..count]);
}

const Failure = struct {
    stage: Stage,
    fn hook(context: ?*anyopaque, stage: Stage) Error!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (stage == self.stage) return error.InjectedFailure;
    }
};
test "prepublication failures retain source base cursor history and remove temporary" {
    for ([_]Stage{ .created, .written, .metadata, .synced, .validated }) |stage| {
        var temp = testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        var doc = try fixture(temp.dir, "original");
        defer doc.deinit(testing.allocator);
        try edit(&doc.buffer);
        var failure: Failure = .{ .stage = stage };
        const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &failure, .hook = Failure.hook });
        try testing.expectEqual(error.InjectedFailure, result.failure.?);
        try testing.expect(result.publication == .none and !result.verified);
        try expectDisk(temp.dir, "source", "original");
        try testing.expectEqualStrings("original", doc.buffer.base);
        try testing.expect(doc.buffer.modified());
        try testing.expectEqual(@as(usize, 0), doc.buffer.cursor);
        try testing.expectEqual(@as(usize, 1), doc.buffer.history.items.len);
        try testing.expect(try doc.buffer.undo(testing.allocator));
        try testing.expectEqualStrings("original", doc.buffer.bytes());
        try expectNoTemporary(temp.dir);
    }
}

test "postpublication failure reports installed text and updates verified save accounting" {
    for ([_]Stage{ .published, .directory_sync, .directory_synced, .verified }) |stage| {
        var temp = testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        var doc = try fixture(temp.dir, "original");
        defer doc.deinit(testing.allocator);
        try edit(&doc.buffer);
        var failure: Failure = .{ .stage = stage };
        const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &failure, .hook = Failure.hook });
        try testing.expectEqual(error.InjectedFailure, result.failure.?);
        try testing.expect(result.publication == .installed and result.verified);
        try testing.expectEqual(stage != .directory_sync, result.durable);
        try testing.expect(!doc.buffer.modified());
        try testing.expectEqualStrings("new\noriginal", doc.buffer.base);
        try expectDisk(temp.dir, "source", "new\noriginal");
        try doc.source.validate(doc.buffer.base);
        try testing.expect(try doc.buffer.undo(testing.allocator));
        try testing.expect(doc.buffer.modified());
        try expectNoTemporary(temp.dir);
    }
}

test "external writes before final validation refuse and postpublication writes stay dirty" {
    const Writer = struct {
        dir: std.Io.Dir,
        stage: Stage,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage != self.stage) return;
            const fd = try openSource(self.dir);
            defer _ = linux.close(fd);
            try writeAll(fd, "external");
        }
    };
    for ([_]Stage{ .synced, .published }) |stage| {
        var temp = testing.tmpDir(.{ .iterate = true });
        defer temp.cleanup();
        var doc = try fixture(temp.dir, "original");
        defer doc.deinit(testing.allocator);
        try edit(&doc.buffer);
        var writer: Writer = .{ .dir = temp.dir, .stage = stage };
        const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &writer, .hook = Writer.hook });
        try testing.expectEqual(error.SourceChanged, result.failure.?);
        try testing.expectEqual(stage == .published, result.publication == .installed);
        try testing.expect(!result.verified and doc.buffer.modified());
        try testing.expectEqualStrings("original", doc.buffer.base);
        try testing.expectEqualStrings("new\noriginal", doc.buffer.bytes());
        try expectNoTemporary(temp.dir);
    }
}

test "copy never clobbers a file symlink or a destination racing publication" {
    const Racer = struct {
        dir: std.Io.Dir,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage == .validated) {
                const fd: posix.fd_t = @intCast(try checked(linux.openat(self.dir.handle, "racing", .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600), error.OpenFailed));
                defer _ = linux.close(fd);
                try writeAll(fd, "winner");
            }
        }
    };
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    try temp.dir.symLink(testing.io, "absent", "dangling", .{});
    try temp.dir.symLink(testing.io, "source", "link", .{});
    for ([_][]const u8{ "source", "dangling", "link" }) |path| {
        const result = copy(testing.allocator, testing.io, temp.dir, path, &doc.buffer, .{});
        try testing.expectEqual(error.PathAlreadyExists, result.failure.?);
        try testing.expect(result.publication == .none);
    }
    var racer: Racer = .{ .dir = temp.dir };
    const result = copy(testing.allocator, testing.io, temp.dir, "racing", &doc.buffer, .{ .context = &racer, .hook = Racer.hook });
    try testing.expectEqual(error.PathAlreadyExists, result.failure.?);
    try expectDisk(temp.dir, "racing", "winner");
    try expectDisk(temp.dir, "source", "original");
    try testing.expectEqualStrings("original", doc.buffer.base);
    try testing.expect(doc.buffer.modified());
    try expectNoTemporary(temp.dir);
}

test "stable loader rejects devices pipes and missing files without blocking" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    try testing.expectError(error.UnsupportedFileType, Source.load(testing.allocator, testing.io, temp.dir, "."));
    try testing.expectError(error.UnsupportedFileType, Source.load(testing.allocator, testing.io, temp.dir, "/dev/null"));
    try testing.expectError(error.FileNotFound, Source.load(testing.allocator, testing.io, temp.dir, "missing"));
    _ = try checked(linux.mknodat(temp.dir.handle, "pipe", linux.S.IFIFO | 0o600, 0), error.OpenFailed);
    try testing.expectError(error.UnsupportedFileType, Source.load(testing.allocator, testing.io, temp.dir, "pipe"));
    try temp.dir.symLink(testing.io, "loop", "loop", .{});
    try testing.expectError(error.LinkLoop, Source.load(testing.allocator, testing.io, temp.dir, "loop"));
}

test "allocation failures in load and save retain resources and original text" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "original" });
    try testing.checkAllAllocationFailures(testing.allocator, allocationLoad, .{temp.dir});
    try testing.checkAllAllocationFailures(testing.allocator, allocationSave, .{temp.dir});
}
fn allocationLoad(allocator: Allocator, dir: std.Io.Dir) !void {
    var doc = try Source.load(allocator, testing.io, dir, "source");
    defer doc.deinit(allocator);
}
fn allocationSave(allocator: Allocator, dir: std.Io.Dir) !void {
    try dir.writeFile(testing.io, .{ .sub_path = "source", .data = "original" });
    const fd = try openSource(dir);
    defer _ = linux.close(fd);
    _ = try checked(linux.fsetxattr(fd, "user.nib.test", "value", 5, 0), error.MetadataUnavailable);
    var doc = try Source.load(allocator, testing.io, dir, "source");
    defer doc.deinit(allocator);
    try doc.buffer.replace(allocator, .{ .start = 0, .end = 0 }, "new\n", 0);
    const result = doc.source.save(allocator, &doc.buffer, .{});
    if (result.failure) |err| {
        try testing.expect(result.publication == .none);
        try expectDisk(dir, "source", "original");
        try testing.expect(doc.buffer.modified());
        try testing.expectEqualStrings("original", doc.buffer.base);
        try expectNoTemporary(dir);
        return err;
    }
    try testing.expect(result.verified);
    try expectDisk(dir, "source", "new\noriginal");
    try expectNoTemporary(dir);
}

test "ACL source access is evaluated for effective owner rather than group write bits" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var initial = try fixture(temp.dir, "original");
    defer initial.deinit(testing.allocator);
    const fd = try openSource(temp.dir);
    defer _ = linux.close(fd);
    var acl: [44]u8 = undefined;
    const words = [_]u32{ 2, 0x00040001, 0xffffffff, 0x00060002, 65534, 0x00000004, 0xffffffff, 0x00060010, 0xffffffff, 0x00000020, 0xffffffff };
    for (words, 0..) |word, i| std.mem.writeInt(u32, acl[i * 4 ..][0..4], word, .little);
    _ = try checked(linux.fsetxattr(fd, "system.posix_acl_access", &acl, acl.len, 0), error.MetadataUnavailable);
    var doc = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    try testing.expect(doc.source.version.mode & 0o020 != 0);
    try testing.expectEqual(error.AccessDenied, doc.source.save(testing.allocator, &doc.buffer, .{}).failure.?);
    try expectDisk(temp.dir, "source", "original");
    try testing.expect(doc.buffer.modified());
}

test "inode policy flags are preserved while unknown policies refuse before writing" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var initial = try fixture(temp.dir, "original");
    defer initial.deinit(testing.allocator);
    const fd = try openSource(temp.dir);
    defer _ = linux.close(fd);
    var flags = (try inodeFlags(fd)).? | 0x40; // FS_NODUMP_FL
    _ = try checked(linux.ioctl(fd, linux.IOCTL.IOW('f', 2, c_long), @intFromPtr(&flags)), error.MetadataUnavailable);
    var doc = try Source.load(testing.allocator, testing.io, temp.dir, "source");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    try testing.expectEqual(@as(?Error, null), doc.source.save(testing.allocator, &doc.buffer, .{}).failure);
    const saved = try open(doc.source.resolved.target(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = linux.close(saved);
    try testing.expect((try inodeFlags(saved)).? & 0x40 != 0);
    // Unsupported policy must be rejected even if a caller can observe but
    // cannot set it on a fixture without privileged capabilities.
    var metadata = try Metadata.read(testing.allocator, saved, try statFd(saved));
    defer metadata.deinit(testing.allocator);
    metadata.flags = metadata.flags.? | 0x00100000; // FS_VERITY_FL
    try testing.expectError(error.UnsupportedFlags, metadata.prepareFlags(saved));
}

test "cleanup failure is secondary to original error and never damages source" {
    const DenyCleanup = struct {
        dir: std.Io.Dir,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage == .created) {
                const fd: posix.fd_t = @intCast(try checked(linux.openat(self.dir.handle, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0), error.OpenFailed));
                defer _ = linux.close(fd);
                _ = try checked(linux.fchmod(fd, 0o500), error.MetadataUnavailable);
                return error.InjectedFailure;
            }
        }
    };
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const parent: posix.fd_t = @intCast(try checked(linux.openat(temp.dir.handle, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0), error.OpenFailed));
    defer _ = linux.close(parent);
    defer _ = linux.fchmod(parent, 0o700);
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    var denial: DenyCleanup = .{ .dir = temp.dir };
    const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &denial, .hook = DenyCleanup.hook });
    try testing.expectEqual(error.InjectedFailure, result.failure.?);
    try testing.expect(result.cleanup_failure and result.publication == .none);
    try expectDisk(temp.dir, "source", "original");
    try testing.expect(doc.buffer.modified());
}

test "termination and suspension remain pending through synchronous saving" {
    const Signal = struct {
        signal: linux.SIG,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage == .written)
                _ = try checked(linux.tgkill(linux.getpid(), linux.gettid(), self.signal), error.InjectedFailure);
        }
    };
    for ([_]linux.SIG{ .TERM, .TSTP }) |signal| {
        var mask = posix.sigemptyset();
        posix.sigaddset(&mask, signal);
        var old: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, &mask, &old);
        defer posix.sigprocmask(posix.SIG.SETMASK, &old, null);
        const signals: posix.fd_t = @intCast(try checked(linux.signalfd(-1, &mask, linux.SFD.NONBLOCK | linux.SFD.CLOEXEC), error.OpenFailed));
        defer _ = linux.close(signals);
        var temp = testing.tmpDir(.{});
        defer temp.cleanup();
        var doc = try fixture(temp.dir, "original");
        defer doc.deinit(testing.allocator);
        try edit(&doc.buffer);
        var delivery: Signal = .{ .signal = signal };
        const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &delivery, .hook = Signal.hook });
        // The save finishes before the existing event loop can handle the signal;
        // this is deliberately not a bound under arbitrarily stalled storage.
        var info: linux.signalfd_siginfo = undefined;
        const size = try checked(linux.read(signals, @ptrCast(&info), @sizeOf(@TypeOf(info))), error.ReadFailed);
        try testing.expectEqual(@sizeOf(@TypeOf(info)), size);
        try testing.expectEqual(@as(u32, @backingInt(signal)), info.signo);
        try testing.expect(result.verified and result.durable and result.failure == null);
        try expectDisk(temp.dir, "source", "new\noriginal");
    }
}

test "unsupported raw bytes and empty files survive save without normalization" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    for ([_][]const u8{ "", "\xff\x00\r\none\nlast\r" }) |content| {
        var doc = try fixture(temp.dir, content);
        defer doc.deinit(testing.allocator);
        const result = doc.source.save(testing.allocator, &doc.buffer, .{});
        try testing.expectEqual(@as(?Error, null), result.failure);
        try expectDisk(temp.dir, "source", content);
    }
}

test "retargeting a symlink during temporary writing prevents publication" {
    const Retarget = struct {
        dir: std.Io.Dir,
        fn hook(context: ?*anyopaque, stage: Stage) Error!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (stage == .synced) {
                _ = try checked(linux.unlinkat(self.dir.handle, "link", 0), error.CleanupFailed);
                _ = try checked(linux.symlinkat("other", self.dir.handle, "link"), error.OpenFailed);
            }
        }
    };
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    try temp.dir.writeFile(testing.io, .{ .sub_path = "source", .data = "original" });
    try temp.dir.writeFile(testing.io, .{ .sub_path = "other", .data = "other" });
    try temp.dir.symLink(testing.io, "source", "link", .{});
    var doc = try Source.load(testing.allocator, testing.io, temp.dir, "link");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    var change: Retarget = .{ .dir = temp.dir };
    const result = doc.source.save(testing.allocator, &doc.buffer, .{ .context = &change, .hook = Retarget.hook });
    try testing.expectEqual(error.SourceChanged, result.failure.?);
    try testing.expect(result.publication == .none and doc.buffer.modified());
    try expectDisk(temp.dir, "source", "original");
    try expectDisk(temp.dir, "other", "other");
    try expectNoTemporary(temp.dir);
}

test "failed temporary creation retains source and trailing-slash copies create nothing" {
    var temp = testing.tmpDir(.{ .iterate = true });
    defer temp.cleanup();
    const parent: posix.fd_t = @intCast(try checked(linux.openat(temp.dir.handle, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0), error.OpenFailed));
    defer _ = linux.close(parent);
    defer _ = linux.fchmod(parent, 0o700);
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    _ = try checked(linux.fchmod(parent, 0o500), error.MetadataUnavailable);
    const result = doc.source.save(testing.allocator, &doc.buffer, .{});
    try testing.expectEqual(error.AccessDenied, result.failure.?);
    try testing.expect(result.publication == .none and doc.buffer.modified());
    try expectDisk(temp.dir, "source", "original");
    try expectNoTemporary(temp.dir);
    _ = try checked(linux.fchmod(parent, 0o700), error.MetadataUnavailable);
    const copied = copy(testing.allocator, testing.io, temp.dir, "unexpected/", &doc.buffer, .{});
    try testing.expectEqual(error.UnsupportedFileType, copied.failure.?);
    try testing.expectError(error.FileNotFound, temp.dir.access(testing.io, "unexpected", .{}));
}

test "validated loading enforces exact byte and logical line limits" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    const large = try temp.dir.createFile(testing.io, "large", .{});
    defer large.close(testing.io);
    try large.setLength(testing.io, limits.max_file_bytes);
    {
        var exact = try Source.load(testing.allocator, testing.io, temp.dir, "large");
        defer exact.deinit(testing.allocator);
        try testing.expectEqual(limits.max_file_bytes, exact.buffer.bytes().len);
    }
    try large.setLength(testing.io, limits.max_file_bytes + 1);
    try testing.expectError(error.FileTooLarge, Source.load(testing.allocator, testing.io, temp.dir, "large"));
    const newlines = try testing.allocator.alloc(u8, limits.max_lines + 1);
    defer testing.allocator.free(newlines);
    @memset(newlines, '\n');
    try temp.dir.writeFile(testing.io, .{ .sub_path = "lines", .data = newlines[0..limits.max_lines] });
    {
        var exact = try Source.load(testing.allocator, testing.io, temp.dir, "lines");
        defer exact.deinit(testing.allocator);
        try testing.expectEqual(limits.max_lines, exact.buffer.lineCount());
    }
    try temp.dir.writeFile(testing.io, .{ .sub_path = "lines", .data = newlines });
    try testing.expectError(error.TooManyLines, Source.load(testing.allocator, testing.io, temp.dir, "lines"));
}

test "saving strips a newly inherited ACL absent from the original" {
    var temp = testing.tmpDir(.{});
    defer temp.cleanup();
    var doc = try fixture(temp.dir, "original");
    defer doc.deinit(testing.allocator);
    try edit(&doc.buffer);
    const parent: posix.fd_t = @intCast(try checked(linux.openat(temp.dir.handle, ".", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0), error.OpenFailed));
    defer _ = linux.close(parent);
    var acl: [44]u8 = undefined;
    const words = [_]u32{ 2, 0x00070001, 0xffffffff, 0x00040002, 65534, 0x00000004, 0xffffffff, 0x00050010, 0xffffffff, 0x00000020, 0xffffffff };
    for (words, 0..) |word, i| std.mem.writeInt(u32, acl[i * 4 ..][0..4], word, .little);
    _ = try checked(linux.fsetxattr(parent, "system.posix_acl_default", &acl, acl.len, 0), error.MetadataUnavailable);
    const result = doc.source.save(testing.allocator, &doc.buffer, .{});
    try testing.expectEqual(@as(?Error, null), result.failure);
    const fd = try open(doc.source.resolved.target(), .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
    defer _ = linux.close(fd);
    var value: [128]u8 = undefined;
    try testing.expectEqual(posix.E.NODATA, posix.errno(linux.fgetxattr(fd, "system.posix_acl_access", &value, value.len)));
    const copied = copy(testing.allocator, testing.io, temp.dir, "copy", &doc.buffer, .{});
    try testing.expectEqual(@as(?Error, null), copied.failure);
    const copy_fd: posix.fd_t = @intCast(try checked(linux.openat(parent, "copy", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0), error.OpenFailed));
    defer _ = linux.close(copy_fd);
    try testing.expectEqual(@as(u16, 0o600), (try statFd(copy_fd)).mode & 0o7777);
    try testing.expectEqual(posix.E.NODATA, posix.errno(linux.fgetxattr(copy_fd, "system.posix_acl_access", &value, value.len)));
}
