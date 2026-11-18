// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const protocol = @import("protocol.zig");
const Position = @import("position.zig").Position;

/// A language's server, fixed in the source.
pub const Server = struct {
    /// Also the command, found on `PATH`.
    name: []const u8,
    /// The `languageId` its documents are opened with.
    language: []const u8,
    extensions: []const []const u8,
};

/// Only confirmed entries: zls is tested automatically, slangd by hand.
pub const servers = [_]Server{
    .{ .name = "zls", .language = "zig", .extensions = &.{ ".zig", ".zon" } },
    .{ .name = "slangd", .language = "slang", .extensions = &.{".slang"} },
};

/// The index in `servers` of the server for `path`
pub fn serverFor(path: []const u8) ?usize {
    const extension = std.fs.path.extension(path);
    for (servers, 0..) |server, index| {
        for (server.extensions) |candidate| {
            if (std.mem.eql(u8, candidate, extension)) return index;
        }
    }
    return null;
}

const initialize_id = 1;

/// What a call to `ready` changed, for the caller to act on.
pub const Change = struct {
    /// The capabilities arrived; requests may now be sent.
    initialized: bool = false,
    /// The pending request was answered; see `answer`.
    answered: bool = false,
    /// The server is gone and has been reaped.
    exited: bool = false,
};

pub const State = union(enum) {
    /// Not running; for the caller to start.
    idle,
    running: std.process.Child,
    /// Died, failed the protocol or failed to start for a reason that may pass
    exited,
    /// Its command can't be run, or it refused to initialize
    unavailable: anyerror,
};

/// A document the server has open, as Nib last sent it.
pub const Document = struct {
    /// The caller's name for the document.
    key: u64,
    /// Owned: the path it was opened with, for closing it.
    path: []const u8,
    version: u64,
};

