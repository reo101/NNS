// Root-manager entry point. Only namespace setup runs with the caller's privileges.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const namespace_descriptor = 3;

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("nns-storage-supervisor: " ++ format ++ "\n", arguments);
    std.process.exit(1);
}

fn errnoCode(result: usize) ?c_int {
    const signed: isize = @bitCast(result);
    return if (signed < 0 and signed >= -4095) @intCast(-signed) else null;
}

fn checked(result: usize, operation: []const u8) usize {
    if (errnoCode(result)) |code| fail("{s}: errno {d}", .{ operation, code });
    return result;
}

fn retainMountCapability() void {
    _ = checked(linux.syscall2(.setgroups, 0, 0), "clear supplementary groups");
    _ = checked(linux.syscall5(.prctl, uapi.PR_CAP_AMBIENT, uapi.PR_CAP_AMBIENT_CLEAR_ALL, 0, 0, 0), "clear ambient capabilities");
    for (0..64) |capability| {
        const result = linux.syscall5(.prctl, uapi.PR_CAPBSET_READ, capability, 0, 0, 0);
        if (errnoCode(result) == uapi.EINVAL) break;
        _ = checked(result, "read capability bounding set");
        if (capability != uapi.CAP_SYS_ADMIN)
            _ = checked(linux.syscall5(.prctl, uapi.PR_CAPBSET_DROP, capability, 0, 0, 0), "reduce capability bounding set");
    }
    var header = uapi.struct___user_cap_header_struct{ .version = uapi._LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    var capabilities = std.mem.zeroes([2]uapi.struct___user_cap_data_struct);
    capabilities[0].permitted = 1 << uapi.CAP_SYS_ADMIN;
    capabilities[0].effective = capabilities[0].permitted;
    _ = checked(linux.syscall2(.capset, @intFromPtr(&header), @intFromPtr(&capabilities)), "retain only mount capability");
}

pub fn main(init: std.process.Init.Minimal) void {
    const arguments = init.args.vector;
    if (arguments.len != 1 and (arguments.len != 2 or
        (!std.mem.eql(u8, std.mem.span(arguments[1]), "--check") and !std.mem.eql(u8, std.mem.span(arguments[1]), "--mode"))))
        fail("usage: nns-storage-supervisor [--check|--mode]", .{});
    if (linux.getuid() != 0 or linux.getgid() != 0 or linux.geteuid() != 0 or linux.getegid() != 0)
        fail("root is required", .{});
    // No inherited descriptors or environment can select the namespace reference.
    _ = checked(linux.syscall3(.close_range, 3, std.math.maxInt(u32), 0), "close inherited descriptors");
    const opened: i32 = @intCast(checked(linux.openat(-100, "/proc/1/ns/mnt", .{ .ACCMODE = .RDONLY }, 0), "open init mount namespace"));
    if (opened != namespace_descriptor) {
        _ = checked(linux.syscall3(.dup3, @intCast(opened), namespace_descriptor, 0), "retain namespace descriptor");
        _ = linux.close(opened);
    }
    var executable_path: [4096]u8 = undefined;
    const length = checked(linux.readlinkat(-100, "/proc/self/exe", &executable_path, executable_path.len), "read supervisor path");
    if (length == executable_path.len) fail("supervisor path is too long", .{});
    const separator = std.mem.lastIndexOfScalar(u8, executable_path[0..length], '/') orelse fail("supervisor path has no parent", .{});
    var controller_path: [4096]u8 = undefined;
    const path = std.mem.printSentinel(&controller_path, "{s}/nns-storage-module-controller", .{executable_path[0..separator]}, 0) catch fail("controller path is too long", .{});
    const executable: i32 = @intCast(checked(linux.openat(-100, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open controller"));
    var metadata = std.mem.zeroes(uapi.struct_statx);
    _ = checked(linux.syscall5(.statx, @intCast(executable), @intFromPtr(@as([*:0]const u8, "")), 0x1000, uapi.STATX_BASIC_STATS, @intFromPtr(&metadata)), "inspect controller");
    if (metadata.stx_uid != 0 or metadata.stx_gid != 0 or (metadata.stx_mode & 0o022) != 0 or
        (metadata.stx_mode & uapi.S_IFMT) != uapi.S_IFREG or metadata.stx_nlink != 1)
        fail("controller must be a root-owned regular file without other writers or hard links", .{});
    _ = checked(linux.syscall2(.setns, namespace_descriptor, linux.CLONE.NEWNS), "enter init mount namespace");
    retainMountCapability();
    const environment = [_:null]?[*:0]const u8{};
    // The controller's executable label must cause the SELinux domain transition.
    _ = checked(linux.syscall5(.execveat, @intCast(executable), @intFromPtr(@as([*:0]const u8, "")),
        @intFromPtr(arguments.ptr), @intFromPtr(&environment), 0x1000), "exec enforcing controller");
    unreachable;
}
