// Read-only fixture probe. Never sets or removes an encryption policy.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const syscall_error = @import("syscall_error");
const syscall = syscall_error.Program("fscrypt-policy");

fn writeAll(fd: i32, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (std.posix.errno(result) == .INTR) continue;
        offset += syscall.check(result, "write result");
    }
}

pub fn main(init: std.process.Init.Minimal) void {
    const arguments = init.args.vector;
    if (arguments.len > 2) {
        std.debug.print("usage: fscrypt-policy [directory]\n", .{});
        std.process.exit(2);
    }
    const path: [*:0]const u8 = if (arguments.len == 2) arguments[1] else "/data/nix";
    const opened = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    if (syscall_error.errno(opened)) |code| syscall.fail("open backing directory: {t}", .{code});
    const descriptor: i32 = @intCast(opened);
    defer _ = linux.close(descriptor);

    var policy = std.mem.zeroes(uapi.struct_fscrypt_get_policy_ex_arg);
    policy.policy_size = @sizeOf(@TypeOf(policy.policy));
    const result = linux.syscall3(.ioctl, @intCast(descriptor), uapi.NNS_FS_IOC_GET_ENCRYPTION_POLICY_EX, @intFromPtr(&policy));
    if (syscall_error.errno(result)) |code| {
        if (code == .NODATA) {
            writeAll(1, "none\n");
            return;
        }
        syscall.fail("get fscrypt policy: {t}", .{code});
    }

    var line: [2 * @sizeOf(@TypeOf(policy.policy)) + 1]u8 = undefined;
    var length: usize = 0;
    for (std.mem.asBytes(&policy.policy)[0..@intCast(policy.policy_size)]) |byte| {
        const printed = std.fmt.bufPrint(line[length..], "{x:0>2}", .{byte}) catch unreachable;
        length += printed.len;
    }
    line[length] = '\n';
    writeAll(1, line[0 .. length + 1]);
}
