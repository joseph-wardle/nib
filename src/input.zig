// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

pub const escape_ms = 100;
pub const Arrow = enum { up, down, right, left };
pub const Event = union(enum) {
    key: u8,
    escape,
    /// An unparameterised cursor key, in CSI or SS3 form. Other sequences
    /// stay `ignored`.
    arrow: Arrow,
    ignored,
    paste_begin,
    paste_byte: u8,
    paste_end,
};

/// A failed paste delimiter can release at most five withheld payload bytes.
/// Events borrow no storage and must be handled in order before the next feed.
pub const Events = struct {
    items: [7]Event = undefined,
    len: usize = 0,

    fn add(self: *Events, event: Event) void {
        self.items[self.len] = event;
        self.len += 1;
    }
};

/// Terminal framing only. CSI and SS3 are the only sequences recognized: Nib
/// sends no queries, so terminals send nothing else, and Escape followed by
/// any other byte is that key. Recognized sequences never time out into key
/// events, but a control byte ends them and arrives as a key, so Ctrl-C always
/// gets through. Paste is streamed, including hostile bytes; its consumer owns
/// validation and atomic collection. Only an ESC has a deadline.
pub const Decoder = struct {
    state: enum { ground, escape, ss3, csi, paste } = .ground,
    deadline: ?i64 = null,
    paste_end: usize = 0,
    parameter: usize = 0,
    plain_parameter: bool = true,
    digits: bool = false,

    pub fn expire(self: *Decoder, now: i64) Events {
        var events: Events = .{};
        if (self.deadline) |deadline| if (now >= deadline) {
            self.deadline = null;
            self.state = .ground;
            events.add(.escape);
        };
        return events;
    }

    pub fn feed(self: *Decoder, byte: u8, now: i64) Events {
        var events = self.expire(now);
        switch (self.state) {
            .ground => if (byte == 0x1b) self.escape(now) else events.add(.{ .key = byte }),
            .escape => {
                self.deadline = null;
                switch (byte) {
                    '[' => {
                        self.state = .csi;
                        self.parameter = 0;
                        self.plain_parameter = true;
                        self.digits = false;
                        events.add(.ignored);
                    },
                    'O' => {
                        self.state = .ss3;
                        events.add(.ignored);
                    },
                    0x1b => {
                        events.add(.escape);
                        self.escape(now);
                    },
                    else => {
                        self.state = .ground;
                        events.add(.escape);
                        events.add(.{ .key = byte });
                    },
                }
            },
            .ss3 => {
                if (byte == 0x1b) self.escape(now) else if (control(byte)) {
                    self.state = .ground;
                    events.add(.{ .key = byte });
                } else if (byte >= 0x30 and byte <= 0x7e) {
                    self.state = .ground;
                    if (arrow(byte)) |direction| events.add(.{ .arrow = direction });
                }
            },
            .csi => {
                // Terminals send whole sequences, so a person typed this ESC.
                if (byte == 0x1b) self.escape(now) else if (control(byte)) {
                    self.state = .ground;
                    events.add(.{ .key = byte });
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = if (byte == '~' and self.plain_parameter and self.parameter == 200) .paste else .ground;
                    self.paste_end = 0;
                    if (self.state == .paste) events.add(.paste_begin);
                    const bare = self.plain_parameter and !self.digits;
                    if (bare) if (arrow(byte)) |direction| events.add(.{ .arrow = direction });
                } else if (byte >= '0' and byte <= '9') {
                    self.digits = true;
                    self.parameter = @min(1000, self.parameter * 10 + byte - '0');
                } else self.plain_parameter = false;
            },
            .paste => {
                const end = "\x1b[201~";
                if (byte == end[self.paste_end]) {
                    self.paste_end += 1;
                    if (self.paste_end == end.len) {
                        self.state = .ground;
                        self.paste_end = 0;
                        events.add(.paste_end);
                    }
                } else {
                    for (end[0..self.paste_end]) |held| events.add(.{ .paste_byte = held });
                    self.paste_end = if (byte == end[0]) 1 else 0;
                    if (self.paste_end == 0) events.add(.{ .paste_byte = byte });
                }
            },
        }
        return events;
    }

    fn escape(self: *Decoder, now: i64) void {
        self.state = .escape;
        self.deadline = now + escape_ms;
    }
};

/// Terminals never put these inside an input sequence; a person typed them.
fn control(byte: u8) bool {
    return (byte < 0x20 and byte != 0x1b) or byte == 0x7f;
}

fn arrow(final: u8) ?Arrow {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        else => null,
    };
}

test "only lone Escape expires; unambiguous rapid commands survive" {
    var decoder: Decoder = .{};
    try std.testing.expectEqual(@as(usize, 0), decoder.feed(0x1b, 0).len);
    try std.testing.expectEqual(@as(usize, 0), decoder.expire(99).len);
    try std.testing.expectEqualDeep(Event.escape, decoder.expire(100).items[0]);
    try std.testing.expect(decoder.deadline == null);
    _ = decoder.feed(0x1b, 200);
    const rapid = decoder.feed('i', 201);
    try std.testing.expectEqual(@as(usize, 2), rapid.len);
    try std.testing.expectEqualDeep(Event.escape, rapid.items[0]);
    try std.testing.expectEqualDeep(Event{ .key = 'i' }, rapid.items[1]);
    _ = decoder.feed(0x1b, 300);
    const waited = decoder.feed('O', 400);
    try std.testing.expectEqualDeep(Event.escape, waited.items[0]);
    try std.testing.expectEqualDeep(Event{ .key = 'O' }, waited.items[1]);
}

