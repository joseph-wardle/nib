// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const Allocator = std.mem.Allocator;
const Buffer = @import("buffer.zig").Buffer;
const EditError = @import("buffer.zig").Error;
const max_file_bytes = @import("buffer.zig").max_file_bytes;
const max_lines = @import("buffer.zig").max_lines;
const Range = @import("buffer.zig").Range;
const char = @import("char.zig");
const motion = @import("motion.zig");
const input = @import("input.zig");
const command = @import("command.zig");
const search = @import("search.zig");
const view = @import("view.zig");

/// Text an operator took. Breaks are always LF, whatever the source used; a
/// linewise register's last line is terminated. Owned by the editor.
pub const Register = struct { text: []u8 = &.{}, linewise: bool = false };

pub const Error = EditError || error{UnsupportedYank};

/// The most register text sent to the system clipboard. Konsole accepts a
/// 1 MiB OSC 52 payload intact; larger text stays in the register only.
pub const clipboard_limit = 1 << 20;

/// The status line's transient message, held in its own storage so it never
/// borrows another owner's memory. Text past `capacity` is cut off.
pub const Status = struct {
    bytes: [capacity]u8 = undefined,
    len: usize = 0,

    pub const capacity = 512;

    /// Borrows the status until it next changes.
    pub fn text(self: *const Status) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *Status, message: []const u8) void {
        const count = @min(message.len, capacity);
        @memmove(self.bytes[0..count], message[0..count]);
        self.len = count;
    }

    pub fn clear(self: *Status) void {
        self.len = 0;
    }

    /// `args` must not borrow the status itself.
    pub fn print(self: *Status, comptime format: []const u8, args: anytype) void {
        var writer: std.Io.Writer = .fixed(&self.bytes);
        writer.print(format, args) catch {};
        self.len = writer.end;
    }
};