/// Owns its process and buffers. Call `deinit`, which kills the server.
pub const Client = struct {
    server: *const Server,
    state: State = .idle,
    /// Bytes for the server
    queue: std.ArrayList(u8) = .empty,
    sent: usize = 0,
    reader: protocol.Reader = .{},
    /// Null until the initialize reply arrives.
    capabilities: ?protocol.Capabilities = null,
    next_id: u32 = initialize_id + 1,
    /// The one navigation request awaiting an answer.
    pending: ?u32 = null,
    /// The last answer to a pending request
    answer: ?protocol.Answer = null,
    answer_memory: std.heap.ArenaAllocator.State = .init,
    /// What the running server has open; empty until initialized.
    documents: std.ArrayList(Document) = .empty,

    pub fn deinit(self: *Client, gpa: Allocator, io: std.Io) void {
        if (self.state == .running) self.stop(io);
        self.queue.deinit(gpa);
        self.reader.deinit(gpa);
        self.answer_memory.promote(gpa).deinit();
        self.forgetAll(gpa);
        self.documents.deinit(gpa);
        self.* = undefined;
    }

    pub fn start(self: *Client, gpa: Allocator, io: std.Io, root: []const u8) void {
        std.debug.assert(self.state == .idle or self.state == .exited);
        self.reset(gpa);
        // Its own process group, so the kill reaches anything it starts.
        const child = std.process.spawn(io, .{
            .argv = &.{self.server.name},
            .cwd = .{ .path = root },
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
            .pgid = 0,
        }) catch |err| {
            // Zig 0.17.1 leaves a zombie and two descriptors when the child
            // reports the failure.
            self.state = switch (err) {
                error.OutOfMemory,
                error.SystemResources,
                error.ProcessFdQuotaExceeded,
                error.SystemFdQuotaExceeded,
                error.ResourceLimitReached,
                error.FileBusy,
                => .exited,
                else => .{ .unavailable = err },
            };
            return;
        };
        self.state = .{ .running = child };
        for ([_]posix.fd_t{ child.stdin.?.handle, child.stdout.?.handle }) |fd| {
            const flags = linux.fcntl(fd, linux.F.GETFL, 0);
            const nonblocking = flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
            if (posix.errno(flags) != .SUCCESS or
                posix.errno(linux.fcntl(fd, linux.F.SETFL, nonblocking)) != .SUCCESS)
            {
                return self.stop(io);
            }
        }
        const process: i32 = linux.getpid();
        protocol.initialize(gpa, &self.queue, initialize_id, process, root) catch {
            return self.stop(io);
        };
        self.flush(gpa, io);
    }

    /// The descriptors to poll: output to read, and input to write while
    /// bytes wait. Each is -1 when not running.
    pub fn descriptors(self: *const Client) [2]linux.pollfd {
        const child = switch (self.state) {
            .running => |child| child,
            else => return .{
                .{ .fd = -1, .events = 0, .revents = 0 },
                .{ .fd = -1, .events = 0, .revents = 0 },
            },
        };
        const waiting = self.sent < self.queue.items.len;
        return .{
            .{ .fd = child.stdout.?.handle, .events = linux.POLL.IN, .revents = 0 },
            .{
                .fd = if (waiting) child.stdin.?.handle else -1,
                .events = linux.POLL.OUT,
                .revents = 0,
            },
        };
    }

    /// Writes what the server can take and reads what it sent, given the
    /// `revents` of `descriptors`. Requests from the server are refused and
    /// notifications dropped. A server that closes its output or breaks the
    /// protocol is killed and reaped.
    pub fn ready(self: *Client, gpa: Allocator, io: std.Io, polled: [2]linux.pollfd) Change {
        if (self.state != .running) return .{};
        if (polled[1].revents != 0) self.flush(gpa, io);
        if (self.state != .running) return .{ .exited = true };
        if (polled[0].revents == 0) return .{};
        var bytes: [64 * 1024]u8 = undefined;
        const count = linux.read(polled[0].fd, &bytes, bytes.len);
        switch (posix.errno(count)) {
            .SUCCESS => if (count == 0) return self.exit(io),
            .AGAIN, .INTR => return .{},
            else => return self.exit(io),
        }
        const result = self.receive(gpa, bytes[0..count]) catch |err| {
            self.stop(io);
            // Starting again would be refused the same way.
            switch (err) {
                error.InitializeRefused,
                error.UnsupportedEncoding,
                => self.state = .{ .unavailable = err },
                else => {},
            }
            return .{ .exited = true };
        };
        self.flush(gpa, io);
        if (self.state != .running) return .{ .exited = true };
        return result;
    }

    /// Takes in server output already read, handling each complete message.
    /// Fails when the server broke the protocol or memory ran out; the caller
    /// then stops the server.
    pub fn receive(
        self: *Client,
        gpa: Allocator,
        bytes: []const u8,
    ) (protocol.Error || error{InitializeRefused})!Change {
        try self.reader.append(gpa, bytes);
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        var result: Change = .{};
        while (try self.reader.next()) |body| {
            _ = scratch.reset(.retain_capacity);
            switch (try protocol.classify(scratch.allocator(), body)) {
                .notification => {},
                .request => |id| try protocol.refuse(gpa, &self.queue, id),
                .response => |maybe| {
                    const id = maybe orelse continue;
                    if (self.capabilities == null) {
                        // Only `initialize` is outstanding before its reply.
                        if (id != initialize_id) continue;
                        const reply = try protocol.initializeReply(scratch.allocator(), body);
                        self.capabilities = switch (reply) {
                            .capabilities => |capabilities| capabilities,
                            .failed => return error.InitializeRefused,
                        };
                        try protocol.initialized(gpa, &self.queue);
                        result.initialized = true;
                    } else if (self.pending == id) {
                        var memory = self.answer_memory.promote(gpa);
                        defer self.answer_memory = memory.state;
                        _ = memory.reset(.retain_capacity);
                        self.answer = try protocol.navigationReply(memory.allocator(), body);
                        self.pending = null;
                        result.answered = true;
                    }
                },
            }
        }
        return result;
    }

    // The writers below need an initialized server. Each queues a message
    // and writes what the server takes now; on running out of memory the
    // queue is unchanged and the error is returned. A server that dies on
    // the write is stopped, so the caller checks `state` afterwards.

    /// Opens the document `key` names, or sends its text again when
    /// `version` differs from what the server has. On running out of memory
    /// nothing is sent or recorded.
    pub fn sync(
        self: *Client,
        gpa: Allocator,
        io: std.Io,
        key: u64,
        path: []const u8,
        version: u64,
        text: []const u8,
    ) Allocator.Error!void {
        std.debug.assert(self.capabilities != null);
        for (self.documents.items) |*document| {
            if (document.key != key) continue;
            if (document.version == version) return;
            try protocol.didChange(gpa, &self.queue, path, version, text);
            document.version = version;
            return self.flush(gpa, io);
        }
        try self.documents.ensureUnusedCapacity(gpa, 1);
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        try protocol.didOpen(gpa, &self.queue, path, self.server.language, version, text);
        self.documents.appendAssumeCapacity(.{ .key = key, .path = owned, .version = version });
        self.flush(gpa, io);
    }

    /// Closes `documents[index]` on the server and forgets it. On running out
    /// of memory nothing changes.
    pub fn forget(self: *Client, gpa: Allocator, io: std.Io, index: usize) Allocator.Error!void {
        std.debug.assert(self.capabilities != null);
        const document = self.documents.items[index];
        try protocol.didClose(gpa, &self.queue, document.path);
        gpa.free(document.path);
        _ = self.documents.swapRemove(index);
        self.flush(gpa, io);
    }

    /// Sends a navigation request, which becomes the pending one; an earlier
    /// pending request's answer will be ignored.
    pub fn navigate(
        self: *Client,
        gpa: Allocator,
        io: std.Io,
        navigation: protocol.Navigation,
        path: []const u8,
        at: Position,
    ) Allocator.Error!void {
        std.debug.assert(self.capabilities != null);
        const id = self.next_id;
        try protocol.navigate(gpa, &self.queue, id, navigation, path, at);
        self.next_id += 1;
        self.pending = id;
        self.answer = null;
        self.flush(gpa, io);
    }

    /// Asks the server to drop the pending request, whose answer is then
    /// ignored. Without memory for the message, the answer is still ignored.
    pub fn cancel(self: *Client, gpa: Allocator, io: std.Io) void {
        const id = self.pending orelse return;
        self.pending = null;
        protocol.cancel(gpa, &self.queue, id) catch return;
        self.flush(gpa, io);
    }

    pub fn stop(self: *Client, io: std.Io) void {
        var child = self.state.running;
        _ = linux.kill(-child.id.?, .KILL);
        // Cancelling the wait would release the handles without reaping.
        const protection = io.swapCancelProtection(.blocked);
        defer _ = io.swapCancelProtection(protection);
        _ = child.wait(io) catch {};
        self.state = .exited;
        self.capabilities = null;
        self.pending = null;
    }

    fn exit(self: *Client, io: std.Io) Change {
        self.stop(io);
        return .{ .exited = true };
    }

    /// Writes queued bytes until the pipe is full. A server that has gone
    /// (EPIPE) or fails the write is stopped.
    fn flush(self: *Client, gpa: Allocator, io: std.Io) void {
        const child = switch (self.state) {
            .running => |child| child,
            else => return,
        };
        while (self.sent < self.queue.items.len) {
            const waiting = self.queue.items[self.sent..];
            const count = linux.write(child.stdin.?.handle, waiting.ptr, waiting.len);
            switch (posix.errno(count)) {
                .SUCCESS => self.sent += count,
                .AGAIN => return,
                .INTR => continue,
                else => return self.stop(io),
            }
        }
        self.sent = 0;
        // Keep a small queue's memory; give back a whole text's.
        if (self.queue.capacity > 1024 * 1024) {
            self.queue.clearAndFree(gpa);
        } else self.queue.clearRetainingCapacity();
    }

    fn reset(self: *Client, gpa: Allocator) void {
        self.queue.clearRetainingCapacity();
        self.sent = 0;
        self.reader.deinit(gpa);
        self.reader = .{};
        self.capabilities = null;
        self.next_id = initialize_id + 1;
        self.pending = null;
        self.answer = null;
        self.forgetAll(gpa);
    }

    fn forgetAll(self: *Client, gpa: Allocator) void {
        for (self.documents.items) |document| gpa.free(document.path);
        self.documents.clearRetainingCapacity();
    }
};

