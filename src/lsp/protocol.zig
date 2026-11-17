// SPDX-License-Identifier: MIT OR Apache-2.0
//! The language-server protocol
const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const position = @import("position.zig");
const Encoding = position.Encoding;
const Position = position.Position;

pub const Error = Allocator.Error || error{
    HeaderTooLong,
    MalformedHeader,
    MessageTooLarge,
    MalformedMessage,
    UnsupportedEncoding,
};

/// Bounds on one incoming message.
pub const max_header_bytes = 1024;
pub const max_body_bytes = 16 * 1024 * 1024;

/// The navigation requests Nib makes.
pub const Navigation = enum {
    definition,
    declaration,
    type_definition,
    implementation,
    references,

    fn method(navigation: Navigation) []const u8 {
        return switch (navigation) {
            .definition => "textDocument/definition",
            .declaration => "textDocument/declaration",
            .type_definition => "textDocument/typeDefinition",
            .implementation => "textDocument/implementation",
            .references => "textDocument/references",
        };
    }
};

/// Collects a server's output and splits it into message bodies.
pub const Reader = struct {
    pending: std.ArrayList(u8) = .empty,
    /// Bytes before this offset belong to messages already returned.
    start: usize = 0,

    pub fn deinit(self: *Reader, gpa: Allocator) void {
        self.pending.deinit(gpa);
        self.* = undefined;
    }

    /// Adds bytes read from the server. Invalidates bodies returned by `next`.
    pub fn append(self: *Reader, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        const unread = self.pending.items.len - self.start;
        std.mem.copyForwards(u8, self.pending.items[0..unread], self.pending.items[self.start..]);
        self.pending.items.len = unread;
        self.start = 0;
        try self.pending.appendSlice(gpa, bytes);
    }

    /// The next complete message body, or null until more bytes arrive. The
    /// body is valid until the next `append`. After an error the stream is
    /// unusable.
    pub fn next(self: *Reader) Error!?[]const u8 {
        const unread = self.pending.items[self.start..];
        const header_end = std.mem.indexOf(u8, unread, "\r\n\r\n") orelse {
            if (unread.len > max_header_bytes) return error.HeaderTooLong;
            return null;
        };
        if (header_end + 4 > max_header_bytes) return error.HeaderTooLong;
        const length = try contentLength(unread[0..header_end]);
        if (length > max_body_bytes) return error.MessageTooLarge;
        const body_start = header_end + 4;
        if (unread.len - body_start < length) return null;
        self.start += body_start + length;
        return unread[body_start..][0..length];
    }
};

/// The value of the one required `Content-Length` field. Other fields, such
/// as `Content-Type`, are ignored.
fn contentLength(header: []const u8) Error!usize {
    var length: ?usize = null;
    var fields = std.mem.splitSequence(u8, header, "\r\n");
    while (fields.next()) |field| {
        const colon = std.mem.indexOfScalar(u8, field, ':') orelse return error.MalformedHeader;
        if (!std.ascii.eqlIgnoreCase(field[0..colon], "Content-Length")) continue;
        if (length != null) return error.MalformedHeader;
        const value = std.mem.trim(u8, field[colon + 1 ..], " \t");
        length = std.fmt.parseUnsigned(usize, value, 10) catch |err| switch (err) {
            error.Overflow => return error.MessageTooLarge,
            error.InvalidCharacter => return error.MalformedHeader,
        };
    }
    return length orelse error.MalformedHeader;
}

/// A local path written as a `file://` URI, percent-encoding every byte
/// except unreserved characters and `/`.
pub const Uri = struct {
    path: []const u8,

    pub fn jsonStringify(self: Uri, writer: *Stringify) Stringify.Error!void {
        try writer.beginWriteRaw();
        try writer.writer.writeAll("\"file://");
        for (self.path) |byte| {
            const unreserved = std.mem.indexOfScalar(u8, "-._~/", byte) != null;
            if (std.ascii.isAlphanumeric(byte) or unreserved) {
                try writer.writer.writeByte(byte);
            } else {
                try writer.writer.print("%{X:0>2}", .{byte});
            }
        }
        try writer.writer.writeByte('"');
        writer.endWriteRaw();
    }
};