/// Modal editing state shared by every document, including the last search
/// and the registers.
/// The caller owns the buffer, its vertical goal column and its viewport, and
/// handles the keys `feed` returns as requests. The editor words its messages
/// into the caller's `Status`. No terminal or I/O ownership.
pub const Editor = struct {
    parser: command.Parser = .{},
    paste: std.ArrayList(u8) = .empty,
    paste_failed: bool = false,
    paste_cr: bool = false,
    paste_newline: [2]u8 = undefined,
    paste_newline_len: usize = 0,
    /// The last search query and direction; empty until the first search.
    last_query: [command.max_line]u8 = undefined,
    last_query_len: usize = 0,
    last_direction: search.Direction = .forward,
    /// Whether the last query's matches are shown. Escape or Ctrl-C in normal
    /// mode hides them; the next search shows them again.
    highlight: bool = false,
    /// Where the open search prompt started. Every query change, and closing
    /// the prompt, starts again from here.
    origin: ?Origin = null,
    /// The unnamed register, `"0` and `"a`–`"z`, indexed by `slot`.
    registers: [2 + 26]Register = @splat(.{}),
    /// The unnamed register changed and fits the clipboard, so the next frame
    /// sends it. Whoever draws clears this once that frame was written whole.
    clipboard: bool = false,

    const Origin = struct { cursor: usize, goal: motion.Goal, viewport: view.Viewport };

    pub fn deinit(self: *Editor, allocator: Allocator) void {
        self.paste.deinit(allocator);
        for (&self.registers) |*held| allocator.free(held.text);
    }

    /// The register named `name` (`"`, `0` or `a`–`z`); borrows editor
    /// storage until the next feed.
    pub fn register(self: *const Editor, name: u8) *const Register {
        return &self.registers[slot(name)];
    }

    pub fn inserting(self: *const Editor) bool {
        return self.parser.mode == .insert;
    }

    /// No command, insertion or paste is in progress, so the text may be
    /// replaced underneath, as a reload or a document switch does.
    pub fn idle(self: *const Editor) bool {
        const parser = &self.parser;
        return parser.mode == .normal and parser.count == null and !parser.pending_g and
            !parser.naming and parser.register == null and !parser.pasting;
    }

    /// The query whose visible matches are drawn: the prompt's while it holds
    /// a valid query, otherwise the last one while highlighting is on. Borrows
    /// editor storage until the next feed.
    pub fn highlighted(self: *const Editor) ?[]const u8 {
        const parser = &self.parser;
        if (parser.mode == .search) {
            if (parser.line.len == 0 or parser.line.invalid) return null;
            return parser.line.text();
        }
        if (!self.highlight or self.last_query_len == 0) return null;
        return self.last_query[0..self.last_query_len];
    }

    pub fn interruptPaste(self: *Editor, status: *Status) void {
        if (self.parser.pasting) {
            self.paste.clearRetainingCapacity();
            self.paste_failed = true;
            status.set("Paste interrupted; nothing inserted");
        }
    }

    pub fn feed(
        self: *Editor,
        allocator: Allocator,
        buffer: *Buffer,
        goal: *motion.Goal,
        viewport: *view.Viewport,
        status: *Status,
        event: input.Event,
    ) ?command.Request {
        if (event == .escape or (event == .key and event.key == 3)) {
            status.clear();
            if (self.parser.mode == .normal) self.highlight = false;
        }
        const parsed = self.parser.feed(event);
        // A dropped character is reported after whatever the event did.
        defer if (self.parser.discarded) {
            status.set("Invalid or interrupted character; nothing inserted");
        };
        const action = parsed orelse return null;
        // The parser is in search mode exactly while `origin` is set, so the
        // actions here are the prompt's own. All but the opening one restore
        // the origin; all but a preview also close the prompt.
        if (self.origin) |origin| {
            buffer.cursor = origin.cursor;
            goal.* = origin.goal;
            viewport.* = origin.viewport;
            if (!(action == .prompt and action.prompt == .preview)) self.origin = null;
        }
        switch (action) {
            .request => |request| return request,
            .invalid => status.set("Unsupported command or count"),
            .unsupported_register => status.set("Unsupported register"),
            .prompt => |prompt| switch (prompt) {
                .open => {
                    self.origin = .{
                        .cursor = buffer.cursor,
                        .goal = goal.*,
                        .viewport = viewport.*,
                    };
                    status.clear();
                },
                .preview => |typed| if (typed) |movement| preview(buffer, goal, movement),
                .close => {},
                .invalid => status.set("Unsupported search; ASCII text only"),
            },
            .jump => |movement| if (self.find(buffer, status, movement)) |destination| {
                buffer.cursor = destination;
                goal.* = motion.screenColumn(buffer, destination, false);
            },
            else => self.edit(allocator, buffer, goal, status, action) catch |err| {
                status.set(editError(err));
                // Insert entry is tentative; a failed open/change must not
                // enter insert mode or leave an active, empty command group.
                if (action == .insert or action == .operate or action == .put) {
                    self.parser.cancel();
                    buffer.endGroup();
                }
            },
        }
        return null;
    }

    fn edit(
        self: *Editor,
        allocator: Allocator,
        buffer: *Buffer,
        goal: *motion.Goal,
        status: *Status,
        action: command.Action,
    ) Error!void {
        switch (action) {
            .move => |movement| {
                status.clear();
                if (motion.resolve(
                    buffer,
                    goal.*,
                    movement.motion,
                    movement.count,
                    null,
                )) |result| {
                    buffer.cursor = result.destination;
                    goal.* = result.goal;
                }
            },
            .insert => |insertion| {
                if (!buffer.editable) return error.UnsupportedText;
                status.clear();
                buffer.beginGroup();
                const row = buffer.rowAt(buffer.cursor);
                const start = buffer.starts.items[row];
                const end = start + buffer.line(row).len;
                switch (insertion) {
                    .before => {},
                    .after => buffer.cursor = @min(char.next(buffer.bytes(), buffer.cursor), end),
                    .above, .below => {
                        const newline = buffer.newlineAt(buffer.cursor);
                        const offset = if (insertion == .above) start else end;
                        // Insert before the existing terminator, preserving its
                        // exact bytes while adding a blank row with local style.
                        try buffer.replace(allocator, .{ .start = offset, .end = offset }, newline, offset + if (insertion == .below) newline.len else 0);
                    },
                }
            },
            .operate => |operation| {
                const yanking = operation.operator == .yank;
                if (!yanking and !buffer.editable) return error.UnsupportedText;
                status.clear();
                const result = switch (operation.movement) {
                    .motion => |movement| motion.resolve(
                        buffer,
                        goal.*,
                        movement.motion,
                        movement.count,
                        operation.operator,
                    ) orelse return,
                    .lines => |count| result: {
                        const row = buffer.rowAt(buffer.cursor);
                        const last = row + @min(count - 1, buffer.lineCount() - row - 1);
                        break :result motion.Result{ .destination = buffer.starts.items[last], .shape = .linewise, .goal = 0 };
                    },
                    .search => |movement| result: {
                        const destination = self.find(buffer, status, movement) orelse return;
                        // Landing on the cursor is a failed motion, like finding nothing.
                        if (destination == buffer.cursor) return;
                        break :result motion.Result{
                            .destination = destination,
                            .shape = .exclusive,
                            .goal = null,
                        };
                    },
                };
                const selection = motion.operatorRange(buffer, result, operation.operator);
                const name = operation.register;
                const linewise = selection.linewise;
                const copied = buffer.bytes()[selection.copied.start..selection.copied.end];
                // Only a read-only buffer can hold text no register may.
                if (yanking and !buffer.editable and !char.editable(copied))
                    return error.UnsupportedYank;
                // As in Vim, a characterwise delete of nothing writes no register.
                const removes_nothing = operation.operator == .delete and !linewise and
                    copied.len == 0;
                // Prepared before the edit; stored only after it succeeds.
                const text = if (name == '_' or removes_nothing)
                    null
                else
                    try copy(allocator, copied, linewise);
                errdefer if (text) |owned| allocator.free(owned);
                // An unnamed yank also fills "0, which deletes leave alone.
                const yanked = if (yanking and text != null and name == '"')
                    try allocator.dupe(u8, text.?)
                else
                    null;
                errdefer if (yanked) |owned| allocator.free(owned);
                if (yanking) {
                    // Vim leaves the cursor at the start of what it yanked;
                    // a line count never moves it.
                    if (operation.movement != .lines and result.destination < buffer.cursor) {
                        buffer.cursor = result.destination;
                        goal.* = motion.screenColumn(buffer, buffer.cursor, false);
                    }
                    const owned = text orelse return;
                    const lines = std.mem.count(u8, owned, "\n") + @intFromBool(!linewise);
                    // Reported first, so a clipboard refusal replaces it.
                    if (lines > 2) status.print("{d} lines yanked", .{lines});
                    self.store(allocator, status, name, owned, linewise);
                    if (yanked) |zero| self.store(allocator, status, '0', zero, linewise);
                    return;
                }
                var range = selection.range;
                const changing = operation.operator == .change;
                // A linewise change keeps the last selected terminator, if
                // present, so insertion stays on a blank logical line.
                if (changing and selection.linewise and range.end > range.start and buffer.bytes()[range.end - 1] == '\n') {
                    range.end -= 1;
                    if (range.end > range.start and buffer.bytes()[range.end - 1] == '\r') range.end -= 1;
                }
                buffer.beginGroup();
                try buffer.replace(allocator, range, "", range.start);
                if (text) |owned| self.store(allocator, status, name, owned, linewise);
                if (changing) {
                    self.parser.mode = .insert;
                } else {
                    buffer.cursor = motion.normal(buffer, buffer.cursor);
                    // Linewise deletion lands at the first nonblank character.
                    if (selection.linewise) buffer.cursor = motion.resolve(buffer, 0, .first, null, null).?.destination;
                    buffer.endCommand();
                }
                goal.* = motion.screenColumn(buffer, buffer.cursor, changing);
            },
            .put => |put| {
                if (!buffer.editable) return error.UnsupportedText;
                status.clear();
                const held = self.register(put.register);
                if (held.text.len == 0) {
                    status.set("Register empty");
                    return;
                }
                const row = buffer.rowAt(buffer.cursor);
                const range = buffer.lineRange(row);
                const end = range.start + buffer.line(row).len;
                const offset = if (held.linewise) switch (put.side) {
                    .after => range.end,
                    .before => range.start,
                } else switch (put.side) {
                    .after => @min(char.next(buffer.bytes(), buffer.cursor), end),
                    .before => buffer.cursor,
                };
                // Below an unterminated last line, the line gets a terminator
                // and the text loses its last one: the file still has no
                // final newline.
                const newline = buffer.newlineAt(buffer.cursor);
                const lead = if (held.linewise and put.side == .after and range.end == end)
                    newline.len
                else
                    0;
                const breaks = std.mem.count(u8, held.text, "\n");
                const one = held.text.len + breaks * (newline.len - 1);
                const total = std.math.mul(usize, one, put.count) catch return error.FileTooLarge;
                // Checked before allocating, so a large count costs nothing.
                if (total > max_file_bytes - buffer.bytes().len) return error.FileTooLarge;
                const built = try allocator.alloc(u8, lead + total);
                defer allocator.free(built);
                @memcpy(built[0..lead], newline[0..lead]);
                expand(built[lead..][0..one], held.text, newline);
                var copied = lead + one;
                while (copied < built.len) : (copied += one) {
                    @memcpy(built[copied..][0..one], built[lead..][0..one]);
                }
                const inserted = built[0..total];
                buffer.beginGroup();
                const at: Range = .{ .start = offset, .end = offset };
                try buffer.replace(allocator, at, inserted, offset + lead);
                // As in Vim: a linewise put lands on the first put line's first
                // nonblank, a multi-line characterwise put at its start, and any
                // other on the last put character.
                if (held.linewise) {
                    buffer.cursor = motion.resolve(buffer, 0, .first, null, null).?.destination;
                } else if (breaks == 0) {
                    buffer.cursor = char.start(buffer.bytes(), offset + total - 1);
                }
                buffer.endCommand();
                goal.* = motion.screenColumn(buffer, buffer.cursor, false);
                const lines = std.mem.count(u8, inserted, "\n");
                if (lines > 2) status.print("{d} more lines", .{lines});
            },
            .text => |text| try insert(allocator, buffer, text),
            .tab => try insert(allocator, buffer, "\t"),
            .newline => try insert(allocator, buffer, buffer.newlineAt(buffer.cursor)),
            .backspace => {
                if (buffer.cursor != 0) {
                    const end = buffer.cursor;
                    const start = char.previous(buffer.bytes(), end);
                    try buffer.replace(allocator, .{ .start = start, .end = end }, "", start);
                }
            },
            .end_insert => {
                const row = buffer.rowAt(buffer.cursor);
                // Stepping back one byte, then snapping, lands on a character start.
                if (buffer.cursor > buffer.starts.items[row]) buffer.cursor -= 1;
                buffer.cursor = motion.normal(buffer, buffer.cursor);
                buffer.endCommand();
                goal.* = motion.screenColumn(buffer, buffer.cursor, false);
            },
            .undo, .redo => {
                const changed = if (action == .undo) try buffer.undo(allocator) else try buffer.redo(allocator);
                status.set(if (changed) "" else "No more history");
                buffer.cursor = motion.normal(buffer, buffer.cursor);
                goal.* = motion.screenColumn(buffer, buffer.cursor, false);
            },
            .paste_begin => {
                self.paste.clearRetainingCapacity();
                self.paste_failed = false;
                self.paste_cr = false;
                const newline = buffer.newlineAt(buffer.cursor);
                @memcpy(self.paste_newline[0..newline.len], newline);
                self.paste_newline_len = newline.len;
                status.clear();
            },
            .paste_byte => |byte| {
                if (self.paste_failed) return;
                if (byte == '\n' and self.paste_cr) {
                    self.paste_cr = false;
                    return;
                }
                self.paste_cr = byte == '\r';
                const bytes: []const u8 = switch (byte) {
                    '\r', '\n' => self.paste_newline[0..self.paste_newline_len],
                    '\t', 0x20...0x7e, 0x80...0xff => &.{byte},
                    else => {
                        self.paste_failed = true;
                        status.set("Unsupported paste; nothing inserted");
                        return;
                    },
                };
                if (bytes.len > max_file_bytes - self.paste.items.len) {
                    self.paste_failed = true;
                    status.set("Paste exceeds temporary 8 MiB limit; nothing inserted");
                    return;
                }
                self.paste.appendSlice(allocator, bytes) catch |err| {
                    self.paste_failed = true;
                    status.set(editError(err));
                };
            },
            .paste_end => {
                defer self.paste.clearRetainingCapacity();
                if (self.paste_failed) return;
                // Checked here, so a bad paste never reads as a read-only refusal.
                if (!char.editable(self.paste.items)) {
                    status.set("Unsupported paste; nothing inserted");
                    return;
                }
                try insert(allocator, buffer, self.paste.items);
            },
            else => unreachable,
        }
    }

    /// The match a search motion reaches from the cursor, recording a typed
    /// query as the last search and reporting a wrap or failure in the notice.
    fn find(
        self: *Editor,
        buffer: *const Buffer,
        status: *Status,
        movement: command.Search,
    ) ?usize {
        var direction = self.last_direction;
        switch (movement.target) {
            .typed => |typed| {
                direction = typed.direction;
                self.last_direction = typed.direction;
                if (typed.query.len != 0) {
                    @memcpy(self.last_query[0..typed.query.len], typed.query);
                    self.last_query_len = typed.query.len;
                }
            },
            .repeat => |repeat| if (repeat == .reverse) {
                direction = direction.reverse();
            },
        }
        if (self.last_query_len == 0) {
            status.set("No previous search");
            return null;
        }
        const query = self.last_query[0..self.last_query_len];
        self.highlight = true;
        const count = movement.count orelse 1;
        const found = search.find(buffer.bytes(), query, buffer.cursor, direction, count) orelse {
            status.print("Not found: {s}", .{query});
            return null;
        };
        status.set(if (!found.wrapped) "" else switch (direction) {
            .forward => "Search wrapped to top",
            .backward => "Search wrapped to bottom",
        });
        return found.start;
    }

    /// Replaces register `name`'s text with `text`, taking ownership. The
    /// unnamed register also goes to the clipboard, unless it is too large,
    /// which the notice says, replacing any other.
    fn store(
        self: *Editor,
        allocator: Allocator,
        status: *Status,
        name: u8,
        text: []u8,
        linewise: bool,
    ) void {
        const held = &self.registers[slot(name)];
        allocator.free(held.text);
        held.* = .{ .text = text, .linewise = linewise };
        if (name != '"') return;
        self.clipboard = text.len <= clipboard_limit;
        if (!self.clipboard) status.set("Not copied to the clipboard: over 1 MiB");
    }
};

