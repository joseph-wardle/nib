// SPDX-License-Identifier: MIT OR Apache-2.0
//! Linux PTY integration checks. Owns child processes and PTY descriptors;
//! exercises the built executable independently of its terminal implementation.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const frame = "\x1b[H\x1b[2J";
const enter = "\x1b[?25s\x1b[?1049h\x1b[?25l\x1b[?2004s\x1b[?2004h";
const leave = "\x1b\\\x1b[0m\x1b[?2004r\x1b[?1049l\x1b[?25r";
const prompt = "NIBTEST> ";
// Borrows main's path buffer for the lifetime of all checks.
var fixture: [:0]const u8 = undefined;

// Keep startup single-threaded: child setup after fork must not inherit runtime
// worker threads or allocator locks. The harness uses fixed owned buffers.
pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const named = args.next() orelse return error.MissingExecutable;
    // Children may change directory before running it.
    var executable_buffer: [4096]u8 = undefined;
    const executable = if (named[0] == '/') named else executable: {
        const length = try checked(linux.getcwd(&executable_buffer, executable_buffer.len));
        // The kernel's length counts the terminating NUL.
        const cwd = executable_buffer[0 .. length - 1];
        const rest = executable_buffer[cwd.len..];
        const suffix = try std.fmt.bufPrintSentinel(rest, "/{s}", .{named}, 0);
        break :executable executable_buffer[0 .. cwd.len + suffix.len :0];
    };
    var directory_buffer: [128]u8 = undefined;
    const directory = try std.fmt.bufPrintSentinel(&directory_buffer, "/tmp/nib-viewer-{d}", .{linux.getpid()}, 0);
    _ = try checked(linux.mkdir(directory, 0o700));
    defer _ = linux.rmdir(directory);
    var path_buffer: [256]u8 = undefined;
    fixture = try std.fmt.bufPrintSentinel(&path_buffer, "{s}/source'\x1b[2J", .{directory}, 0);
    const fd: posix.fd_t = @intCast(try checked(linux.open(fixture, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600)));
    defer _ = linux.unlink(fixture);
    {
        defer _ = linux.close(fd);
        var row: [128]u8 = undefined;
        for (0..60) |number| {
            const label = try std.fmt.bufPrint(row[0..8], "line{d:0>3} ", .{number});
            @memset(row[label.len..120], 'x');
            @memcpy(row[120..][0..8], "TAIL\t!\r\n");
            try write(fd, &row);
        }
    }
    const checks = .{
        .{ "quitAndIdle", quitAndIdle },
        .{ "interruptAndTermination", interruptAndTermination },
        .{ "resizeAndSuspend", resizeAndSuspend },
        .{ "pendingTermination", pendingTermination },
        .{ "setupFailures", setupFailures },
        .{ "redirectedStdio", redirectedStdio },
        .{ "disconnect", disconnect },
        .{ "shellJobControl", shellJobControl },
        .{ "viewerWorkflow", viewerWorkflow },
        .{ "cursorMotions", cursorMotions },
        .{ "modalCommands", modalCommands },
        .{ "editingWorkflow", editingWorkflow },
        .{ "pasteLifecycle", pasteLifecycle },
        .{ "externalChanges", externalChanges },
        .{ "startupFailures", startupFailures },
        .{ "stalledOutputRecovery", stalledOutputRecovery },
        .{ "stalledOutputTermination", stalledOutputTermination },
        .{ "stalledOutputSuspend", stalledOutputSuspend },
        .{ "finderSwitching", finderSwitching },
        .{ "finderSafety", finderSafety },
        .{ "finderQuit", finderQuit },
    };
    inline for (checks) |check| {
        check[1](executable) catch |err| {
            std.debug.print("terminal check {s}: {t}\n", .{ check[0], err });
            return err;
        };
    }
    std.debug.print("All {d} terminal viewer checks passed.\n", .{checks.len});
}

fn checked(result: usize) !usize {
    const errno = posix.errno(result);
    if (errno != .SUCCESS) {
        std.debug.print("test syscall failed: {t}\n", .{errno});
        return error.SystemCallFailed;
    }
    return result;
}

fn now() !i64 {
    var time: linux.timespec = undefined;
    _ = try checked(linux.clock_gettime(.MONOTONIC, &time));
    return time.sec * 1000 + @divTrunc(time.nsec, 1_000_000);
}

fn write(fd: posix.fd_t, bytes: []const u8) !void {
    var remaining = bytes;
    while (remaining.len != 0) {
        const result = linux.write(fd, remaining.ptr, remaining.len);
        if (posix.errno(result) == .INTR) continue;
        const count = try checked(result);
        if (count == 0) return error.ShortWrite;
        remaining = remaining[count..];
    }
}

const Options = struct {
    readonly: bool = false,
    no_descriptors: bool = false,
    redirected_input: bool = false,
    redirected_output: bool = false,
    shell: bool = false,
    path: ?[:0]const u8 = null,
    missing_argument: bool = false,
    extra_argument: bool = false,
    size: [2]u16 = .{ 24, 80 },
    nonblocking_output: bool = false,
    /// Working directory for the child.
    cwd: ?[:0]const u8 = null,
};