/// The local path a `file:///` URI names, percent-decoded and allocated in
/// `arena`, or null for another scheme, a host, a bad escape or a NUL.
pub fn pathFromUri(arena: Allocator, uri: []const u8) Allocator.Error!?[]const u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    const encoded = uri[prefix.len..];
    if (encoded.len == 0 or encoded[0] != '/') return null;
    const path = try arena.alloc(u8, encoded.len);
    var length: usize = 0;
    var index: usize = 0;
    while (index < encoded.len) : (length += 1) {
        if (encoded[index] == '%') {
            if (encoded.len - index < 3) return null;
            const digits = encoded[index + 1 ..][0..2];
            path[length] = std.fmt.parseUnsigned(u8, digits, 16) catch return null;
            index += 3;
        } else {
            path[length] = encoded[index];
            index += 1;
        }
        if (path[length] == 0) return null;
    }
    return path[0..length];
}

// Each writer appends one framed message to `queue`, the bytes waiting to be
// written to the server. On failure the queue is left as it was.

pub fn initialize(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    id: u32,
    process: i32,
    root: []const u8,
) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "initialize",
        .params = .{
            .processId = process,
            // Not `workspaceFolders`: given those, ZLS builds the project in
            // the background.
            .rootUri = Uri{ .path = root },
            .capabilities = .{
                .general = .{ .positionEncodings = [_][]const u8{ "utf-8", "utf-16" } },
            },
        },
    });
}

pub fn initialized(gpa: Allocator, queue: *std.ArrayList(u8)) Allocator.Error!void {
    // An empty tuple would be written as `[]`.
    try frame(gpa, queue, .{ .jsonrpc = "2.0", .method = "initialized", .params = struct {}{} });
}

pub fn didOpen(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    path: []const u8,
    language: []const u8,
    version: u64,
    text: []const u8,
) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didOpen",
        .params = .{ .textDocument = .{
            .uri = Uri{ .path = path },
            .languageId = language,
            .version = version,
            .text = text,
        } },
    });
}

/// Sends the whole text, which servers accept under either sync kind.
pub fn didChange(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    path: []const u8,
    version: u64,
    text: []const u8,
) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = .{
            .textDocument = .{ .uri = Uri{ .path = path }, .version = version },
            .contentChanges = [_]struct { text: []const u8 }{.{ .text = text }},
        },
    });
}

pub fn didClose(gpa: Allocator, queue: *std.ArrayList(u8), path: []const u8) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didClose",
        .params = .{ .textDocument = .{ .uri = Uri{ .path = path } } },
    });
}

/// References leave out the declaration, so the first is a use.
pub fn navigate(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    id: u32,
    navigation: Navigation,
    path: []const u8,
    at: Position,
) Allocator.Error!void {
    const document = .{ .uri = Uri{ .path = path } };
    if (navigation == .references) return frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = navigation.method(),
        .params = .{
            .textDocument = document,
            .position = at,
            .context = .{ .includeDeclaration = false },
        },
    });
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = navigation.method(),
        .params = .{ .textDocument = document, .position = at },
    });
}

pub fn cancel(gpa: Allocator, queue: *std.ArrayList(u8), id: u32) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "$/cancelRequest",
        .params = .{ .id = id },
    });
}

/// Answers a request from the server, whose `id` is echoed as received, with
/// "method not found": Nib offers the server no requests.
pub fn refuse(gpa: Allocator, queue: *std.ArrayList(u8), id: std.json.Value) Allocator.Error!void {
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .@"error" = .{ .code = -32601, .message = "Method not found" },
    });
}

