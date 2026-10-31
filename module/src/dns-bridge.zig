// No DT_NEEDED libc: this preload travels through both glibc and Bionic
// children. Only glibc-facing calls are bridged (getaddrinfo, plus a
// TCGETS2/TCSETS2 ioctl translation); Bionic mostly passes through unchanged.
const std = @import("std");
const linux = std.os.linux;
extern fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
extern fn getenv([*:0]const u8) ?[*:0]const u8;
extern fn readlink([*:0]const u8, [*]u8, usize) isize;
extern fn calloc(usize, usize) ?*anyopaque;
extern fn free(?*anyopaque) void;
const wire = @import("dns-wire.zig");

// The preload must not request libc linkage: std.c declarations are gated on
// link_libc, so the five symbols this library borrows from its host are
// declared here and stay undefined until the loading process resolves them.
const next: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize)); // RTLD_NEXT, LP64

// Termios ioctls: the modern pair carries the platform xperm whitelist that
// rejects app ptys, the legacy pair is the permitted fallback.
const tcgets: u64 = 0x5401;
const tcsets: u64 = 0x5402;
const tcgets2: u64 = 0x542a;
const tcsets2: u64 = 0x542b;

const eacces: c_int = @backingInt(std.posix.E.ACCES);
const eperm: c_int = @backingInt(std.posix.E.PERM);
const enotty: c_int = @backingInt(std.posix.E.NOTTY);
const AddrInfo = extern struct {
    flags: i32 = 0,
    family: i32 = 0,
    socktype: i32 = 0,
    protocol: i32 = 0,
    addrlen: u32 = 0,
    addr: ?*anyopaque = null,
    canon: ?[*:0]u8 = null,
    next: ?*AddrInfo = null,
};
const GetAddrInfo = *const fn (?[*:0]const u8, ?[*:0]const u8, ?*const AddrInfo, *?*AddrInfo) callconv(.c) c_int;
const Ioctl = *const fn (i32, u64, ?*anyopaque) callconv(.c) c_int;
const RealIsatty = *const fn (c_int) callconv(.c) c_int;
const RealTcGetattr = *const fn (c_int, ?*anyopaque) callconv(.c) c_int;
const RealTcSetattr = *const fn (c_int, c_int, ?*anyopaque) callconv(.c) c_int;
const RealFstat = *const fn (c_int, ?*anyopaque) callconv(.c) c_int;
const RealTtyname = *const fn (c_int) callconv(.c) ?[*:0]u8;
const Errno = *const fn () callconv(.c) *c_int;
var tty_name_buffer: [4096]u8 = undefined;

fn errnoPtr() ?*c_int {
    const f: Errno = @ptrCast(@alignCast(dlsym(next, "__errno_location") orelse return null));
    return f();
}

// glibc resolves its own termios helpers intra-DSO: isatty's internal
// ioctl never crosses the preload boundary, so exporting ioctl alone
// misses every app that calls the wrappers (btop, nvim, ...). The
// wrappers must be bridged themselves; below, a permission failure on
// the modern code retries the legacy one the platform whitelist does
// carry, and a refusal of both is reported as ENOTTY - the truthful
// answer for binaries and plain files.
pub export fn isatty(fd: c_int) c_int {
    const native: RealIsatty = @ptrCast(@alignCast(dlsym(next, "isatty") orelse return 0));
    if (native(fd) != 0) return 1;
    const ep = errnoPtr() orelse return 0;
    if (ep.* != eacces and ep.* != eperm) return 0; // genuine ENOTTY etc: not a tty
    const io: Ioctl = @ptrCast(@alignCast(dlsym(next, "ioctl") orelse return 0));
    var probe: [64]u8 = undefined; // termios2-sized scratch for the probe
    if (io(fd, tcgets, &probe) >= 0) {
        ep.* = 0;
        return 1;
    }
    ep.* = enotty;
    return 0;
}

fn tcRetry(fd: c_int, legacy: u64, arg: ?*anyopaque, restore: ?*anyopaque) c_int {
    const ep = errnoPtr() orelse return -1;
    if (ep.* != eacces and ep.* != eperm) return -1;
    const io: Ioctl = @ptrCast(@alignCast(dlsym(next, "ioctl") orelse return -1));
    if (io(fd, legacy, restore orelse arg) >= 0) {
        ep.* = 0;
        return 0;
    }
    if (ep.* == eacces or ep.* == eperm) ep.* = enotty;
    return -1;
}