const Process = struct {
    master: ?posix.fd_t,
    slave: posix.fd_t,
    pid: posix.pid_t,
    saved: posix.termios,
    saved_flags: usize,
    reaped: bool = false,
    eof: bool = false,
    output: [65536]u8 = undefined,
    used: usize = 0,

    fn start(executable: [:0]const u8, options: Options) !Process {
        const master: posix.fd_t = @intCast(try checked(linux.open("/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0)));
        errdefer _ = linux.close(master);
        var unlock: c_int = 0;
        _ = try checked(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock)));
        const slave: posix.fd_t = @intCast(try checked(linux.ioctl(master, linux.T.IOCGPTPEER, @as(u32, @bitCast(linux.O{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true })))));
        errdefer _ = linux.close(slave);
        var dimensions: posix.winsize = .{ .row = options.size[0], .col = options.size[1], .xpixel = 0, .ypixel = 0 };
        _ = try checked(linux.ioctl(slave, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
        if (options.nonblocking_output) {
            const flags = try checked(linux.fcntl(slave, linux.F.GETFL, 0));
            _ = try checked(linux.fcntl(slave, linux.F.SETFL, flags | @as(u32, @bitCast(linux.O{ .NONBLOCK = true }))));
        }
        const saved_flags = try checked(linux.fcntl(slave, linux.F.GETFL, 0));
        const saved = try posix.tcgetattr(slave);
        const pid: posix.pid_t = @intCast(try checked(linux.fork()));
        if (pid == 0) {
            child(master, slave, executable, options) catch {};
            linux.exit_group(127);
        }
        return .{ .master = master, .slave = slave, .pid = pid, .saved = saved, .saved_flags = saved_flags };
    }

    fn child(master: posix.fd_t, slave: posix.fd_t, executable: [:0]const u8, options: Options) !void {
        _ = try checked(linux.close(master));
        if (options.cwd) |directory| _ = try checked(linux.chdir(directory));
        _ = try checked(linux.setsid());
        _ = try checked(linux.ioctl(slave, linux.T.IOCSCTTY, 0));
        for (0..3) |fd| _ = try checked(linux.dup2(slave, @intCast(fd)));
        if (slave > 2) _ = try checked(linux.close(slave));
        if (options.readonly) {
            const fd: posix.fd_t = @intCast(try checked(linux.open("/dev/tty", .{ .ACCMODE = .RDONLY }, 0)));
            _ = try checked(linux.dup2(fd, 1));
            _ = try checked(linux.close(fd));
        }
        if (options.redirected_input or options.redirected_output) {
            const fd: posix.fd_t = @intCast(try checked(linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0)));
            _ = try checked(linux.dup2(fd, if (options.redirected_input) 0 else 1));
            _ = try checked(linux.close(fd));
        }
        if (options.no_descriptors) {
            const limit: linux.rlimit = .{ .cur = 3, .max = 3 };
            _ = try checked(linux.setrlimit(.NOFILE, &limit));
        }
        const env = [_:null]?[*:0]const u8{ "PS1=" ++ prompt, "PATH=/usr/bin:/bin", "TERM=xterm-256color" };
        const argv = [_:null]?[*:0]const u8{ executable.ptr, if (options.missing_argument) null else (options.path orelse fixture).ptr, if (options.extra_argument) "extra" else null };
        const shell_argv = [_:null]?[*:0]const u8{ "/bin/zsh", "-dfi" };
        _ = try checked(linux.execve(if (options.shell) "/bin/zsh" else executable.ptr, if (options.shell) &shell_argv else &argv, &env));
    }

    fn close(self: *Process) void {
        if (!self.reaped) {
            // Shell jobs have separate process groups. Kill direct job groups
            // before killing/reaping their shell, including on assertion failure.
            var path: [128]u8 = undefined;
            const text = std.fmt.bufPrint(path[0 .. path.len - 1], "/proc/{d}/task/{d}/children", .{ self.pid, self.pid }) catch unreachable;
            path[text.len] = 0;
            const children = path[0..text.len :0];
            const fd = linux.open(children, .{ .ACCMODE = .RDONLY }, 0);
            if (posix.errno(fd) == .SUCCESS) {
                defer _ = linux.close(@intCast(fd));
                var buffer: [4096]u8 = undefined;
                const count = linux.read(@intCast(fd), &buffer, buffer.len);
                if (posix.errno(count) == .SUCCESS) {
                    var ids = std.mem.tokenizeScalar(u8, buffer[0..count], ' ');
                    while (ids.next()) |id| {
                        const pid = std.fmt.parseInt(posix.pid_t, id, 10) catch continue;
                        _ = linux.kill(-pid, .KILL);
                    }
                }
            }
            _ = linux.kill(-self.pid, .KILL);
            _ = linux.kill(self.pid, .KILL);
            var status: i32 = 0;
            while (posix.errno(linux.waitpid(self.pid, &status, 0)) == .INTR) {}
        }
        if (self.master) |fd| _ = linux.close(fd);
        _ = linux.close(self.slave);
    }

    fn read(self: *Process, timeout_ms: i32) !usize {
        if (self.eof) return 0;
        var fds = [_]linux.pollfd{.{ .fd = self.master orelse return error.Disconnected, .events = linux.POLL.IN, .revents = 0 }};
        const deadline = try now() + timeout_ms;
        while (true) {
            const remaining: i32 = @intCast(@max(0, deadline - try now()));
            const result = linux.poll(&fds, 1, remaining);
            if (posix.errno(result) == .INTR) continue;
            if (try checked(result) == 0) return 0;
            if (self.used == self.output.len) return error.OutputLimitExceeded;
            const count = linux.read(fds[0].fd, self.output[self.used..].ptr, self.output.len - self.used);
            switch (posix.errno(count)) {
                .INTR => continue,
                .IO => { // PTY master reports EIO after slave disconnect.
                    self.eof = true;
                    return 0;
                },
                else => {},
            }
            self.used += try checked(count);
            if (count == 0) self.eof = true;
            return count;
        }
    }

    fn until(self: *Process, marker: []const u8) !void {
        const deadline = try now() + 5000;
        while (std.mem.indexOf(u8, self.output[0..self.used], marker) == null) {
            if (self.eof or try now() >= deadline) {
                std.debug.print("missing {f}; received {f}\n", .{ std.zig.fmtString(marker), std.zig.fmtString(self.output[0..self.used]) });
                return if (self.eof) error.MissingOutput else error.OutputTimeout;
            }
            _ = try self.read(50);
        }
        const end = std.mem.indexOf(u8, self.output[0..self.used], marker).? + marker.len;
        std.mem.copyForwards(u8, &self.output, self.output[end..self.used]);
        self.used -= end;
    }

    fn wait(self: *Process, stopped: bool) !u8 {
        const deadline = try now() + 5000;
        while (try now() < deadline) {
            var raw_status: i32 = 0;
            const result = try checked(linux.waitpid(self.pid, &raw_status, linux.W.NOHANG | linux.W.UNTRACED));
            if (result != 0) {
                const status: u32 = @bitCast(raw_status);
                if (linux.W.IFSTOPPED(status)) {
                    if (!stopped) return error.UnexpectedStop;
                    return @intCast(@backingInt(linux.W.STOPSIG(status)));
                }
                self.reaped = true;
                if (stopped) return error.ExitedInsteadOfStopping;
                if (linux.W.IFEXITED(status)) return linux.W.EXITSTATUS(status);
                return error.ChildKilled;
            }
            _ = try checked(linux.poll(&.{}, 0, 10));
        }
        return error.ChildTimeout;
    }

    fn send(self: *Process, bytes: []const u8) !void {
        try write(self.master orelse return error.Disconnected, bytes);
    }

    fn signal(self: *Process, sig: posix.SIG) !void {
        _ = try checked(linux.kill(self.pid, sig));
    }

    fn restored(self: *Process) !void {
        try std.testing.expectEqualDeep(self.saved, try posix.tcgetattr(self.slave));
        // The harness dup2s one open file description onto stdin/stdout/stderr.
        // This also detects leaked changes affecting the shell's descriptors.
        try equal(self.saved_flags, try checked(linux.fcntl(self.slave, linux.F.GETFL, 0)));
    }

    fn ready(self: *Process) !void {
        try self.until("\x1b[0m");
        const mode = try posix.tcgetattr(self.slave);
        try expect(!mode.lflag.ECHO and !mode.lflag.ICANON);
        try expect(mode.lflag.ISIG and !mode.iflag.IXON);
        try equal(@as(u8, 0), mode.cc[@backingInt(linux.V.INTR)]);
        try equal(@as(u8, 0), mode.cc[@backingInt(linux.V.SUSP)]);
        try equal(@as(u8, 0), mode.cc[@backingInt(linux.V.QUIT)]);
    }

    // Wait without reading: the 60 KiB frame cannot fit in the PTY output
    // queue. This synchronizes with active rendering, not a startup sleep.
    fn stalled(self: *Process) !void {
        const deadline = try now() + 5000;
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/stat", .{self.pid}, 0);
        while (try now() < deadline) {
            var queued: c_int = 0;
            _ = try checked(linux.ioctl(self.master.?, linux.T.FIONREAD, @intFromPtr(&queued)));
            const mode = try posix.tcgetattr(self.slave);
            if (queued >= 4095 and !mode.lflag.ICANON and !mode.lflag.ECHO) {
                const fd: posix.fd_t = @intCast(try checked(linux.open(path, .{ .ACCMODE = .RDONLY }, 0)));
                defer _ = linux.close(fd);
                var buffer: [256]u8 = undefined;
                const count = try checked(linux.read(fd, &buffer, buffer.len));
                const name_end = std.mem.lastIndexOfScalar(u8, buffer[0..count], ')') orelse return error.BadProcessStatus;
                // The renderer has filled the PTY and is asleep in its output
                // wait. Do not race a signal against still-running rendering.
                if (name_end + 2 < count and buffer[name_end + 2] == 'S') return;
            }
            _ = try checked(linux.poll(&.{}, 0, 10));
        }
        return error.OutputDidNotStall;
    }

    /// Fill any slack left in a stalled output queue, so even short cleanup
    /// output cannot fit. How full a renderer leaves the queue depends on how
    /// the kernel splits its writes. A separate description keeps Nib's flags.
    fn saturate(self: *Process) !void {
        const peer: posix.fd_t = @intCast(try checked(linux.ioctl(self.master.?, linux.T.IOCGPTPEER, @as(u32, @bitCast(linux.O{ .ACCMODE = .WRONLY, .NOCTTY = true, .CLOEXEC = true, .NONBLOCK = true })))));
        defer _ = linux.close(peer);
        const filler: [256]u8 = @splat('.');
        var size = filler.len;
        while (true) {
            const count = linux.write(peer, &filler, size);
            switch (posix.errno(count)) {
                .SUCCESS => {},
                .INTR => continue,
                .AGAIN => if (size == 1) return else {
                    size = 1;
                },
                else => return error.WriteFailed,
            }
        }
    }

    fn rejected(self: *Process, message: []const u8) !void {
        try equal(@as(u8, 1), try self.wait(false));
        _ = try self.read(50);
        // Inspect all output before until consumes the diagnostic's prefix.
        try self.excludes(enter);
        try self.until(message);
        try self.restored();
    }

    fn excludes(self: *Process, bytes: []const u8) !void {
        try expect(std.mem.indexOf(u8, self.output[0..self.used], bytes) == null);
    }
};

fn quitAndIdle(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    try equal(@as(usize, 0), process.used);
    try equal(@as(usize, 0), try process.read(150));
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
}

fn interruptAndTermination(executable: [:0]const u8) !void {
    for ([_]posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        var process = try Process.start(executable, .{});
        defer process.close();
        try process.ready();
        try process.signal(sig);
        try equal(@as(u8, 128 + @as(u8, @intCast(@backingInt(sig)))), try process.wait(false));
        try process.until(leave);
        try process.restored();
    }
}

fn resizeAndSuspend(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    for ([_][2]u16{ .{ 1, 1 }, .{ 0, 0 }, .{ 2, 2 }, .{ 30, 100 } }) |size| {
        var dimensions: posix.winsize = .{ .row = size[0], .col = size[1], .xpixel = 0, .ypixel = 0 };
        _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
        try process.until(frame);
        if (size[0] <= 1 or size[1] <= 1) {
            // Inspect the complete frame before ready consumes it.
            const deadline = try now() + 5000;
            while (std.mem.indexOf(u8, process.output[0..process.used], "\x1b[0m") == null) {
                if (process.eof or try now() >= deadline) return error.OutputTimeout;
                _ = try process.read(50);
            }
            try process.excludes("\x1b[?25h");
            try process.ready();
        } else if (size[0] == 2 and size[1] == 2) {
            try process.until("\x1b[1;1H\x1b[?25h");
            try process.ready();
        }
    }
    try process.until("Ctrl-P files");
    for (0..3) |_| {
        try process.send("\x1a");
        try equal(@as(u8, @backingInt(posix.SIG.STOP)), try process.wait(true));
        try process.until(leave);
        try process.restored();
        try process.signal(.CONT);
        try process.ready();
    }
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.restored();
}

fn pendingTermination(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    try process.send("\x1a");
    _ = try process.wait(true);
    try process.until(leave);
    try process.signal(.TERM);
    try process.signal(.CONT);
    try equal(@as(u8, 128 + @backingInt(posix.SIG.TERM)), try process.wait(false));
    try equal(@as(usize, 0), try process.read(50));
    try process.excludes(enter);
    try process.restored();
}

fn setupFailures(executable: [:0]const u8) !void {
    for ([_]Options{ .{ .no_descriptors = true }, .{ .readonly = true } }, [_][]const u8{ "SignalSetupFailed", "OutputFailed" }) |option, message| {
        var process = try Process.start(executable, option);
        defer process.close();
        try equal(@as(u8, 1), try process.wait(false));
        try process.until(message);
        try process.restored();
    }
}

fn redirectedStdio(executable: [:0]const u8) !void {
    for ([_]Options{ .{ .redirected_input = true }, .{ .redirected_output = true } }) |option| {
        var process = try Process.start(executable, option);
        defer process.close();
        try process.rejected("controlling terminal");
    }
}

fn disconnect(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    _ = try checked(linux.close(process.master.?));
    process.master = null;
    const code = try process.wait(false);
    try expect(code == 1 or code == 128 + @backingInt(posix.SIG.HUP));
}

fn shellJobControl(executable: [:0]const u8) !void {
    var shell = try Process.start(executable, .{ .shell = true });
    defer shell.close();
    try shell.until(prompt);
    try shell.send("unsetopt zle\n");
    try shell.until(prompt);
    shell.saved = try posix.tcgetattr(shell.slave);
    var command: [8192]u8 = undefined;
    var length: usize = 0;
    for ([_][]const u8{ executable, fixture }) |path| {
        if (length != 0) {
            command[length] = ' ';
            length += 1;
        }
        command[length] = '\'';
        length += 1;
        for (path) |byte| {
            const text = if (byte == '\'') "'\\''" else &[_]u8{byte};
            if (length + text.len + 5 > command.len) return error.PathTooLong;
            @memcpy(command[length..][0..text.len], text);
            length += text.len;
        }
        command[length] = '\'';
        length += 1;
    }
    command[length] = '\n';
    try shell.send(command[0 .. length + 1]);
    try shell.until("Ctrl-P files");
    for (0..2) |_| {
        try shell.send("\x1a");
        try shell.until(prompt);
        try shell.restored();
        try shell.send("fg\n");
        try shell.until("Ctrl-P files");
    }
    try shell.send("\x1a");
    try shell.until(prompt);
    try shell.send("bg\n");
    try shell.until(prompt);
    try shell.restored();
    _ = try shell.read(100);
    try shell.excludes(enter);
    try shell.send("fg\n");
    try shell.until("Ctrl-P files");
    try shell.send(":qa\r");
    try shell.until(prompt);
    try shell.restored();
    @memcpy(command[length..][0..3], " &\n");
    try shell.send(command[0 .. length + 3]);
    try shell.until("run Nib as a foreground terminal job");
    try shell.excludes(enter);
    try shell.send("wait; exit 0\n");
    try equal(@as(u8, 0), try shell.wait(false));
}

fn viewerWorkflow(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.until("line000 ");
    try process.until("source'?[2J");
    try process.ready();
    try process.send("2j3l");
    try process.until("3:4 | ");
    try process.until("\x1b[0m");
    // Fragmented CSI, SS3 and pasted commands are ignored.
    for ([_][]const u8{ "\x1b[", "999q", "\x1bO", "q", "\x1b[200~qhjkl\x1b[201~" }) |part| {
        try process.send(part);
        try equal(@as(usize, 0), try process.read(20));
    }
    try process.send("\x1a");
    _ = try process.wait(true);
    try process.until(leave);
    try process.restored();
    var dimensions: posix.winsize = .{ .row = 4, .col = 12, .xpixel = 0, .ypixel = 0 };
    _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
    try process.signal(.CONT);
    try process.until("line000 xxx");
    try process.until("\x1b[3;4H\x1b[?25h");
    try process.ready();
    // Reach the final row and the final display column, then check the whole
    // clipped frame. The fixture ends with CRLF and contains an eight-stop tab.
    var movement: [128]u8 = undefined;
    @memset(&movement, 'j');
    try process.send(&movement);
    try process.until("line059 xxx\r\n");
    try process.until("\x1b[0m");
    @memset(&movement, 'l');
    try process.send(&movement);
    try process.until("\x1b[H\x1b[2JxxTAIL    !\r\nxxTAIL    !\r\nxxTAIL    !\r\n");
    try process.until("\x1b[3;11H\x1b[?25h");
    try process.ready();
    try process.send("gg0");
    try process.until("line000 xxx\r\nline001 xxx\r\nline002 xxx\r\n");
    try process.until("\x1b[1;1H\x1b[?25h");
    try process.ready();
    try equal(@as(usize, 0), try process.read(100));
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    // Read the source independently after the viewer exits; it never writes it.
    const fd: posix.fd_t = @intCast(try checked(linux.open(fixture, .{ .ACCMODE = .RDONLY }, 0)));
    defer _ = linux.close(fd);
    var bytes: [8192]u8 = undefined;
    const count = try checked(linux.read(fd, &bytes, bytes.len));
    try equal(@as(usize, 60 * 128), count);
    for (0..60) |number| {
        var label: [8]u8 = undefined;
        _ = try std.fmt.bufPrint(&label, "line{d:0>3} ", .{number});
        try std.testing.expectEqualSlices(u8, &label, bytes[number * 128 ..][0..8]);
        for (bytes[number * 128 + 8 ..][0..112]) |byte| try equal(@as(u8, 'x'), byte);
        try std.testing.expectEqualStrings("TAIL\t!\r\n", bytes[number * 128 + 120 ..][0..8]);
    }
}

fn cursorMotions(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    const cases = [_]struct { keys: []const u8, position: []const u8 }{
        .{ .keys = "w", .position = "1:9 | " },
        .{ .keys = "e", .position = "1:124 | " },
        .{ .keys = "b", .position = "1:9 | " },
        .{ .keys = "$", .position = "1:129 | " },
        .{ .keys = "h", .position = "1:128 | " },
        .{ .keys = "j", .position = "2:128 | " },
        .{ .keys = "k", .position = "1:128 | " },
        .{ .keys = "0", .position = "1:1 | " },
        .{ .keys = "3G", .position = "3:1 | " },
        .{ .keys = "G", .position = "60:1 | " },
        .{ .keys = "gg", .position = "1:1 | " },
        .{ .keys = "6w", .position = "3:1 | " },
        .{ .keys = "2l^", .position = "3:1 | " },
    };
    for (cases) |case| {
        try process.send(case.keys);
        try process.until(case.position);
        try process.ready();
    }
    // A refused count cannot execute a truncated movement, redraw continuously,
    // or modify this read-only viewer.
    try process.send("99999999999999999999999999999999j");
    try process.until("Unsupported command or count");
    try process.ready();
    try process.send("\x03");
    try process.ready();
    try equal(@as(usize, 0), try process.read(150));
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.restored();
}

fn startupFailures(executable: [:0]const u8) !void {
    for ([_]Options{
        .{ .extra_argument = true },
        .{ .path = "/a/missing/nib-test-file" },
        .{ .path = "/dev/null" },
    }, [_][]const u8{ "usage: nib [path]", "file not found", "regular file" }) |options, message| {
        var process = try Process.start(executable, options);
        defer process.close();
        try process.rejected(message);
    }
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "{s}-large", .{fixture}, 0);
    const fd: posix.fd_t = @intCast(try checked(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600)));
    defer _ = linux.close(fd);
    defer _ = linux.unlink(path);
    _ = try checked(linux.ftruncate(fd, 8 * 1024 * 1024 + 1));
    var process = try Process.start(executable, .{ .path = path });
    defer process.close();
    try process.rejected("temporary 8 MiB limit");
    _ = try checked(linux.ftruncate(fd, 0));
    var newlines: [4096]u8 = undefined;
    @memset(&newlines, '\n');
    // The descriptor offset is still zero after ftruncate.
    for (0..64) |_| try write(fd, &newlines);
    try write(fd, "\n");
    var lines = try Process.start(executable, .{ .path = path });
    defer lines.close();
    try lines.rejected("temporary 262,144-line limit");
}

