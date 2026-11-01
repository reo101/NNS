// Device-only fixture: provision one empty scratch directory or inspect execution.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const syscall_error = @import("syscall_error");
const syscall = syscall_error.Program("storage-device-probe");
const scratch = "/data/nns-storage-probe";
const mountpoint = "/data/nix-probe";
const at_fdcwd = linux.AT.FDCWD;

const fail = syscall.fail;
const checked = syscall.check;
const errnoCode = syscall_error.errno;

fn print(comptime format: []const u8, arguments: anytype) void {
    var buffer: [1024]u8 = undefined;
    const text = std.mem.printSentinel(&buffer, format, arguments, 0) catch fail("output too long", .{});
    if (checked(linux.write(1, text.ptr, text.len), "write output") != text.len) fail("short output", .{});
}

fn openDirectory(path: [*:0]const u8) i32 {
    return @intCast(checked(linux.openat(at_fdcwd, path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open directory"));
}

fn readText(path: [*:0]const u8, buffer: []u8) []const u8 {
    const descriptor: i32 = @intCast(checked(linux.openat(at_fdcwd, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0), "open metadata"));
    defer _ = linux.close(descriptor);
    var length: usize = 0;
    while (length < buffer.len) {
        const result = linux.read(descriptor, buffer.ptr + length, buffer.len - length);
        if (errnoCode(result) == .INTR) continue;
        const count = checked(result, "read metadata");
        if (count == 0) break;
        length += count;
    }
    if (length == buffer.len) fail("metadata is too long", .{});
    return std.mem.trim(u8, buffer[0..length], "\n\x00");
}

fn requireContext(expected: []const u8) void {
    var buffer: [256]u8 = undefined;
    if (!std.mem.eql(u8, readText("/proc/self/attr/current", &buffer), expected)) fail("unexpected caller domain", .{});
    if (linux.geteuid() != 0 or linux.getegid() != 0) fail("root is required", .{});
}

fn ioctl(descriptor: i32, request: usize, argument: usize) usize {
    return linux.syscall3(.ioctl, @intCast(descriptor), request, argument);
}

fn policy(descriptor: i32) uapi.struct_fscrypt_policy_v2 {
    var argument = std.mem.zeroes(uapi.struct_fscrypt_get_policy_ex_arg);
    argument.policy_size = @sizeOf(@TypeOf(argument.policy));
    _ = checked(ioctl(descriptor, uapi.NNS_FS_IOC_GET_ENCRYPTION_POLICY_EX, @intFromPtr(&argument)), "read encryption policy");
    if (argument.policy.version != uapi.FSCRYPT_POLICY_V2 or argument.policy_size != @sizeOf(uapi.struct_fscrypt_policy_v2))
        fail("a v2 encryption policy is required", .{});
    return argument.policy.v2;
}

fn requireAvailableKey(descriptor: i32, encryption: uapi.struct_fscrypt_policy_v2) void {
    var key = std.mem.zeroes(uapi.struct_fscrypt_get_key_status_arg);
    key.key_spec.type = uapi.FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER;
    @memcpy(&key.key_spec.u.identifier, &encryption.master_key_identifier);
    _ = checked(ioctl(descriptor, uapi.FS_IOC_GET_ENCRYPTION_KEY_STATUS, @intFromPtr(&key)), "query encryption key");
    if (key.status != uapi.FSCRYPT_KEY_STATUS_PRESENT) fail("encryption key is unavailable", .{});
}

fn provision() void {
    requireContext("u:r:ksu:s0");
    const target = openDirectory(scratch);
    defer _ = linux.close(target);
    var status = std.mem.zeroes(uapi.struct_statx);
    _ = checked(linux.syscall5(.statx, @intCast(target), @intFromPtr(@as([*:0]const u8, "")), linux.AT.EMPTY_PATH, uapi.STATX_BASIC_STATS, @intFromPtr(&status)), "inspect scratch directory");
    if (status.stx_uid != 0 or status.stx_gid != 0 or (status.stx_mode & 0o777) != 0o700) fail("scratch directory must be private and root-owned", .{});
    var filesystem = std.mem.zeroes(uapi.struct_statfs);
    _ = checked(linux.syscall2(.fstatfs, @intCast(target), @intFromPtr(&filesystem)), "inspect scratch filesystem");
    if (filesystem.f_type != uapi.F2FS_SUPER_MAGIC) fail("scratch storage is not F2FS", .{});
    var previous = std.mem.zeroes(uapi.struct_fscrypt_get_policy_ex_arg);
    previous.policy_size = @sizeOf(@TypeOf(previous.policy));
    if (errnoCode(ioctl(target, uapi.NNS_FS_IOC_GET_ENCRYPTION_POLICY_EX, @intFromPtr(&previous))) != .NODATA)
        fail("refusing an existing or unreadable encryption policy", .{});
    // SET_ENCRYPTION_POLICY also requires the directory to be empty.
    const source = openDirectory("/data/system_de/0");
    defer _ = linux.close(source);
    const encryption = policy(source);
    requireAvailableKey(source, encryption);
    _ = checked(ioctl(target, uapi.FS_IOC_SET_ENCRYPTION_POLICY, @intFromPtr(&encryption)), "set scratch DE policy");
    const actual = policy(target);
    if (!std.mem.eql(u8, std.mem.asBytes(&actual), std.mem.asBytes(&encryption))) fail("scratch DE policy differs", .{});
    requireAvailableKey(target, actual);
    print("device_policy={s}\nkey_present=true\n", .{std.fmt.bytesToHex(std.mem.asBytes(&actual), .lower)});
}

fn requireDenied(descriptor: i32, request: usize) void {
    // A null argument cannot perform the requested mutation even if policy is wrong.
    const result = ioctl(descriptor, request, 0);
    const code = errnoCode(result) orelse fail("forbidden ioctl {x} succeeded", .{request});
    if (code != .ACCES) fail("forbidden ioctl {x}: expected EACCES, got {t}", .{ request, code });
    print("denied_ioctl={x} errno={d}\n", .{ request & 0xffff, code });
}

fn checkRestrictions() void {
    requireContext("u:r:nns_storage:s0");
    var header = uapi.struct___user_cap_header_struct{ .version = uapi._LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    var capabilities = std.mem.zeroes([2]uapi.struct___user_cap_data_struct);
    _ = checked(linux.syscall2(.capget, @intFromPtr(&header), @intFromPtr(&capabilities)), "read capabilities");
    if (capabilities[0].effective != 1 << uapi.CAP_SYS_ADMIN or capabilities[1].effective != 0) fail("unexpected capabilities", .{});
    const directory = openDirectory(scratch);
    defer _ = linux.close(directory);
    inline for (.{ uapi.FS_IOC_SET_ENCRYPTION_POLICY, uapi.FS_IOC_ADD_ENCRYPTION_KEY, uapi.FS_IOC_REMOVE_ENCRYPTION_KEY, uapi.FS_IOC_REMOVE_ENCRYPTION_KEY_ALL_USERS }) |request|
        requireDenied(directory, request);
    const mounted = openDirectory(mountpoint);
    defer _ = linux.close(mounted);
    inline for (.{ uapi.FS_IOC_GET_ENCRYPTION_KEY_STATUS, uapi.BTRFS_IOC_RESIZE, uapi.BTRFS_IOC_SUBVOL_CREATE, uapi.BTRFS_IOC_SNAP_DESTROY }) |request|
        requireDenied(mounted, request);
}

fn identity() void {
    var context_buffer: [256]u8 = undefined;
    const context = readText("/proc/self/attr/current", &context_buffer);
    const target = openDirectory(mountpoint);
    defer _ = linux.close(target);
    var filesystem = std.mem.zeroes(uapi.struct_statfs);
    _ = checked(linux.syscall2(.fstatfs, @intCast(target), @intFromPtr(&filesystem)), "inspect mounted filesystem");
    if (filesystem.f_type != uapi.BTRFS_SUPER_MAGIC) fail("execution probe cannot see Btrfs backing", .{});
    const image = linux.openat(at_fdcwd, scratch ++ "/nix.btrfs", .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0);
    const denied = errnoCode(image) == .ACCES;
    if (errnoCode(image) == null) _ = linux.close(@intCast(image));
    var status_buffer: [4096]u8 = undefined;
    const status = readText("/proc/self/status", &status_buffer);
    var effective: ?[]const u8 = null;
    var no_new_privileges: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, status, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "CapEff:")) effective = std.mem.trim(u8, line[7..], " \t");
        if (std.mem.startsWith(u8, line, "NoNewPrivs:")) no_new_privileges = std.mem.trim(u8, line[11..], " \t");
    }
    print("uid={d} gid={d} context={s} filesystem={x} private_image_denied={any} cap_eff={s} no_new_privs={s}\n", .{
        linux.geteuid(), linux.getegid(), context, filesystem.f_type, denied,
        effective orelse fail("missing capability status", .{}), no_new_privileges orelse fail("missing privilege status", .{}),
    });
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    if (args.len == 1) return identity();
    if (args.len != 2) fail("usage: storage-device-probe [--provision|--check]", .{});
    const command = std.mem.span(args[1]);
    if (std.mem.eql(u8, command, "--provision")) return provision();
    if (std.mem.eql(u8, command, "--check")) return checkRestrictions();
    fail("unknown probe action", .{});
}