/// A register's slot: the unnamed register, `"0`, then `"a`–`"z`.
fn slot(name: u8) usize {
    return switch (name) {
        '"' => 0,
        '0' => 1,
        'a'...'z' => 2 + @as(usize, name - 'a'),
        else => unreachable,
    };
}

/// Register text for `bytes`, which are editable: every CR belongs to a
/// CRLF and is dropped, and linewise text gets a final LF if it lacks one.
/// Caller owns the result.
fn copy(allocator: Allocator, bytes: []const u8, linewise: bool) Allocator.Error![]u8 {
    const terminate = linewise and (bytes.len == 0 or bytes[bytes.len - 1] != '\n');
    const len = bytes.len - std.mem.count(u8, bytes, "\r") + @intFromBool(terminate);
    const text = try allocator.alloc(u8, len);
    var written: usize = 0;
    for (bytes) |byte| if (byte != '\r') {
        text[written] = byte;
        written += 1;
    };
    if (terminate) text[written] = '\n';
    return text;
}

/// Writes register `text` into `destination`, with each LF as `newline`.
/// `destination` holds exactly the expanded text.
fn expand(destination: []u8, text: []const u8, newline: []const u8) void {
    var written: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            @memcpy(destination[written..][0..newline.len], newline);
            written += newline.len;
        } else {
            destination[written] = byte;
            written += 1;
        }
    }
    std.debug.assert(written == destination.len);
}

/// Moves to the match the prompt's query would reach, or stays put.
fn preview(buffer: *Buffer, goal: *motion.Goal, movement: command.Search) void {
    const typed = movement.target.typed;
    const count = movement.count orelse 1;
    const text = buffer.bytes();
    const cursor = buffer.cursor;
    const found = search.find(text, typed.query, cursor, typed.direction, count) orelse return;
    buffer.cursor = found.start;
    goal.* = motion.screenColumn(buffer, found.start, false);
}

fn insert(allocator: Allocator, buffer: *Buffer, bytes: []const u8) EditError!void {
    try buffer.replace(allocator, .{ .start = buffer.cursor, .end = buffer.cursor }, bytes, buffer.cursor + bytes.len);
}

fn editError(err: anyerror) []const u8 {
    return switch (err) {
        error.UnsupportedText => "Read-only: invalid UTF-8 or unsupported control bytes",
        error.UnsupportedYank => "Invalid UTF-8 or unsupported control bytes; nothing yanked",
        error.FileTooLarge => "Edit exceeds temporary 8 MiB limit",
        error.TooManyLines => "Edit exceeds temporary 262,144-line limit",
        error.OutOfMemory => "Not enough memory; edit refused",
        else => @errorName(err),
    };
}

fn keys(
    editor: *Editor,
    status: *Status,
    allocator: Allocator,
    buffer: *Buffer,
    goal: *motion.Goal,
    bytes: []const u8,
) void {
    var viewport: view.Viewport = .{};
    for (bytes) |byte| _ = editor.feed(
        allocator,
        buffer,
        goal,
        &viewport,
        status,
        .{ .key = byte },
    );
}

fn pasted(
    editor: *Editor,
    status: *Status,
    allocator: Allocator,
    buffer: *Buffer,
    goal: *motion.Goal,
    bytes: []const u8,
) void {
    var viewport: view.Viewport = .{};
    _ = editor.feed(allocator, buffer, goal, &viewport, status, .paste_begin);
    for (bytes) |byte| _ = editor.feed(
        allocator,
        buffer,
        goal,
        &viewport,
        status,
        .{ .paste_byte = byte },
    );
    _ = editor.feed(allocator, buffer, goal, &viewport, status, .paste_end);
}

test "a status keeps a copy of its message and cuts it at capacity" {
    var status: Status = .{};
    var source = "Not found: x".*;
    status.set(&source);
    source[0] = '?';
    try std.testing.expectEqualStrings("Not found: x", status.text());
    const long: [Status.capacity + 1]u8 = @splat('y');
    status.set(&long);
    try std.testing.expectEqualStrings(long[0..Status.capacity], status.text());
    status.print("{s}z", .{long[0..Status.capacity]});
    try std.testing.expectEqualStrings(long[0..Status.capacity], status.text());
    status.clear();
    try std.testing.expectEqualStrings("", status.text());
}

// é is 2 bytes; €, ✅ and 材 are 3, and the last two are wide; 𝑥 is 4.
const acute = "\u{e9}";
const euro = "\u{20ac}";
const check = "\u{2705}";
const wide = "\u{6750}";
const math = "\u{1d465}";

test "composed operators have fixed Vim text and cursor results and one undo group" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { before: []const u8, keys: []const u8, after: []const u8, cursor: usize }{
        .{ .before = "one two three\n", .keys = "dw", .after = "two three\n", .cursor = 0 },
        .{ .before = "one two three\n", .keys = "cwNEW\x03", .after = "NEW two three\n", .cursor = 2 },
        .{ .before = "one\r\ntwo\nthree", .keys = "dd", .after = "two\nthree", .cursor = 0 },
        .{ .before = "one\r\ntwo\nthree", .keys = "ccNEW\x03", .after = "NEW\r\ntwo\nthree", .cursor = 2 },
        .{ .before = "one\r\ntwo\nthree", .keys = "dj", .after = "three", .cursor = 0 },
        .{ .before = "one two\nthree", .keys = "ld$", .after = "o\nthree", .cursor = 0 },
        .{ .before = "one two\nthree", .keys = "$db", .after = "one o\nthree", .cursor = 4 },
        .{ .before = "one\ntwo\nthree", .keys = "dw", .after = "\ntwo\nthree", .cursor = 0 },
        .{ .before = "a b c d e f g h\n", .keys = "2d3w", .after = "g h\n", .cursor = 0 },
        .{ .before = "one\ntwo", .keys = "GccNEW\x03", .after = "one\nNEW", .cursor = 6 },
        .{ .before = "one\ntwo\n", .keys = "Gdd", .after = "one\n", .cursor = 0 },
        .{ .before = "a\nb\nc\nd\n", .keys = "2ccX\x03", .after = "X\nc\nd\n", .cursor = 0 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var goal: motion.Goal = 0;
        defer editor.deinit(allocator);
        keys(&editor, &status, allocator, &buffer, &goal, case.keys);
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
        try std.testing.expectEqual(@as(usize, 1), buffer.position);
        keys(&editor, &status, allocator, &buffer, &goal, "u");
        try std.testing.expectEqualStrings(case.before, buffer.bytes());
        keys(&editor, &status, allocator, &buffer, &goal, "\x12");
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
    }
}

test "insert entry, newline style, backspace and EOF stay reversible" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { before: []const u8, keys: []const u8, after: []const u8, cursor: usize, undo_cursor: usize = 0 }{
        .{ .before = "abc", .keys = "$a\rX\tY\x7fZ\x03", .after = "abc\nX\tZ", .cursor = 6, .undo_cursor = 2 },
        .{ .before = "abc\r\nlast", .keys = "oX\x03", .after = "abc\r\nX\r\nlast", .cursor = 5 },
        .{ .before = "abc\r\nlast", .keys = "OX\x03", .after = "X\r\nabc\r\nlast", .cursor = 0 },
        .{ .before = "abc", .keys = "oX\x03", .after = "abc\nX", .cursor = 4 },
        .{ .before = "", .keys = "i\rX\x03", .after = "\nX", .cursor = 1 },
        .{ .before = "a\r\nb", .keys = "ji\x7fX\x03", .after = "aXb", .cursor = 1, .undo_cursor = 3 },
        .{ .before = "abc", .keys = "iX\x03", .after = "Xabc", .cursor = 0 },
        .{ .before = "abc", .keys = "aX\x03", .after = "aXbc", .cursor = 1 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var goal: motion.Goal = 0;
        defer editor.deinit(allocator);
        keys(&editor, &status, allocator, &buffer, &goal, case.keys);
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
        keys(&editor, &status, allocator, &buffer, &goal, "u");
        try std.testing.expectEqualStrings(case.before, buffer.bytes());
        try std.testing.expectEqual(case.undo_cursor, buffer.cursor);
        keys(&editor, &status, allocator, &buffer, &goal, "\x12");
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.cursor, buffer.cursor);
    }
}

test "paste validates atomically, normalizes breaks, joins insert group and never executes commands" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\r\nb\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    var viewport: view.Viewport = .{};
    defer editor.deinit(allocator);
    keys(&editor, &status, allocator, &buffer, &goal, "iX");
    pasted(&editor, &status, allocator, &buffer, &goal, "1\n2\r\n3\r4\t");
    try std.testing.expectEqualStrings("X1\r\n2\r\n3\r\n4\ta\r\nb\n", buffer.bytes());
    for ([_][]const u8{ "BAD\x03:w\r", "BAD\x1a", "BAD\x1c", "BAD\x1b", "BAD\x00", "BAD\xff" }) |bad| {
        pasted(&editor, &status, allocator, &buffer, &goal, bad);
        try std.testing.expectEqualStrings("X1\r\n2\r\n3\r\n4\ta\r\nb\n", buffer.bytes());
    }
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .paste_begin);
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .{ .paste_byte = 'x' });
    editor.interruptPaste(&status);
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .paste_end);
    keys(&editor, &status, allocator, &buffer, &goal, "\x03u");
    try std.testing.expectEqualStrings("a\r\nb\n", buffer.bytes());
    try std.testing.expect(!buffer.modified());
    pasted(&editor, &status, allocator, &buffer, &goal, "iEVIL:q!\r");
    try std.testing.expectEqualStrings("a\r\nb\n", buffer.bytes());
}