fn stalledOutputTermination(executable: [:0]const u8) !void {
    for ([_]posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        for ([_]bool{ false, true }) |nonblocking_output| {
            var process = try Process.start(executable, .{ .size = .{ 200, 300 }, .nonblocking_output = nonblocking_output });
            defer process.close();
            try process.stalled();
            const start = try now();
            try process.signal(sig);
            // Keep output unread until exit. A full queue can prevent screen
            // cleanup, which is reported as failure rather than hanging exit.
            const code = try process.wait(false);
            try expect(code == 1 or code == 128 + @as(u8, @intCast(@backingInt(sig))));
            try expect(try now() - start < 2000);
            try process.restored();
        }
    }
}

fn stalledOutputSuspend(executable: [:0]const u8) !void {
    for ([_]bool{ false, true }) |nonblocking_output| {
        var process = try Process.start(executable, .{ .size = .{ 200, 300 }, .nonblocking_output = nonblocking_output });
        defer process.close();
        try process.stalled();
        try process.saturate();
        const start = try now();
        try process.signal(.TSTP);
        try equal(@as(u8, @backingInt(posix.SIG.STOP)), try process.wait(true));
        try expect(try now() - start < 2000);
        try process.restored();
        // Release backpressure while stopped. On fg/resume, incomplete screen
        // cleanup must precede saving modes again and drawing a fresh frame.
        while (try process.read(0) != 0) process.used = 0;
        var dimensions: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
        try process.signal(.CONT);
        try process.until(leave);
        try process.until(enter);
        try process.ready();
        try process.send(":qa\r");
        try equal(@as(u8, 0), try process.wait(false));
        try process.until(leave);
        try process.restored();
    }
}

