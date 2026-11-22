// SPDX-License-Identifier: MIT OR Apache-2.0
//! The language-server protocol
const std = @import("std");
const Allocator = std.mem.Allocator;
const Stringify = std.json.Stringify;
const position = @import("position.zig");
const Encoding = position.Encoding;
const Position = position.Position;
const Buffer = @import("../text/buffer.zig").Buffer;
const ChangedRows = @import("../text/buffer.zig").ChangedRows;
const syntax = @import("../text/syntax.zig");

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
        // Moving only after a message was taken keeps a long message linear.
        if (self.start != 0) {
            const unread = self.pending.items.len - self.start;
            std.mem.copyForwards(u8, self.pending.items[0..unread], self.pending.items[self.start..]);
            self.pending.items.len = unread;
            self.start = 0;
        }
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
                .textDocument = .{ .semanticTokens = .{
                    .requests = .{ .range = true, .full = false },
                    .tokenTypes = token_names,
                    .tokenModifiers = [_][]const u8{},
                    .formats = [_][]const u8{"relative"},
                } },
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

/// Replaces whole lines of the text a server has, or the whole text when
/// `range` is null.
pub const TextChange = struct { range: ?Range, text: []const u8 };

/// A character past any line's end, which a server takes as the line's end:
/// the largest integer every JSON-RPC server accepts.
pub const line_end: u32 = std.math.maxInt(i32);

/// The change that turns the text a server last had into `buffer`'s, where
/// `changed` is the buffer's record since then, or null when nothing changed.
/// The lines named start at column 0 and end at the start of the first line
/// after them, or past the end of the old last line. Borrows the buffer's
/// bytes until it changes.
pub fn textChange(buffer: *const Buffer, changed: ChangedRows) ?TextChange {
    const lines = switch (changed) {
        .none => return null,
        .whole => return .{ .range = null, .text = buffer.bytes() },
        .lines => |lines| lines,
    };
    const rows = buffer.insertionRows();
    const end: Position = if (lines.unchanged == 0)
        .{ .line = @intCast(lines.rows - 1), .character = line_end }
    else
        .{ .line = @intCast(lines.rows - lines.unchanged), .character = 0 };
    const text_end = if (lines.unchanged == 0)
        buffer.bytes().len
    else
        buffer.lineStart(rows - lines.unchanged);
    return .{
        .range = .{ .start = .{ .line = @intCast(lines.first), .character = 0 }, .end = end },
        .text = buffer.bytes()[buffer.lineStart(lines.first)..text_end],
    };
}

/// Sends one change; servers accept a whole text under either sync kind and
/// a range under incremental sync.
pub fn didChange(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    path: []const u8,
    version: u64,
    change: TextChange,
) Allocator.Error!void {
    const document = .{ .uri = Uri{ .path = path }, .version = version };
    if (change.range) |range| return frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = .{
            .textDocument = document,
            .contentChanges = [_]struct { range: Range, text: []const u8 }{
                .{ .range = range, .text = change.text },
            },
        },
    });
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .method = "textDocument/didChange",
        .params = .{
            .textDocument = document,
            .contentChanges = [_]struct { text: []const u8 }{.{ .text = change.text }},
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
            .context = .{ .includeDeclaration = true },
        },
    });
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = navigation.method(),
        .params = .{ .textDocument = document, .position = at },
    });
}