const testing = std.testing;

/// The queued messages' bodies, without their headers, joined by newlines.
fn queued(client: *const Client, storage: []u8) ![]const u8 {
    var reader: protocol.Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.append(testing.allocator, client.queue.items[client.sent..]);
    var length: usize = 0;
    while (try reader.next()) |body| {
        @memcpy(storage[length..][0..body.len], body);
        storage[length + body.len] = '\n';
        length += body.len + 1;
    }
    return storage[0..length];
}

inline fn framed(comptime body: []const u8) []const u8 {
    return std.fmt.comptimePrint("Content-Length: {d}\r\n\r\n{s}", .{ body.len, body });
}

test "the table finds a file's server by extension" {
    try testing.expectEqualStrings("zls", servers[serverFor("/p/src/main.zig").?].name);
    try testing.expectEqualStrings("zls", servers[serverFor("build.zig.zon").?].name);
    try testing.expectEqualStrings("slangd", servers[serverFor("shaders/a.slang").?].name);
    for ([_][]const u8{ "README.md", "zig", "/p/.zig", "a.zig.bak" }) |path| {
        try testing.expectEqual(null, serverFor(path));
    }
}

test "server requests are refused, notifications dropped, and only the pending answer kept" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    var storage: [4096]u8 = undefined;
    // Before initialization, a stray response is ignored.
    const early = try client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hi"}}
    ) ++ framed(
        \\{"jsonrpc":"2.0","id":"register-1","method":"client/registerCapability","params":{}}
    ) ++ framed(
        \\{"jsonrpc":"2.0","id":9,"result":null}
    ));
    try testing.expectEqual(Change{}, early);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":"register-1","error":{"code":-32601,"message":"Method not found"}}
        \\
    , try queued(&client, &storage));
    client.queue.clearRetainingCapacity();
    const initialized = try client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-8","definitionProvider":true}}}
    ));
    try testing.expectEqual(Change{ .initialized = true }, initialized);
    try testing.expect(client.capabilities.?.offers.contains(.definition));
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
        \\
    , try queued(&client, &storage));
    client.queue.clearRetainingCapacity();
    // A replaced request's late answer is ignored; the pending one's is kept.
    const first: Position = .{ .line = 0, .character = 0 };
    const second: Position = .{ .line = 1, .character = 0 };
    try client.navigate(testing.allocator, testing.io, .definition, "/p/a.zig", first);
    try client.navigate(testing.allocator, testing.io, .definition, "/p/a.zig", second);
    const late = try client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","id":2,"result":{"uri":"file:///p/old.zig","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}}
    ));
    try testing.expectEqual(Change{}, late);
    try testing.expectEqual(@as(?u32, 3), client.pending);
    const answered = try client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","id":3,"result":[{"uri":"file:///p/b.zig","range":{"start":{"line":4,"character":2},"end":{"line":4,"character":3}}}]}
    ));
    try testing.expectEqual(Change{ .answered = true }, answered);
    try testing.expectEqual(null, client.pending);
    try testing.expectEqualStrings("/p/b.zig", client.answer.?.locations[0].path.?);
    // A cancelled request's answer is ignored too.
    try client.navigate(testing.allocator, testing.io, .references, "/p/a.zig", second);
    client.cancel(testing.allocator, testing.io);
    try testing.expectEqual(Change{}, try client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","id":4,"result":[]}
    )));
    try testing.expect(std.mem.endsWith(u8, try queued(&client, &storage),
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":4}}
        \\
    ));
    try testing.expectError(error.MalformedMessage, client.receive(testing.allocator, framed("{")));
}

