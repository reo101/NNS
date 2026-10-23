// SPDX-License-Identifier: Apache-2.0
// Shizuku process transport: framed input/control, unmodified output streams.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

const max_data = 4096;
// POSIX signal sentinels are integer values, not aligned function addresses.
extern "c" fn signal(number: c_int, handler: usize) usize;
const Kind = enum(u8) { data = 1, window = 2, eof = 3, _ };
var termination = std.atomic.Value(c_int).init(0);
var resized = std.atomic.Value(bool).init(false);

fn signalHandler(number: c_int) callconv(.c) void {
    if (number == c.SIGWINCH) resized.store(true, .monotonic) else termination.store(number, .monotonic);
}

fn installSignals() void {
    for ([_]c_int{ c.SIGTERM, c.SIGHUP, c.SIGINT, c.SIGQUIT, c.SIGWINCH }) |number| {
        _ = signal(number, @intFromPtr(&signalHandler));
    }
    _ = signal(c.SIGPIPE, 1);
}

fn errno() c_int {
    return if (builtin.abi == .android) c.__errno().* else c.__errno_location().*;
}

fn checkSignal() !void {
    if (termination.load(.monotonic) != 0) return error.Interrupted;
}

fn nonblocking(fd: c_int) !void {
    const flags = c.fcntl(fd, c.F_GETFL);
    if (flags < 0 or c.fcntl(fd, c.F_SETFL, flags | c.O_NONBLOCK) < 0) return error.System;
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try checkSignal();
        const count = c.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (count > 0) {
            offset += @intCast(count);
        } else if (count < 0 and errno() == c.EINTR) {
            continue;
        } else if (count < 0 and errno() == c.EAGAIN) {
            var descriptor: c.struct_pollfd = .{ .fd = fd, .events = c.POLLOUT, .revents = 0 };
            _ = c.poll(&descriptor, 1, 100);
        } else return error.Write;
    }
}

fn sendFrame(kind: Kind, payload: []const u8) !void {
    var header: [5]u8 = undefined;
    header[0] = @backingInt(kind);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .big);
    try writeAll(1, &header);
    try writeAll(1, payload);
}

fn sendWindow(fd: c_int) !void {
    var size: c.struct_winsize = undefined;
    if (c.ioctl(fd, c.TIOCGWINSZ, &size) < 0) return error.WindowSize;
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], size.ws_row, .big);
    std.mem.writeInt(u16, bytes[2..4], size.ws_col, .big);
    std.mem.writeInt(u16, bytes[4..6], size.ws_xpixel, .big);
    std.mem.writeInt(u16, bytes[6..8], size.ws_ypixel, .big);
    try sendFrame(.window, &bytes);
}

fn inputMode(mask: u3, tty_path: [*:0]const u8) !u8 {
    installSignals();
    const parent = c.getppid();
    if (parent == 1 or c.prctl(c.PR_SET_PDEATHSIG, @as(c_ulong, c.SIGTERM), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) < 0 or c.getppid() != parent) return error.ParentExited;
    try nonblocking(1);
    const tty = if (mask != 0) c.open(tty_path, c.O_RDONLY | c.O_NOCTTY | c.O_CLOEXEC) else -1;
    defer if (tty >= 0) {
        _ = c.close(tty);
    };
    if (mask != 0 and tty < 0) return error.Terminal;
    var original: c.struct_termios = undefined;
    if (mask == 7) {
        if (c.tcgetattr(0, &original) < 0) return error.Terminal;
        var raw = original;
        c.cfmakeraw(&raw);
        if (c.tcsetattr(0, c.TCSANOW, &raw) < 0) return error.Terminal;
    }
    defer if (mask == 7) {
        _ = c.tcsetattr(0, c.TCSANOW, &original);
    };
    if (tty >= 0) try sendWindow(tty);
    while (true) {
        try checkSignal();
        if (resized.swap(false, .monotonic) and tty >= 0) try sendWindow(tty);
        var descriptor: c.struct_pollfd = .{ .fd = 0, .events = c.POLLIN, .revents = 0 };
        const ready = c.poll(&descriptor, 1, 100);
        if (ready < 0 and errno() != c.EINTR) return error.Poll;
        if (ready <= 0) continue;
        if (descriptor.revents & c.POLLNVAL != 0) return error.Input;
        var bytes: [max_data]u8 = undefined;
        const count = c.read(0, &bytes, bytes.len);
        if (count > 0) {
            try sendFrame(.data, bytes[0..@intCast(count)]);
        } else if (count == 0) {
            try sendFrame(.eof, "");
            return 0;
        } else if (errno() != c.EINTR and errno() != c.EAGAIN) return error.Input;
    }
}

