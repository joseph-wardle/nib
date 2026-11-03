// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");

pub const escape_ms = 100;
pub const Event = union(enum) {
    key: u8,
    escape,
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

/// Terminal framing only. Recognized sequences never time out into key events.
/// Paste is streamed, including hostile bytes; its consumer owns validation and
/// atomic collection. Only an unrecognized, lone ESC has a deadline.
pub const Decoder = struct {
    state: enum { ground, escape, intermediate, csi, string, string_escape, paste } = .ground,
    deadline: ?i64 = null,
    paste_end: usize = 0,
    string_bell: bool = false,
    parameter: usize = 0,
    plain_parameter: bool = true,

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
            .ground => if (byte == 0x1b) {
                self.state = .escape;
                self.deadline = now + escape_ms;
            } else events.add(.{ .key = byte }),
            .escape => {
                const lone = self.deadline != null;
                self.deadline = null;
                switch (byte) {
                    '[' => {
                        self.state = .csi;
                        self.parameter = 0;
                        self.plain_parameter = true;
                        events.add(.ignored);
                    },
                    ']', 'P', 'X', '^', '_' => {
                        self.state = .string;
                        self.string_bell = byte == ']';
                        events.add(.ignored);
                    },
                    'O', 0x20...0x2f => {
                        self.state = .intermediate;
                        events.add(.ignored);
                    },
                    0x1b => {
                        if (lone) {
                            events.add(.escape);
                            self.deadline = now + escape_ms;
                        }
                    },
                    else => {
                        self.state = .ground;
                        if (lone) {
                            events.add(.escape);
                            events.add(.{ .key = byte });
                        }
                    },
                }
            },
            .intermediate => {
                if (byte == 0x1b) self.state = .escape else if (byte >= 0x30 and byte <= 0x7e) self.state = .ground;
            },
            .csi => {
                if (byte == 0x1b) {
                    // An ESC inside a recognized sequence starts another
                    // shielded sequence, never a timed standalone key.
                    self.state = .escape;
                } else if (byte >= 0x40 and byte <= 0x7e) {
                    self.state = if (byte == '~' and self.plain_parameter and self.parameter == 200) .paste else .ground;
                    self.paste_end = 0;
                    if (self.state == .paste) events.add(.paste_begin);
                } else if (byte >= '0' and byte <= '9') {
                    self.parameter = @min(1000, self.parameter * 10 + byte - '0');
                } else self.plain_parameter = false;
            },
            .string => {
                if (byte == 0x07 and self.string_bell) self.state = .ground else if (byte == 0x1b) self.state = .string_escape;
            },
            .string_escape => {
                self.state = if (byte == '\\') .ground else if (byte == 0x1b) .string_escape else .string;
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
};

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
    for ([_][]const u8{ "\x1b[A", "\x1bOq", "\x1b[9999999999999q", "\x1b]qhjkl\x07", "\x1bPq\x07hjkl\x1b\\", "\x1bXqhjkl\x1b\\", "\x1b^qhjkl\x1b\\", "\x1b(B", "\x1b[123\x1b]qhjkl\x07", "\x1bO\x1bPqhjkl\x1b\\" }) |sequence| {
        var decoder: Decoder = .{};
        for (sequence, 0..) |byte, index| {
            // Prefix arrives promptly; recognized payload may be arbitrarily late.
            const events = decoder.feed(byte, if (index < 2) @intCast(index) else @intCast(index * 1000));
            for (events.items[0..events.len]) |event| try std.testing.expect(event == .ignored);
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