test "a server that refuses to initialize is reported" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    try testing.expectError(error.InitializeRefused, client.receive(testing.allocator, framed(
        \\{"jsonrpc":"2.0","id":1,"error":{"code":-32603,"message":"no"}}
    )));
}

test "sync opens a document once, resends it only at a new version, and forget closes it" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    client.capabilities = .{ .encoding = .utf8, .offers = .empty };
    var storage: [4096]u8 = undefined;
    try client.sync(testing.allocator, testing.io, 7, "/p/a.zig", 0, "a");
    try client.sync(testing.allocator, testing.io, 7, "/p/a.zig", 0, "a");
    try client.sync(testing.allocator, testing.io, 7, "/p/a.zig", 2, "ab");
    try client.forget(testing.allocator, testing.io, 0);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///p/a.zig","languageId":"zig","version":0,"text":"a"}}}
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":2},"contentChanges":[{"text":"ab"}]}}
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///p/a.zig"}}}
        \\
    , try queued(&client, &storage));
    try testing.expectEqual(@as(usize, 0), client.documents.items.len);
}

test "a sync that runs out of memory sends and records nothing" {
    const Case = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = .{ .server = &servers[0] };
            defer client.deinit(gpa, testing.io);
            client.capabilities = .{ .encoding = .utf8, .offers = .empty };
            try client.sync(gpa, testing.io, 1, "/p/a.zig", 0, "a");
            const before = client.queue.items.len;
            client.sync(gpa, testing.io, 2, "/p/b.zig", 0, "b") catch |err| {
                try testing.expectEqual(before, client.queue.items.len);
                try testing.expectEqual(@as(usize, 1), client.documents.items.len);
                return err;
            };
            client.sync(gpa, testing.io, 1, "/p/a.zig", 1, "aa") catch |err| {
                try testing.expectEqual(@as(u64, 0), client.documents.items[0].version);
                return err;
            };
            client.forget(gpa, testing.io, 0) catch |err| {
                try testing.expectEqual(@as(usize, 2), client.documents.items.len);
                return err;
            };
        }
    };
    try testing.checkAllAllocationFailures(testing.allocator, Case.run, .{});
}

