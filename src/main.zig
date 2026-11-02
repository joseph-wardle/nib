// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const terminal = @import("terminal.zig");

pub fn main(init: std.process.Init) u8 {
    var session = terminal.Terminal.open() catch |err| {
        report(init.io, err);
        return 1;
    };
    const outcome = run(&session);
    const cleanup = session.close();
    // Diagnostics follow cleanup so they remain visible in the shell.
    var code = outcome catch |err| code: {
        report(init.io, err);
        break :code @as(u8, 1);
    };
    cleanup catch |err| {
        report(init.io, err);
        code = 1;
    };
    return code;
}

fn run(session: *terminal.Terminal) terminal.Error!u8 {
    while (true) {
        switch (try session.next()) {
            .redraw => |dimensions| {
                try terminal.write("\x1b[H\x1b[2J");
                const message = "Nib terminal foundation: q quit, Ctrl-Z suspend";
                if (dimensions.rows > 0 and dimensions.columns > 1)
                    try terminal.write(message[0..@min(message.len, dimensions.columns - 1)]);
            },
            .input => |byte| if (byte == 'q') {
                return 0;
            },
            .quit => |code| {
                return code;
            },
        }
    }
}

fn report(io: std.Io, err: terminal.Error) void {
    const message = switch (err) {
        error.NotATerminal => "stdin and stdout must be the controlling terminal",
        error.NotForeground => "run Nib as a foreground terminal job",
        else => @errorName(err),
    };
    var buffer: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "nib: {s}\n", .{message}) catch unreachable;
    std.Io.File.stderr().writeStreamingAll(io, text) catch {};
}