fn stalledOutputRecovery(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{ .size = .{ 200, 300 } });
    defer process.close();
    try process.stalled();
    // Resume reading without signalling: partial writes must continue exactly
    // where they stopped, with no dropped/duplicated source bytes or row padding.
    const deadline = try now() + 5000;
    while (std.mem.indexOf(u8, process.output[0..process.used], "\x1b[0m") == null) {
        if (try now() >= deadline) return error.OutputTimeout;
        _ = try process.read(50);
    }
    const bytes = process.output[0..process.used];
    const start = (std.mem.indexOf(u8, bytes, frame) orelse return error.MissingOutput) + frame.len;
    const status = std.mem.indexOf(u8, bytes, "\x1b[7mNORMAL") orelse return error.MissingOutput;
    try equal(@as(usize, 199 * 301), status - start);
    for (0..199) |number| {
        var expected: [299]u8 = @splat(' ');
        if (number < 60) {
            _ = try std.fmt.bufPrint(expected[0..8], "line{d:0>3} ", .{number});
            @memset(expected[8..120], 'x');
            @memcpy(expected[120..124], "TAIL");
            expected[128] = '!';
        }
        try std.testing.expectEqualSlices(u8, &expected, bytes[start + number * 301 ..][0..299]);
        try std.testing.expectEqualStrings("\r\n", bytes[start + number * 301 + 299 ..][0..2]);
    }
    process.used = 0;
    // Each large command-line frame also meets backpressure. Consume each
    // frame before continuing so the bounded capture retains one at a time.
    try process.send(":");
    try process.ready();
    try process.send("qa");
    try process.ready();
    try process.send("\r");
    try process.until(leave);
    try equal(@as(u8, 0), try process.wait(false));
    try process.restored();
}