/// Appends `message` as JSON behind its header. The body is written first
/// and the header inserted before it, which moves the body once.
fn frame(gpa: Allocator, queue: *std.ArrayList(u8), message: anytype) Allocator.Error!void {
    const start = queue.items.len;
    errdefer queue.shrinkRetainingCapacity(start);
    // The writer holds the queue's memory until it gives it back.
    var output: std.Io.Writer.Allocating = .fromArrayList(gpa, queue);
    const written = Stringify.value(message, .{}, &output.writer);
    queue.* = output.toArrayList();
    // Writing into growing memory fails only when allocation does.
    written catch return error.OutOfMemory;
    var header: [64]u8 = undefined;
    const length = queue.items.len - start;
    const format = "Content-Length: {d}\r\n\r\n";
    const text = std.fmt.bufPrint(&header, format, .{length}) catch unreachable;
    try queue.insertSlice(gpa, start, text);
}

/// What one incoming message is, by its `id` and `method`.
pub const Message = union(enum) {
    /// A reply to Nib's request; the id is null unless it is one Nib could
    /// have sent.
    response: ?u32,
    /// A request from the server, to be answered with `refuse`. The id is
    /// allocated in the arena given to `classify`.
    request: std.json.Value,
    notification,
};

/// Classifies one body from `Reader.next`, allocating in `arena`.
pub fn classify(arena: Allocator, body: []const u8) Error!Message {
    const Envelope = struct { id: ?std.json.Value = null, method: ?[]const u8 = null };
    const envelope = try parse(Envelope, arena, body);
    const id = envelope.id orelse {
        return if (envelope.method != null) .notification else error.MalformedMessage;
    };
    if (envelope.method != null) return .{ .request = id };
    return .{ .response = switch (id) {
        .integer => |number| std.math.cast(u32, number),
        else => null,
    } };
}

/// What a server offers, from its initialize reply.
pub const Capabilities = struct {
    encoding: Encoding,
    offers: std.EnumSet(Navigation),
};

/// The reply to `initialize`, or a server error's message.
pub const Initialized = union(enum) { capabilities: Capabilities, failed: []const u8 };

/// Decodes the reply to `initialize`, allocating in `arena`. A server that
/// names no position encoding uses UTF-16, the protocol's default.
pub fn initializeReply(arena: Allocator, body: []const u8) Error!Initialized {
    const Offered = struct {
        positionEncoding: ?[]const u8 = null,
        definitionProvider: Provider = .{},
        declarationProvider: Provider = .{},
        typeDefinitionProvider: Provider = .{},
        implementationProvider: Provider = .{},
        referencesProvider: Provider = .{},
    };
    const Reply = struct {
        result: ?struct { capabilities: Offered } = null,
        @"error": ?Failure = null,
    };
    const reply = try parse(Reply, arena, body);
    if (reply.@"error") |failure| return .{ .failed = failure.message };
    const offered = (reply.result orelse return error.MalformedMessage).capabilities;
    const name = offered.positionEncoding orelse "utf-16";
    const encoding: Encoding = if (std.mem.eql(u8, name, "utf-8"))
        .utf8
    else if (std.mem.eql(u8, name, "utf-16"))
        .utf16
    else
        return error.UnsupportedEncoding;
    const offers: std.EnumSet(Navigation) = .init(.{
        .definition = offered.definitionProvider.offered,
        .declaration = offered.declarationProvider.offered,
        .type_definition = offered.typeDefinitionProvider.offered,
        .implementation = offered.implementationProvider.offered,
        .references = offered.referencesProvider.offered,
    });
    return .{ .capabilities = .{ .encoding = encoding, .offers = offers } };
}

/// Where a navigation answer points. `path` is null for a URI that names no
/// local file.
pub const Location = struct { path: ?[]const u8, at: Position };

/// The reply to a navigation request, or a server error's message.
pub const Answer = union(enum) { locations: []const Location, failed: []const u8 };

