// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;
const posix = std.posix;
const protocol = @import("protocol.zig");
const Position = @import("position.zig").Position;
const Buffer = @import("../text/buffer.zig").Buffer;
const ChangedRows = @import("../text/buffer.zig").ChangedRows;
const syntax = @import("../text/syntax.zig");

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
    /// The token request was answered, so another may be sent; `tokens`
    /// decodes the answer unless it was dropped as stale.
    tokens: bool = false,
    /// The server is gone and has been reaped.
    exited: bool = false,
};

pub const State = union(enum) {
    /// Not running; for the caller to start.
    idle,
    running: std.process.Child,
    /// Died, failed the protocol or failed to start for a reason that may pass.
    exited,
    /// Its command can't be run, or it refused to initialize.
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

/// A token request: rows `top` up to `bottom` of document `key` at the
/// version the server had when it was asked.
pub const TokenRequest = struct {
    id: u32,
    key: u64,
    version: u64,
    top: usize,
    bottom: usize,
    /// Its document was closed on the server since, so the answer is dropped
    /// even if the key opens again at the same version.
    closed: bool = false,
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
    /// The one token request awaiting an answer, independent of `pending`.
    token_request: ?TokenRequest = null,
    /// The request whose answer is in `token_reply`, until `tokens` takes it.
    token_answered: ?TokenRequest = null,
    token_reply: std.ArrayList(u8) = .empty,
    /// What the running server has open; empty until initialized.
    documents: std.ArrayList(Document) = .empty,

    pub fn deinit(self: *Client, gpa: Allocator, io: std.Io) void {
        if (self.state == .running) self.stop(io);
        self.queue.deinit(gpa);
        self.reader.deinit(gpa);
        self.answer_memory.promote(gpa).deinit();
        self.token_reply.deinit(gpa);
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
                    } else if (self.token_request) |request| {
                        if (request.id != id) continue;
                        self.token_request = null;
                        result.tokens = true;
                        if (self.current(request)) self.keepTokens(gpa, request, body);
                    }
                },
            }
        }
        return result;
    }

    /// Whether the server still has the text `request` was asked about.
    fn current(self: *const Client, request: TokenRequest) bool {
        if (request.closed) return false;
        for (self.documents.items) |document| {
            if (document.key == request.key) return document.version == request.version;
        }
        return false;
    }

    /// Keeps a token answer for `tokens`. Tokens are optional, so without
    /// memory the answer is dropped and the server kept.
    fn keepTokens(self: *Client, gpa: Allocator, request: TokenRequest, body: []const u8) void {
        self.token_answered = null;
        self.token_reply.clearRetainingCapacity();
        self.token_reply.appendSlice(gpa, body) catch return;
        self.token_answered = request;
    }

    /// Decodes the token answer for `buffer`, the text of the document it
    /// was asked about, into a new set in the server's rows, which
    /// `Held.row` maps through the buffer's record; and gives up the answer.
    /// Null when there is no answer or the server failed the request. Call
    /// it before that document is synced again.
    pub fn tokens(self: *Client, gpa: Allocator, buffer: *const Buffer) protocol.Error!?syntax.Held {
        const request = self.token_answered orelse return null;
        defer {
            self.token_answered = null;
            // Keep a small answer's memory; give back a large one's.
            if (self.token_reply.capacity > 1024 * 1024) self.token_reply.clearAndFree(gpa);
        }
        const capabilities = self.capabilities.?;
        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        // No sync since the request, so the buffer's record holds every
        // change since the server's text.
        return protocol.tokensReply(
            gpa,
            scratch.allocator(),
            self.token_reply.items,
            &capabilities.legend.?,
            capabilities.encoding,
            buffer,
            buffer.changed_rows,
            request.top,
            request.bottom,
        );
    }

    // The writers below need an initialized server. Each queues a message
    // and writes what the server takes now; on running out of memory the
    // queue is unchanged and the error is returned. A server that dies on
    // the write is stopped, so the caller checks `state` afterwards.

    /// Opens the document `key` names with `buffer`'s text, or, when the
    /// buffer's `changes` differ from the version the server has, sends the
    /// lines its record names, or its whole text to a server that takes no
    /// lines. Then resets the record and returns what it held, for records
    /// of the server's text kept elsewhere. On running out of memory nothing
    /// is sent, reset or recorded.
    pub fn sync(
        self: *Client,
        gpa: Allocator,
        io: std.Io,
        key: u64,
        path: []const u8,
        buffer: *Buffer,
    ) Allocator.Error!ChangedRows {
        const capabilities = self.capabilities.?;
        const version = buffer.changes;
        const taken = buffer.changed_rows;
        for (self.documents.items) |*document| {
            if (document.key != key) continue;
            if (document.version == version) return .none;
            const changed: ChangedRows = if (capabilities.incremental) taken else .whole;
            if (protocol.textChange(buffer, changed)) |change| {
                try protocol.didChange(gpa, &self.queue, path, version, change);
            }
            document.version = version;
            buffer.changed_rows = .none;
            self.flush(gpa, io);
            return taken;
        }
        try self.documents.ensureUnusedCapacity(gpa, 1);
        const owned = try gpa.dupe(u8, path);
        errdefer gpa.free(owned);
        const language = self.server.language;
        try protocol.didOpen(gpa, &self.queue, path, language, version, buffer.bytes());
        self.documents.appendAssumeCapacity(.{ .key = key, .path = owned, .version = version });
        buffer.changed_rows = .none;
        self.flush(gpa, io);
        return taken;
    }

    /// Closes `documents[index]` on the server and forgets it. On running out
    /// of memory nothing changes.
    pub fn forget(self: *Client, gpa: Allocator, io: std.Io, index: usize) Allocator.Error!void {
        std.debug.assert(self.capabilities != null);
        const document = self.documents.items[index];
        try protocol.didClose(gpa, &self.queue, document.path);
        gpa.free(document.path);
        _ = self.documents.swapRemove(index);
        if (self.token_request) |*request| {
            if (request.key == document.key) request.closed = true;
        }
        self.flush(gpa, io);
    }

    /// Asks for the tokens of rows `top` up to `bottom` of the open document
    /// `key`, whose text has `rows` rows, as the server has it. The server
    /// must offer a legend, and no token request may be awaiting an answer.
    pub fn requestTokens(
        self: *Client,
        gpa: Allocator,
        io: std.Io,
        key: u64,
        top: usize,
        bottom: usize,
        rows: usize,
    ) Allocator.Error!void {
        std.debug.assert(self.capabilities.?.legend != null and self.token_request == null);
        const document = for (self.documents.items) |document| {
            if (document.key == key) break document;
        } else unreachable;
        const id = self.next_id;
        try protocol.semanticTokens(gpa, &self.queue, id, document.path, top, bottom, rows);
        self.next_id += 1;
        self.token_request = .{
            .id = id,
            .key = key,
            .version = document.version,
            .top = top,
            .bottom = bottom,
        };
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
        self.token_request = null;
        self.token_answered = null;
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
        self.token_request = null;
        self.token_answered = null;
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

/// Capabilities as ZLS's, with a two-kind legend.
const test_capabilities: protocol.Capabilities = .{
    .encoding = .utf8,
    .offers = .initOne(.definition),
    .incremental = true,
    .legend = .init(&.{ "function", "property" }),
};

test "sync opens a document whole once, then sends its changed lines at each new version" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    client.capabilities = test_capabilities;
    var buffer = try Buffer.fromBytes(testing.allocator, "a\nb\n");
    defer buffer.deinit(testing.allocator);
    var storage: [4096]u8 = undefined;
    const gpa = testing.allocator;
    const io = testing.io;
    try testing.expectEqual(ChangedRows.whole, try client.sync(gpa, io, 7, "/p/a.zig", &buffer));
    try testing.expectEqual(ChangedRows.none, buffer.changed_rows);
    try testing.expectEqual(ChangedRows.none, try client.sync(gpa, io, 7, "/p/a.zig", &buffer));
    try buffer.replace(gpa, .{ .start = 2, .end = 3 }, "c", 3);
    const one: ChangedRows = .{ .lines = .{ .first = 1, .unchanged = 1, .rows = 3 } };
    try testing.expectEqual(one, try client.sync(gpa, io, 7, "/p/a.zig", &buffer));
    try testing.expectEqual(ChangedRows.none, buffer.changed_rows);
    // A server that takes no lines gets the whole text, and the record is
    // still taken.
    client.capabilities.?.incremental = false;
    try buffer.replace(gpa, .{ .start = 0, .end = 1 }, "d", 1);
    const first: ChangedRows = .{ .lines = .{ .first = 0, .unchanged = 2, .rows = 3 } };
    try testing.expectEqual(first, try client.sync(gpa, io, 7, "/p/a.zig", &buffer));
    try client.forget(gpa, io, 0);
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///p/a.zig","languageId":"zig","version":0,"text":"a\nb\n"}}}
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":1},"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":2,"character":0}},"text":"c\n"}]}}
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":2},"contentChanges":[{"text":"d\nc\n"}]}}
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///p/a.zig"}}}
        \\
    , try queued(&client, &storage));
    try testing.expectEqual(@as(usize, 0), client.documents.items.len);
}