/// Asks for the tokens of rows `top` up to `bottom` of a text with `rows`
/// rows, ending past the last line's end when `bottom` is `rows`.
pub fn semanticTokens(
    gpa: Allocator,
    queue: *std.ArrayList(u8),
    id: u32,
    path: []const u8,
    top: usize,
    bottom: usize,
    rows: usize,
) Allocator.Error!void {
    std.debug.assert(top < bottom and bottom <= rows);
    const end: Position = if (bottom < rows)
        .{ .line = @intCast(bottom), .character = 0 }
    else
        .{ .line = @intCast(rows - 1), .character = line_end };
    try frame(gpa, queue, .{
        .jsonrpc = "2.0",
        .id = id,
        .method = "textDocument/semanticTokens/range",
        .params = .{
            .textDocument = .{ .uri = Uri{ .path = path } },
            .range = Range{ .start = .{ .line = @intCast(top), .character = 0 }, .end = end },
        },
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
    /// How its token types draw, when it offers tokens for a range of rows.
    legend: ?Legend = null,
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
        semanticTokensProvider: ?std.json.Value = null,
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
    const legend = if (offered.semanticTokensProvider) |tokens| offeredLegend(tokens) else null;
    return .{ .capabilities = .{ .encoding = encoding, .offers = offers, .legend = legend } };
}

/// The legend of a `semanticTokensProvider` that offers ranges, or null for
/// any other value: tokens are optional, so an odd one costs only them.
fn offeredLegend(provider: std.json.Value) ?Legend {
    if (provider != .object) return null;
    const range = provider.object.get("range") orelse return null;
    if (range != .object and !(range == .bool and range.bool)) return null;
    const legend = provider.object.get("legend") orelse return null;
    if (legend != .object) return null;
    const types = legend.object.get("tokenTypes") orelse return null;
    if (types != .array) return null;
    var names: [Legend.max_kinds][]const u8 = undefined;
    const count = @min(types.array.items.len, names.len);
    for (types.array.items[0..count], names[0..count]) |value, *name| {
        name.* = if (value == .string) value.string else "";
    }
    return .init(names[0..count]);
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

/// How a server's token types draw: the kind of each, by its index in the
/// server's legend. Types past `max_kinds`, and unknown ones, draw plain.
pub const Legend = struct {
    kinds: [max_kinds]?syntax.Kind = @splat(null),

    pub const max_kinds = 64;

    fn init(names: []const []const u8) Legend {
        var legend: Legend = .{};
        const count = @min(names.len, max_kinds);
        for (names[0..count], legend.kinds[0..count]) |name, *slot| {
            slot.* = token_kinds.get(name) orelse null;
        }
        return legend;
    }

    fn kind(self: *const Legend, index: u32) ?syntax.Kind {
        return if (index < max_kinds) self.kinds[index] else null;
    }
};

/// The token types Nib knows, by their protocol names, and how each draws:
/// the standard ones and ZLS's own. The rest draw plain.
const token_kinds: std.StaticStringMap(?syntax.Kind) = .initComptime(token_list);
const token_list = [_]struct { []const u8, ?syntax.Kind }{
    .{ "comment", .comment },
    .{ "keyword", .keyword },
    .{ "modifier", .keyword },
    .{ "string", .string },
    .{ "escapeSequence", .string },
    .{ "regexp", .string },
    .{ "number", .constant },
    .{ "keywordLiteral", .constant },
    .{ "enumMember", .constant },
    .{ "errorTag", .constant },
    .{ "builtin", .builtin },
    .{ "macro", .builtin },
    .{ "function", .function },
    .{ "method", .function },
    .{ "namespace", .type },
    .{ "type", .type },
    .{ "class", .type },
    .{ "enum", .type },
    .{ "struct", .type },
    .{ "interface", .type },
    .{ "typeParameter", .type },
    .{ "property", .field },
    .{ "variable", null },
    .{ "parameter", null },
    .{ "operator", null },
    .{ "label", null },
    .{ "event", null },
    .{ "decorator", null },
};
const token_names: [token_list.len][]const u8 = names: {
    var names: [token_list.len][]const u8 = undefined;
    for (token_list, &names) |entry, *name| name.* = entry[0];
    break :names names;
};

/// Decodes a reply to `semanticTokens` for rows `top` up to `bottom` of the
/// text it asked about into a new set, or null for an error or no result.
/// `since` is the buffer's record of the changes since that text: a row
/// changed since gets no tokens, and an unchanged row's columns are found
/// in its text now, which is the same. Tokens outside the rows asked, empty
/// ones, and the parts of one past its line's end or before the token ahead
/// of it are dropped, so every token is on character boundaries, in order
/// and apart. Allocates the set with `gpa`, which the caller then owns, and
/// scratch in `arena`.
pub fn tokensReply(
    gpa: Allocator,
    arena: Allocator,
    body: []const u8,
    legend: *const Legend,
    encoding: Encoding,
    buffer: *const Buffer,
    since: ChangedRows,
    top: usize,
    bottom: usize,
) Error!?syntax.Held {
    var held: syntax.Held = .{ .top = top };
    errdefer held.deinit(gpa);
    var decoder: Decoder = .{
        .gpa = gpa,
        .arena = arena,
        .held = &held,
        .legend = legend,
        .encoding = encoding,
        .buffer = buffer,
        .since = since,
        .bottom = bottom,
    };
    var scanner: std.json.Scanner = .initCompleteInput(arena, body);
    defer scanner.deinit();
    const found = decoder.reply(&scanner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.MalformedMessage,
    };
    if (!found) {
        held.deinit(gpa);
        return null;
    }
    try decoder.fill(bottom);
    return held;
}

/// The state of one `tokensReply`.
const Decoder = struct {
    gpa: Allocator,
    arena: Allocator,
    held: *syntax.Held,
    legend: *const Legend,
    encoding: Encoding,
    buffer: *const Buffer,
    since: ChangedRows,
    bottom: usize,
    /// The last token's line and start, as the relative format counts them.
    line: u64 = 0,
    start: u64 = 0,
    /// The row tokens are being added to, its columns when it is unchanged,
    /// and where its last token ended.
    row: ?usize = null,
    columns: ?position.Columns = null,
    end: usize = 0,

    const Malformed = std.json.Scanner.NextError || std.json.Scanner.AllocError ||
        std.json.Scanner.SkipError ||
        error{UnexpectedToken};

    /// Reads the reply object, returning whether it had a result.
    fn reply(self: *Decoder, scanner: *std.json.Scanner) Malformed!bool {
        if (try scanner.next() != .object_begin) return error.UnexpectedToken;
        var found = false;
        while (try self.key(scanner)) |name| {
            if (std.mem.eql(u8, name, "result")) {
                found = try self.result(scanner);
            } else try scanner.skipValue();
        }
        if (try scanner.next() != .end_of_document) return error.UnexpectedToken;
        return found;
    }

    /// The next member's name, or null at the end of the object.
    fn key(self: *Decoder, scanner: *std.json.Scanner) Malformed!?[]const u8 {
        return switch (try scanner.nextAlloc(self.arena, .alloc_if_needed)) {
            .object_end => null,
            .string, .allocated_string => |name| name,
            else => error.UnexpectedToken,
        };
    }

    /// Reads a result, null or an object whose `data` holds the tokens,
    /// returning whether it was an object.
    fn result(self: *Decoder, scanner: *std.json.Scanner) Malformed!bool {
        switch (try scanner.next()) {
            .null => return false,
            .object_begin => {},
            else => return error.UnexpectedToken,
        }
        while (try self.key(scanner)) |name| {
            if (std.mem.eql(u8, name, "data")) try self.data(scanner) else try scanner.skipValue();
        }
        return true;
    }

    /// Reads the tokens, five integers each.
    fn data(self: *Decoder, scanner: *std.json.Scanner) Malformed!void {
        if (try scanner.next() != .array_begin) return error.UnexpectedToken;
        var token: [5]u32 = undefined;
        var count: usize = 0;
        while (true) {
            const digits = switch (try scanner.next()) {
                .array_end => break,
                .number => |digits| digits,
                else => return error.UnexpectedToken,
            };
            token[count] = std.fmt.parseUnsigned(u32, digits, 10) catch
                return error.UnexpectedToken;
            count += 1;
            if (count == token.len) {
                try self.add(token[0], token[1], token[2], token[3]);
                count = 0;
            }
        }
        if (count != 0) return error.UnexpectedToken;
    }

    /// Adds one token from its line and start deltas, length and type.
    fn add(self: *Decoder, lines: u32, start: u32, length: u32, kind: u32) Allocator.Error!void {
        if (lines != 0) self.start = 0;
        self.line += lines;
        self.start += start;
        const held = self.held;
        if (self.line < held.top or self.line >= self.bottom) return;
        const row: usize = @intCast(self.line);
        if (self.row != row) {
            try self.fill(row);
            self.row = row;
            const now = self.since.after(row, self.buffer.insertionRows());
            self.columns = if (now) |shown| .init(self.buffer.line(shown), self.encoding) else null;
            self.end = 0;
        }
        const columns = &(self.columns orelse return);
        const limit = std.math.maxInt(u32);
        const first: u32 = @intCast(@min(self.start, limit));
        const last: u32 = @intCast(@min(self.start + length, limit));
        const token_start = @max(columns.at(first), self.end);
        const token_end = columns.at(last);
        if (token_end <= token_start) return;
        try held.tokens.append(self.gpa, .{
            .start = token_start,
            .end = token_end,
            .kind = self.legend.kind(kind),
        });
        self.end = token_end;
    }

    /// Ends every row before `row` that has not ended.
    fn fill(self: *Decoder, row: usize) Allocator.Error!void {
        const held = self.held;
        while (held.top + held.ends.items.len < row) {
            try held.ends.append(self.gpa, held.tokens.items.len);
        }
    }
};

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

pub const Range = struct { start: Position, end: Position };

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
const char = @import("../text/char.zig");

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
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"processId":42,"rootUri":"file:///p","capabilities":{"general":{"positionEncodings":["utf-8","utf-16"]},"textDocument":{"semanticTokens":{"requests":{"range":true,"full":false},"tokenTypes":["comment","keyword","modifier","string","escapeSequence","regexp","number","keywordLiteral","enumMember","errorTag","builtin","macro","function","method","namespace","type","class","enum","struct","interface","typeParameter","property","variable","parameter","operator","label","event","decorator"],"tokenModifiers":[],"formats":["relative"]}}}}}
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
                    const change: TextChange = .{ .range = null, .text = "all" };
                    try didChange(testing.allocator, queue, "/p/a.zig", 9, change);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///p/a.zig","version":10},"contentChanges":[{"range":{"start":{"line":1,"character":0},"end":{"line":3,"character":2147483647}},"text":"b\n"}]}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    const range: Range = .{
                        .start = .{ .line = 1, .character = 0 },
                        .end = .{ .line = 3, .character = line_end },
                    };
                    const change: TextChange = .{ .range = range, .text = "b\n" };
                    try didChange(testing.allocator, queue, "/p/a.zig", 10, change);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":11,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///p/a.zig"},"range":{"start":{"line":2,"character":0},"end":{"line":5,"character":0}}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try semanticTokens(testing.allocator, queue, 11, "/p/a.zig", 2, 5, 9);
                }
            }.write,
        },
        .{
            .body =
            \\{"jsonrpc":"2.0","id":12,"method":"textDocument/semanticTokens/range","params":{"textDocument":{"uri":"file:///p/a.zig"},"range":{"start":{"line":0,"character":0},"end":{"line":8,"character":2147483647}}}}
            ,
            .write = struct {
                fn write(queue: *std.ArrayList(u8)) Allocator.Error!void {
                    try semanticTokens(testing.allocator, queue, 12, "/p/a.zig", 0, 9, 9);
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
            \\{"jsonrpc":"2.0","id":8,"method":"textDocument/references","params":{"textDocument":{"uri":"file:///p/a.zig"},"position":{"line":4,"character":2},"context":{"includeDeclaration":true}}}
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
            const change: TextChange = .{ .range = null, .text = &text };
            didChange(allocator, &queue, "/p/a.zig", 2, change) catch |err| {
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

/// The text a server has after applying `change` to `before` by the
/// protocol's rules: a character past a line's end means its end.
fn applied(allocator: Allocator, before: []const u8, change: TextChange) ![]u8 {
    const range = change.range orelse return allocator.dupe(u8, change.text);
    var old = try Buffer.fromBytes(allocator, before);
    defer old.deinit(allocator);
    const start = old.lineStart(range.start.line) +
        position.column(old.line(range.start.line), range.start.character, .utf8);
    const end = old.lineStart(range.end.line) +
        position.column(old.line(range.end.line), range.end.character, .utf8);
    return std.mem.concat(allocator, u8, &.{ before[0..start], change.text, before[end..] });
}

test "the change from a buffer's record turns the server's text into the buffer's" {
    const allocator = testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "first\r\nsecond\n\nthird\r\nlast");
    defer buffer.deinit(allocator);
    // A new buffer's record sends the whole text.
    const whole = textChange(&buffer, buffer.changed_rows).?;
    try testing.expectEqual(null, whole.range);
    try testing.expectEqualStrings(buffer.bytes(), whole.text);
    buffer.changed_rows = .none;
    try testing.expectEqual(null, textChange(&buffer, .none));
    var server = try allocator.dupe(u8, buffer.bytes());
    defer allocator.free(server);
    var random = std.Random.DefaultPrng.init(0x51c3);
    const rng = random.random();
    const replacements = [_][]const u8{ "", "x", "\n", "\r\n", "\n\n", "pasted\r\ntext\n" };
    for (0..2000) |_| {
        switch (rng.uintLessThan(u8, 8)) {
            0 => _ = try buffer.undo(allocator),
            1 => _ = try buffer.redo(allocator),
            2 => buffer.beginGroup(),
            3 => buffer.endGroup(),
            else => {
                const bytes = buffer.bytes();
                var start = rng.uintLessThan(usize, bytes.len + 1);
                var end = start + rng.uintLessThan(usize, @min(bytes.len - start, 12) + 1);
                start = char.start(bytes, start);
                end = char.start(bytes, end);
                const inserted = replacements[rng.uintLessThan(usize, replacements.len)];
                try buffer.replace(allocator, .{ .start = start, .end = end }, inserted, start);
            },
        }
        // Syncs come between some edits, not after each one.
        if (rng.boolean()) continue;
        const change = textChange(&buffer, buffer.changed_rows) orelse {
            try testing.expectEqualStrings(server, buffer.bytes());
            continue;
        };
        const after = try applied(allocator, server, change);
        allocator.free(server);
        server = after;
        try testing.expectEqualStrings(buffer.bytes(), server);
        buffer.changed_rows = .none;
    }
}

test "initialize replies give a legend when tokens are offered for ranges" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    // As ZLS 0.17.0 answers, with its legend.
    const zls = try initializeReply(gpa,
        \\{"id":1,"result":{"capabilities":{"positionEncoding":"utf-8","definitionProvider":true,
        \\"semanticTokensProvider":{"legend":{"tokenTypes":["namespace","type","class","enum",
        \\"interface","struct","typeParameter","parameter","variable","property","enumMember",
        \\"event","function","method","macro","keyword","modifier","comment","string",
        \\"escapeSequence","number","regexp","operator","decorator","errorTag","builtin","label",
        \\"keywordLiteral"],"tokenModifiers":["declaration"]},"range":true,"full":true}}}}
    );
    const legend = zls.capabilities.legend.?;
    try testing.expectEqual(syntax.Kind.type, legend.kind(0).?);
    try testing.expectEqual(null, legend.kind(8));
    try testing.expectEqual(syntax.Kind.field, legend.kind(9).?);
    try testing.expectEqual(syntax.Kind.function, legend.kind(13).?);
    try testing.expectEqual(syntax.Kind.constant, legend.kind(27).?);
    try testing.expectEqual(null, legend.kind(28));
    try testing.expectEqual(null, legend.kind(std.math.maxInt(u32)));
    // By name in any order, unknown names plain, and options as the range.
    const other = try initializeReply(gpa,
        \\{"id":1,"result":{"capabilities":{"semanticTokensProvider":{"range":{},
        \\"legend":{"tokenTypes":["property","mystery",7,"comment"],"tokenModifiers":[]}}}}}
    );
    const ordered = other.capabilities.legend.?;
    try testing.expectEqual(syntax.Kind.field, ordered.kind(0).?);
    try testing.expectEqual(null, ordered.kind(1));
    try testing.expectEqual(null, ordered.kind(2));
    try testing.expectEqual(syntax.Kind.comment, ordered.kind(3).?);
    // No range requests, or an odd provider, costs only the tokens.
    for ([_][]const u8{
        \\{"id":1,"result":{"capabilities":{"definitionProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":[]},"full":true}}}}
        ,
        \\{"id":1,"result":{"capabilities":{"definitionProvider":true,"semanticTokensProvider":{"legend":{"tokenTypes":[]},"range":false}}}}
        ,
        \\{"id":1,"result":{"capabilities":{"definitionProvider":true,"semanticTokensProvider":true}}}
        ,
        \\{"id":1,"result":{"capabilities":{"definitionProvider":true,"semanticTokensProvider":{"range":true,"legend":[]}}}}
        ,
        \\{"id":1,"result":{"capabilities":{"definitionProvider":true}}}
    }) |body| {
        const reply = try initializeReply(gpa, body);
        try testing.expectEqual(null, reply.capabilities.legend);
        try testing.expect(reply.capabilities.offers.contains(.definition));
    }
}