fn modalCommands(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    // Normal q cannot exit. Editing and saving use explicit modal commands.
    try process.send("q");
    try process.until("Unsupported command or count");
    try process.ready();
    try process.send("\x03");
    try process.until("Ctrl-P files");
    try process.ready();
    try process.send(":e!\r");
    try process.until("; local edits and history discarded");
    try process.ready();
    try process.send("\x03d");
    try process.until("OPERATOR pending");
    try process.ready();
    const start = try now();
    try process.send("\x1b");
    try equal(@as(usize, 0), try process.read(30));
    try process.until("Ctrl-P files");
    try expect(try now() - start >= 80 and try now() - start < 2000);
    try process.ready();
    // With no Escape pending the loop returns to indefinite idle waiting.
    try equal(@as(usize, 0), try process.read(200));
    try process.send("O");
    try process.until("INSERT");
    try process.ready();
    try process.send("\x03ud");
    try process.until("OPERATOR pending");
    try process.ready();
    // An unambiguous following key cancels the operator immediately, rather
    // than waiting or becoming an operator range.
    try process.send("\x1bj");
    try process.until("2:1 | ");
    try process.ready();
    // Recognized prefixes have no lone-Escape deadline. A payload arriving
    // later than 100 ms stays shielded.
    for ([_][2][]const u8{ .{ "\x1bO", "A" }, .{ "\x1b[", "999q" } }) |parts| {
        try process.send(parts[0]);
        try equal(@as(usize, 0), try process.read(150));
        try process.send(parts[1]);
        try equal(@as(usize, 0), try process.read(20));
    }
    try process.send("\x0320g\x03j");
    try process.until("3:1 | ");
    try process.ready();
    // Ctrl-C cancels a command line and paste cannot submit a quit command.
    try process.send(":");
    try process.ready();
    try process.send("\x1b[200~q!\r\x03\x1b[201~");
    try equal(@as(usize, 0), try process.read(150));
    try process.send("\x03^");
    try process.until("3:1 | ");
    try process.ready();
    try process.send("2d3w");
    try process.until("NORMAL [+]");
    try process.ready();
    // Ctrl-C ends an unfinished sequence, and Escape then `]` (Alt+] in
    // Konsole) is two keys, so the quit command still gets through.
    try process.send("\x1b[");
    try equal(@as(usize, 0), try process.read(150));
    try process.send("\x03\x1b]:qa!\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
}

fn putFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd: posix.fd_t = @intCast(try checked(linux.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o600)));
    defer _ = linux.close(fd);
    try write(fd, bytes);
}

fn expectFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd: posix.fd_t = @intCast(try checked(linux.open(path, .{ .ACCMODE = .RDONLY }, 0)));
    defer _ = linux.close(fd);
    var buffer: [1024]u8 = undefined;
    const count = try checked(linux.read(fd, &buffer, buffer.len));
    try std.testing.expectEqualStrings(bytes, buffer[0..count]);
}

// Synchronize each input byte with its resulting frame. This keeps tests about
// editing independent of PTY backpressure and bounded frame-capture capacity.
fn editingKeys(process: *Process, bytes: []const u8) !void {
    for (bytes) |byte| {
        try process.send(&.{byte});
        try process.ready();
    }
}

fn editingWorkflow(executable: [:0]const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/nib-edit-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);
    var copy_buffer: [128]u8 = undefined;
    const copy_path = try std.fmt.bufPrintSentinel(&copy_buffer, "/tmp/nib-copy-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(copy_path);
    try putFile(path, "abc\r\nlast");
    var process = try Process.start(executable, .{ .path = path });
    defer process.close();
    try process.ready();
    try editingKeys(&process, "G$a\rX\tY\x7fZ");
    try process.send("\x03");
    try process.until("3:9 | ");
    try process.until("\x1b[3;9H\x1b[?25h");
    try process.ready();
    try process.send(":q\r");
    try process.until("Unsaved changes");
    try process.ready();
    try expectFile(path, "abc\r\nlast");
    var command: [256]u8 = undefined;
    try process.send(try std.fmt.bufPrint(&command, ":w {s}\r", .{copy_path}));
    try process.until("Copy written");
    try process.ready();
    try expectFile(copy_path, "abc\r\nlast\r\nX\tZ");
    try process.send(try std.fmt.bufPrint(&command, ":w {s}\r", .{copy_path}));
    try process.until("Copy destination exists");
    try process.ready();
    try process.send(":q\r");
    try process.until("Unsaved changes");
    try process.ready();
    try process.send(":w\r");
    try process.until("Written");
    try process.ready();
    try expectFile(path, "abc\r\nlast\r\nX\tZ");
    try process.send("u");
    try process.until("NORMAL [+]");
    try process.ready();
    try process.send(":q\r");
    try process.until("Unsaved changes");
    try process.ready();
    try editingKeys(&process, "\x12");
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    // Reopen saved bytes, then let an independent writer change the source.
    var reopened = try Process.start(executable, .{ .path = path });
    defer reopened.close();
    try reopened.until("last");
    try reopened.ready();
    try editingKeys(&reopened, "cwLOCAL\x03");
    try putFile(path, "external\n");
    try reopened.send(":w\r");
    try reopened.until("Source changed or missing");
    try reopened.ready();
    try expectFile(path, "external\n");
    // The refused save retains undo: undo the local command, redo, then discard.
    try editingKeys(&reopened, "u\x12");
    try reopened.send(":qa!\r");
    try equal(@as(u8, 0), try reopened.wait(false));
    try reopened.until(leave);
    try reopened.restored();
    try expectFile(path, "external\n");
    // Unsupported source bytes stay exact and visibly read-only.
    try putFile(path, "raw\xff\r");
    var readonly = try Process.start(executable, .{ .path = path });
    defer readonly.close();
    try readonly.until("read-only");
    try readonly.ready();
    try readonly.send("i");
    try readonly.until("Read-only: non-ASCII");
    try readonly.ready();
    try readonly.send(":w\r");
    try readonly.until("Written");
    try readonly.ready();
    try readonly.send(":qa\r");
    try equal(@as(u8, 0), try readonly.wait(false));
    try readonly.restored();
    try expectFile(path, "raw\xff\r");
}