/// Polls `client` until `wanted` holds of everything that changed, failing
/// after ten seconds.
fn settle(client: *Client, wanted: *const fn (Change) bool) !Change {
    var seen: Change = .{};
    var remaining: i32 = 10_000;
    while (!wanted(seen)) {
        var polled = client.descriptors();
        const started = std.Io.Clock.awake.now(testing.io);
        const result = linux.poll(&polled, polled.len, remaining);
        if (posix.errno(result) != .SUCCESS) return error.PollFailed;
        if (result == 0) return error.ServerTooSlow;
        const elapsed = started.untilNow(testing.io, .awake).toMilliseconds();
        remaining -= @intCast(@min(elapsed, remaining));
        const change = client.ready(testing.allocator, testing.io, polled);
        seen.initialized = seen.initialized or change.initialized;
        seen.answered = seen.answered or change.answered;
        seen.exited = seen.exited or change.exited;
    }
    return seen;
}

fn isInitialized(change: Change) bool {
    return change.initialized;
}

fn isAnswered(change: Change) bool {
    return change.answered;
}

fn isExited(change: Change) bool {
    return change.exited;
}

/// A two-file Zig project in a temporary directory, and its absolute path.
const Project = struct {
    temp: testing.TmpDir,
    storage: [4096]u8,
    root: []const u8,

    const a =
        \\const b = @import("b.zig");
        \\pub fn main() void {
        \\    b.target();
        \\    b.target();
        \\}
        \\
    ;

    fn init(project: *Project) !void {
        project.temp = testing.tmpDir(.{});
        errdefer project.temp.cleanup();
        try project.temp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = a });
        const b = "pub fn target() void {}\n";
        try project.temp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = b });
        const length = try project.temp.dir.realPath(testing.io, &project.storage);
        project.root = project.storage[0..length];
    }

    fn path(project: *const Project, name: []const u8, storage: []u8) ![]const u8 {
        return std.fmt.bufPrint(storage, "{s}/{s}", .{ project.root, name });
    }
};

/// Starts zls on `project` and waits for its capabilities. Fails by name
/// when zls isn't on `PATH`.
fn startZls(client: *Client, project: *const Project) !void {
    client.start(testing.allocator, testing.io, project.root);
    if (client.state == .unavailable) {
        const reason = @errorName(client.state.unavailable);
        std.debug.print("language-server tests need zls on PATH: {s}\n", .{reason});
        return error.ZlsUnavailable;
    }
    _ = try settle(client, isInitialized);
}