/// ZLS's legend, as far as the tests use it: 0 type, 1 property (a field),
/// 2 function, 3 variable (plain), 4 keyword.
const test_legend: Legend = .init(&.{ "type", "property", "function", "variable", "keyword" });

/// Decodes a UTF-8 answer for the first `bottom` rows of `buffer`'s text,
/// unchanged since it was asked for.
fn unchangedReply(
    gpa: Allocator,
    arena: Allocator,
    body: []const u8,
    buffer: *const Buffer,
    bottom: usize,
) Error!?syntax.Held {
    return tokensReply(gpa, arena, body, &test_legend, .utf8, buffer, .none, 0, bottom);
}

/// Decodes `body` as an answer for rows `top` up to `bottom` of `buffer`'s
/// text, unchanged since, and checks each row's tokens, written as
/// `kind:text` separated by spaces, with `plain` for a null kind and `|`
/// between rows.
fn expectRows(
    expected: []const u8,
    buffer: *const Buffer,
    body: []const u8,
    encoding: Encoding,
    since: ChangedRows,
    top: usize,
    bottom: usize,
) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var held = (try tokensReply(
        testing.allocator,
        arena.allocator(),
        body,
        &test_legend,
        encoding,
        buffer,
        since,
        top,
        bottom,
    )).?;
    defer held.deinit(testing.allocator);
    try testing.expectEqual(top, held.top);
    try testing.expectEqual(bottom - top, held.ends.items.len);
    var written: std.ArrayList(u8) = .empty;
    defer written.deinit(testing.allocator);
    for (top..bottom) |row| {
        if (row != top) try written.append(testing.allocator, '|');
        const now = since.after(row, buffer.insertionRows()) orelse continue;
        const text = buffer.line(now);
        for (held.row(since, buffer.insertionRows(), now), 0..) |token, index| {
            if (index != 0) try written.append(testing.allocator, ' ');
            const name = if (token.kind) |kind| @tagName(kind) else "plain";
            const shown = text[token.start..token.end];
            try written.print(testing.allocator, "{s}:{s}", .{ name, shown });
        }
    }
    try testing.expectEqualStrings(expected, written.items);
}