test "recognized sequences retain framing across arbitrary delays" {
    for ([_][]const u8{ "\x1b[A", "\x1bOq", "\x1b[9999999999999q", "\x1b[?2004;1$y", "\x1b[1;5A" }) |sequence| {
        var decoder: Decoder = .{};
        for (sequence, 0..) |byte, index| {
            // Prefix arrives promptly; recognized payload may be arbitrarily late.
            const events = decoder.feed(byte, if (index < 2) @intCast(index) else @intCast(index * 1000));
            for (events.items[0..events.len]) |event| {
                try std.testing.expect(event == .ignored or event == .arrow);
            }
            if (index != 0) try std.testing.expect(decoder.deadline == null);
        }
        try std.testing.expectEqualDeep(Event{ .key = 'j' }, decoder.feed('j', 99999).items[0]);
    }
}

test "paste framing preserves exact payload including false and overlapping delimiters" {
    var decoder: Decoder = .{};
    const payload = "q\x03\x1b[20x\x1b\x1b[201X\r\n";
    var collected: [128]u8 = undefined;
    var used: usize = 0;
    var began = false;
    var ended = false;
    for ("\x1b[200~" ++ payload ++ "\x1b[201~") |byte| {
        const events = decoder.feed(byte, 0);
        for (events.items[0..events.len]) |event| switch (event) {
            .ignored => {},
            .paste_begin => began = true,
            .paste_end => ended = true,
            .paste_byte => |value| {
                collected[used] = value;
                used += 1;
            },
            else => return error.PayloadEscaped,
        };
    }
    try std.testing.expect(began and ended);
    try std.testing.expectEqualStrings(payload, collected[0..used]);
    try std.testing.expectEqualDeep(Event{ .key = 'q' }, decoder.feed('q', 0).items[0]);
}

test "bare cursor keys decode as arrows in CSI and SS3 form; modified ones stay ignored" {
    const cases = [_]struct { bytes: []const u8, arrow: ?Arrow }{
        .{ .bytes = "\x1b[A", .arrow = .up },
        .{ .bytes = "\x1b[B", .arrow = .down },
        .{ .bytes = "\x1bOB", .arrow = .down },
        .{ .bytes = "\x1bOD", .arrow = .left },
        .{ .bytes = "\x1b[1;5A", .arrow = null },
        .{ .bytes = "\x1b[2A", .arrow = null },
        .{ .bytes = "\x1b[?A", .arrow = null },
        .{ .bytes = "\x1bOq", .arrow = null },
    };
    for (cases) |case| {
        var decoder: Decoder = .{};
        var found: ?Arrow = null;
        for (case.bytes) |byte| {
            const events = decoder.feed(byte, 0);
            for (events.items[0..events.len]) |event| switch (event) {
                .arrow => |direction| found = direction,
                .ignored => {},
                else => return error.UnexpectedEvent,
            };
        }
        try std.testing.expectEqual(case.arrow, found);
        try std.testing.expectEqualDeep(Event{ .key = 'j' }, decoder.feed('j', 0).items[0]);
    }
}

test "Escape before any byte but [ or O is that key, and control bytes end sequences" {
    // Konsole sends Alt+key as Escape and the key; none of these may capture
    // what follows.
    for ("]PX^_ /(\\") |second| {
        var decoder: Decoder = .{};
        _ = decoder.feed(0x1b, 0);
        const events = decoder.feed(second, 10);
        try std.testing.expectEqual(@as(usize, 2), events.len);
        try std.testing.expectEqualDeep(Event.escape, events.items[0]);
        try std.testing.expectEqualDeep(Event{ .key = second }, events.items[1]);
        for ("hj\x03:q\r", 0..) |byte, index| {
            const later = decoder.feed(byte, @intCast(1000 + index * 1000));
            try std.testing.expectEqual(@as(usize, 1), later.len);
            try std.testing.expectEqualDeep(Event{ .key = byte }, later.items[0]);
        }
    }
    // An unfinished CSI or SS3 never swallows a control key, and an Escape
    // typed inside one is a lone Escape.
    for ([_][]const u8{ "\x1b[", "\x1b[12;", "\x1bO" }) |prefix| for ("\x03\r\x7f") |key| {
        var decoder: Decoder = .{};
        for (prefix) |byte| _ = decoder.feed(byte, 0);
        const events = decoder.feed(key, 5000);
        try std.testing.expectEqual(@as(usize, 1), events.len);
        try std.testing.expectEqualDeep(Event{ .key = key }, events.items[0]);
        try std.testing.expectEqualDeep(Event{ .key = 'j' }, decoder.feed('j', 5001).items[0]);
        for (prefix) |byte| _ = decoder.feed(byte, 6000);
        try std.testing.expectEqual(@as(usize, 0), decoder.feed(0x1b, 6001).len);
        try std.testing.expectEqualDeep(Event.escape, decoder.expire(6101).items[0]);
    };
}