/// Decodes the reply to `navigate`: null, a `Location`, or an array of
/// `Location` or `LocationLink`, in the server's order. Allocates in `arena`.
pub fn navigationReply(arena: Allocator, body: []const u8) Error!Answer {
    const Reply = struct { result: ?Items = null, @"error": ?Failure = null };
    const reply = try parse(Reply, arena, body);
    if (reply.@"error") |failure| return .{ .failed = failure.message };
    const items = if (reply.result) |result| result.items else &.{};
    const locations = try arena.alloc(Location, items.len);
    for (items, locations) |item, *location| {
        const uri = item.targetUri orelse item.uri orelse return error.MalformedMessage;
        const range = if (item.targetUri != null) item.targetSelectionRange else item.range;
        location.* = .{
            .path = try pathFromUri(arena, uri),
            .at = (range orelse return error.MalformedMessage).start,
        };
    }
    return .{ .locations = locations };
}

const Failure = struct { message: []const u8 = "" };

/// A capability that is offered when true or given as an options object.
const Provider = struct {
    offered: bool = false,

    pub fn jsonParse(arena: Allocator, source: anytype, options: std.json.ParseOptions) !Provider {
        switch (try source.peekNextTokenType()) {
            .true, .false => {
                return .{ .offered = try std.json.innerParse(bool, arena, source, options) };
            },
            .null => {
                _ = try source.next();
                return .{};
            },
            .object_begin => {
                try source.skipValue();
                return .{ .offered = true };
            },
            else => return error.UnexpectedToken,
        }
    }
};

/// One `Location` (`uri`, `range`) or `LocationLink` (`targetUri`,
/// `targetSelectionRange`).
const Item = struct {
    uri: ?[]const u8 = null,
    range: ?Range = null,
    targetUri: ?[]const u8 = null,
    targetSelectionRange: ?Range = null,
};

const Range = struct { start: Position, end: Position };

/// A navigation result: one item or an array of them.
const Items = struct {
    items: []const Item,

    pub fn jsonParse(arena: Allocator, source: anytype, options: std.json.ParseOptions) !Items {
        switch (try source.peekNextTokenType()) {
            .object_begin => {
                const items = try arena.alloc(Item, 1);
                items[0] = try std.json.innerParse(Item, arena, source, options);
                return .{ .items = items };
            },
            .array_begin => {
                return .{ .items = try std.json.innerParse([]const Item, arena, source, options) };
            },
            else => return error.UnexpectedToken,
        }
    }
};

fn parse(comptime T: type, arena: Allocator, body: []const u8) Error!T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.MalformedMessage,
    };
}

const testing = std.testing;

fn expectNext(reader: *Reader, expected: ?[]const u8) !void {
    const body = try reader.next();
    if (expected) |text| {
        try testing.expectEqualStrings(text, body.?);
    } else try testing.expectEqual(null, body);
}

test "messages split at any byte arrive whole, and several in one read all arrive" {
    const stream = "Content-Length: 2\r\n\r\n{}" ++
        "content-length:  7\r\nContent-Type: x\r\n\r\n[1,2,3]";
    for (0..stream.len + 1) |split| {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        var bodies: [2][]const u8 = undefined;
        var count: usize = 0;
        for ([_][]const u8{ stream[0..split], stream[split..] }) |part| {
            try reader.append(testing.allocator, part);
            while (try reader.next()) |body| : (count += 1) {
                // Copied: a body lasts only until the next append.
                bodies[count] = try testing.allocator.dupe(u8, body);
            }
        }
        defer for (bodies[0..count]) |body| testing.allocator.free(body);
        try testing.expectEqual(@as(usize, 2), count);
        try testing.expectEqualStrings("{}", bodies[0]);
        try testing.expectEqualStrings("[1,2,3]", bodies[1]);
    }
    // One byte at a time.
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    for (stream[0 .. stream.len - 1]) |byte| {
        try reader.append(testing.allocator, &.{byte});
        if (try reader.next()) |body| try testing.expectEqualStrings("{}", body);
    }
    try reader.append(testing.allocator, stream[stream.len - 1 ..]);
    try expectNext(&reader, "[1,2,3]");
    try expectNext(&reader, null);
}