fn pasteLifecycle(executable: [:0]const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/nib-paste-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);
    try putFile(path, "base\r\n");
    var process = try Process.start(executable, .{ .path = path });
    defer process.close();
    try process.ready();
    try editingKeys(&process, "iX");
    // Signal characters must reach paste validation, even if the whole frame
    // is already queued in the kernel before its begin delimiter is decoded.
    for ([_]u8{ 3, 26, 28, 0, 0xff }) |control| {
        const packet = [_]u8{ 27, '[', '2', '0', '0', '~', 'B', control, 'D', 27, '[', '2', '0', '1', '~' };
        try process.send(&packet);
        try process.until("Unsupported paste");
        try process.ready();
    }
    // Real suspension during collection discards the entire pending paste.
    try process.send("\x1b[200~");
    try process.ready();
    try process.send("partial");
    try equal(@as(usize, 0), try process.read(30));
    try process.signal(.TSTP);
    _ = try process.wait(true);
    try process.until(leave);
    try process.restored();
    try process.signal(.CONT);
    try process.until("Paste interrupted");
    try process.ready();
    try process.send("remaining\x1b[201~");
    try equal(@as(usize, 0), try process.read(30));
    // A following valid paste is part of the original insertion group.
    try process.send("\x1b[200~A\nB\r\nC\rD\t\x1b[201~");
    try process.until("XA");
    try process.ready();
    try editingKeys(&process, "\x03u\x12");
    try process.send(":w\r");
    try process.until("Written");
    try process.ready();
    try expectFile(path, "XA\r\nB\r\nC\r\nD\tbase\r\n");
    // Keyboard suspension also retains a dirty insertion and its undo group.
    try editingKeys(&process, "iQ");
    try process.send("\x1a");
    _ = try process.wait(true);
    try process.until(leave);
    try process.restored();
    try process.signal(.CONT);
    try process.until("INSERT [+]");
    try process.ready();
    try editingKeys(&process, "R");
    try process.send("\x1b");
    try equal(@as(usize, 0), try process.read(30));
    try process.until("NORMAL [+]");
    try process.ready();
    try editingKeys(&process, "u");
    try process.send(":qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    try expectFile(path, "XA\r\nB\r\nC\r\nD\tbase\r\n");
}

fn externalChanges(executable: [:0]const u8) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/tmp/nib-external-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(path);
    var replacement_buffer: [128]u8 = undefined;
    const replacement = try std.fmt.bufPrintSentinel(&replacement_buffer, "/tmp/nib-replacement-{d}", .{linux.getpid()}, 0);
    defer _ = linux.unlink(replacement);
    try putFile(path, "original\nlast");
    var process = try Process.start(executable, .{ .path = path });
    defer process.close();
    try process.ready();
    // Idle atomic replacement reloads without keyboard activity.
    try putFile(replacement, "renamed\n");
    _ = try checked(linux.rename(replacement, path));
    try process.until("renamed");
    try process.until("Reloaded external changes");
    try process.ready();
    try equal(@as(usize, 0), try process.read(100));
    // A pending operator retains old text until cancelled.
    try process.send("d");
    try process.until("OPERATOR pending");
    try process.ready();
    try putFile(path, "pending\n");
    try process.until("renamed");
    try process.until("DISK CONFLICT | OPERATOR pending");
    try process.ready();
    try equal(@as(usize, 0), try process.read(100));
    try process.send("\x03");
    try process.until("pending");
    try process.until("Reloaded external changes");
    try process.ready();
    // Even a clean insert session postpones reloading; subsequent typing is local.
    try process.send("i");
    try process.until("INSERT");
    try process.ready();
    try putFile(path, "outside\n");
    try process.until("pending");
    try process.until("DISK CONFLICT");
    try process.ready();
    try process.send("X\x03");
    try process.until("Xpending");
    try process.ready();
    try process.send(":w\r");
    try process.until("save refused");
    try process.ready();
    try expectFile(path, "outside\n");
    var copy_command: [256]u8 = undefined;
    try process.send(try std.fmt.bufPrint(&copy_command, ":w {s}\r", .{replacement}));
    try process.until("Copy written");
    try process.ready();
    try expectFile(replacement, "Xpending\n");
    try process.send(":q\r");
    try process.until("Unsaved changes");
    try process.ready();
    try process.send(":e!\r");
    try process.until("outside");
    try process.until("; local edits and history discarded");
    try process.ready();
    try process.send("u");
    try process.until("No more history");
    try process.ready();
    // Deletion retains clean text; neither :w nor a failed :e! recreates it.
    _ = try checked(linux.unlink(path));
    try process.until("outside");
    try process.until("SOURCE MISSING");
    try process.ready();
    try process.send(":e!\r");
    try process.until(" failed; local state retained");
    try process.ready();
    try process.send(":w\r");
    try process.until("save refused");
    try process.ready();
    try equal(posix.E.NOENT, posix.errno(linux.access(path, linux.F_OK)));
    try putFile(path, "recreated\n");
    try process.until("recreated");
    try process.until("Reloaded external changes");
    try process.ready();
    // Resume validation is independent of queued events. A clean pending command
    // survives suspension and holds the replacement until cancellation.
    // Decoded Ctrl-Z follows the count in input order, so the count is known
    // to be pending before suspension without racing an external signal.
    try process.send("2\x1a");
    try process.until(leave);
    try equal(@as(u8, 19), try process.wait(true));
    try process.restored();
    try putFile(path, "resumed\n");
    _ = try checked(linux.kill(process.pid, .CONT));
    try process.until(enter);
    try process.until("DISK CONFLICT");
    try process.ready();
    try process.send("\x03");
    try process.until("resumed");
    try process.until("Reloaded external changes");
    try process.ready();
    // Saving and processing our own notification must retain clean undo history.
    try editingKeys(&process, "iY\x03");
    try process.send(":w\r");
    try process.until("Written");
    try process.ready();
    try equal(@as(usize, 0), try process.read(100));
    try process.send("u");
    try process.until("NORMAL [+]");
    try process.ready();
    try process.send("\x12:qa\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    try expectFile(path, "Yresumed\n");
}

/// Runs a helper program to completion with no terminal I/O.
fn spawn(argv: []const ?[*:0]const u8) !void {
    const pid: posix.pid_t = @intCast(try checked(linux.fork()));
    if (pid == 0) {
        const null_fd = linux.open("/dev/null", .{ .ACCMODE = .RDWR }, 0);
        if (posix.errno(null_fd) == .SUCCESS) {
            for (0..3) |fd| _ = linux.dup2(@intCast(null_fd), @intCast(fd));
        }
        const env = [_:null]?[*:0]const u8{"PATH=/usr/bin:/bin"};
        const program = argv[0].?;
        _ = linux.execve(program, @ptrCast(argv.ptr), &env);
        linux.exit_group(127);
    }
    var status: i32 = 0;
    while (posix.errno(linux.waitpid(pid, &status, 0)) == .INTR) {}
    const code: u32 = @bitCast(status);
    if (!linux.W.IFEXITED(code) or linux.W.EXITSTATUS(code) != 0) return error.HelperFailed;
}