test "refused input at byte and line caps keeps earlier typing and all undo and save positions" {
    const allocator = std.testing.allocator;
    const large = try allocator.alloc(u8, max_file_bytes);
    defer allocator.free(large);
    for ([_]bool{ false, true }) |lines| {
        @memset(large, if (lines) '\n' else 'x');
        const before = large[0..if (lines) max_lines - 1 else max_file_bytes - 1];
        var buffer = try Buffer.fromBytes(allocator, before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var goal: motion.Goal = 0;
        defer editor.deinit(allocator);
        keys(&editor, &status, allocator, &buffer, &goal, "iX");
        const cursor = buffer.cursor;
        const len = buffer.bytes().len;
        keys(&editor, &status, allocator, &buffer, &goal, if (lines) "\r\r" else "Y\r");
        // With max_lines-1 LF plus X, one LF is allowed and the second is not.
        const expected = len + @as(usize, if (lines) 1 else 0);
        try std.testing.expectEqual(expected, buffer.bytes().len);
        try std.testing.expectEqual(cursor + @as(usize, if (lines) 1 else 0), buffer.cursor);
        pasted(&editor, &status, allocator, &buffer, &goal, "Y\nY");
        try std.testing.expectEqual(expected, buffer.bytes().len);
        keys(&editor, &status, allocator, &buffer, &goal, "\x03u");
        try std.testing.expectEqualStrings(before, buffer.bytes());
        keys(&editor, &status, allocator, &buffer, &goal, "\x12");
        try std.testing.expectEqual(expected, buffer.bytes().len);
        try buffer.markSaved(allocator);
        var reopened = try Buffer.fromBytes(allocator, buffer.bytes());
        defer reopened.deinit(allocator);
        try std.testing.expectEqualStrings(buffer.bytes(), reopened.bytes());
    }
}

test "read-only edits and cancellations preserve original bytes and history" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "raw\xff\r");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    defer editor.deinit(allocator);
    keys(&editor, &status, allocator, &buffer, &goal, "iX\x03ddcwX\x03oO");
    try std.testing.expectEqualStrings("raw\xff\r", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 0), buffer.position);
    try std.testing.expect(!editor.inserting());
    var editable = try Buffer.fromBytes(allocator, "one two\n");
    defer editable.deinit(allocator);
    keys(&editor, &status, allocator, &editable, &goal, "2d3\x03dg\x03\x03");
    try std.testing.expectEqualStrings("one two\n", editable.bytes());
    try std.testing.expectEqual(@as(usize, 0), editable.position);
}

test "allocation failures retain earlier insert edits and reject whole pastes" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationWorkflow, .{});
}

fn allocationWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "abc\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    defer editor.deinit(allocator);
    // Exercise fallible operations directly to propagate allocation failures to
    // the harness; production feed turns them into a visible notice.
    try editor.edit(allocator, &buffer, &goal, &status, .{ .insert = .before });
    try editor.edit(allocator, &buffer, &goal, &status, .{ .text = "X" });
    editor.edit(allocator, &buffer, &goal, &status, .{ .insert = .above }) catch |err| {
        try std.testing.expectEqualStrings("Xabc\n", buffer.bytes());
        return err;
    };
    try editor.edit(allocator, &buffer, &goal, &status, .paste_begin);
    // Collection handles OOM by latching refusal until the end delimiter.
    try editor.edit(allocator, &buffer, &goal, &status, .{ .paste_byte = 'Y' });
    if (editor.paste_failed) return error.OutOfMemory;
    editor.edit(allocator, &buffer, &goal, &status, .paste_end) catch |err| {
        try std.testing.expectEqualStrings("\nXabc\n", buffer.bytes());
        return err;
    };
}

test "long insert and backspace sessions replay coalesced text and cursor exactly" {
    const allocator = std.testing.allocator;
    const before = "prefix\r\nabcdefghijklmnopqrstuvwxyz\r\nsuffix";
    var buffer = try Buffer.fromBytes(allocator, before);
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    defer editor.deinit(allocator);
    keys(&editor, &status, allocator, &buffer, &goal, "j$a123456789\x7f\x7f\x7fX\x03");
    try std.testing.expectEqualStrings("prefix\r\nabcdefghijklmnopqrstuvwxyz123456X\r\nsuffix", buffer.bytes());
    try std.testing.expectEqual(@as(usize, 1), buffer.history.items[0].edits.items.len);
    keys(&editor, &status, allocator, &buffer, &goal, "u\x12u");
    try std.testing.expectEqualStrings(before, buffer.bytes());
    keys(&editor, &status, allocator, &buffer, &goal, "j$i");
    for (0..27) |_| keys(&editor, &status, allocator, &buffer, &goal, "\x7f");
    keys(&editor, &status, allocator, &buffer, &goal, "X\x03");
    const after = try allocator.dupe(u8, buffer.bytes());
    defer allocator.free(after);
    try std.testing.expectEqual(@as(usize, 2), buffer.history.items[0].edits.items.len);
    keys(&editor, &status, allocator, &buffer, &goal, "u");
    try std.testing.expectEqualStrings(before, buffer.bytes());
    keys(&editor, &status, allocator, &buffer, &goal, "\x12");
    try std.testing.expectEqualStrings(after, buffer.bytes());
}

test "paste collection overflow is bounded and inserts nothing" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "base");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    var viewport: view.Viewport = .{};
    defer editor.deinit(allocator);
    keys(&editor, &status, allocator, &buffer, &goal, "iX");
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .paste_begin);
    for (0..max_file_bytes + 1) |_| _ = editor.feed(
        allocator,
        &buffer,
        &goal,
        &viewport,
        &status,
        .{ .paste_byte = 'a' },
    );
    try std.testing.expect(editor.paste_failed);
    try std.testing.expectEqual(@as(usize, max_file_bytes), editor.paste.items.len);
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .paste_end);
    try std.testing.expectEqualStrings("Xbase", buffer.bytes());
    keys(&editor, &status, allocator, &buffer, &goal, "\x03u");
    try std.testing.expectEqualStrings("base", buffer.bytes());
}

test "typing, a, Backspace and insert exit work by character" {
    const allocator = std.testing.allocator;
    // Before, keys, after, then the cursor after the keys and after undo.
    const Case = struct { []const u8, []const u8, []const u8, usize, usize };
    const cases = [_]Case{
        .{ acute ++ euro, "a" ++ check ++ "\x03", acute ++ check ++ euro, 2, 0 },
        .{ acute ++ euro, "$a\x7f\x7fX\x03", "X", 0, 2 },
        .{ wide ++ "\r\nx", "ji\x7f\x7fY\x03", "Yx", 0, 5 },
        .{ "ab" ++ check, "$i" ++ acute ++ "\x03", "ab" ++ acute ++ check, 2, 2 },
        .{ math ++ "y", "a" ++ acute ++ "\x03", math ++ acute ++ "y", 4, 0 },
        .{ "x" ++ math, "$a\x03", "x" ++ math, 1, 1 },
        // An interrupted character inserts nothing; the interrupting key acts.
        .{ "z", "i" ++ check[0..2] ++ "X" ++ acute[0..1] ++ "\x03", "Xz", 0, 0 },
    };
    for (cases) |case| {
        const before, const typed, const after, const cursor, const undo_cursor = case;
        var buffer = try Buffer.fromBytes(allocator, before);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        var goal: motion.Goal = 0;
        defer editor.deinit(allocator);
        keys(&editor, &status, allocator, &buffer, &goal, typed);
        try std.testing.expectEqualStrings(after, buffer.bytes());
        try std.testing.expectEqual(cursor, buffer.cursor);
        try std.testing.expect(!editor.inserting());
        keys(&editor, &status, allocator, &buffer, &goal, "u");
        try std.testing.expectEqualStrings(before, buffer.bytes());
        try std.testing.expectEqual(undo_cursor, buffer.cursor);
        keys(&editor, &status, allocator, &buffer, &goal, "\x12");
        try std.testing.expectEqualStrings(after, buffer.bytes());
    }
}

test "a dropped character or a non-ASCII command shows a notice and changes nothing" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "ok\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    var viewport: view.Viewport = .{};
    defer editor.deinit(allocator);
    const dropped = "Invalid or interrupted character; nothing inserted";
    keys(&editor, &status, allocator, &buffer, &goal, "i\xff");
    try std.testing.expectEqualStrings(dropped, status.text());
    keys(&editor, &status, allocator, &buffer, &goal, "\u{9b}");
    try std.testing.expectEqualStrings(dropped, status.text());
    // Escape still leaves insert mode, and the notice survives it.
    keys(&editor, &status, allocator, &buffer, &goal, euro[0..2]);
    _ = editor.feed(allocator, &buffer, &goal, &viewport, &status, .escape);
    try std.testing.expect(!editor.inserting());
    try std.testing.expectEqualStrings(dropped, status.text());
    try std.testing.expectEqualStrings("ok\n", buffer.bytes());
    try std.testing.expect(!buffer.modified());
    keys(&editor, &status, allocator, &buffer, &goal, "l" ++ check);
    try std.testing.expectEqualStrings("Unsupported command or count", status.text());
    try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
    keys(&editor, &status, allocator, &buffer, &goal, "h");
    try std.testing.expectEqualStrings("", status.text());
}

