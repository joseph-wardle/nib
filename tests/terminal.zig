// SPDX-License-Identifier: MIT OR Apache-2.0
//! Linux PTY integration checks. Owns child processes and PTY descriptors;
//! exercises the built executable independently of its terminal implementation.
const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const frame = "\x1b[H\x1b[2J";
const enter = "\x1b[?25s\x1b[?1049h\x1b[?25l";
const leave = "\x1b[?1049l\x1b[?25r";
const prompt = "NIBTEST> ";

// Keep startup single-threaded: child setup after fork must not inherit runtime
// worker threads or allocator locks. The harness uses fixed owned buffers.
pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterate();
    _ = args.next();
    const executable = args.next() orelse return error.MissingExecutable;
    const checks = .{
        .{ "quitAndIdle", quitAndIdle },
        .{ "interruptAndTermination", interruptAndTermination },
        .{ "resizeAndSuspend", resizeAndSuspend },
        .{ "pendingTermination", pendingTermination },
        .{ "setupFailures", setupFailures },
        .{ "redirectedStdio", redirectedStdio },
        .{ "disconnect", disconnect },
        .{ "shellJobControl", shellJobControl },
    };
    inline for (checks) |check| {
        check[1](executable) catch |err| {
            std.debug.print("terminal check {s}: {t}\n", .{ check[0], err });
            return err;
        };
    }
    std.debug.print("All {d} terminal lifecycle checks passed.\n", .{checks.len});
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
};

const Process = struct {
    master: ?posix.fd_t,
    slave: posix.fd_t,
    pid: posix.pid_t,
    saved: posix.termios,
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
        var dimensions: posix.winsize = .{ .row = 24, .col = 80, .xpixel = 0, .ypixel = 0 };
        _ = try checked(linux.ioctl(slave, linux.T.IOCSWINSZ, @intFromPtr(&dimensions)));
        const saved = try posix.tcgetattr(slave);
        const pid: posix.pid_t = @intCast(try checked(linux.fork()));
        if (pid == 0) {
            child(master, slave, executable, options) catch {};
            linux.exit_group(127);
        }
        return .{ .master = master, .slave = slave, .pid = pid, .saved = saved };
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
        const argv = [_:null]?[*:0]const u8{executable.ptr};
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
    }

    fn ready(self: *Process) !void {
        try self.until("Ctrl-Z suspend");
        const mode = try posix.tcgetattr(self.slave);
        try expect(!mode.lflag.ECHO and !mode.lflag.ICANON);
        try expect(mode.lflag.ISIG and !mode.iflag.IXON);
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
        try equal(@as(u8, 1), try process.wait(false));
        try process.until("controlling terminal");
        try process.excludes(enter);
        try process.restored();
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
    // Shell single-quote escaping, including apostrophes in the executable path.
    var command: [8192]u8 = undefined;
    var length: usize = 0;
    for (executable) |byte| length += if (byte == '\'') 4 else @as(usize, 1);
    if (length + 5 > command.len) return error.PathTooLong;
    length = 0;
    command[length] = '\'';
    length += 1;
    for (executable) |byte| {
        const text = if (byte == '\'') "'\\''" else &[_]u8{byte};
        @memcpy(command[length..][0..text.len], text);
        length += text.len;
    }
    command[length] = '\'';
    length += 1;
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