test "a sync that runs out of memory sends, resets and records nothing" {
    const Case = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = .{ .server = &servers[0] };
            defer client.deinit(gpa, testing.io);
            client.capabilities = test_capabilities;
            var a = try Buffer.fromBytes(gpa, "a\nb\n");
            defer a.deinit(gpa);
            var b = try Buffer.fromBytes(gpa, "b");
            defer b.deinit(gpa);
            _ = try client.sync(gpa, testing.io, 1, "/p/a.zig", &a);
            const before = client.queue.items.len;
            _ = client.sync(gpa, testing.io, 2, "/p/b.zig", &b) catch |err| {
                try testing.expectEqual(before, client.queue.items.len);
                try testing.expectEqual(@as(usize, 1), client.documents.items.len);
                try testing.expectEqual(ChangedRows.whole, b.changed_rows);
                return err;
            };
            try a.replace(gpa, .{ .start = 2, .end = 3 }, "c", 3);
            const record = a.changed_rows;
            // No room kept, so queueing the change must allocate.
            client.queue.clearAndFree(gpa);
            const changed = client.queue.items.len;
            _ = client.sync(gpa, testing.io, 1, "/p/a.zig", &a) catch |err| {
                try testing.expectEqual(changed, client.queue.items.len);
                try testing.expectEqual(@as(u64, 0), client.documents.items[0].version);
                try testing.expectEqual(record, a.changed_rows);
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

test "a sync that ran out of memory sends the same lines when tried again" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{});
    const gpa = failing.allocator();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(gpa, testing.io);
    client.capabilities = test_capabilities;
    var buffer = try Buffer.fromBytes(gpa, "a\nb\nc\n");
    defer buffer.deinit(gpa);
    _ = try client.sync(gpa, testing.io, 1, "/p/a.zig", &buffer);
    try buffer.replace(gpa, .{ .start = 2, .end = 3 }, "x", 3);
    client.queue.clearAndFree(gpa);
    failing.fail_index = failing.alloc_index;
    failing.resize_fail_index = failing.resize_index;
    try testing.expectError(error.OutOfMemory, client.sync(gpa, testing.io, 1, "/p/a.zig", &buffer));
    failing.fail_index = std.math.maxInt(usize);
    failing.resize_fail_index = std.math.maxInt(usize);
    _ = try client.sync(gpa, testing.io, 1, "/p/a.zig", &buffer);
    var storage: [1024]u8 = undefined;
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":1},"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":2,"character":0}},"text":"x\n"}]}}
        \\
    , try queued(&client, &storage));
}