test "UTF-8 pastes insert as one step; invalid ones insert nothing with their own notice" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\r\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    defer editor.deinit(allocator);
    keys(&editor, &status, allocator, &buffer, &goal, "i");
    pasted(&editor, &status, allocator, &buffer, &goal, acute ++ check ++ "\n" ++ wide ++ math);
    const after = acute ++ check ++ "\r\n" ++ wide ++ math ++ "a\r\n";
    try std.testing.expectEqualStrings(after, buffer.bytes());
    try std.testing.expectEqual(@as(usize, 14), buffer.cursor);
    // Invalid bytes, truncated and overlong forms, a surrogate, a code point
    // above U+10FFFF, C1, DEL and ESC.
    const invalid = [_][]const u8{
        "\xff",          "x" ++ acute[0..1], acute[1..] ++ "x", "\xc0\xaf",
        "\xed\xa0\x80",  "\xf4\x90\x80\x80", "x\u{9b}",         "x\x7f",
        check ++ "\x1b",
    };
    for (invalid) |bad| {
        pasted(&editor, &status, allocator, &buffer, &goal, bad);
        try std.testing.expectEqualStrings(after, buffer.bytes());
        try std.testing.expectEqualStrings("Unsupported paste; nothing inserted", status.text());
        try std.testing.expect(editor.inserting());
    }
    keys(&editor, &status, allocator, &buffer, &goal, "\x03u");
    try std.testing.expectEqualStrings("a\r\n", buffer.bytes());
    try std.testing.expect(!buffer.modified());
}

test "allocation failures during multi-byte typing and paste keep earlier edits" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, multibyteWorkflow, .{});
}

fn multibyteWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, euro ++ "\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    var goal: motion.Goal = 0;
    defer editor.deinit(allocator);
    try editor.edit(allocator, &buffer, &goal, &status, .{ .insert = .after });
    editor.edit(allocator, &buffer, &goal, &status, .{ .text = acute }) catch |err| {
        try std.testing.expectEqualStrings(euro ++ "\n", buffer.bytes());
        return err;
    };
    try editor.edit(allocator, &buffer, &goal, &status, .paste_begin);
    for (check ++ "\n" ++ wide) |byte| {
        try editor.edit(allocator, &buffer, &goal, &status, .{ .paste_byte = byte });
    }
    if (editor.paste_failed) return error.OutOfMemory;
    editor.edit(allocator, &buffer, &goal, &status, .paste_end) catch |err| {
        try std.testing.expectEqualStrings(euro ++ acute ++ "\n", buffer.bytes());
        try std.testing.expectEqual(@as(usize, 5), buffer.cursor);
        return err;
    };
    const typed = euro ++ acute ++ check ++ "\n" ++ wide ++ "\n";
    try std.testing.expectEqualStrings(typed, buffer.bytes());
    // Leaving insert mode lands on the start of the last inserted character.
    try editor.edit(allocator, &buffer, &goal, &status, .end_insert);
    try std.testing.expectEqual(@as(usize, 9), buffer.cursor);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings(euro ++ "\n", buffer.bytes());
}

/// A document's goal and viewport, as the session keeps them.
const Place = struct { goal: motion.Goal = 0, viewport: view.Viewport = .{} };

fn type_(editor: *Editor, status: *Status, buffer: *Buffer, place: *Place, bytes: []const u8) void {
    for (bytes) |byte| _ = editor.feed(
        std.testing.allocator,
        buffer,
        &place.goal,
        &place.viewport,
        status,
        .{ .key = byte },
    );
}

fn escape(editor: *Editor, status: *Status, buffer: *Buffer, place: *Place) void {
    _ = editor.feed(std.testing.allocator, buffer, &place.goal, &place.viewport, status, .escape);
}

test "each query change previews from the origin and closing restores cursor, goal and view" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "alpha\nbeta\nalphabet\nbetamax\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    const closings = [_][]const u8{ "\x1b", "\x03", "\x7f\x7f\x7f\x7f\x7f\x7f" };
    for (closings) |closing| {
        buffer.cursor = 2;
        var place: Place = .{ .goal = null, .viewport = .{ .top = 1, .left = 4 } };
        type_(&editor, &status, &buffer, &place, "/b");
        try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
        // Each change searches again from the origin, not from the preview.
        type_(&editor, &status, &buffer, &place, "et");
        try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
        type_(&editor, &status, &buffer, &place, "am");
        try std.testing.expectEqual(@as(usize, 20), buffer.cursor);
        try std.testing.expectEqual(@as(motion.Goal, 0), place.goal);
        // The main loop scrolls after each batch; the origin's view returns.
        place.viewport = .{ .top = 3, .left = 0 };
        type_(&editor, &status, &buffer, &place, "z");
        try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
        try std.testing.expectEqual(view.Viewport{ .top = 1, .left = 4 }, place.viewport);
        type_(&editor, &status, &buffer, &place, "\x7f");
        try std.testing.expectEqual(@as(usize, 20), buffer.cursor);
        place.viewport = .{ .top = 3, .left = 0 };
        if (closing[0] != 0x1b) type_(&editor, &status, &buffer, &place, closing) else {
            escape(&editor, &status, &buffer, &place);
        }
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
        try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
        try std.testing.expectEqual(@as(motion.Goal, null), place.goal);
        try std.testing.expectEqual(view.Viewport{ .top = 1, .left = 4 }, place.viewport);
        try std.testing.expectEqual(@as(?[]const u8, null), editor.highlighted());
    }
    try std.testing.expect(!buffer.modified());
}

test "Enter keeps the match, records the query, and n and N repeat it with counts and notices" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "x one\nx two\nx three\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "n");
    try std.testing.expectEqualStrings("No previous search", status.text());
    type_(&editor, &status, &buffer, &place, "/X\r");
    try std.testing.expectEqualStrings("Not found: X", status.text());
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "/x\r");
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    try std.testing.expectEqualStrings("", status.text());
    try std.testing.expectEqualStrings("x", editor.highlighted().?);
    type_(&editor, &status, &buffer, &place, "n");
    try std.testing.expectEqual(@as(usize, 12), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "n");
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    try std.testing.expectEqualStrings("Search wrapped to top", status.text());
    type_(&editor, &status, &buffer, &place, "N");
    try std.testing.expectEqual(@as(usize, 12), buffer.cursor);
    try std.testing.expectEqualStrings("Search wrapped to bottom", status.text());
    type_(&editor, &status, &buffer, &place, "2N");
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "2/x\r");
    try std.testing.expectEqual(@as(usize, 12), buffer.cursor);
    // `?` with an empty query repeats backward, and `n` then follows it.
    type_(&editor, &status, &buffer, &place, "?\r");
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "n");
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "N");
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "/caf\xc3\xa9\r");
    try std.testing.expectEqualStrings("Unsupported search; ASCII text only", status.text());
    try std.testing.expectEqual(@as(usize, 6), buffer.cursor);
    try std.testing.expectEqualStrings("x", editor.highlighted().?);
    try std.testing.expect(!buffer.modified());
    try std.testing.expect(!try buffer.undo(allocator));
}

test "a count beyond the matches lands where its remainder does" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\nb\na\nb\na\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "18446744073709551615/a\r");
    // 2^64 - 1 steps over three matches: (2^64 - 2) mod 3 = 2 more after the first.
    try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "4n");
    try std.testing.expectEqual(@as(usize, 4), buffer.cursor);
}

test "the last search and its highlight carry to another document" {
    const allocator = std.testing.allocator;
    var first = try Buffer.fromBytes(allocator, "one\nneedle\n");
    defer first.deinit(allocator);
    var second = try Buffer.fromBytes(allocator, "two\nthree\nneedle\n");
    defer second.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var first_place: Place = .{};
    var second_place: Place = .{};
    type_(&editor, &status, &first, &first_place, "/needle\r");
    try std.testing.expectEqual(@as(usize, 4), first.cursor);
    type_(&editor, &status, &second, &second_place, "n");
    try std.testing.expectEqual(@as(usize, 10), second.cursor);
    try std.testing.expectEqualStrings("needle", editor.highlighted().?);
}

test "Escape and Ctrl-C in normal mode hide the highlight and searching shows it again" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "ab ab\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "/ab\r");
    escape(&editor, &status, &buffer, &place);
    try std.testing.expectEqual(@as(?[]const u8, null), editor.highlighted());
    type_(&editor, &status, &buffer, &place, "n");
    try std.testing.expectEqualStrings("ab", editor.highlighted().?);
    type_(&editor, &status, &buffer, &place, "\x03");
    try std.testing.expectEqual(@as(?[]const u8, null), editor.highlighted());
    type_(&editor, &status, &buffer, &place, "N");
    try std.testing.expectEqualStrings("ab", editor.highlighted().?);
    // Leaving insert mode or a prompt does not hide it.
    type_(&editor, &status, &buffer, &place, "i");
    escape(&editor, &status, &buffer, &place);
    type_(&editor, &status, &buffer, &place, "/x");
    try std.testing.expectEqualStrings("x", editor.highlighted().?);
    escape(&editor, &status, &buffer, &place);
    try std.testing.expectEqualStrings("ab", editor.highlighted().?);
}