test "headers over the bound, bodies over the bound and malformed headers are refused" {
    const padding: [max_header_bytes]u8 = @splat('y');
    const overflow = "99999999999999999999999";
    const cases = [_]struct { stream: []const u8, err: Error }{
        .{
            .stream = "Content-Length: 1\r\nX: " ++ &padding ++ "\r\n\r\n{",
            .err = error.HeaderTooLong,
        },
        .{ .stream = "X-Padding: " ++ &padding, .err = error.HeaderTooLong },
        .{ .stream = "Content-Length: 16777217\r\n\r\n", .err = error.MessageTooLarge },
        .{ .stream = "Content-Length: " ++ overflow ++ "\r\n\r\n", .err = error.MessageTooLarge },
        .{ .stream = "Content-Type: x\r\n\r\n{}", .err = error.MalformedHeader },
        .{ .stream = "Content-Length: 2x\r\n\r\n{}", .err = error.MalformedHeader },
        .{ .stream = "Content-Length: -2\r\n\r\n{}", .err = error.MalformedHeader },
        .{ .stream = "Content-Length 2\r\n\r\n{}", .err = error.MalformedHeader },
        .{
            .stream = "Content-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
            .err = error.MalformedHeader,
        },
    };
    for (cases) |case| {
        var reader: Reader = .{};
        defer reader.deinit(testing.allocator);
        try reader.append(testing.allocator, case.stream);
        try testing.expectError(case.err, reader.next());
    }
    // A body at the bound is waited for, not refused.
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.append(testing.allocator, "Content-Length: 16777216\r\n\r\n");
    try expectNext(&reader, null);
}

fn expectFramed(queue: []const u8, body: []const u8) !void {
    var reader: Reader = .{};
    defer reader.deinit(testing.allocator);
    try reader.append(testing.allocator, queue);
    try expectNext(&reader, body);
    try expectNext(&reader, null);
}

test "messages are framed with their byte length and URIs are percent-encoded" {
    var queue: std.ArrayList(u8) = .empty;
    defer queue.deinit(testing.allocator);
    try didOpen(testing.allocator, &queue, "/tmp/a b/é%.zig", "zig", 3, "x\t\"é\"\n");
    try expectFramed(queue.items,
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///tmp/a%20b/%C3%A9%25.zig","languageId":"zig","version":3,"text":"x\t\"é\"\n"}}}
    );
    // Bytes, not characters: each "é" counts two.
    try testing.expect(std.mem.startsWith(u8, queue.items, "Content-Length: 169\r\n\r\n"));
}

test "each message Nib sends has the expected shape" {
    const at: Position = .{ .line = 4, .character = 2 };
    const Write = *const fn (*std.ArrayList(u8)) Allocator.Error!void;
    const cases = [_]struct { body: []const u8, write: Write }{
        .{
            .body =
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":42,"rootUri":"file:///p","capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]}}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try initialize(testing.allocator, queue, 1, 42, "/p");
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","method":"initialized","params":{}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try initialized(testing.allocator, queue);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":9},"contentChanges":[{"text":"all"}]}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try didChange(testing.allocator, queue, "/p/a.zig", 9, "all");
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///p/a.zig"}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try didClose(testing.allocator, queue, "/p/a.zig");
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":7,"method":"textDocument/typeDefinition","params":{"textDocument":{"uri":"file:///p/a.zig"},"position":{"line":4,"character":2}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try navigate(testing.allocator, queue, 7, .type_definition, "/p/a.zig", at);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":8,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///p/a.zig"},"position":{"line":4,"character":2},"context":{"includeDeclaration":false}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try navigate(testing.allocator, queue, 8, .references, "/p/a.zig", at);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":8}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try cancel(testing.allocator, queue, 8);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":"register-1","error":{"code":-32601,"message":"Method not found"}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try refuse(testing.allocator, queue, .{ .string = "register-1" });
                }
            }.write,
        },
    };
    for (cases) |case| {
        var queue: std.ArrayList(u8) = .empty;
        defer queue.deinit(testing.allocator);
        try case.write(&queue);
        try expectFramed(queue.items, case.body);
    }
}

