// Module adapter. The root-manager supervisor passes init's namespace on fd 3.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const storage = @import("storage");
const syscall_error = @import("syscall_error");
const syscall = syscall_error.Program("nns-storage-controller");
const at_fdcwd = linux.AT.FDCWD;

const fail = syscall.fail;
const checked = syscall.check;
const errnoCode = syscall_error.errno;

fn requireDomain() void {
    const descriptor: i32 = @intCast(checked(linux.openat(at_fdcwd, "/proc/self/attr/current", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0), "open controller context"));
    defer _ = linux.close(descriptor);
    var context: [256]u8 = undefined;
    const count = checked(linux.read(descriptor, &context, context.len), "read controller context");
    if (!std.mem.eql(u8, std.mem.trim(u8, context[0..count], "\n\x00"), "u:r:nns_storage:s0"))
        fail("nns_storage domain transition is required", .{});
}

fn requireMountCapability() void {
    var header = uapi.struct___user_cap_header_struct{ .version = uapi._LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    var capabilities = std.mem.zeroes([2]uapi.struct___user_cap_data_struct);
    _ = checked(linux.syscall2(.capget, @intFromPtr(&header), @intFromPtr(&capabilities)), "read capabilities");
    const mask = 1 << uapi.CAP_SYS_ADMIN;
    if (capabilities[0].effective != mask or capabilities[0].permitted != mask or capabilities[0].inheritable != 0 or
        capabilities[1].effective != 0 or capabilities[1].permitted != 0 or capabilities[1].inheritable != 0)
        fail("only SYS_ADMIN may remain in the controller", .{});
    for (0..64) |capability| {
        const result = linux.syscall5(.prctl, uapi.PR_CAPBSET_READ, capability, 0, 0, 0);
        if (errnoCode(result) == .INVAL) break;
        if (checked(result, "read capability bounding set") != @intFromBool(capability == uapi.CAP_SYS_ADMIN))
            fail("unexpected capability in the bounding set", .{});
        if (checked(linux.syscall5(.prctl, uapi.PR_CAP_AMBIENT, uapi.PR_CAP_AMBIENT_IS_SET, capability, 0, 0), "read ambient capability") != 0)
            fail("ambient capabilities must be empty", .{});
    }
    if (checked(linux.syscall2(.getgroups, 0, 0), "read supplementary groups") != 0)
        fail("supplementary groups must be empty", .{});
}

pub fn main(init: std.process.Init.Minimal) void {
    requireDomain();
    requireMountCapability();
    _ = checked(linux.syscall5(.prctl, uapi.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0), "prevent privilege gain");
    std.debug.print("nns-storage: module controller context=u:r:nns_storage:s0 capabilities=SYS_ADMIN\n", .{});
    storage.run(init.args.vector, 3);
}