test "zls initializes with UTF-8 and answers definitions and references" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    try startZls(&client, &project);
    const capabilities = client.capabilities.?;
    try testing.expectEqual(@import("position.zig").Encoding.utf8, capabilities.encoding);
    try testing.expect(capabilities.offers.contains(.definition));
    try testing.expect(capabilities.offers.contains(.references));
    var a_storage: [4096]u8 = undefined;
    var b_storage: [4096]u8 = undefined;
    const a = try project.path("a.zig", &a_storage);
    const b = try project.path("b.zig", &b_storage);
    try client.sync(testing.allocator, testing.io, 0, a, 0, Project.a);
    // On `target` in the first call.
    const call: Position = .{ .line = 2, .character = 6 };
    try client.navigate(testing.allocator, testing.io, .definition, a, call);
    _ = try settle(&client, isAnswered);
    const definition = client.answer.?.locations;
    try testing.expectEqual(@as(usize, 1), definition.len);
    try testing.expectEqualStrings(b, definition[0].path.?);
    try testing.expectEqual(Position{ .line = 0, .character = 7 }, definition[0].at);
    try client.navigate(testing.allocator, testing.io, .references, a, call);
    _ = try settle(&client, isAnswered);
    // Both calls, without the declaration.
    const references = client.answer.?.locations;
    try testing.expectEqual(@as(usize, 2), references.len);
    for (references, [_]u32{ 2, 3 }) |reference, line| {
        try testing.expectEqualStrings(a, reference.path.?);
        try testing.expectEqual(Position{ .line = line, .character = 6 }, reference.at);
    }
}

test "a server killed mid-request is reported, and starts again" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    try startZls(&client, &project);
    var storage: [4096]u8 = undefined;
    const a = try project.path("a.zig", &storage);
    try client.sync(testing.allocator, testing.io, 0, a, 0, Project.a);
    const call: Position = .{ .line = 2, .character = 6 };
    try client.navigate(testing.allocator, testing.io, .definition, a, call);
    _ = linux.kill(-client.state.running.id.?, .KILL);
    _ = try settle(&client, isExited);
    try testing.expect(client.state == .exited);
    try testing.expectEqual(null, client.pending);
    try startZls(&client, &project);
    try testing.expect(client.state == .running);
}

test "a write to a server that has died stops it instead of killing Nib" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    try startZls(&client, &project);
    const child = client.state.running;
    _ = linux.kill(-child.id.?, .KILL);
    // Its output closes once it has exited.
    const stdout = child.stdout.?.handle;
    var output = [_]linux.pollfd{.{ .fd = stdout, .events = linux.POLL.IN, .revents = 0 }};
    while (output[0].revents & linux.POLL.HUP == 0) _ = linux.poll(&output, 1, 10_000);
    // Larger than a pipe holds, so the write reaches the closed end.
    const text: [256 * 1024]u8 = @splat('x');
    try client.sync(testing.allocator, testing.io, 0, "/p/a.zig", 0, &text);
    try testing.expect(client.state == .exited);
}

test "quitting kills and reaps the server" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    try startZls(&client, &project);
    const id = client.state.running.id.?;
    client.deinit(testing.allocator, testing.io);
    // Reaped: no such process remains, not even a zombie.
    const probe = linux.kill(id, @fromBackingInt(@intCast(0)));
    try testing.expectEqual(posix.E.SRCH, posix.errno(probe));
}

test "a missing command is unavailable" {
    const missing: Server = .{ .name = "nib-no-such-server", .language = "x", .extensions = &.{} };
    var client: Client = .{ .server = &missing };
    defer client.deinit(testing.allocator, testing.io);
    client.start(testing.allocator, testing.io, "/");
    try testing.expectEqual(error.FileNotFound, client.state.unavailable);
}

pub const NoDescriptors = struct {
    saved: linux.rlimit,
    /// The lowest free descriptor when lowered.
    lowest: u64,

    pub fn lower() !NoDescriptors {
        const lowest = lowestFree();
        var saved: linux.rlimit = undefined;
        if (posix.errno(linux.getrlimit(.NOFILE, &saved)) != .SUCCESS) return error.LimitFailed;
        var lowered = saved;
        lowered.cur = lowest;
        if (posix.errno(linux.setrlimit(.NOFILE, &lowered)) != .SUCCESS) return error.LimitFailed;
        return .{ .saved = saved, .lowest = lowest };
    }

    pub fn restore(self: NoDescriptors) void {
        _ = linux.setrlimit(.NOFILE, &self.saved);
    }

    pub fn lowestFree() u64 {
        const copy = linux.dup(0);
        _ = linux.close(@intCast(copy));
        return copy;
    }
};

test "a start short of descriptors leaves the server exited, leaking none, and it starts later" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    const limit = try NoDescriptors.lower();
    client.start(testing.allocator, testing.io, project.root);
    limit.restore();
    try testing.expect(client.state == .exited);
    try testing.expectEqual(limit.lowest, NoDescriptors.lowestFree());
    try startZls(&client, &project);
    try testing.expect(client.state == .running);
}