/// A worktree for the finder workflows, at `<base>/repo`:
/// tracked `.gitignore`, `alpha.txt`, `beta.txt` and `sub/gamma.txt`;
/// untracked `big.txt` (over 64 KiB), `link` to `alpha.txt` and `pipe` to a
/// FIFO outside it; ignored `debug.log`.
const Project = struct {
    base: [:0]const u8,
    storage: [128]u8 = undefined,
    repo_storage: [160]u8 = undefined,
    repo: [:0]const u8 = undefined,

    fn create(base_storage: *[128]u8, name: []const u8) !Project {
        const format = "/tmp/nib-{s}-{d}";
        const pid = linux.getpid();
        const base = try std.fmt.bufPrintSentinel(base_storage, format, .{ name, pid }, 0);
        var project: Project = .{ .base = base };
        project.repo = try std.fmt.bufPrintSentinel(&project.repo_storage, "{s}/repo", .{base}, 0);
        _ = try checked(linux.mkdir(base, 0o700));
        errdefer project.remove();
        const repo = project.repo;
        try spawn(&.{ "/usr/bin/git", "init", "-q", repo, null });
        var sub_buffer: [192]u8 = undefined;
        _ = try checked(linux.mkdir(try project.path(&sub_buffer, "sub"), 0o700));
        const files = [_][2][]const u8{
            .{ ".gitignore", "*.log\n" },
            .{ "alpha.txt", "alpha one\nalpha two\n" },
            .{ "beta.txt", "beta\n" },
            .{ "sub/gamma.txt", "gamma\n" },
            .{ "debug.log", "log\n" },
        };
        for (files) |entry| {
            var buffer: [192]u8 = undefined;
            try putFile(try project.path(&buffer, entry[0]), entry[1]);
        }
        var big: [70 * 1024]u8 = undefined;
        @memset(&big, 'b');
        @memcpy(big[0..9], "big file\n");
        var big_buffer: [192]u8 = undefined;
        try putFile(try project.path(&big_buffer, "big.txt"), &big);
        var link_buffer: [192]u8 = undefined;
        _ = try checked(linux.symlink("alpha.txt", try project.path(&link_buffer, "link")));
        var fifo_buffer: [192]u8 = undefined;
        const fifo = try std.fmt.bufPrintSentinel(&fifo_buffer, "{s}/fifo", .{base}, 0);
        _ = try checked(linux.mknodat(linux.AT.FDCWD, fifo, linux.S.IFIFO | 0o600, 0));
        var pipe_buffer: [192]u8 = undefined;
        _ = try checked(linux.symlink(fifo, try project.path(&pipe_buffer, "pipe")));
        const tracked = [_:null]?[*:0]const u8{
            "/usr/bin/git", "-C",        repo,       "add",           "--",
            ".gitignore",   "alpha.txt", "beta.txt", "sub/gamma.txt",
        };
        try spawn(&tracked);
        return project;
    }

    fn path(self: *const Project, buffer: []u8, relative: []const u8) ![:0]const u8 {
        return std.fmt.bufPrintSentinel(buffer, "{s}/{s}", .{ self.repo, relative }, 0);
    }

    fn remove(self: *const Project) void {
        spawn(&.{ "/usr/bin/rm", "-rf", self.base, null }) catch {};
    }
};

/// Waits for a finder frame showing `counts` with nothing scanning or
/// searching, above the query row holding exactly `query`. Background work
/// draws extra frames, so a bare count can match a stale one.
fn settled(process: *Process, counts: []const u8, query: []const u8) !void {
    // Rows are 79 cells in the default 80-column terminal.
    var marker: [79 + 4 + 64]u8 = undefined;
    @memset(marker[0..79], ' ');
    @memcpy(marker[0..counts.len], counts);
    const rest = try std.fmt.bufPrint(marker[79..], "\r\n> {s} ", .{query});
    try process.until(marker[0 .. 79 + rest.len]);
}

/// Sends one key and waits for its frame.
fn finderKeys(process: *Process, bytes: []const u8) !void {
    for (bytes) |byte| {
        try process.send(&.{byte});
        try process.ready();
    }
}