test "a message that runs out of memory leaves the queue as it was" {
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(allocator: Allocator) !void {
            const text: [300]u8 = @splat('x');
            var queue: std.ArrayList(u8) = .empty;
            defer queue.deinit(allocator);
            try queue.appendSlice(allocator, "earlier");
            didChange(allocator, &queue, "/p/a.zig", 2, &text) catch |err| {
                try testing.expectEqualStrings("earlier", queue.items);
                return err;
            };
            try testing.expect(std.mem.startsWith(u8, queue.items, "earlierContent-Length: "));
        }
    }.run, .{});
}

test "file URIs decode to paths; other schemes, hosts, bad escapes and NUL don't" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const decoded = try pathFromUri(gpa, "file:///tmp/a%20b/%c3%A9.zig");
    try testing.expectEqualStrings("/tmp/a b/é.zig", decoded.?);
    try testing.expectEqualStrings("/x+y", (try pathFromUri(gpa, "file:///x+y")).?);
    for ([_][]const u8{
        "untitled:Untitled-1",
        "file://host/x",
        "file://",
        "file:///x%2",
        "file:///x%zz",
        "file:///x%00y",
        "zls:/builtin.zig",
    }) |uri| try testing.expectEqual(null, try pathFromUri(gpa, uri));
}

test "incoming messages are told apart by id and method" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const ours = try classify(gpa, "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":null}");
    try testing.expectEqual(Message{ .response = 3 }, ours);
    for ([_][]const u8{ "{\"id\":\"x\",\"result\":[]}", "{\"id\":-1,\"result\":[]}" }) |body| {
        try testing.expectEqual(Message{ .response = null }, try classify(gpa, body));
    }
    try testing.expectEqual(Message.notification, try classify(gpa,
        \\{"jsonrpc":"2.0","method":"window/logMessage","params":{"type":3,"message":"hi"}}
    ));
    const request = try classify(gpa,
        \\{"jsonrpc":"2.0","id":"register-1","method":"client/registerCapability","params":{}}
    );
    try testing.expectEqualStrings("register-1", request.request.string);
    const malformed = [_][]const u8{
        "{\"result\":null}",
        "{",
        "[]",
        "{\"id\":1,\"method\":7}",
        "\xff",
    };
    for (malformed) |body| {
        try testing.expectError(error.MalformedMessage, classify(gpa, body));
    }
}