test "the token lane and the navigation lane each get only their own answers" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    client.capabilities = test_capabilities;
    const gpa = testing.allocator;
    const io = testing.io;
    var buffer = try Buffer.fromBytes(gpa, "ab cd\nef\n");
    defer buffer.deinit(gpa);
    _ = try client.sync(gpa, io, 7, "/p/a.zig", &buffer);
    client.queue.clearRetainingCapacity();
    try client.requestTokens(gpa, io, 7, 0, 3, 3);
    try client.navigate(gpa, io, .definition, "/p/a.zig", .{ .line = 0, .character = 0 });
    var storage: [4096]u8 = undefined;
    try testing.expectEqualStrings(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///p/a.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":2,"character":2147483647}}}}
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/definition","params":{"textDocument":{"uri":"file:///p/a.zig"},"position":{"line":0,"character":0}}}
        \\
    , try queued(&client, &storage));
    // Cancelling navigation leaves the token request waiting.
    client.cancel(gpa, io);
    try testing.expectEqual(@as(u32, 2), client.token_request.?.id);
    try testing.expectEqual(Change{}, try client.receive(gpa, framed(
        \\{"jsonrpc":"2.0","id":3,"result":null}
    )));
    try client.navigate(gpa, io, .definition, "/p/a.zig", .{ .line = 1, .character = 0 });
    // Edits after the request, not yet synced, move the answer's rows.
    try buffer.replace(gpa, .{ .start = 0, .end = 0 }, "new\n", 4);
    // "ab" a function on row 0, "ef" a property on row 1.
    const tokens = try client.receive(gpa, framed(
        \\{"jsonrpc":"2.0","id":2,"result":{"data":[0,0,2,0,0,1,0,2,1,0]}}
    ));
    try testing.expectEqual(Change{ .tokens = true }, tokens);
    try testing.expectEqual(@as(?u32, 4), client.pending);
    try testing.expectEqual(null, client.token_request);
    var held = (try client.tokens(gpa, &buffer)).?;
    defer held.deinit(gpa);
    try testing.expectEqual(null, try client.tokens(gpa, &buffer));
    const rows = buffer.insertionRows();
    // The first row was rewritten; the second moved down one.
    try testing.expectEqual(@as(usize, 0), held.row(buffer.changed_rows, rows, 0).len);
    try testing.expectEqual(@as(usize, 0), held.row(buffer.changed_rows, rows, 1).len);
    const moved = held.row(buffer.changed_rows, rows, 2);
    try testing.expectEqual(@as(usize, 1), moved.len);
    try testing.expectEqual(syntax.Tagged{ .start = 0, .end = 2, .kind = .field }, moved[0]);
    try testing.expectEqual(Change{ .answered = true }, try client.receive(gpa, framed(
        \\{"jsonrpc":"2.0","id":4,"result":null}
    )));
    // An error answer frees the lane and decodes to none.
    try client.requestTokens(gpa, io, 7, 0, 1, 3);
    try testing.expectEqual(Change{ .tokens = true }, try client.receive(gpa, framed(
        \\{"jsonrpc":"2.0","id":5,"error":{"code":-32801,"message":"content modified"}}
    )));
    try testing.expectEqual(null, try client.tokens(gpa, &buffer));
}