pub export fn tcgetattr(fd: c_int, out: ?*anyopaque) c_int {
    const native: RealTcGetattr = @ptrCast(@alignCast(dlsym(next, "tcgetattr") orelse return -1));
    const rc = native(fd, out);
    if (rc == 0) return 0;
    // The legacy TCGETS writes the identical 36-byte prefix of the
    // termios2 struct; only the trailing speed fields stay stale.
    return tcRetry(fd, tcgets, out, out);
}

pub export fn tcsetattr(fd: c_int, actions: c_int, in: ?*anyopaque) c_int {
    const native: RealTcSetattr = @ptrCast(@alignCast(dlsym(next, "tcsetattr") orelse return -1));
    const rc = native(fd, actions, in);
    if (rc == 0) return 0;
    return tcRetry(fd, tcsets, in, in);
}

// glibc's ttyname calls its hidden __tcgetattr, bypassing the ioctl and
// tcgetattr preload hooks. Recover only for app ptys after that probe is
// refused by the platform's TCGETS2 ioctl whitelist.
pub export fn ttyname(fd: c_int) ?[*:0]u8 {
    const native: RealTtyname = @ptrCast(@alignCast(dlsym(next, "ttyname") orelse return null));
    if (native(fd)) |name| return name;
    if (dlsym(next, "gnu_get_libc_version") == null) return null;
    const ep = errnoPtr() orelse return null;
    const original_error = ep.*;
    if (original_error != eacces and original_error != eperm) return null;
    if (isatty(fd) != 1) {
        ep.* = original_error;
        return null;
    }
    var fd_path: [32]u8 = undefined;
    const path = std.mem.printSentinel(&fd_path, "/proc/self/fd/{d}", .{fd}, 0) catch return null;
    const length = readlink(path.ptr, &tty_name_buffer, tty_name_buffer.len - 1);
    if (length <= 0 or !std.mem.startsWith(u8, tty_name_buffer[0..@intCast(length)], "/dev/pts/")) {
        ep.* = original_error;
        return null;
    }
    tty_name_buffer[@intCast(length)] = 0;
    ep.* = 0;
    return @ptrCast(&tty_name_buffer);
}

pub export fn fstat(fd: c_int, buf: ?*anyopaque) c_int {
    const native: RealFstat = @ptrCast(@alignCast(dlsym(next, "fstat") orelse return -1));
    const rc = native(fd, buf);
    if (rc != 0 or buf == null or getenv("NNS_RISH_PROPERTY_INFO_SHIM") == null or
        dlsym(next, "gnu_get_libc_version") != null) return rc;

    var proc_path: [32]u8 = undefined;
    const path = std.mem.printSentinel(&proc_path, "/proc/self/fd/{d}", .{fd}, 0) catch return rc;
    var target: [64]u8 = undefined;
    const n = readlink(path.ptr, &target, target.len);
    if (n <= 0) return rc;
    const name = target[0..@intCast(n)];
    const property_dir = "/dev/__properties__/";
    if (!std.mem.startsWith(u8, name, property_dir) or
        std.mem.indexOfScalar(u8, name[property_dir.len..], '/') != null) return rc;

    // Bionic's 64-bit stat layout: uid/gid are at 24/28 on arm64 and 28/32
    // on x86_64. The session userns leaves host root unmapped, so Bionic sees
    // overflowuid and rejects its read-only property metadata and area files.
    const uid_offset: usize = if (@import("builtin").target.cpu.arch == .aarch64) 24 else 28;
    const bytes: [*]u8 = @ptrCast(buf.?);
    const uid: *align(1) u32 = @ptrCast(bytes + uid_offset);
    const gid: *align(1) u32 = @ptrCast(bytes + uid_offset + 4);
    uid.* = 0;
    gid.* = 0;
    return rc;
}