// Covers starting with no file from a subdirectory, searching, previews,
// dirty switching with exact state, categories, dimming, Open markers,
// list keys, :qa protection, closing back to the most recent file, and
// quitting by closing the last one.
fn finderSwitching(executable: [:0]const u8) !void {
    var base: [128]u8 = undefined;
    const project = try Project.create(&base, "finder");
    defer project.remove();
    var sub: [192]u8 = undefined;
    var process = try Process.start(executable, .{
        .missing_argument = true,
        .cwd = try project.path(&sub, "sub"),
    });
    defer process.close();
    // `nib` alone in a subdirectory roots at the worktree.
    var header: [192]u8 = undefined;
    try process.until(try std.fmt.bufPrint(&header, "[Project] All  Open  | {s}", .{project.repo}));
    try settled(&process, "7/7 files", "");
    // The first result, .gitignore, is previewed.
    try process.until("*.log");
    try process.ready();
    // Escape moves from the query to the list, where letters move instead of
    // searching; with no file open, Escape there has nowhere to go.
    try process.send("\x1b");
    try process.until("LIST | ");
    try process.ready();
    try process.send("G");
    try process.until("\x1b[7m>   sub/gamma.txt");
    try process.ready();
    try process.send("k");
    try process.ready();
    try process.send("j");
    try process.until("\x1b[7m>   sub/gamma.txt");
    try process.ready();
    try process.send("g");
    try process.ready();
    try process.send("g");
    try process.until("\x1b[7m>   .gitignore");
    try process.ready();
    try process.send("\x1b");
    try process.until("No file open; :q quits");
    try process.ready();
    try process.send("/");
    try process.until("SEARCH | ");
    try process.ready();
    try process.send("alp");
    try settled(&process, "1/7 files", "alp");
    try process.until("alpha one");
    try process.ready();
    try process.send("\r");
    try process.until("\x1b[2Jalpha one ");
    try process.until("NORMAL | 1:1 | ");
    try process.ready();
    try editingKeys(&process, "iA\x03j");
    try process.send("$");
    try process.until("NORMAL [+] | 2:9 | ");
    try process.ready();
    // The finder keeps the query; the open dirty file shows its marker and
    // previews its unsaved text.
    try process.send("\x10");
    try process.until(">+  ");
    try process.until("Open file, unsaved edits");
    try process.until("Aalpha one");
    try process.ready();
    try finderKeys(&process, "\x7f\x7f\x7f");
    try process.send("beta");
    try settled(&process, "1/7 files", "beta");
    try process.ready();
    try process.send("\r");
    try process.until("NORMAL | 1:1 | ");
    try process.ready();
    try editingKeys(&process, "iB\x03");
    try process.send(":w\r");
    try process.until("Written");
    try process.ready();
    var beta: [192]u8 = undefined;
    try expectFile(try project.path(&beta, "beta.txt"), "Bbeta\n");
    // All adds the ignored log, dimmed as Git lists it.
    try process.send("\x10");
    try process.ready();
    try finderKeys(&process, "\x7f\x7f\x7f\x7f");
    try process.send("\t");
    try process.until("[All]");
    try process.until("\x1b[2mdebug.log");
    try process.ready();
    // Open lists both, most recent first; the other one previews its edits.
    try process.send("\t");
    try process.until("[Open]");
    try settled(&process, "2/2 files", "");
    try process.ready();
    try process.send("\x1b");
    try process.until("LIST | ");
    try process.ready();
    try process.send("j");
    try process.until("Open file, unsaved edits");
    try process.ready();
    try process.send("\r");
    // Switching back restores text, cursor and history exactly.
    try process.until("\x1b[2JAalpha one ");
    try process.until("NORMAL [+] | 2:9 | ");
    try process.ready();
    try process.send("u");
    try process.until("NORMAL | 1:1 | ");
    try process.ready();
    try process.send("\x12");
    try process.until("NORMAL [+] | 1:1 | ");
    try process.ready();
    try process.send(":qa\r");
    try process.until("Unsaved changes in 1 file: alpha.txt; :qa! discards them");
    try process.ready();
    try process.send(":q\r");
    try process.until("Unsaved changes in alpha.txt; use :q! to discard");
    try process.ready();
    try process.send(":q!\r");
    try process.until("Bbeta");
    try process.until("Discarded edits and closed alpha.txt");
    try process.ready();
    // From the list, q returns to the file; the query was kept.
    try process.send("\x10");
    try process.until("SEARCH | ");
    try process.ready();
    try process.send("\x1b");
    try process.until("LIST | ");
    try process.ready();
    try process.send("q");
    try process.until("NORMAL | 1:1 | ");
    try process.ready();
    // Closing the last file quits.
    try process.send(":q\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    var alpha: [192]u8 = undefined;
    try expectFile(try project.path(&alpha, "alpha.txt"), "alpha one\nalpha two\n");
}

// Covers aliases, special-file previews and refusals, refresh, resize and
// suspension in the finder, an inactive dirty file replaced on disk, and
// :wq failing and succeeding.
fn finderSafety(executable: [:0]const u8) !void {
    var base: [128]u8 = undefined;
    const project = try Project.create(&base, "safety");
    defer project.remove();
    var link: [192]u8 = undefined;
    var process = try Process.start(executable, .{ .path = try project.path(&link, "link") });
    defer process.close();
    try process.until("alpha one");
    try process.until("repo/link | ");
    try process.ready();
    try editingKeys(&process, "iL\x03");
    // Opening the link's target reuses its document and first spelling.
    try process.send("\x10");
    try settled(&process, "7/7 files", "");
    try process.ready();
    try process.send("alpha");
    try settled(&process, "1/7 files", "alpha");
    try process.ready();
    try process.send("\r");
    try process.until("Lalpha one");
    try process.until("NORMAL [+] | 1:1 | ");
    try process.until("repo/link | ");
    try process.ready();
    // A FIFO behind a symlink is neither previewed nor opened, and never blocks.
    try process.send("\x10");
    try process.ready();
    try finderKeys(&process, "\x7f\x7f\x7f\x7f\x7f");
    try process.send("pipe");
    try process.until("No preview: not a regular file");
    try process.ready();
    try process.send("\r");
    try process.until("Cannot open: not a regular file");
    try process.ready();
    // The large file is marked truncated.
    try finderKeys(&process, "\x7f\x7f\x7f\x7f");
    try process.send("big");
    try process.until("Preview: first 64 KiB");
    try process.ready();
    // Files created by others appear on refresh.
    try finderKeys(&process, "\x7f\x7f\x7f");
    var fresh: [192]u8 = undefined;
    try putFile(try project.path(&fresh, "new.txt"), "fresh\n");
    try process.send("new");
    try settled(&process, "0/7 files", "new");
    try process.ready();
    try process.send("\x12");
    try settled(&process, "1/8 files", "new");
    try process.until("fresh");
    try process.ready();
    // Resizing redraws from what was read; a narrow terminal hides the preview
    // but keeps the query, the selected path and the status.
    var narrow: posix.winsize = .{ .row = 6, .col = 30, .xpixel = 0, .ypixel = 0 };
    _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&narrow)));
    try process.until("> new");
    try process.until("new.txt");
    try process.until("Enter open");
    try process.ready();
    var wide: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
    _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&wide)));
    try process.until(frame);
    try process.until("fresh");
    try process.ready();
    // Suspension from the finder restores the shell's terminal, then the finder.
    try process.send("\x1a");
    try equal(@as(u8, @backingInt(posix.SIG.STOP)), try process.wait(true));
    try process.until(leave);
    try process.restored();
    try process.signal(.CONT);
    try process.until("[Project]");
    try process.ready();
    try finderKeys(&process, "\x1b");
    try process.send("\x1b");
    try process.until("Lalpha one");
    try process.ready();
    // A dirty inactive file keeps its edits when replaced on disk.
    try process.send("\x10");
    try process.ready();
    try finderKeys(&process, "\x7f\x7f\x7f");
    try process.send("beta");
    try settled(&process, "1/8 files", "beta");
    try process.ready();
    try process.send("\r");
    try process.until("NORMAL | 1:1 | ");
    try process.ready();
    var alpha: [192]u8 = undefined;
    const alpha_path = try project.path(&alpha, "alpha.txt");
    var staged: [192]u8 = undefined;
    const staged_path = try project.path(&staged, "staged");
    try putFile(staged_path, "replaced\n");
    _ = try checked(linux.rename(staged_path, alpha_path));
    try process.send("\x10");
    try process.ready();
    try finderKeys(&process, "\x7f\x7f\x7f\x7f");
    try process.send("alpha");
    try settled(&process, "1/8 files", "alpha");
    try process.ready();
    try process.send("\r");
    try process.until("Lalpha one");
    try process.until("DISK CONFLICT | ");
    try process.ready();
    // :wq refuses the conflicting save and keeps the file open and dirty.
    try process.send(":wq\r");
    try process.until("Source changed or missing; save refused");
    try process.ready();
    try process.send("\x03");
    try process.until("NORMAL [+]");
    try process.ready();
    try expectFile(alpha_path, "replaced\n");
    try process.send(":q!\r");
    try process.until("beta");
    try process.ready();
    // :wq on the last, clean file saves, closes it and quits.
    var beta: [192]u8 = undefined;
    const beta_path = try project.path(&beta, "beta.txt");
    try process.send(":wq\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
    try expectFile(alpha_path, "replaced\n");
    try expectFile(beta_path, "beta\n");
}

// Ctrl-C leaves the query for the list, half pages move, and with no file
// open the list's : enters a command and :q quits.
fn finderQuit(executable: [:0]const u8) !void {
    var base: [128]u8 = undefined;
    const project = try Project.create(&base, "quit");
    defer project.remove();
    var process = try Process.start(executable, .{ .missing_argument = true, .cwd = project.repo });
    defer process.close();
    try settled(&process, "7/7 files", "");
    try process.ready();
    try process.send("\x03");
    try process.until("LIST | ");
    try process.ready();
    // Seven results fit in half the page of 24 rows.
    try process.send("\x04");
    try process.until("\x1b[7m>   sub/gamma.txt");
    try process.ready();
    try process.send("\x15");
    try process.until("\x1b[7m>   .gitignore");
    try process.ready();
    try process.send(":");
    try process.until("\x1b[7m:");
    try process.ready();
    try process.send("q\r");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
}