test "operators take a search from the origin as a characterwise exclusive motion" {
    const allocator = std.testing.allocator;
    const Case = struct {
        text: []const u8,
        from: usize,
        keys: []const u8,
        after: []const u8,
        at: usize,
    };
    const cases = [_]Case{
        .{ .text = "one two three\n", .from = 0, .keys = "d/thr\r", .after = "three\n", .at = 0 },
        .{
            .text = "one two three\n",
            .from = 4,
            .keys = "d?ne\r",
            .after = "otwo three\n",
            .at = 1,
        },
        .{
            .text = "one two three\n",
            .from = 0,
            .keys = "c/two\rX\x03",
            .after = "Xtwo three\n",
            .at = 0,
        },
        .{ .text = "a x b x c x\n", .from = 0, .keys = "d2/x\r", .after = "x c x\n", .at = 0 },
        .{ .text = "a x b x c x\n", .from = 0, .keys = "/x\r0dn", .after = "x b x c x\n", .at = 0 },
        .{
            .text = "a x b x c x\n",
            .from = 6,
            .keys = "/x\rcNY\x03",
            .after = "a x b Yx\n",
            .at = 6,
        },
        // A destination in column one stops at the end of the line before.
        .{ .text = "ab cd\nef\n", .from = 1, .keys = "d/ef\r", .after = "a\nef\n", .at = 0 },
        // From the line's first character it takes the whole lines.
        .{ .text = "ab cd\nef\n", .from = 0, .keys = "d/ef\r", .after = "ef\n", .at = 0 },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, case.text);
        defer buffer.deinit(allocator);
        buffer.cursor = case.from;
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(allocator);
        var place: Place = .{};
        type_(&editor, &status, &buffer, &place, case.keys);
        try std.testing.expectEqualStrings(case.after, buffer.bytes());
        try std.testing.expectEqual(case.at, buffer.cursor);
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
        // One undo step restores the text.
        type_(&editor, &status, &buffer, &place, "u");
        try std.testing.expectEqualStrings(case.text, buffer.bytes());
    }
}

test "a search motion that fails, lands on the cursor or is cancelled changes nothing" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { keys: []const u8, escape: bool = false }{
        .{ .keys = "d/zz\r" },
        .{ .keys = "c?zz\r" },
        .{ .keys = "dn" },
        // The only "b" is under the cursor, reached by wrapping.
        .{ .keys = "d/b\r" },
        .{ .keys = "c?b\r" },
        .{ .keys = "d/caf\xc3\xa9\r" },
        .{ .keys = "d/c", .escape = true },
    };
    for (cases) |case| {
        var buffer = try Buffer.fromBytes(allocator, "ab\ncd\n");
        defer buffer.deinit(allocator);
        buffer.cursor = 1;
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(allocator);
        var place: Place = .{};
        type_(&editor, &status, &buffer, &place, case.keys);
        if (case.escape) escape(&editor, &status, &buffer, &place);
        try std.testing.expectEqualStrings("ab\ncd\n", buffer.bytes());
        try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
        try std.testing.expect(!buffer.modified());
        try std.testing.expect(!try buffer.undo(allocator));
    }
}

test "a read-only file is searchable but refuses search operators at the origin" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\x00b\nb\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "/b\r");
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    type_(&editor, &status, &buffer, &place, "d/b\r");
    try std.testing.expectEqual(@as(usize, 2), buffer.cursor);
    const refused = "Read-only: invalid UTF-8 or unsupported control bytes";
    try std.testing.expectEqualStrings(refused, status.text());
    try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
}

test "allocation failures in a search operator leave text and cursor unchanged" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, searchOperatorWorkflow, .{});
}

fn searchOperatorWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "one two three\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var goal: motion.Goal = 0;
    const typed: command.Search = .{
        .target = .{ .typed = .{ .query = "thr", .direction = .forward } },
    };
    for ([_]motion.Operator{ .delete, .change }) |operator| {
        const action: command.Action = .{ .operate = .{
            .operator = operator,
            .movement = .{ .search = typed },
        } };
        editor.edit(allocator, &buffer, &goal, &status, action) catch |err| {
            try std.testing.expectEqualStrings("one two three\n", buffer.bytes());
            try std.testing.expectEqual(@as(usize, 0), buffer.cursor);
            return err;
        };
        try std.testing.expectEqualStrings("three\n", buffer.bytes());
        try std.testing.expect(try buffer.undo(allocator));
        editor.parser.cancel();
        buffer.endGroup();
    }
}

fn expectRegister(editor: *const Editor, name: u8, text: []const u8, linewise: bool) !void {
    try std.testing.expectEqualStrings(text, editor.register(name).text);
    try std.testing.expectEqual(linewise, editor.register(name).linewise);
}

test "yanks fill the unnamed register and \"0 with Vim's text and shape, and edit nothing" {
    const allocator = std.testing.allocator;
    // Text, cursor, keys, then the register's text and shape and the cursor.
    const Case = struct { []const u8, usize, []const u8, []const u8, bool, usize };
    const cases = [_]Case{
        .{ "one two three\n", 4, "yw", "two ", false, 4 },
        .{ "one two three\n", 4, "yb", "one ", false, 0 },
        .{ "one two three\n", 4, "y$", "two three", false, 4 },
        .{ "one two three\n", 4, "Y", "two three", false, 4 },
        .{ "one two three\n", 4, "y0", "one ", false, 0 },
        .{ "one two three\n", 4, "ye", "two", false, 4 },
        .{ "abcdef\nbcdef\nc\n", 10, "yk", "abcdef\nbcdef\n", true, 3 },
        .{ "abcdef\nbcdef\nc\n", 10, "yj", "bcdef\nc\n", true, 10 },
        .{ "abcdef\nbcdef\nc\n", 10, "yy", "bcdef\n", true, 10 },
        .{ "a\nbcdef\nc\nd\n", 4, "yG", "bcdef\nc\nd\n", true, 4 },
        .{ "a\nb\nc\nd\n", 2, "2Y", "b\nc", false, 2 },
        .{ "a\nb\nc\nd\n", 0, "2y3y", "a\nb\nc\nd\n", true, 0 },
        // Exclusive to column one from the line's start becomes linewise...
        .{ "ab cd\nef\n", 0, "y/ef\r", "ab cd\n", true, 0 },
        .{ "  ab cd\n  ef\n", 5, "y/ef\r", "cd\n  ", false, 5 },
        // ...but delete's whitespace promotion is delete's alone.
        .{ "ab\n  cd\n", 0, "y/cd\r", "ab\n  ", false, 0 },
        .{ "one two\nthree\n", 4, "yw", "two", false, 4 },
        .{ "one two\nthree\n", 4, "2yw", "two\nthree", false, 4 },
        .{ "one two\nthree four\n", 14, "yb", "three ", false, 8 },
        .{ "one two\nthree four\n", 14, "y?two\r", "two\nthree ", false, 4 },
        // Breaks become LF, and a linewise register's last line is terminated.
        .{ "x\r\ny\r\nz", 0, "yj", "x\ny\n", true, 0 },
        .{ "x\r\ny\r\nz", 0, "y/z\r", "x\ny\n", true, 0 },
        .{ "a\nb", 2, "yy", "b\n", true, 2 },
        .{ "", 0, "yy", "\n", true, 0 },
        .{ euro ++ wide ++ " x\n", 3, "yl", wide, false, 3 },
    };
    for (cases) |case| {
        const text, const from, const typed, const yanked, const linewise, const at = case;
        var buffer = try Buffer.fromBytes(allocator, text);
        defer buffer.deinit(allocator);
        buffer.cursor = from;
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(allocator);
        var place: Place = .{ .goal = motion.screenColumn(&buffer, from, false) };
        type_(&editor, &status, &buffer, &place, typed);
        errdefer std.debug.print("case {s}: {f}\n", .{ typed, std.zig.fmtString(text) });
        try expectRegister(&editor, '"', yanked, linewise);
        try expectRegister(&editor, '0', yanked, linewise);
        try std.testing.expectEqual(at, buffer.cursor);
        try std.testing.expectEqualStrings(text, buffer.bytes());
        try std.testing.expectEqual(@as(usize, 0), buffer.position);
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
    }
}

test "deletes and changes fill the register they name, and only unnamed yanks fill \"0" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "one\ntwo\nthree\nfour\nfive\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "yyjdd");
    try expectRegister(&editor, '"', "two\n", true);
    try expectRegister(&editor, '0', "one\n", true);
    type_(&editor, &status, &buffer, &place, "\"_dd");
    try std.testing.expectEqualStrings("one\nfour\nfive\n", buffer.bytes());
    try expectRegister(&editor, '"', "two\n", true);
    type_(&editor, &status, &buffer, &place, "\"ayy\"b2yy");
    try expectRegister(&editor, 'a', "four\n", true);
    try expectRegister(&editor, 'b', "four\nfive\n", true);
    try expectRegister(&editor, '"', "two\n", true);
    try expectRegister(&editor, '0', "one\n", true);
    type_(&editor, &status, &buffer, &place, "\"zcwFOUR\x03");
    try std.testing.expectEqualStrings("one\nFOUR\nfive\n", buffer.bytes());
    try expectRegister(&editor, 'z', "four", false);
    type_(&editor, &status, &buffer, &place, "gg\"ad/v\r");
    try std.testing.expectEqualStrings("ve\n", buffer.bytes());
    try expectRegister(&editor, 'a', "one\nFOUR\nfi", false);
    type_(&editor, &status, &buffer, &place, "cwX\x03");
    try expectRegister(&editor, '"', "ve", false);
    try expectRegister(&editor, '0', "one\n", true);
    // A failed or refused command changes no register.
    for ([_][]const u8{ "\"ai", "\"aj", "\"au", "\"0y" }) |typed| {
        type_(&editor, &status, &buffer, &place, typed);
        try std.testing.expect(status.text().len != 0);
        try expectRegister(&editor, 'a', "one\nFOUR\nfi", false);
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
    }
    try std.testing.expectEqualStrings("Unsupported register", status.text());
}