test "initialize replies give the position encoding and the offered navigation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // As ZLS 0.17.0 answers, abridged.
    const zls = try initializeReply(gpa,
        \\{"jsonrpc":"2.0","id":1,"result":{"capabilities":{"positionEncoding":"utf-8","textDocumentSync":{"openClose":true,"change":2},"definitionProvider":true,"declarationProvider":true,"typeDefinitionProvider":true,"implementationProvider":false,"referencesProvider":true},"serverInfo":{"name":"zls"}}}
    );
    try testing.expectEqual(Encoding.utf8, zls.capabilities.encoding);
    try testing.expect(zls.capabilities.offers.contains(.definition));
    try testing.expect(!zls.capabilities.offers.contains(.implementation));
    try testing.expect(zls.capabilities.offers.contains(.references));
    // As slangd 1.8 answers, abridged: UTF-16 by name, definitions as options.
    const slangd = try initializeReply(gpa,
        \\{"id":1,"result":{"capabilities":{"positionEncoding":"utf-16","definitionProvider":{"workDoneProgress":false},"declarationProvider":null}}}
    );
    try testing.expectEqual(Encoding.utf16, slangd.capabilities.encoding);
    try testing.expect(slangd.capabilities.offers.eql(.initOne(.definition)));
    const unnamed = try initializeReply(gpa, "{\"id\":1,\"result\":{\"capabilities\":{}}}");
    try testing.expectEqual(Encoding.utf16, unnamed.capabilities.encoding);
    try testing.expect(unnamed.capabilities.offers.eql(.empty));
    const failed = try initializeReply(gpa,
        \\{"id":1,"error":{"code":-32603,"message":"no root"}}
    );
    try testing.expectEqualStrings("no root", failed.failed);
    try testing.expectError(error.UnsupportedEncoding, initializeReply(gpa,
        \\{"id":1,"result":{"capabilities":{"positionEncoding":"utf-32"}}}
    ));
    try testing.expectError(error.MalformedMessage, initializeReply(gpa, "{\"id\":1}"));
    try testing.expectError(error.MalformedMessage, initializeReply(gpa,
        \\{"id":1,"result":{"capabilities":{"definitionProvider":1}}}
    ));
}

test "navigation replies decode Location, LocationLink, arrays and null in order" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const single = try navigationReply(gpa,
        \\{"id":2,"result":{"uri":"file:///p/b.zig","range":{"start":{"line":0,"character":7},"end":{"line":0,"character":13}}}}
    );
    try testing.expectEqual(@as(usize, 1), single.locations.len);
    try testing.expectEqualStrings("/p/b.zig", single.locations[0].path.?);
    try testing.expectEqual(Position{ .line = 0, .character = 7 }, single.locations[0].at);
    const many = try navigationReply(gpa,
        \\{"id":3,"result":[
        \\ {"uri":"file:///p/a.zig","range":{"start":{"line":4,"character":1},"end":{"line":4,"character":2}}},
        \\ {"uri":"untitled:x","range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}}}]}
    );
    try testing.expectEqual(@as(usize, 2), many.locations.len);
    try testing.expectEqualStrings("/p/a.zig", many.locations[0].path.?);
    try testing.expectEqual(null, many.locations[1].path);
    // Links point at the target's selection, not its whole range.
    const links = try navigationReply(gpa,
        \\{"id":4,"result":[{"originSelectionRange":{"start":{"line":9,"character":9},"end":{"line":9,"character":9}},
        \\ "targetUri":"file:///p/c.zig","targetRange":{"start":{"line":1,"character":0},"end":{"line":5,"character":0}},
        \\ "targetSelectionRange":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}}}]}
    );
    try testing.expectEqualStrings("/p/c.zig", links.locations[0].path.?);
    try testing.expectEqual(Position{ .line = 2, .character = 4 }, links.locations[0].at);
    const empty = [_][]const u8{
        "{\"id\":5,\"result\":null}",
        "{\"id\":5,\"result\":[]}",
        "{\"id\":5}",
    };
    for (empty) |body| {
        try testing.expectEqual(@as(usize, 0), (try navigationReply(gpa, body)).locations.len);
    }
    const failed = try navigationReply(gpa,
        \\{"id":6,"error":{"code":-32800,"message":"cancelled"}}
    );
    try testing.expectEqualStrings("cancelled", failed.failed);
    for ([_][]const u8{
        "{\"id\":7,\"result\":[{\"uri\":\"file:///p\"}]}",
        \\{"id":7,"result":[{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":0}}}]}
        ,
        \\{"id":7,"result":[{"uri":"file:///p","range":{"start":{"line":-1,"character":0},"end":{"line":0,"character":0}}}]}
        ,
        "{\"id\":7,\"result\":7}",
        "{\"id\":7,\"result\":[",
    }) |body| try testing.expectError(error.MalformedMessage, navigationReply(gpa, body));
}