test "a range answer decodes into each row's tokens by byte column" {
    const allocator = testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "const S = struct { f: u8 };\nfn g() void {}\n");
    defer buffer.deinit(allocator);
    buffer.changed_rows = .none;
    // Line 0: keyword, type S, field f; line 1: keyword, function g.
    const answer =
        \\{"jsonrpc":"2.0","id":2,"result":{"data":[0,0,5,4,0, 0,6,1,0,0, 0,4,6,4,0, 0,9,1,1,1,
        \\ 1,0,2,4,0, 0,3,1,2,0]}}
    ;
    const both = "keyword:const type:S keyword:struct field:f|keyword:fn function:g";
    try expectRows(both, &buffer, answer, .utf8, .none, 0, 2);
    // Rows outside the asked ones are dropped, and rows asked that the
    // answer leaves out have none.
    try expectRows("keyword:fn function:g", &buffer, answer, .utf8, .none, 1, 2);
    try expectRows("keyword:fn function:g|", &buffer, answer, .utf8, .none, 1, 3);
    // Members in any order, unknown ones skipped, and a null result or an
    // error is no set.
    const reordered =
        \\{"result":{"resultId":"7","data":[1,3,1,2,0],"x":[1,{}]},"id":2,"jsonrpc":"2.0"}
    ;
    try expectRows("function:g", &buffer, reordered, .utf8, .none, 1, 2);
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"id\":2,\"result\":null}",
        "{\"id\":2,\"error\":{\"code\":-32801,\"message\":\"content modified\"}}",
        "{\"id\":2}",
    }) |body| {
        const held = try unchangedReply(allocator, arena.allocator(), body, &buffer, 2);
        try testing.expectEqual(null, held);
    }
}

