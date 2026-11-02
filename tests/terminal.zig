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
    const executable = args.next() orelse return error.MissingExecutable;
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
        .{ "startupFailures", startupFailures },
        .{ "stalledOutputRecovery", stalledOutputRecovery },
        .{ "stalledOutputTermination", stalledOutputTermination },
        .{ "stalledOutputSuspend", stalledOutputSuspend },
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
    try process.send("q");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
}

fn interruptAndTermination(executable: [:0]const u8) !void {
    for ([_]posix.SIG{ .INT, .TERM, .HUP }) |sig| {
        var process = try Process.start(executable, .{});
        defer process.close();
        try process.ready();
        if (sig == .INT) try process.send("\x03") else try process.signal(sig);
        try equal(@as(u8, 128 + @as(u8, @intCast(@backingInt(sig)))), try process.wait(false));
        try process.until(leave);
        try process.restored();
    }
}

fn resizeAndSuspend(executable: [:0]const u8) !void {
    var process = try Process.start(executable, .{});
    defer process.close();
    try process.ready();
    for ([_][2]u16{ .{ 1, 1 }, .{ 0, 0 }, .{ 30, 100 } }) |size| {
        var dimensions: posix.winsize = .{ .row = size[0], .col = size[1], .xpixel = 0, .ypixel = 0 };
        _ = try checked(linux.ioctl(process.master.?, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
        try process.until(frame);
    }
    try process.until("Ctrl-Z suspend");
    for (0..3) |_| {
        try process.send("\x1a");
        try equal(@as(u8, @backingInt(posix.SIG.STOP)), try process.wait(true));
        try process.until(leave);
        try process.restored();
        try process.signal(.CONT);
        try process.ready();
    }
    try process.send("q");
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
    try shell.until("Ctrl-Z suspend");
    for (0..2) |_| {
        try shell.send("\x1a");
        try shell.until(prompt);
        try shell.restored();
        try shell.send("fg\n");
        try shell.until("Ctrl-Z suspend");
    }
    try shell.send("\x1a");
    try shell.until(prompt);
    try shell.send("bg\n");
    try shell.until(prompt);
    try shell.restored();
    _ = try shell.read(100);
    try shell.excludes(enter);
    try shell.send("fg\n");
    try shell.until("Ctrl-Z suspend");
    try shell.send("q");
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
    try process.send("jjlll");
    try process.until("3:4 | ");
    try process.until("\x1b[0m");
    // Fragmented CSI, SS3, OSC, DCS, Alt-q and pasted commands are ignored.
    for ([_][]const u8{ "\x1b[", "999q", "\x1bO", "q", "\x1b]qhjkl", "\x07", "\x1bPq", "\x1b\\", "\x1bq", "\x1b[200~qhjkl\x1b[201~" }) |part| {
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
    try process.until("e002 xxxxxx");
    try process.ready();
    // Reach the final row and the final display column, then check the whole
    // clipped frame. The fixture ends with CRLF and contains an eight-stop tab.
    var movement: [128]u8 = undefined;
    @memset(&movement, 'j');
    try process.send(&movement);
    try process.until("e059 xxxxxx\r\n");
    try process.until("\x1b[0m");
    @memset(&movement, 'l');
    try process.send(&movement);
    try process.until("\x1b[H\x1b[2JxxTAIL    !\r\nxxTAIL    !\r\nxxTAIL    !\r\n");
    try process.ready();
    try equal(@as(usize, 0), try process.read(100));
    try process.send("q");
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

fn startupFailures(executable: [:0]const u8) !void {
    for ([_]Options{
        .{ .missing_argument = true },
        .{ .extra_argument = true },
        .{ .path = "/a/missing/nib-test-file" },
        .{ .path = "/tmp" },
        .{ .path = "/dev/null" },
    }, [_][]const u8{ "usage: nib <path>", "exactly one file", "file not found", "regular file", "regular file" }) |options, message| {
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
    try process.rejected("temporary 8 MiB viewer limit");
    _ = try checked(linux.ftruncate(fd, 0));
    var newlines: [4096]u8 = undefined;
    @memset(&newlines, '\n');
    // The descriptor offset is still zero after ftruncate.
    for (0..64) |_| try write(fd, &newlines);
    try write(fd, "\n");
    var lines = try Process.start(executable, .{ .path = path });
    defer lines.close();
    try lines.rejected("temporary 262,144-line viewer limit");
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
        try process.send("q");
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
    const status = std.mem.indexOf(u8, bytes, "\x1b[7mq quit") orelse return error.MissingOutput;
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
    try process.send("q");
    try equal(@as(u8, 0), try process.wait(false));
    try process.until(leave);
    try process.restored();
}
