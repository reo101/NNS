// Test replacement for the child executable, never part of the module.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");

fn require(condition: bool, comptime message: []const u8) void {
    if (!condition) {
        std.debug.print("handoff test: {s}\n", .{message});
        std.process.exit(1);
    }
}

fn errnoCode(result: usize) ?c_int {
    const signed: isize = @bitCast(result);
    return if (signed < 0 and signed >= -4095) @intCast(-signed) else null;
}

fn metadata(descriptor: i32, path: [*:0]const u8, flags: u32) uapi.struct_statx {
    var result = std.mem.zeroes(uapi.struct_statx);
    require(errnoCode(linux.syscall5(.statx, @bitCast(@as(isize, descriptor)), @intFromPtr(path), flags,
        uapi.STATX_BASIC_STATS, @intFromPtr(&result))) == null, "cannot inspect namespace");
    return result;
}

pub fn main() void {
    require(linux.getuid() == 0 and linux.geteuid() == 0 and linux.getgid() == 0 and linux.getegid() == 0, "unexpected credentials");
    require(linux.syscall2(.getgroups, 0, 0) == 0, "supplementary groups survived");
    const inherited = metadata(3, "", 0x1000);
    const current = metadata(-100, "/proc/self/ns/mnt", 0);
    require(inherited.stx_dev_major == current.stx_dev_major and inherited.stx_dev_minor == current.stx_dev_minor and
        inherited.stx_ino == current.stx_ino, "namespace reference does not match");
    require(errnoCode(linux.syscall3(.fcntl, 9, 1, 0)) == uapi.EBADF, "unrelated descriptor survived");
    const opened = linux.openat(-100, "/proc/self/environ", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    require(errnoCode(opened) == null, "cannot inspect environment");
    const descriptor: i32 = @intCast(opened);
    defer _ = linux.close(descriptor);
    var byte: [1]u8 = undefined;
    require(linux.read(descriptor, &byte, byte.len) == 0, "caller environment survived");

    var header = uapi.struct___user_cap_header_struct{ .version = uapi._LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    var capabilities = std.mem.zeroes([2]uapi.struct___user_cap_data_struct);
    require(linux.syscall2(.capget, @intFromPtr(&header), @intFromPtr(&capabilities)) == 0, "capget failed");
    const mask = 1 << uapi.CAP_SYS_ADMIN;
    require(capabilities[0].effective == mask and capabilities[0].permitted == mask and capabilities[0].inheritable == 0 and
        capabilities[1].effective == 0 and capabilities[1].permitted == 0 and capabilities[1].inheritable == 0, "excess capabilities survived");
    for (0..64) |capability| {
        const value = linux.syscall5(.prctl, uapi.PR_CAPBSET_READ, capability, 0, 0, 0);
        if (errnoCode(value) == uapi.EINVAL) break;
        require(value == @intFromBool(capability == uapi.CAP_SYS_ADMIN), "bounding set was not reduced");
        require(linux.syscall5(.prctl, uapi.PR_CAP_AMBIENT, uapi.PR_CAP_AMBIENT_IS_SET, capability, 0, 0) == 0, "ambient capability survived");
    }
    capabilities[0].effective |= 1 << uapi.CAP_SYS_PTRACE;
    capabilities[0].permitted |= 1 << uapi.CAP_SYS_PTRACE;
    require(errnoCode(linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&capabilities))) == uapi.EPERM, "controller regained SYS_PTRACE");
    var output: [128]u8 = undefined;
    const text = std.mem.printSentinel(&output, "namespace={d} capabilities={x} inherited_descriptors=3\n", .{ current.stx_ino, mask }, 0) catch unreachable;
    require(linux.write(1, text.ptr, text.len) == text.len, "short result write");
}
