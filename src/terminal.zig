// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Size = struct { rows: u16, columns: u16 };
pub const Event = union(enum) { input: u8, redraw: Size, quit: u8 };
pub const Error = error{
    NotATerminal,
    NotForeground,
    TerminalUnavailable,
    SignalSetupFailed,
    SignalReadFailed,
    WaitFailed,
    InputFailed,
    OutputFailed,
    OutputBlocked,
    Interrupted,
    SuspendFailed,
    CloseFailed,
};

const nonblocking = @as(u32, @bitCast(linux.O{ .NONBLOCK = true }));
const screen_cleanup = "\x1b[0m\x1b[?2004r\x1b[?1049l\x1b[?25r";

const handled_signals = [_]posix.SIG{ .INT, .TERM, .HUP, .TSTP, .CONT, .WINCH };

/// Owns the signal descriptor and saved process/terminal state. stdin/stdout
/// remain borrowed. Call close even when next or write fails. Use on the main
/// thread, before starting any concurrent work, so the signal mask is inherited.
pub const Terminal = struct {
    saved_mode: posix.termios,
    saved_mask: posix.sigset_t,
    signal_fd: posix.fd_t,
    saved_output_flags: usize,
    output_flags_active: bool = false,
    pending: Signals = .{},
    mode_active: bool = false,
    screen_active: bool = false,

    pub fn open() Error!Terminal {
        const saved_mode = posix.tcgetattr(0) catch return error.NotATerminal;
        if (!try foreground()) return error.NotForeground;
        // Validate stdout as the controlling terminal too, before any mutation.
        _ = posix.tcgetpgrp(1) catch return error.NotATerminal;
        const output_flags = linux.fcntl(1, linux.F.GETFL, 0);
        if (posix.errno(output_flags) != .SUCCESS) return error.OutputFailed;
        var mask = posix.sigemptyset();
        for (handled_signals) |sig| posix.sigaddset(&mask, sig);
        var saved_mask: posix.sigset_t = undefined;
        posix.sigprocmask(posix.SIG.BLOCK, &mask, &saved_mask);
        errdefer posix.sigprocmask(posix.SIG.SETMASK, &saved_mask, null);
        const result = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
        if (posix.errno(result) != .SUCCESS) return error.SignalSetupFailed;
        return .{ .saved_mode = saved_mode, .saved_mask = saved_mask, .signal_fd = @intCast(result), .saved_output_flags = output_flags };
    }

    pub fn close(self: *Terminal) Error!void {
        // Release every acquired resource even when terminal cleanup fails.
        defer posix.sigprocmask(posix.SIG.SETMASK, &self.saved_mask, null);
        var failure: ?Error = null;
        self.leave() catch |err| {
            failure = err;
        };
        if (posix.errno(linux.close(self.signal_fd)) != .SUCCESS and failure == null)
            failure = error.CloseFailed;
        if (failure) |err| return err;
    }

    fn enter(self: *Terminal) Error!void {
        var mode = self.saved_mode;
        mode.lflag.ICANON = false;
        mode.lflag.ECHO = false;
        mode.lflag.ECHONL = false;
        mode.lflag.IEXTEN = false;
        mode.lflag.ISIG = true;
        mode.iflag.IXON = false;
        mode.iflag.ICRNL = false;
        mode.oflag.OPOST = false;
        mode.cc[@backingInt(linux.V.MIN)] = 1;
        mode.cc[@backingInt(linux.V.TIME)] = 0;
        posix.tcsetattr(0, .NOW, mode) catch return error.TerminalUnavailable;
        self.mode_active = true;
        try self.setOutputNonblocking();
        // A suspension may have left screen cleanup queued behind stalled
        // output. Finish it before saving modes again, or we would save our
        // hidden cursor/paste state as the shell's original state.
        if (self.screen_active) {
            try self.write(screen_cleanup);
            self.screen_active = false;
        }
        // Mark the screen acquired before output: a partial write must unwind.
        // Save/restore bracketed paste as well as cursor visibility in Konsole.
        // Pasted text is discarded by the input parser, never run as commands.
        self.screen_active = true;
        try self.write("\x1b[?25s\x1b[?1049h\x1b[?25l\x1b[?2004s\x1b[?2004h");
    }

    fn leave(self: *Terminal) Error!void {
        var failure: ?Error = null;
        if (self.mode_active) {
            posix.tcsetattr(0, .NOW, self.saved_mode) catch {
                failure = error.TerminalUnavailable;
            };
            self.mode_active = false;
        }
        if (self.screen_active) {
            self.setOutputNonblocking() catch |err| {
                if (failure == null) failure = err;
            };
            if (self.output_flags_active) {
                if (writeCleanup(screen_cleanup)) |_| {
                    self.screen_active = false;
                } else |err| {
                    if (failure == null) failure = err;
                }
            }
        }
        if (self.output_flags_active) {
            if (posix.errno(linux.fcntl(1, linux.F.SETFL, self.saved_output_flags)) != .SUCCESS) {
                if (failure == null) failure = error.OutputFailed;
            } else self.output_flags_active = false;
        }
        if (failure) |err| return err;
    }

    /// Blocks until input or a lifecycle event. Signals are drained before
    /// entering/redrawing, so a queued termination wins over resume or input.
    pub fn next(self: *Terminal) Error!Event {
        while (true) {
            try self.readSignals();
            const signals = self.pending;
            self.pending = .{};
            if (signals.exit_code) |code| return .{ .quit = code };
            if (signals.should_suspend) {
                self.leave() catch |err| {
                    if (err != error.OutputBlocked) return err;
                    // Termios/descriptor flags are already restored. A stalled
                    // screen must not prevent stopping; resume retries it.
                    writeDiagnostic("nib: screen cleanup blocked by terminal output\n");
                };
                // Cleanup can wait briefly for output. Termination received
                // during that wait still takes precedence over stopping.
                try self.readSignals();
                if (self.pending.exit_code) |code| return .{ .quit = code };
                self.pending.should_suspend = false;
                // SIGTSTP was consumed by signalfd. SIGSTOP actually stops us;
                // unlike SIGTSTP it cannot be swallowed by our blocked mask.
                posix.kill(linux.getpid(), .STOP) catch return error.SuspendFailed;
                continue;
            }
            if (!try foreground()) {
                // zsh need not send SIGCONT when foregrounding a running job.
                // Stay stopped after bg, like a program needing terminal input,
                // so a later fg will reliably resume us without polling.
                posix.kill(linux.getpid(), .STOP) catch return error.SuspendFailed;
                continue;
            }
            if (!self.mode_active) {
                self.enter() catch |err| {
                    if (err == error.Interrupted) continue;
                    return err;
                };
                return .{ .redraw = try size() };
            }
            if (signals.resize) return .{ .redraw = try size() };

            var fds = [_]linux.pollfd{
                .{ .fd = self.signal_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = 0, .events = linux.POLL.IN, .revents = 0 },
            };
            const result = linux.poll(&fds, fds.len, -1);
            switch (posix.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.WaitFailed,
            }
            if (fds[0].revents != 0) {
                if (fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                    return error.SignalReadFailed;
                continue;
            }
            if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0)
                return error.TerminalUnavailable;
            if (fds[1].revents & linux.POLL.IN != 0) {
                var byte: [1]u8 = undefined;
                const count = linux.read(0, &byte, 1);
                switch (posix.errno(count)) {
                    .SUCCESS => if (count == 0) return error.TerminalUnavailable else return .{ .input = byte[0] },
                    .INTR, .AGAIN => continue,
                    else => return error.InputFailed,
                }
            }
        }
    }

    fn setOutputNonblocking(self: *Terminal) Error!void {
        if (self.output_flags_active) return;
        if (posix.errno(linux.fcntl(1, linux.F.SETFL, self.saved_output_flags | nonblocking)) != .SUCCESS)
            return error.OutputFailed;
        self.output_flags_active = true;
    }

    /// Writes a frame while observing lifecycle signals under backpressure.
    /// Interrupted means abandon the frame and call next to handle the signal.
    pub fn write(self: *Terminal, bytes: []const u8) Error!void {
        try self.readSignals();
        if (self.pending.exit_code != null or self.pending.should_suspend) return error.Interrupted;
        var remaining = bytes;
        while (remaining.len != 0) {
            remaining = try writeAvailable(1, remaining);
            if (remaining.len == 0) return;
            var fds = [_]linux.pollfd{
                .{ .fd = self.signal_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = 1, .events = linux.POLL.OUT, .revents = 0 },
            };
            const result = linux.poll(&fds, fds.len, -1);
            switch (posix.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.WaitFailed,
            }
            if (fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                return error.SignalReadFailed;
            if (fds[0].revents & linux.POLL.IN != 0) {
                try self.readSignals();
                if (self.pending.exit_code != null or self.pending.should_suspend)
                    return error.Interrupted;
            }
            if (fds[1].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                return error.OutputFailed;
        }
    }

    const Signals = struct { exit_code: ?u8 = null, should_suspend: bool = false, resize: bool = false };

    fn readSignals(self: *Terminal) Error!void {
        while (true) {
            var info: linux.signalfd_siginfo = undefined;
            const count = linux.read(self.signal_fd, @ptrCast(&info), @sizeOf(@TypeOf(info)));
            switch (posix.errno(count)) {
                .AGAIN => return,
                .INTR => continue,
                .SUCCESS => {},
                else => return error.SignalReadFailed,
            }
            if (count != @sizeOf(@TypeOf(info))) return error.SignalReadFailed;
            switch (@as(posix.SIG, @fromBackingInt(@intCast(info.signo)))) {
                .INT, .TERM, .HUP => self.pending.exit_code = @intCast(128 + info.signo),
                .TSTP => self.pending.should_suspend = true,
                .WINCH => self.pending.resize = true,
                .CONT => {},
                else => unreachable,
            }
        }
    }
};

fn foreground() Error!bool {
    const group = linux.getpgid(0);
    if (posix.errno(group) != .SUCCESS) return error.TerminalUnavailable;
    const terminal_group = posix.tcgetpgrp(0) catch return error.NotATerminal;
    return terminal_group == @as(posix.pid_t, @intCast(group));
}

fn size() Error!Size {
    var dimensions: posix.winsize = undefined;
    const result = linux.ioctl(0, linux.T.IOCGWINSZ, @intFromPtr(&dimensions));
    if (posix.errno(result) != .SUCCESS) return error.TerminalUnavailable;
    return .{ .rows = dimensions.row, .columns = dimensions.col };
}

/// All callers must first make the descriptor nonblocking. Returns the suffix
/// not yet written, rather than waiting for a full terminal/pipe to drain.
fn writeAvailable(fd: posix.fd_t, bytes: []const u8) Error![]const u8 {
    var remaining = bytes;
    while (remaining.len != 0) {
        const count = linux.write(fd, remaining.ptr, remaining.len);
        switch (posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.OutputFailed;
                remaining = remaining[count..];
            },
            .INTR => continue,
            .AGAIN => return remaining,
            else => return error.OutputFailed,
        }
    }
    return remaining;
}

fn milliseconds() Error!i64 {
    var time: linux.timespec = undefined;
    if (posix.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return error.WaitFailed;
    return time.sec * 1000 + @divTrunc(time.nsec, 1_000_000);
}

// Termios is restored before this bounded best-effort screen cleanup. An
// unresponsive emulator must not hold termination or suspension indefinitely.
fn writeCleanup(bytes: []const u8) Error!void {
    const deadline = try milliseconds() + 100;
    var remaining = bytes;
    while (remaining.len != 0) {
        remaining = try writeAvailable(1, remaining);
        if (remaining.len == 0) return;
        const timeout: i32 = @intCast(@max(0, deadline - try milliseconds()));
        if (timeout == 0) return error.OutputBlocked;
        var fds = [_]linux.pollfd{.{ .fd = 1, .events = linux.POLL.OUT, .revents = 0 }};
        const result = linux.poll(&fds, 1, timeout);
        switch (posix.errno(result)) {
            .SUCCESS => if (result == 0) return error.OutputBlocked,
            .INTR => continue,
            else => return error.WaitFailed,
        }
        if (fds[0].revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
            return error.OutputFailed;
    }
}

/// Reporting a cleanup failure must not block on the same stalled terminal.
/// stderr can share stdout's open file description; always restore its flags.
pub fn writeDiagnostic(bytes: []const u8) void {
    const flags = linux.fcntl(2, linux.F.GETFL, 0);
    if (posix.errno(flags) != .SUCCESS) return;
    if (posix.errno(linux.fcntl(2, linux.F.SETFL, flags | nonblocking)) != .SUCCESS) return;
    defer _ = linux.fcntl(2, linux.F.SETFL, flags);
    _ = writeAvailable(2, bytes) catch return;
}