pub export fn ioctl(fd: c_int, request: u64, arg: ?*anyopaque) c_int {
    // TCGETS2 (0x542a) / TCSETS2 (0x542b) carry the platform's ioctl xperm
    // whitelist, which lists only the legacy codes for this domain - and
    // ksud cannot load xperm rules (parsed, echoed, never applied). glibc >=
    // 2.42 probes TCGETS2 first and treats anything but ENOTTY as fatal, so
    // a permission failure is retried as the legacy code on the same buffer
    // (the kernel writes the identical 36-byte prefix; only the trailing
    // speed fields stay stale, which no tool here reads). If even the legacy
    // code is refused, the target is not a tty - binaries and plain files -
    // and ENOTTY is the truthful answer for callers to fall back on.
    const native: Ioctl = @ptrCast(@alignCast(dlsym(next, "ioctl") orelse return -1));
    const rc = native(fd, request, arg);
    if (rc >= 0 or (request != tcgets2 and request != tcsets2)) return rc;
    const errno_fn: Errno = @ptrCast(@alignCast(dlsym(next, "__errno_location") orelse return rc));
    const err = errno_fn().*;
    if (err != eacces and err != eperm) return rc;
    const retry = native(fd, if (request == tcgets2) tcgets else tcsets, arg);
    if (retry >= 0) return 0;
    if (errno_fn().* == eacces or errno_fn().* == eperm) errno_fn().* = enotty;
    return -1;
}

pub export fn getaddrinfo(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfo, result: *?*AddrInfo) c_int {
    // Never interpret a Bionic addrinfo as a glibc one. Same call ABI, different
    // struct layout; the native function must receive the original pointers.
    if (dlsym(next, "gnu_get_libc_version") == null) {
        const native: GetAddrInfo = @ptrCast(@alignCast(dlsym(next, "getaddrinfo") orelse return 4));
        return native(node, service, hints, result);
    }
    result.* = null;
    return resolve(node, service, hints, result) catch |err| switch (err) {
        error.BadFlags => -1,
        error.OutOfMemory => -10,
        else => -3,
    };
}

fn release(first: ?*AddrInfo) void {
    var ai = first;
    while (ai) |p| {
        ai = p.next;
        free(p.canon);
        free(p); // sockaddr is allocated inline, as glibc freeaddrinfo expects
    }
}

fn milliseconds() !i64 {
    var ts: linux.timespec = undefined;
    if (std.posix.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return error.Clock;
    return ts.sec * 1000 + @divTrunc(ts.nsec, 1_000_000);
}
fn readFull(fd: i32, bytes: []u8, deadline: i64) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const left = deadline - try milliseconds();
        if (left <= 0) return error.Timeout;
        var pfd: linux.pollfd = .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
        var timeout: linux.timespec = .{ .sec = @divTrunc(left, 1000), .nsec = @mod(left, 1000) * 1_000_000 };
        const ready = linux.ppoll(@ptrCast(&pfd), 1, &timeout, null);
        if (std.posix.errno(ready) == .INTR) continue;
        if (wire.signed(ready) <= 0) return error.Timeout;
        const n = linux.read(fd, bytes[pos..].ptr, bytes.len - pos);
        if (std.posix.errno(n) == .INTR) continue;
        if (wire.signed(n) <= 0) return error.Truncated;
        pos += n;
    }
}