test "a delete of nothing keeps the registers, while an empty yank or change empties them" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "abc\n\nxyz\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "yyj");
    editor.clipboard = false;
    type_(&editor, &status, &buffer, &place, "d$");
    try std.testing.expectEqualStrings("abc\n\nxyz\n", buffer.bytes());
    try expectRegister(&editor, '"', "abc\n", true);
    try std.testing.expect(!editor.clipboard);
    // Neovim empties the register for these, and the clipboard follows it.
    for ([_][]const u8{ "y$", "Y", "c$" }) |typed| {
        type_(&editor, &status, &buffer, &place, "ggyyj");
        editor.clipboard = false;
        type_(&editor, &status, &buffer, &place, typed);
        try expectRegister(&editor, '"', "", false);
        try std.testing.expect(editor.clipboard);
        escape(&editor, &status, &buffer, &place);
    }
    try std.testing.expectEqualStrings("abc\n\nxyz\n", buffer.bytes());
}

test "a last line deleted with its preceding break is still one line in the register" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "a\r\nb");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "jdd");
    try std.testing.expectEqualStrings("a", buffer.bytes());
    try expectRegister(&editor, '"', "b\n", true);
    type_(&editor, &status, &buffer, &place, "u");
    type_(&editor, &status, &buffer, &place, "ccX\x03");
    try std.testing.expectEqualStrings("a\r\nX", buffer.bytes());
    try expectRegister(&editor, '"', "b\n", true);
}

test "registers carry to another document" {
    const allocator = std.testing.allocator;
    var first = try Buffer.fromBytes(allocator, "alpha\n");
    defer first.deinit(allocator);
    var second = try Buffer.fromBytes(allocator, "beta\n");
    defer second.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var first_place: Place = .{};
    var second_place: Place = .{};
    type_(&editor, &status, &first, &first_place, "\"qyw");
    type_(&editor, &status, &second, &second_place, "dw");
    try expectRegister(&editor, 'q', "alpha", false);
    try expectRegister(&editor, '"', "beta", false);
}

test "a read-only file yanks editable text and refuses the rest, keeping the registers" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "raw\xff\rline\nok\r\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "jyy");
    try expectRegister(&editor, '"', "ok\n", true);
    type_(&editor, &status, &buffer, &place, "kyy");
    const refused = "Invalid UTF-8 or unsupported control bytes; nothing yanked";
    try std.testing.expectEqualStrings(refused, status.text());
    type_(&editor, &status, &buffer, &place, "y$");
    type_(&editor, &status, &buffer, &place, "dd\"add");
    try expectRegister(&editor, '"', "ok\n", true);
    try expectRegister(&editor, '0', "ok\n", true);
    try expectRegister(&editor, 'a', "", false);
    type_(&editor, &status, &buffer, &place, "y2l");
    try expectRegister(&editor, '"', "ra", false);
    try std.testing.expectEqual(@as(usize, 0), buffer.position);
}

test "yanking more than two lines reports how many, each time" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "1\n2\n3\n4\n5\n6\n7\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "2yy");
    try std.testing.expectEqualStrings("", status.text());
    type_(&editor, &status, &buffer, &place, "y2j");
    try std.testing.expectEqualStrings("3 lines yanked", status.text());
    for ([_][]const u8{ "\"a5yy", "\"a6yy", "\"a4yy" }) |typed| {
        type_(&editor, &status, &buffer, &place, typed);
        try std.testing.expectEqual(typed[2] - '0', status.text()[0] - '0');
        try std.testing.expect(std.mem.endsWith(u8, status.text(), " lines yanked"));
    }
    // Lines 1 to 4: the search ends in column one, so the yank is linewise.
    type_(&editor, &status, &buffer, &place, "y/5\r");
    try std.testing.expectEqualStrings("4 lines yanked", status.text());
}

test "allocation failures in yanks, deletes and changes keep the text and every register" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, registerWorkflow, .{});
}

fn registerWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "one\r\ntwo\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var goal: motion.Goal = 0;
    const steps = [_]struct { operator: motion.Operator, register: u8, after: []const u8 }{
        .{ .operator = .yank, .register = '"', .after = "one\r\ntwo\n" },
        .{ .operator = .yank, .register = 'a', .after = "one\r\ntwo\n" },
        .{ .operator = .delete, .register = '"', .after = "two\n" },
        .{ .operator = .change, .register = 'b', .after = "\n" },
    };
    for (steps) |step| {
        const before = try allocator.dupe(u8, buffer.bytes());
        defer allocator.free(before);
        const unnamed = editor.register('"').text;
        const zero = editor.register('0').text;
        const action: command.Action = .{ .operate = .{
            .operator = step.operator,
            .register = step.register,
            .movement = .{ .lines = 1 },
        } };
        editor.edit(allocator, &buffer, &goal, &status, action) catch |err| {
            try std.testing.expectEqualStrings(before, buffer.bytes());
            try std.testing.expectEqual(unnamed.ptr, editor.register('"').text.ptr);
            try std.testing.expectEqual(zero.ptr, editor.register('0').text.ptr);
            return err;
        };
        try std.testing.expectEqualStrings(step.after, buffer.bytes());
        if (step.operator == .change) try editor.edit(
            allocator,
            &buffer,
            &goal,
            &status,
            .end_insert,
        );
    }
    try expectRegister(&editor, '0', "one\n", true);
    try expectRegister(&editor, 'a', "one\n", true);
    try expectRegister(&editor, '"', "one\n", true);
    try expectRegister(&editor, 'b', "two\n", true);
}

test "p and P put after real yanks with Vim's text and cursor, as one undo step" {
    const allocator = std.testing.allocator;
    // Text, cursor, keys, then the text and cursor after the put.
    const Case = struct { []const u8, usize, []const u8, []const u8, usize };
    const cases = [_]Case{
        .{ "one two\n", 0, "ywP", "one one two\n", 3 },
        .{ "one two\n", 0, "yw$p", "one twoone \n", 10 },
        .{ "ab\n", 0, "yl3p", "aaaab\n", 3 },
        .{ "ab\n", 0, "yl3P", "aaaab\n", 2 },
        .{ "ab\n\n", 0, "yljp", "ab\na\n", 3 },
        .{ euro ++ wide ++ " x\n", 3, "ylp", euro ++ wide ++ wide ++ " x\n", 6 },
        // A multi-line characterwise put leaves the cursor at its start.
        .{ "ab\ncd\n", 1, "y/d\rp", "abb\nc\ncd\n", 2 },
        .{ "a\nb\n", 0, "yyjp", "a\nb\na\n", 4 },
        .{ "a\nb\n", 0, "yyjP", "a\na\nb\n", 2 },
        .{ "  x\ny\n", 0, "yyj3p", "  x\ny\n  x\n  x\n  x\n", 8 },
        .{ "a\nb\n", 2, "yy2P", "a\nb\nb\nb\n", 2 },
        // Below an unterminated last line, the file keeps no final newline.
        .{ "a\nb", 0, "yyjp", "a\nb\na", 4 },
        .{ "a\nb", 0, "yyj2p", "a\nb\na\na", 4 },
        .{ "a\nb", 2, "yyP", "a\nb\nb", 2 },
        // Every LF becomes the terminator where the text lands.
        .{ "a\nb\r\nc\r\n", 0, "yyjp", "a\nb\r\na\r\nc\r\n", 5 },
        .{ "a\r\nb\n", 0, "yyjp", "a\r\nb\na\n", 5 },
        .{ "ab\r\ncd\r\n", 1, "y/d\rp", "abb\r\nc\r\ncd\r\n", 2 },
    };
    for (cases) |case| {
        const text, const from, const typed, const after, const at = case;
        var buffer = try Buffer.fromBytes(allocator, text);
        defer buffer.deinit(allocator);
        buffer.cursor = from;
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(allocator);
        var place: Place = .{ .goal = motion.screenColumn(&buffer, from, false) };
        type_(&editor, &status, &buffer, &place, typed);
        errdefer std.debug.print("case {s}: {f}\n", .{ typed, std.zig.fmtString(text) });
        try std.testing.expectEqualStrings(after, buffer.bytes());
        try std.testing.expectEqual(at, buffer.cursor);
        try std.testing.expectEqual(@as(usize, 1), buffer.position);
        try std.testing.expectEqual(command.Mode.normal, editor.parser.mode);
        type_(&editor, &status, &buffer, &place, "u");
        try std.testing.expectEqualStrings(text, buffer.bytes());
        try std.testing.expect(!buffer.modified());
        type_(&editor, &status, &buffer, &place, "\x12");
        try std.testing.expectEqualStrings(after, buffer.bytes());
        try std.testing.expectEqual(at, buffer.cursor);
    }
}