test "a token answer is dropped once a newer version or another document was sent" {
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    client.capabilities = test_capabilities;
    const gpa = testing.allocator;
    const io = testing.io;
    var buffer = try Buffer.fromBytes(gpa, "ab\n");
    defer buffer.deinit(gpa);
    _ = try client.sync(gpa, io, 7, "/p/a.zig", &buffer);
    const reply = "\"result\":{\"data\":[0,0,2,0,0]}}";
    // Newer text sent after the request.
    try client.requestTokens(gpa, io, 7, 0, 1, 2);
    try buffer.replace(gpa, .{ .start = 0, .end = 0 }, "x", 1);
    _ = try client.sync(gpa, io, 7, "/p/a.zig", &buffer);
    const newer = framed("{\"jsonrpc\":\"2.0\",\"id\":2," ++ reply);
    try testing.expectEqual(Change{ .tokens = true }, try client.receive(gpa, newer));
    try testing.expectEqual(null, client.token_answered);
    try testing.expectEqual(null, try client.tokens(gpa, &buffer));
    // Closed, then opened again under the same key at the same version.
    try client.requestTokens(gpa, io, 7, 0, 1, 2);
    try client.forget(gpa, io, 0);
    _ = try client.sync(gpa, io, 7, "/p/b.zig", &buffer);
    const reopened = framed("{\"jsonrpc\":\"2.0\",\"id\":3," ++ reply);
    try testing.expectEqual(Change{ .tokens = true }, try client.receive(gpa, reopened));
    try testing.expectEqual(null, client.token_answered);
    // The same document at the same version keeps its answer.
    try client.requestTokens(gpa, io, 7, 0, 1, 2);
    const kept = framed("{\"jsonrpc\":\"2.0\",\"id\":4," ++ reply);
    try testing.expectEqual(Change{ .tokens = true }, try client.receive(gpa, kept));
    var held = (try client.tokens(gpa, &buffer)).?;
    defer held.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), held.tokens.items.len);
}