fn resolve(node: ?[*:0]const u8, service: ?[*:0]const u8, hints: ?*const AddrInfo, result: *?*AddrInfo) !c_int {
    const h = if (hints) |p| p.* else AddrInfo{ .flags = 0x28 };
    const flags = try wire.bionicFlags(h.flags, h.family);
    if (h.family != 0 and h.family != wire.af_inet and h.family != wire.af_inet6) return -6;
    if (node == null and service == null) return -2;
    if (node) |p| {
        if (std.mem.span(p).len > 4096) return -2;
    }
    if (service) |p| {
        if (std.mem.span(p).len > 256) return -8;
    }
    const helper = getenv("NNS_DNS_HELPER") orelse "/nix/bin/nns-resolver";
    if (helper[0] != '/') return error.HelperPath;
    var text: [4][16]u8 = undefined;
    var argv: [10:null]?[*:0]const u8 = @splat(null);
    argv[0] = helper;
    for ([_]i32{ flags, h.family, h.socktype, h.protocol }, 0..) |value, i|
        argv[i + 1] = (try std.mem.printSentinel(&text[i], "{d}", .{value}, 0)).ptr;
    argv[5] = if (node != null) "1" else "0";
    argv[6] = node orelse "";
    argv[7] = if (service != null) "1" else "0";
    argv[8] = service orelse "";
    // No inherited LD_PRELOAD/LD_LIBRARY_PATH, and no process-global unsetenv.
    const env = [_:null]?[*:0]const u8{};
    var fds: [2]i32 = undefined;
    if (std.posix.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.Pipe;
    defer _ = linux.close(fds[0]);
    // Keep the write endpoint above stdio even when the caller closed stdout.
    const out = linux.fcntl(fds[1], linux.F.DUPFD_CLOEXEC, 3);
    _ = linux.close(fds[1]);
    if (std.posix.errno(out) != .SUCCESS) return error.Pipe;
    const output: i32 = @intCast(out);
    const deadline = (milliseconds() catch {
        _ = linux.close(output);
        return error.Clock;
    }) + 30_000;
    // A fork-like clone, not vfork. In the child use ONLY raw syscalls until
    // exec: libc locks may be held by another thread in the parent.
    const child = linux.syscall5(.clone, @backingInt(linux.SIG.CHLD), 0, 0, 0, 0);
    if (child == 0) {
        _ = linux.close(0);
        if (std.posix.errno(linux.dup3(output, 1, 0)) != .SUCCESS) linux.exit(127);
        if (std.posix.errno(linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0)) != .SUCCESS) linux.exit(127);
        _ = linux.execve(helper, &argv, &env);
        linux.exit(127);
    }
    _ = linux.close(output);
    if (std.posix.errno(child) != .SUCCESS) return error.Spawn;
    var reaped = false;
    defer if (!reaped) {
        _ = linux.kill(@intCast(child), linux.SIG.KILL);
        while (std.posix.errno(linux.syscall4(.wait4, @intCast(child), 0, 0, 0)) == .INTR) {}
    };
    var header: wire.Header = undefined;
    try readFull(fds[0], std.mem.asBytes(&header), deadline);
    if (header.magic != wire.magic or header.count > wire.max_results or
        header.status > 0 or header.status < -12 or
        (header.status != 0 and header.count != 0)) return error.Protocol;
    var first: ?*AddrInfo = null;
    errdefer release(first);
    var tail = &first;
    for (0..header.count) |_| {
        var r: wire.Record = undefined;
        try readFull(fds[0], std.mem.asBytes(&r), deadline);
        if (!r.valid()) return error.Protocol;
        const p: *AddrInfo = @ptrCast(@alignCast(calloc(1, @sizeOf(AddrInfo) + r.addrlen) orelse return error.OutOfMemory));
        tail.* = p;
        tail = &p.next;
        p.* = .{ .flags = h.flags, .family = r.family, .socktype = r.socktype, .protocol = r.protocol, .addrlen = r.addrlen, .addr = @ptrFromInt(@intFromPtr(p) + @sizeOf(AddrInfo)) };
        @memcpy(@as([*]u8, @ptrCast(p.addr.?))[0..r.addrlen], r.addr[0..r.addrlen]);
        if (r.canonlen != 0) {
            p.canon = @ptrCast(calloc(1, r.canonlen + 1) orelse return error.OutOfMemory);
            @memcpy(p.canon.?[0..r.canonlen], r.canon[0..r.canonlen]);
        }
    }
    // Bound the child lifetime, including helpers that close stdout then hang.
    var status: u32 = 0;
    while (true) {
        const done = linux.syscall4(.wait4, @intCast(child), @intFromPtr(&status), 1, 0);
        if (done == child) {
            reaped = true;
            break;
        }
        if (std.posix.errno(done) != .SUCCESS and std.posix.errno(done) != .INTR) return error.Wait;
        if (try milliseconds() >= deadline) return error.Timeout;
        var delay: linux.timespec = .{ .sec = 0, .nsec = 1_000_000 };
        _ = linux.nanosleep(&delay, null);
    }
    if (status != 0) return error.HelperFailed;
    if (header.status == 0 and first == null) return error.Protocol;
    if (header.status == -11) {
        const errno_fn: Errno = @ptrCast(@alignCast(dlsym(next, "__errno_location") orelse return error.Errno));
        errno_fn().* = header.err;
    }
    result.* = first;
    return header.status;
}