test "puts into an empty buffer and across documents convert breaks for the target" {
    const allocator = std.testing.allocator;
    var crlf = try Buffer.fromBytes(allocator, "one\r\ntwo\r\n");
    defer crlf.deinit(allocator);
    var empty = try Buffer.fromBytes(allocator, "");
    defer empty.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var crlf_place: Place = .{};
    var empty_place: Place = .{};
    type_(&editor, &status, &crlf, &crlf_place, "yj");
    // Vim's two lines: the empty one, then the put lines.
    type_(&editor, &status, &empty, &empty_place, "p");
    try std.testing.expectEqualStrings("\none\ntwo", empty.bytes());
    try std.testing.expectEqual(@as(usize, 1), empty.cursor);
    type_(&editor, &status, &empty, &empty_place, "u");
    try std.testing.expectEqualStrings("", empty.bytes());
    type_(&editor, &status, &empty, &empty_place, "P");
    try std.testing.expectEqualStrings("one\ntwo\n", empty.bytes());
    try std.testing.expectEqual(@as(usize, 0), empty.cursor);
    // And back: LF text put into the CRLF file gets CRLF.
    type_(&editor, &status, &empty, &empty_place, "yy");
    type_(&editor, &status, &crlf, &crlf_place, "Gp");
    try std.testing.expectEqualStrings("one\r\ntwo\r\none\r\n", crlf.bytes());
}

test "register interactions: moves, \"0 after a delete, the black hole and named puts" {
    const allocator = std.testing.allocator;
    const Case = struct { []const u8, []const u8, []const u8 };
    const cases = [_]Case{
        .{ "one two\n", "dw$p", "twoone \n" },
        .{ "a\nb\nc\n", "ddp", "b\na\nc\n" },
        .{ "a\nb\nc\n", "yyjdd\"0p", "a\nc\na\n" },
        .{ "a\nb\nc\n", "yyj\"_ddp", "a\nc\na\n" },
        .{ "a\nb\nc\n", "yyj\"ayyjp", "a\nb\nc\na\n" },
        .{ "a\nb\nc\n", "yyj\"ayyj\"ap", "a\nb\nc\nb\n" },
        .{ "a foo b\n", "\"ay/foo\r$\"aP", "a foo a b\n" },
        .{ "a b c d\n", "\"a3dw\"ap", "da b c \n" },
    };
    for (cases) |case| {
        const text, const typed, const after = case;
        var buffer = try Buffer.fromBytes(allocator, text);
        defer buffer.deinit(allocator);
        var editor: Editor = .{};
        var status: Status = .{};
        defer editor.deinit(allocator);
        var place: Place = .{};
        type_(&editor, &status, &buffer, &place, typed);
        errdefer std.debug.print("case {s}: {f}\n", .{ typed, std.zig.fmtString(text) });
        try std.testing.expectEqualStrings(after, buffer.bytes());
    }
}

test "a put with nothing to put, in a read-only file or over the caps changes nothing" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "ab\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "p");
    try std.testing.expectEqualStrings("Register empty", status.text());
    type_(&editor, &status, &buffer, &place, "\"qP");
    try std.testing.expectEqualStrings("Register empty", status.text());
    type_(&editor, &status, &buffer, &place, "yy");
    // 4 MiB copies of three bytes, and a count that overflows the size.
    const refused = [_]struct { []const u8, []const u8 }{
        .{ "4194304p", "Edit exceeds temporary 8 MiB limit" },
        .{ "9223372036854775807P", "Edit exceeds temporary 8 MiB limit" },
        .{ "262144p", "Edit exceeds temporary 262,144-line limit" },
        .{ "\"_p", "Unsupported register" },
    };
    for (refused) |case| {
        const typed, const notice = case;
        type_(&editor, &status, &buffer, &place, "l");
        type_(&editor, &status, &buffer, &place, typed);
        try std.testing.expectEqualStrings(notice, status.text());
        try std.testing.expectEqualStrings("ab\n", buffer.bytes());
        try std.testing.expectEqual(@as(usize, 1), buffer.cursor);
        try std.testing.expectEqual(@as(usize, 0), buffer.position);
    }
    var read_only = try Buffer.fromBytes(allocator, "raw\xff\nok\n");
    defer read_only.deinit(allocator);
    type_(&editor, &status, &read_only, &place, "jyyp");
    const refused_edit = "Read-only: invalid UTF-8 or unsupported control bytes";
    try std.testing.expectEqualStrings(refused_edit, status.text());
    try std.testing.expectEqualStrings("raw\xff\nok\n", read_only.bytes());
    try std.testing.expectEqual(@as(usize, 0), read_only.position);
    try expectRegister(&editor, '"', "ok\n", true);
}

test "putting more than two lines reports how many, each time" {
    const allocator = std.testing.allocator;
    var buffer = try Buffer.fromBytes(allocator, "x\n");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    type_(&editor, &status, &buffer, &place, "yy2p");
    try std.testing.expectEqualStrings("", status.text());
    for ([_][]const u8{ "3p", "4p", "5P" }) |typed| {
        type_(&editor, &status, &buffer, &place, typed);
        try std.testing.expectEqual(typed[0] - '0', status.text()[0] - '0');
        try std.testing.expect(std.mem.endsWith(u8, status.text(), " more lines"));
    }
}

test "allocation failures in puts keep the text, cursor and history" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, putWorkflow, .{});
}

fn putWorkflow(allocator: Allocator) !void {
    var buffer = try Buffer.fromBytes(allocator, "one\r\ntwo");
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var goal: motion.Goal = 0;
    const yank: command.Action = .{ .operate = .{
        .operator = .yank,
        .movement = .{ .lines = 1 },
    } };
    try editor.edit(allocator, &buffer, &goal, &status, yank);
    const steps = [_]struct { put: command.Put, after: []const u8 }{
        .{ .put = .{ .count = 2, .side = .before }, .after = "one\r\none\r\none\r\ntwo" },
        .{ .put = .{ .side = .after }, .after = "one\r\none\r\none\r\none\r\ntwo" },
    };
    for (steps) |step| {
        const before = try allocator.dupe(u8, buffer.bytes());
        defer allocator.free(before);
        const cursor = buffer.cursor;
        const position = buffer.position;
        editor.edit(allocator, &buffer, &goal, &status, .{ .put = step.put }) catch |err| {
            try std.testing.expectEqualStrings(before, buffer.bytes());
            try std.testing.expectEqual(cursor, buffer.cursor);
            try std.testing.expectEqual(position, buffer.position);
            try expectRegister(&editor, '"', "one\n", true);
            return err;
        };
        try std.testing.expectEqualStrings(step.after, buffer.bytes());
    }
}

test "the clipboard takes unnamed writes up to 1 MiB and refuses larger ones with a notice" {
    const allocator = std.testing.allocator;
    // 1024 lines of 1 KiB make exactly 1 MiB, then one empty line more.
    const text = try allocator.alloc(u8, clipboard_limit + 1);
    defer allocator.free(text);
    @memset(text, 'x');
    for (1..1025) |number| text[number * 1024 - 1] = '\n';
    text[clipboard_limit] = '\n';
    var buffer = try Buffer.fromBytes(allocator, text);
    defer buffer.deinit(allocator);
    var editor: Editor = .{};
    var status: Status = .{};
    defer editor.deinit(allocator);
    var place: Place = .{};
    // Neither the black hole nor a named register reaches the clipboard.
    type_(&editor, &status, &buffer, &place, "\"_yy\"ayy\"_dd\"add");
    try std.testing.expect(!editor.clipboard);
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expect(try buffer.undo(allocator));
    try std.testing.expectEqualStrings(text, buffer.bytes());
    type_(&editor, &status, &buffer, &place, "gg1024yy");
    try std.testing.expect(editor.clipboard);
    try std.testing.expectEqualStrings("1024 lines yanked", status.text());
    try std.testing.expectEqual(@as(usize, clipboard_limit), editor.register('"').text.len);
    // One byte more stays in the registers, and cancels the earlier write,
    // which would now send the larger text.
    type_(&editor, &status, &buffer, &place, "yG");
    try std.testing.expect(!editor.clipboard);
    try std.testing.expectEqualStrings("Not copied to the clipboard: over 1 MiB", status.text());
    try expectRegister(&editor, '0', text, true);
    try expectRegister(&editor, '"', text, true);
    // Deletes and changes write the clipboard too.
    type_(&editor, &status, &buffer, &place, "dd");
    try std.testing.expect(editor.clipboard);
    try std.testing.expectEqualStrings("", status.text());
    editor.clipboard = false;
    type_(&editor, &status, &buffer, &place, "cw");
    try std.testing.expect(editor.clipboard);
    escape(&editor, &status, &buffer, &place);
    type_(&editor, &status, &buffer, &place, "uugg");
    try std.testing.expectEqualStrings(text, buffer.bytes());
    editor.clipboard = false;
    type_(&editor, &status, &buffer, &place, "dG");
    try std.testing.expect(!editor.clipboard);
    try std.testing.expectEqualStrings("Not copied to the clipboard: over 1 MiB", status.text());
    try std.testing.expectEqualStrings("", buffer.bytes());
}