test "answer columns count UTF-16 units or bytes, and stop at the line's end" {
    const allocator = testing.allocator;
    // "é" is 2 bytes and 1 unit; "😀" 4 bytes and 2 units.
    var buffer = try Buffer.fromBytes(allocator, "\u{e9} x \u{1f600} y\r\nz");
    defer buffer.deinit(allocator);
    buffer.changed_rows = .none;
    const utf16 = "{\"result\":{\"data\":[0,2,1,3,0, 0,2,2,0,0, 0,3,1,1,0, 1,0,9,2,0]}}";
    const expected = "plain:x type:\u{1f600} field:y|function:z";
    try expectRows(expected, &buffer, utf16, .utf16, .none, 0, 2);
    const utf8 = "{\"result\":{\"data\":[0,3,1,3,0, 0,2,4,0,0, 0,5,1,1,0, 1,0,9,2,0]}}";
    try expectRows(expected, &buffer, utf8, .utf8, .none, 0, 2);
    // A column inside a character moves to its start, and a token that
    // overlaps the one before it keeps only its own bytes.
    const inside = "{\"result\":{\"data\":[0,1,1,0,0, 0,6,2,1,0, 0,1,3,2,0]}}";
    try expectRows("type:\u{e9} field:\u{1f600} function: y", &buffer, inside, .utf8, .none, 0, 1);
}