const Packet = struct { kind: Kind, payload: []const u8 };
const Decoder = struct {
    header: [5]u8 = undefined,
    header_used: usize = 0,
    body: [max_data]u8 = undefined,
    body_used: usize = 0,
    length: usize = 0,
    kind: Kind = .eof,

    fn read(self: *Decoder) !?Packet {
        while (true) {
            const reading_header = self.header_used < 5;
            const destination = if (reading_header) self.header[self.header_used..] else self.body[self.body_used..self.length];
            if (destination.len == 0) {
                const packet: Packet = .{ .kind = self.kind, .payload = self.body[0..self.length] };
                self.header_used = 0;
                self.body_used = 0;
                return packet;
            }
            const count = c.read(0, destination.ptr, destination.len);
            if (count == 0) return error.Disconnected;
            if (count < 0) {
                if (errno() == c.EINTR) {
                    try checkSignal();
                    continue;
                }
                if (errno() == c.EAGAIN) return null;
                return error.Input;
            }
            if (reading_header) {
                self.header_used += @intCast(count);
                if (self.header_used == 5) {
                    self.kind = @fromBackingInt(@intCast(self.header[0]));
                    self.length = std.mem.readInt(u32, self.header[1..5], .big);
                    switch (self.kind) {
                        .data => if (self.length == 0 or self.length > max_data) return error.Protocol,
                        .window => if (self.length != 8) return error.Protocol,
                        .eof => if (self.length != 0) return error.Protocol,
                        else => return error.Protocol,
                    }
                }
            } else self.body_used += @intCast(count);
        }
    }
};

const Pending = struct {
    bytes: [8192]u8 = undefined,
    offset: usize = 0,
    length: usize = 0,

    fn empty(self: *const Pending) bool {
        return self.offset == self.length;
    }
    fn replace(self: *Pending, bytes: []const u8) void {
        @memcpy(self.bytes[0..bytes.len], bytes);
        self.offset = 0;
        self.length = bytes.len;
    }
    fn write(self: *Pending, fd: c_int) !void {
        const count = c.write(fd, self.bytes[self.offset..self.length].ptr, self.length - self.offset);
        if (count > 0) self.offset += @intCast(count) else if (count < 0 and errno() != c.EINTR and errno() != c.EAGAIN) return error.Write;
    }
};

fn applyWindow(fd: c_int, bytes: []const u8) !void {
    var size: c.struct_winsize = .{
        .ws_row = std.mem.readInt(u16, bytes[0..2], .big),
        .ws_col = std.mem.readInt(u16, bytes[2..4], .big),
        .ws_xpixel = std.mem.readInt(u16, bytes[4..6], .big),
        .ws_ypixel = std.mem.readInt(u16, bytes[6..8], .big),
    };
    if (c.ioctl(fd, c.TIOCSWINSZ, &size) < 0) return error.WindowSize;
}

fn reap(child: c.pid_t, status: *c_int, flags: c_int) !bool {
    while (true) {
        const result = c.waitpid(child, status, flags);
        if (result == child) return true;
        if (result == 0) return false;
        if (errno() != c.EINTR) return error.Wait;
    }
}

fn childExited(child: c.pid_t) !bool {
    var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
    while (c.waitid(c.P_PID, @intCast(child), &info, c.WEXITED | c.WNOHANG | c.WNOWAIT) < 0) {
        if (errno() != c.EINTR) return error.Wait;
    }
    // Linux siginfo_t starts with si_signo. Bionic wraps it in an anonymous union.
    const signo: *const c_int = @ptrCast(&info);
    return signo.* == c.SIGCHLD;
}

