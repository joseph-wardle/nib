// SPDX-License-Identifier: MIT OR Apache-2.0
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

pub const Size = struct { rows: u16, columns: u16 };
/// `input` borrows the terminal's read buffer until the next call to `next`.
/// `watch` and `background` report the descriptors the caller passed in.
pub const Event = union(enum) {
    input: []const u8,
    redraw: Size,
    quit: u8,
    timeout,
    watch,
    background,
};
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
// Entry prefixes mark the byte boundaries where each state was acquired.
const cursor_save = "\x1b[?25s";
const alternate_enter = cursor_save ++ "\x1b[?1049h";
const paste_save = alternate_enter ++ "\x1b[?25l\x1b[?2004s";
const screen_entry = paste_save ++ "\x1b[?2004h";
const cleanup_capacity = 32;

const handled_signals = [_]posix.SIG{ .INT, .TERM, .HUP, .TSTP, .CONT, .WINCH };

/// Owns the signal descriptor and saved process/terminal state. stdin/stdout
/// remain borrowed. Call close even when next or write fails. Use on the main
/// thread, before starting any concurrent work, so the signal mask is inherited.
pub const Terminal = struct {
    saved_mode: posix.termios,
    saved_mask: posix.sigset_t,
    signal_fd: posix.fd_t,
    suspension_count: usize = 0,
    resumption_count: usize = 0,
    saved_output_flags: usize,
    output_flags_active: bool = false,
    pending: Signals = .{},
    mode_active: bool = false,
    entry_written: usize = 0,
    input: [4096]u8 = undefined,

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
        // Deliver control keys to the decoder, including inside bracketed
        // paste. The application requests suspension for an ordinary Ctrl-Z.
        // External lifecycle signals still arrive through signalfd.
        mode.cc[@backingInt(linux.V.INTR)] = 0;
        mode.cc[@backingInt(linux.V.SUSP)] = 0;
        mode.cc[@backingInt(linux.V.QUIT)] = 0;
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
        if (self.entry_written != 0) {
            var buffer: [cleanup_capacity]u8 = undefined;
            try self.write(self.cleanupBytes(&buffer));
            self.entry_written = 0;
        }
        // Record progress even on interruption/error. Restore only modes
        // whose saves completed; terminate incomplete escape sequences first.
        try self.writeProgress(screen_entry, &self.entry_written);
    }

    fn cleanupBytes(self: *const Terminal, buffer: *[cleanup_capacity]u8) []const u8 {
        // ST starts with ESC, cancelling an incomplete CSI, and terminates
        // without printing or moving the cursor in Konsole. CAN prints a glyph.
        // Resynchronize again when retrying cleanup after suspension.
        return std.fmt.bufPrint(buffer, "{s}{s}{s}{s}{s}", .{
            if (self.entry_written != 0) "\x1b\\" else "",
            if (self.entry_written >= alternate_enter.len) "\x1b[0m" else "",
            if (self.entry_written >= paste_save.len) "\x1b[?2004r" else "",
            if (self.entry_written >= alternate_enter.len) "\x1b[?1049l" else "",
            if (self.entry_written >= cursor_save.len) "\x1b[?25r" else "",
        }) catch unreachable;
    }

    fn leave(self: *Terminal) Error!void {
        var failure: ?Error = null;
        if (self.mode_active) {
            posix.tcsetattr(0, .NOW, self.saved_mode) catch {
                failure = error.TerminalUnavailable;
            };
            self.mode_active = false;
        }
        if (self.entry_written != 0) {
            self.setOutputNonblocking() catch |err| {
                if (failure == null) failure = err;
            };
            if (self.output_flags_active) {
                var buffer: [cleanup_capacity]u8 = undefined;
                if (writeCleanup(self.cleanupBytes(&buffer))) |_| {
                    self.entry_written = 0;
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

    /// Request the existing lifecycle transition for a decoded keyboard Ctrl-Z.
    pub fn requestSuspend(self: *Terminal) void {
        self.pending.should_suspend = true;
    }

    /// Blocks until input, lifecycle activity, readiness of `watch_fd` (-1 for
    /// none) or `background_fd`, or an optional monotonic deadline. Signals are
    /// drained first; queued termination wins over resume or input.
    pub fn next(
        self: *Terminal,
        deadline: ?i64,
        watch_fd: posix.fd_t,
        background_fd: posix.fd_t,
    ) Error!Event {
        while (true) {
            try self.readSignals();
            const signals = self.pending;
            self.pending = .{};
            if (signals.exit_code) |code| return .{ .quit = code };
            if (signals.should_suspend) {
                self.suspension_count +%= 1;
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
                .{ .fd = watch_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = background_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const timeout: i32 = if (deadline) |end| @intCast(@min(std.math.maxInt(i32), @max(0, end - try milliseconds()))) else -1;
            const result = linux.poll(&fds, fds.len, timeout);
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
            if (result == 0) return .timeout;
            if (fds[1].revents & (linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL) != 0)
                return error.TerminalUnavailable;
            if (fds[1].revents & linux.POLL.IN != 0) {
                const count = linux.read(0, &self.input, self.input.len);
                switch (posix.errno(count)) {
                    .SUCCESS => if (count == 0) return error.TerminalUnavailable else return .{ .input = self.input[0..count] },
                    .INTR, .AGAIN => continue,
                    else => return error.InputFailed,
                }
            }
            if (fds[2].revents != 0) return .watch;
            if (fds[3].revents != 0) return .background;
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
        var written: usize = 0;
        try self.writeProgress(bytes, &written);
    }

    fn writeProgress(self: *Terminal, bytes: []const u8, written: *usize) Error!void {
        try self.readSignals();
        if (self.pending.exit_code != null or self.pending.should_suspend) return error.Interrupted;
        var remaining = bytes[written.*..];
        defer written.* = bytes.len - remaining.len;
        while (remaining.len != 0) {
            try writeAvailable(1, &remaining);
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
                .CONT => {
                    self.resumption_count +%= 1;
                    self.pending.resize = true;
                },
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

/// All callers must first make the descriptor nonblocking. Consumes the written
/// prefix even on error, without waiting for a full terminal/pipe to drain.
fn writeAvailable(fd: posix.fd_t, remaining: *[]const u8) Error!void {
    while (remaining.len != 0) {
        const count = linux.write(fd, remaining.ptr, remaining.len);
        switch (posix.errno(count)) {
            .SUCCESS => {
                if (count == 0) return error.OutputFailed;
                remaining.* = remaining.*[count..];
            },
            .INTR => continue,
            .AGAIN => return,
            else => return error.OutputFailed,
        }
    }
}

pub fn milliseconds() Error!i64 {
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
        try writeAvailable(1, &remaining);
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
    var remaining = bytes;
    writeAvailable(2, &remaining) catch return;
}

test "interrupted entry restores only completed saves at every byte boundary" {
    for (0..screen_entry.len + 1) |prefix| {
        try interruptedSetup(prefix, 0, .TERM);
        try interruptedSetup(prefix, 0, .TSTP);
    }
}

test "cleanup retries cancel incomplete escape sequences before restoring modes" {
    const cleanup = "\x1b\\\x1b[0m\x1b[?2004r\x1b[?1049l\x1b[?25r";
    for (1..cleanup.len + 1) |prefix| {
        try interruptedSetup(screen_entry.len, prefix, .TERM);
        try interruptedSetup(screen_entry.len, prefix, .TSTP);
    }
}

// Isolate descriptor and signal mutations in a child. The pipe captures exactly
// what an emulator would receive, including interrupted escape sequences.
fn interruptedSetup(entry_prefix: usize, cleanup_prefix: usize, signal: posix.SIG) !void {
    const testing = std.testing;
    var pipe: [2]posix.fd_t = undefined;
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);
    const result = linux.fork();
    if (posix.errno(result) != .SUCCESS) {
        _ = linux.close(pipe[1]);
        return error.ForkFailed;
    }
    if (result == 0) {
        interruptedSetupChild(pipe, entry_prefix, cleanup_prefix, signal) catch linux.exit_group(1);
        linux.exit_group(0);
    }
    _ = linux.close(pipe[1]);
    const pid: posix.pid_t = @intCast(result);
    defer {
        _ = linux.kill(pid, .KILL);
        var status: i32 = 0;
        while (posix.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
    }
    var output: [128]u8 = undefined;
    var used: usize = 0;
    while (true) {
        const count = linux.read(pipe[0], output[used..].ptr, output.len - used);
        if (posix.errno(count) == .INTR) continue;
        try testing.expectEqual(posix.E.SUCCESS, posix.errno(count));
        if (count == 0) break;
        used += count;
        try testing.expect(used < output.len);
    }
    // Independent expected ranges: no restore before its matching CSI save (or
    // alternate-screen entry) has actually reached the output stream.
    const cleanup: []const u8 = if (entry_prefix == 0)
        ""
    else if (entry_prefix < 6)
        "\x1b\\"
    else if (entry_prefix < 14)
        "\x1b\\\x1b[?25r"
    else if (entry_prefix < 28)
        "\x1b\\\x1b[0m\x1b[?1049l\x1b[?25r"
    else
        "\x1b\\\x1b[0m\x1b[?2004r\x1b[?1049l\x1b[?25r";
    var expected: [128]u8 = undefined;
    @memcpy(expected[0..entry_prefix], screen_entry[0..entry_prefix]);
    @memcpy(expected[entry_prefix..][0..cleanup_prefix], cleanup[0..cleanup_prefix]);
    @memcpy(expected[entry_prefix + cleanup_prefix ..][0..cleanup.len], cleanup);
    try testing.expectEqualSlices(u8, expected[0 .. entry_prefix + cleanup_prefix + cleanup.len], output[0..used]);
    // Wait with WNOWAIT so the deferred reap still owns the pid even on failure.
    var info: linux.siginfo_t = undefined;
    try testing.expectEqual(posix.E.SUCCESS, posix.errno(linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOWAIT, null)));
    try testing.expectEqual(@as(i32, 0), info.fields.common.second.sigchld.status);
}

fn interruptedSetupChild(pipe: [2]posix.fd_t, entry_prefix: usize, cleanup_prefix: usize, signal: posix.SIG) !void {
    _ = linux.close(pipe[0]);
    if (posix.errno(linux.dup2(pipe[1], 1)) != .SUCCESS) return error.DupFailed;
    if (pipe[1] != 1) _ = linux.close(pipe[1]);
    var mask = posix.sigemptyset();
    posix.sigaddset(&mask, signal);
    var saved_mask: posix.sigset_t = undefined;
    posix.sigprocmask(posix.SIG.BLOCK, &mask, &saved_mask);
    const fd = linux.signalfd(-1, &mask, linux.SFD.CLOEXEC | linux.SFD.NONBLOCK);
    if (posix.errno(fd) != .SUCCESS) return error.SignalSetupFailed;
    var session: Terminal = .{
        .saved_mode = undefined, // No termios was acquired in this pipe test.
        .saved_mask = saved_mask,
        .signal_fd = @intCast(fd),
        .saved_output_flags = linux.fcntl(1, linux.F.GETFL, 0),
    };
    try session.setOutputNonblocking();
    try session.writeProgress(screen_entry[0..entry_prefix], &session.entry_written);
    if (cleanup_prefix != 0) {
        var buffer: [cleanup_capacity]u8 = undefined;
        try session.write(session.cleanupBytes(&buffer)[0..cleanup_prefix]);
    }
    try posix.kill(linux.getpid(), signal);
    if (cleanup_prefix == 0) {
        try std.testing.expectError(error.Interrupted, session.writeProgress(screen_entry, &session.entry_written));
        try std.testing.expectEqual(entry_prefix, session.entry_written);
    } else {
        var buffer: [cleanup_capacity]u8 = undefined;
        try std.testing.expectError(error.Interrupted, session.write(session.cleanupBytes(&buffer)));
    }
    try session.close();
    try std.testing.expectEqual(@as(usize, 0), session.entry_written);
    try std.testing.expectEqual(session.saved_output_flags, linux.fcntl(1, linux.F.GETFL, 0));
}