test "rows changed since the answer was asked for get none, and the others move" {
    const allocator = testing.allocator;
    const text = "fn a() void {}\nfn b() void {}\nfn c() void {}\n";
    var buffer = try Buffer.fromBytes(allocator, text);
    defer buffer.deinit(allocator);
    buffer.changed_rows = .none;
    const answer = "{\"result\":{\"data\":[0,3,1,2,0, 1,3,1,2,0, 1,3,1,2,0]}}";
    // A line added in the middle row after the request.
    try buffer.replace(allocator, .{ .start = 18, .end = 18 }, "\n", 18);
    const since = buffer.changed_rows;
    try expectRows("function:a||function:c", &buffer, answer, .utf8, since, 0, 3);
}

test "malformed token data is refused, and every allocation failure frees the set" {
    const allocator = testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "fn a() void {}\n");
    defer buffer.deinit(allocator);
    buffer.changed_rows = .none;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"result\":{\"data\":[0,3,1,2]}}",
        "{\"result\":{\"data\":[0,3,1,2,-1]}}",
        "{\"result\":{\"data\":[0,3,1.5,2,0]}}",
        "{\"result\":{\"data\":[0,3,1,2,4294967296]}}",
        "{\"result\":{\"data\":[0,3,1,\"2\",0]}}",
        "{\"result\":{\"data\":{}}}",
        "{\"result\":[]}",
        "{\"result\":{\"data\":[0,3,1,2,0]}",
        "{\"result\":{\"data\":[]}} x",
        "[]",
    }) |body| {
        const decoded = unchangedReply(allocator, arena.allocator(), body, &buffer, 1);
        try testing.expectError(error.MalformedMessage, decoded);
    }
    try testing.checkAllAllocationFailures(allocator, struct {
        fn run(gpa: Allocator, text: *const Buffer) !void {
            var scratch: std.heap.ArenaAllocator = .init(gpa);
            defer scratch.deinit();
            const body = "{\"result\":{\"data\":[0,0,2,4,0, 0,3,1,2,0, 1,0,0,0,0]}}";
            var held = (try unchangedReply(gpa, scratch.allocator(), body, text, 2)).?;
            defer held.deinit(gpa);
            try testing.expectEqual(2, held.tokens.items.len);
        }
    }.run, .{&buffer});
}