fn terminateChild(child: c.pid_t) void {
    _ = c.kill(-child, c.SIGTERM);
    _ = c.kill(child, c.SIGTERM);
    for (0..100) |_| {
        if (childExited(child) catch false) break;
        _ = c.poll(null, 0, 20);
    }
    _ = c.kill(-child, c.SIGKILL);
    _ = c.kill(child, c.SIGKILL);
    var status: c_int = 0;
    _ = reap(child, &status, 0) catch false;
}

fn hostMode(mask: u3, argv: [*]?[*:0]const u8) !u8 {
    installSignals();
    _ = signal(c.SIGCHLD, 0);
    try nonblocking(0);
    var decoder: Decoder = .{};
    var initial_window: [8]u8 = undefined;
    if (mask != 0) {
        while (true) {
            try checkSignal();
            if (try decoder.read()) |packet| {
                if (packet.kind != .window) return error.Protocol;
                @memcpy(&initial_window, packet.payload);
                break;
            }
            var descriptor: c.struct_pollfd = .{ .fd = 0, .events = c.POLLIN, .revents = 0 };
            _ = c.poll(&descriptor, 1, 100);
        }
    }
    var master: c_int = -1;
    var slave: c_int = -1;
    defer if (master >= 0) {
        _ = c.close(master);
    };
    defer if (slave >= 0) {
        _ = c.close(slave);
    };
    if (mask != 0) {
        master = c.posix_openpt(c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (master < 0 or c.grantpt(master) < 0 or c.unlockpt(master) < 0) return error.Terminal;
        var name: [256]u8 = undefined;
        if (c.ptsname_r(master, &name, name.len) != 0) return error.Terminal;
        slave = c.open(@as([*:0]u8, @ptrCast(&name)), c.O_RDWR | c.O_NOCTTY | c.O_CLOEXEC);
        if (slave < 0) return error.Terminal;
        try applyWindow(slave, &initial_window);
    }
    var pipe: [2]c_int = .{ -1, -1 };
    if (mask & 1 == 0 and c.pipe2(&pipe, c.O_CLOEXEC) < 0) return error.Pipe;
    defer for (&pipe) |*fd| {
        if (fd.* >= 0) _ = c.close(fd.*);
    };
    const child = c.fork();
    if (child < 0) return error.Fork;
    if (child == 0) {
        for ([_]c_int{ c.SIGTERM, c.SIGHUP, c.SIGINT, c.SIGQUIT, c.SIGPIPE, c.SIGWINCH, c.SIGCHLD }) |number| _ = signal(number, 0);
        if (c.setsid() < 0) c._exit(127);
        if (slave >= 0 and c.ioctl(slave, c.TIOCSCTTY, @as(c_int, 0)) < 0) c._exit(127);
        if (c.dup2(if (mask & 1 != 0) slave else pipe[0], 0) < 0) c._exit(127);
        if (mask & 2 != 0 and c.dup2(slave, 1) < 0) c._exit(127);
        if (mask & 4 != 0 and c.dup2(slave, 2) < 0) c._exit(127);
        if (master >= 0) _ = c.close(master);
        if (slave >= 0) _ = c.close(slave);
        for (pipe) |fd| {
            if (fd >= 0) _ = c.close(fd);
        }
        const shell = if (builtin.abi == .android) "/system/bin/sh" else "/bin/sh";
        argv[2] = shell;
        _ = c.execv(shell, @ptrCast(argv + 2));
        c._exit(127);
    }
    var child_done = false;
    var child_reaped = false;
    var status: c_int = 0;
    defer if (!child_reaped) terminateChild(child);
    if (slave >= 0) {
        _ = c.close(slave);
        slave = -1;
    }
    if (pipe[0] >= 0) {
        _ = c.close(pipe[0]);
        pipe[0] = -1;
    }
    const input_fd = if (mask & 1 != 0) master else pipe[1];
    const output_fd: c_int = if (mask & 2 != 0) 1 else if (mask & 4 != 0) 2 else -1;
    try nonblocking(input_fd);
    if (master >= 0) try nonblocking(master);
    if (output_fd >= 0) try nonblocking(output_fd);
    var input: Pending = .{};
    var output: Pending = .{};
    var got_eof = false;
    var input_closed = false;
    var master_closed = master < 0;
    while (true) {
        try checkSignal();
        if (!child_done and try childExited(child)) {
            child_done = true;
            // Keep the leader waitable until group cleanup, so its ID cannot
            // be reused while descendants still hold transport descriptors.
            _ = c.kill(-child, c.SIGKILL);
        }
        if (child_done and master_closed and output.empty()) break;
        var descriptors = [_]c.struct_pollfd{
            .{ .fd = if (!got_eof and !input_closed and input.empty() and !child_done) 0 else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (!input.empty() and !input_closed) input_fd else -1, .events = c.POLLOUT, .revents = 0 },
            .{ .fd = if (!master_closed and output.empty()) master else -1, .events = c.POLLIN, .revents = 0 },
            .{ .fd = if (!output.empty()) output_fd else -1, .events = c.POLLOUT, .revents = 0 },
        };
        // After the shell exits, drain only data already available, not a
        // background descendant's indefinitely open slave descriptor.
        const ready = c.poll(&descriptors, descriptors.len, if (child_done and output.empty()) 0 else 100);
        if (ready < 0) {
            if (errno() == c.EINTR) continue;
            return error.Poll;
        }
        if (child_done and output.empty() and descriptors[2].revents == 0) master_closed = true;
        if (descriptors[0].revents != 0) {
            if (try decoder.read()) |packet| switch (packet.kind) {
                .data => input.replace(packet.payload),
                .window => {
                    if (master >= 0) try applyWindow(master, packet.payload);
                },
                .eof => {
                    got_eof = true;
                    if (mask & 1 != 0) {
                        var attributes: c.struct_termios = undefined;
                        if (c.tcgetattr(master, &attributes) < 0) return error.Terminal;
                        input.replace(&.{attributes.c_cc[c.VEOF]});
                    }
                },
                else => return error.Protocol,
            };
        }
        if (descriptors[1].revents != 0) input.write(input_fd) catch {
            input_closed = true;
            input.length = input.offset;
        };
        if (got_eof and mask & 1 == 0 and input.empty() and !input_closed) {
            _ = c.close(pipe[1]);
            pipe[1] = -1;
            input_closed = true;
        }
        if (descriptors[2].revents != 0) {
            const count = c.read(master, &output.bytes, output.bytes.len);
            if (count > 0 and output_fd >= 0) {
                output.offset = 0;
                output.length = @intCast(count);
            }
            if (count == 0 or (count < 0 and errno() == c.EIO)) master_closed = true;
            if (count < 0 and errno() != c.EIO and errno() != c.EAGAIN and errno() != c.EINTR) return error.Output;
        }
        if (descriptors[3].revents != 0) try output.write(output_fd);
    }
    child_reaped = try reap(child, &status, 0);
    const bits: u32 = @bitCast(status);
    return if (bits & 0x7f == 0) @intCast((bits >> 8) & 0xff) else @intCast(128 + (bits & 0x7f));
}

pub export fn main(argc: c_int, argv: [*]?[*:0]const u8) c_int {
    if (argc < 3) return 2;
    const mask = std.fmt.parseInt(u3, std.mem.span(argv[2].?), 10) catch return 2;
    const mode = std.mem.span(argv[1].?);
    const result = if (std.mem.eql(u8, mode, "--input") and argc == 4)
        inputMode(mask, argv[3].?)
    else if (std.mem.eql(u8, mode, "--host"))
        hostMode(mask, argv)
    else
        return 2;
    return result catch |failure| {
        const number = termination.load(.monotonic);
        if (number != 0) return 128 + number;
        std.debug.print("nns-rish-terminal: {s}\n", .{@errorName(failure)});
        return 1;
    };
}