test "decoding a token answer that runs out of memory gives it up and frees the set" {
    const Case = struct {
        fn run(gpa: Allocator) !void {
            var client: Client = .{ .server = &servers[0] };
            defer client.deinit(gpa, testing.io);
            client.capabilities = test_capabilities;
            var buffer = try Buffer.fromBytes(gpa, "ab cd\nef\n");
            defer buffer.deinit(gpa);
            _ = try client.sync(gpa, testing.io, 7, "/p/a.zig", &buffer);
            try client.requestTokens(gpa, testing.io, 7, 0, 3, 3);
            const change = try client.receive(gpa, framed(
                \\{"jsonrpc":"2.0","id":2,"result":{"data":[0,0,2,0,0,0,3,2,0,0,1,0,2,1,0]}}
            ));
            try testing.expect(change.tokens);
            // Keeping the answer gives it up without memory, quietly.
            if (client.token_answered == null) return error.OutOfMemory;
            var held = (client.tokens(gpa, &buffer) catch |err| {
                try testing.expectEqual(null, client.token_answered);
                return err;
            }) orelse return;
            held.deinit(gpa);
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
        seen.tokens = seen.tokens or change.tokens;
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

fn isTokens(change: Change) bool {
    return change.tokens;
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
    var buffer = try Buffer.fromBytes(testing.allocator, Project.a);
    defer buffer.deinit(testing.allocator);
    _ = try client.sync(testing.allocator, testing.io, 0, a, &buffer);
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
    // The declaration in the other file, then both calls.
    const references = client.answer.?.locations;
    try testing.expectEqual(@as(usize, 3), references.len);
    try testing.expectEqualStrings(b, references[0].path.?);
    try testing.expectEqual(Position{ .line = 0, .character = 7 }, references[0].at);
    for (references[1..], [_]u32{ 2, 3 }) |reference, line| {
        try testing.expectEqualStrings(a, reference.path.?);
        try testing.expectEqual(Position{ .line = line, .character = 6 }, reference.at);
    }
}

test "zls follows changed lines, and answers tokens for a range of them" {
    var project: Project = undefined;
    try project.init();
    defer project.temp.cleanup();
    var client: Client = .{ .server = &servers[0] };
    defer client.deinit(testing.allocator, testing.io);
    try startZls(&client, &project);
    try testing.expect(client.capabilities.?.incremental);
    try testing.expect(client.capabilities.?.legend != null);
    const gpa = testing.allocator;
    const io = testing.io;
    var a_storage: [4096]u8 = undefined;
    var b_storage: [4096]u8 = undefined;
    const a = try project.path("a.zig", &a_storage);
    const b = try project.path("b.zig", &b_storage);
    var buffer = try Buffer.fromBytes(gpa, Project.a);
    defer buffer.deinit(gpa);
    _ = try client.sync(gpa, io, 0, a, &buffer);
    // Two lines added above the first call, synced apart; then the second
    // call removed, with the text's last line, and synced.
    const second = buffer.lineStart(3);
    try buffer.replace(gpa, .{ .start = second, .end = buffer.bytes().len }, "}", second);
    try buffer.replace(gpa, .{ .start = buffer.lineStart(2), .end = buffer.lineStart(2) }, "    // one\n", 0);
    _ = try client.sync(gpa, io, 0, a, &buffer);
    try buffer.replace(gpa, .{ .start = buffer.lineStart(3), .end = buffer.lineStart(3) }, "    // two\n", 0);
    _ = try client.sync(gpa, io, 0, a, &buffer);
    try testing.expectEqualStrings(
        \\const b = @import("b.zig");
        \\pub fn main() void {
        \\    // one
        \\    // two
        \\    b.target();
        \\}
    , buffer.bytes());
    const call: Position = .{ .line = 4, .character = 6 };
    try client.navigate(gpa, io, .definition, a, call);
    _ = try settle(&client, isAnswered);
    const definition = client.answer.?.locations;
    try testing.expectEqual(@as(usize, 1), definition.len);
    try testing.expectEqualStrings(b, definition[0].path.?);
    const rows = buffer.insertionRows();
    try client.requestTokens(gpa, io, 0, 1, rows, rows);
    _ = try settle(&client, isTokens);
    var held = (try client.tokens(gpa, &buffer)).?;
    defer held.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), held.top);
    try testing.expectEqual(rows - 1, held.ends.items.len);
    // `main` and `target` are functions, the comments comments.
    const expected = [_]struct { usize, []const u8, syntax.Kind }{
        .{ 1, "main", .function },
        .{ 2, "// one", .comment },
        .{ 4, "target", .function },
    };
    for (expected) |case| {
        const line = buffer.line(case[0]);
        const found = for (held.row(buffer.changed_rows, rows, case[0])) |token| {
            if (std.mem.eql(u8, line[token.start..token.end], case[1])) break token;
        } else return error.TestExpectedToken;
        try testing.expectEqual(@as(?syntax.Kind, case[2]), found.kind);
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
    var buffer = try Buffer.fromBytes(testing.allocator, Project.a);
    defer buffer.deinit(testing.allocator);
    _ = try client.sync(testing.allocator, testing.io, 0, a, &buffer);
    const call: Position = .{ .line = 2, .character = 6 };
    try client.navigate(testing.allocator, testing.io, .definition, a, call);
    try client.requestTokens(testing.allocator, testing.io, 0, 0, 1, buffer.insertionRows());
    _ = linux.kill(-client.state.running.id.?, .KILL);
    _ = try settle(&client, isExited);
    try testing.expect(client.state == .exited);
    try testing.expectEqual(null, client.pending);
    try testing.expectEqual(null, client.token_request);
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
    var buffer = try Buffer.fromBytes(testing.allocator, &text);
    defer buffer.deinit(testing.allocator);
    _ = try client.sync(testing.allocator, testing.io, 0, "/p/a.zig", &buffer);
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
