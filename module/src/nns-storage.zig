// Prepared Btrfs image mounting. No formatting, repair, migration or libc.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const allocator = std.heap.page_allocator;
const storage_directory: [:0]const u8 = "/data/nns-storage";
const target_directory: [:0]const u8 = "/data/nix";
const at_fdcwd = -100;

const Configuration = struct {
    image: [256:0]u8 = @splat(0),
    uuid: [16]u8 = undefined,
    subvolume: u64 = 0,
};

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("nns-storage: " ++ format ++ "\n", arguments);
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

fn message(text: []const u8) void {
    if (checked(linux.write(1, text.ptr, text.len), "write result") != text.len)
        fail("short result write", .{});
}

fn openAt(directory: i32, path: [*:0]const u8, flags: linux.O) usize {
    return linux.openat(directory, path, flags, 0);
}

fn readAll(descriptor: i32) []u8 {
    var contents = std.ArrayList(u8).empty;
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = checked(linux.read(descriptor, &buffer, buffer.len), "read descriptor");
        if (count == 0) break;
        contents.appendSlice(allocator, buffer[0..count]) catch fail("allocation failed", .{});
    }
    return contents.toOwnedSlice(allocator) catch fail("allocation failed", .{});
}

fn readPath(path: [*:0]const u8) []u8 {
    const descriptor: i32 = @intCast(checked(openAt(at_fdcwd, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }), "open metadata"));
    defer _ = linux.close(descriptor);
    return readAll(descriptor);
}

fn statAt(directory: i32, path: [*:0]const u8, flags: u32) uapi.struct_statx {
    var metadata: uapi.struct_statx = std.mem.zeroes(uapi.struct_statx);
    _ = checked(linux.syscall5(.statx, @bitCast(@as(isize, directory)), @intFromPtr(path), flags, uapi.STATX_BASIC_STATS, @intFromPtr(&metadata)), "stat descriptor or namespace");
    return metadata;
}

fn status(descriptor: i32) uapi.struct_statx {
    return statAt(descriptor, "", 0x1000); // AT_EMPTY_PATH
}

fn requirePrivate(metadata: uapi.struct_statx, directory: bool) void {
    if (metadata.stx_uid != 0 or metadata.stx_gid != 0 or (metadata.stx_mode & 0o077) != 0 or
        (metadata.stx_mode & uapi.S_IFMT) != (if (directory) @as(u16, uapi.S_IFDIR) else @as(u16, uapi.S_IFREG)) or
        (!directory and metadata.stx_nlink != 1))
        fail("storage directory, configuration and image must be private root-owned objects", .{});
}

fn ioctl(descriptor: i32, request: usize, argument: usize) usize {
    return linux.syscall3(.ioctl, @intCast(descriptor), request, argument);
}

fn requireAvailableKey(directory: i32) void {
    var policy = std.mem.zeroes(uapi.struct_fscrypt_get_policy_ex_arg);
    policy.policy_size = @sizeOf(@TypeOf(policy.policy));
    if (errnoCode(ioctl(directory, uapi.NNS_FS_IOC_GET_ENCRYPTION_POLICY_EX, @intFromPtr(&policy)))) |code| {
        switch (code) {
            uapi.ENODATA, uapi.ENOTTY, uapi.EOPNOTSUPP => return,
            else => fail("read storage encryption policy: errno {d}", .{code}),
        }
    }
    var key = std.mem.zeroes(uapi.struct_fscrypt_get_key_status_arg);
    switch (policy.policy.version) {
        uapi.FSCRYPT_POLICY_V2 => {
            key.key_spec.type = uapi.FSCRYPT_KEY_SPEC_TYPE_IDENTIFIER;
            @memcpy(&key.key_spec.u.identifier, &policy.policy.v2.master_key_identifier);
        },
        uapi.FSCRYPT_POLICY_V1 => {
            key.key_spec.type = uapi.FSCRYPT_KEY_SPEC_TYPE_DESCRIPTOR;
            @memcpy(&key.key_spec.u.descriptor, &policy.policy.v1.master_key_descriptor);
        },
        else => fail("unsupported storage encryption policy", .{}),
    }
    _ = checked(ioctl(directory, uapi.FS_IOC_GET_ENCRYPTION_KEY_STATUS, @intFromPtr(&key)), "read storage encryption key status");
    if (key.status != uapi.FSCRYPT_KEY_STATUS_PRESENT)
        fail("storage encryption key is unavailable; directory fallback refused", .{});
}

fn parseUuid(text: []const u8) [16]u8 {
    if (text.len != 36) fail("invalid filesystem UUID", .{});
    var result: [16]u8 = undefined;
    var input: usize = 0;
    var output: usize = 0;
    while (input < text.len) {
        if (input == 8 or input == 13 or input == 18 or input == 23) {
            if (text[input] != '-') fail("invalid filesystem UUID", .{});
            input += 1;
            continue;
        }
        const high = std.fmt.charToDigit(text[input], 16) catch fail("invalid filesystem UUID", .{});
        const low = std.fmt.charToDigit(text[input + 1], 16) catch fail("invalid filesystem UUID", .{});
        result[output] = high * 16 + low;
        input += 2;
        output += 1;
    }
    return result;
}

fn readConfiguration(directory: i32) ?Configuration {
    const opened = openAt(directory, "backing.conf", .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .NOATIME = true, .CLOEXEC = true });
    if (errnoCode(opened)) |code| {
        if (code == uapi.ENOENT) {
            requireAvailableKey(directory);
            return null;
        }
        fail("open backing.conf: errno {d}", .{code});
    }
    const descriptor: i32 = @intCast(opened);
    defer _ = linux.close(descriptor);
    const metadata = status(descriptor);
    requirePrivate(metadata, false);
    if (metadata.stx_size == 0 or metadata.stx_size > 1024) fail("invalid configuration size", .{});
    var buffer: [1025]u8 = undefined;
    var length: usize = 0;
    while (length < buffer.len) {
        const count = checked(linux.read(descriptor, buffer[length..].ptr, buffer.len - length), "read configuration");
        if (count == 0) break;
        length += count;
    }
    if (length == 0 or length > 1024 or buffer[length - 1] != '\n' or std.mem.indexOfScalar(u8, buffer[0..length], 0) != null)
        fail("configuration lines must end with a newline and contain no NUL bytes", .{});
    var result: Configuration = .{};
    var fields: u8 = 0;
    var lines = std.mem.splitScalar(u8, buffer[0 .. length - 1], '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "image=") and (fields & 1) == 0) {
            const name = line[6..];
            if (name.len == 0 or name.len >= result.image.len or name[0] == '.') fail("image must be a basename inside {s}", .{storage_directory});
            for (name) |character| if (!std.ascii.isAlphanumeric(character) and character != '.' and character != '-' and character != '_') fail("invalid image basename", .{});
            @memcpy(result.image[0..name.len], name);
            fields |= 1;
        } else if (std.mem.startsWith(u8, line, "uuid=") and (fields & 2) == 0) {
            result.uuid = parseUuid(line[5..]);
            fields |= 2;
        } else if (std.mem.startsWith(u8, line, "subvolume_id=") and (fields & 4) == 0) {
            const number = line[13..];
            if (number.len == 0) fail("missing subvolume ID", .{});
            for (number) |character| if (!std.ascii.isDigit(character)) fail("invalid subvolume ID", .{});
            result.subvolume = std.fmt.parseInt(u64, number, 10) catch fail("invalid subvolume ID", .{});
            if (result.subvolume != 5 and result.subvolume < 256) fail("invalid subvolume ID", .{});
            fields |= 4;
        } else fail("unknown or duplicate configuration field", .{});
    }
    if (fields != 7) fail("configuration requires image, uuid and subvolume_id", .{});
    return result;
}

fn mountCount(target: []const u8) usize {
    const contents = readPath("/proc/self/mountinfo");
    defer allocator.free(contents);
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.tokenizeScalar(u8, line, ' ');
        for (0..4) |_| _ = fields.next() orelse fail("invalid mountinfo record", .{});
        const path = fields.next() orelse fail("invalid mountinfo record", .{});
        if (std.mem.eql(u8, path, target)) count += 1;
    }
    return count;
}

fn inInitNamespace(initial_descriptor: ?i32) bool {
    const current = statAt(at_fdcwd, "/proc/self/ns/mnt", 0);
    const initial = if (initial_descriptor) |descriptor| status(descriptor) else statAt(at_fdcwd, "/proc/1/ns/mnt", 0);
    return current.stx_dev_major == initial.stx_dev_major and current.stx_dev_minor == initial.stx_dev_minor and current.stx_ino == initial.stx_ino;
}

test "inherited mount namespace identity" {
    const descriptor: i32 = @intCast(checked(openAt(at_fdcwd, "/proc/self/ns/mnt", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }), "open test namespace"));
    defer _ = linux.close(descriptor);
    try std.testing.expect(inInitNamespace(descriptor));
    const other: i32 = @intCast(checked(openAt(at_fdcwd, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }), "open non-namespace descriptor"));
    defer _ = linux.close(other);
    try std.testing.expect(!inInitNamespace(other));
}

test "inherited reference rejects a private mount namespace" {
    const descriptor: i32 = @intCast(checked(openAt(at_fdcwd, "/proc/self/ns/mnt", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }), "open test namespace"));
    defer _ = linux.close(descriptor);
    const result = linux.syscall1(.unshare, linux.CLONE.NEWUSER | linux.CLONE.NEWNS);
    if (errnoCode(result)) |code| {
        if (code == uapi.EPERM) return error.SkipZigTest;
        fail("create test namespace: errno {d}", .{code});
    }
    try std.testing.expect(!inInitNamespace(descriptor));
}

fn requireEmpty(descriptor: i32) void {
    var buffer: [4096]u8 align(8) = undefined;
    while (true) {
        const count = checked(linux.syscall3(.getdents64, @intCast(descriptor), @intFromPtr(&buffer), buffer.len), "read mountpoint");
        if (count == 0) return;
        var offset: usize = 0;
        while (offset < count) {
            if (count - offset < 20) fail("invalid directory entry", .{});
            const length = std.mem.readInt(u16, buffer[offset + 16 ..][0..2], .little);
            if (length < 20 or length > count - offset) fail("invalid directory entry", .{});
            const name_bytes = buffer[offset + 19 .. offset + length];
            const end = std.mem.indexOfScalar(u8, name_bytes, 0) orelse fail("invalid directory entry", .{});
            const name = name_bytes[0..end];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) fail("refusing to cover a populated {s}", .{target_directory});
            offset += length;
        }
    }
}

fn deviceNumber(major: u32, minor: u32) u64 {
    return (@as(u64, major & 0xfffff000) << 32) | (@as(u64, major & 0xfff) << 8) |
        (@as(u64, minor & 0xffffff00) << 12) | @as(u64, minor & 0xff);
}

fn verifyMount(configuration: Configuration, image: uapi.struct_statx) bool {
    const opened = openAt(at_fdcwd, target_directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (errnoCode(opened) != null) return false;
    const target: i32 = @intCast(opened);
    defer _ = linux.close(target);
    var filesystem = std.mem.zeroes(uapi.struct_btrfs_ioctl_fs_info_args);
    if (mountCount(target_directory) != 1 or errnoCode(ioctl(target, uapi.BTRFS_IOC_FS_INFO, @intFromPtr(&filesystem))) != null or
        filesystem.num_devices != 1 or !std.mem.eql(u8, &filesystem.fsid, &configuration.uuid)) return false;
    var subvolume = std.mem.zeroes(uapi.struct_btrfs_ioctl_get_subvol_info_args);
    // Linux 6.1 can return positive success for GET_SUBVOL_INFO.
    if (errnoCode(ioctl(target, uapi.BTRFS_IOC_GET_SUBVOL_INFO, @intFromPtr(&subvolume))) != null) return false;
    const root = status(target);
    var filesystem_status = std.mem.zeroes(uapi.struct_statfs);
    if (errnoCode(linux.syscall2(.fstatfs, @intCast(target), @intFromPtr(&filesystem_status))) != null) return false;
    if (subvolume.treeid != configuration.subvolume or (subvolume.flags & uapi.BTRFS_SUBVOL_RDONLY) != 0 or
        root.stx_ino != 256 or root.stx_uid != 0 or root.stx_gid != 0 or (root.stx_mode & 0o022) != 0 or
        (filesystem_status.f_flags & 15) != 6) return false;
    var device = std.mem.zeroes(uapi.struct_btrfs_ioctl_dev_info_args);
    device.devid = filesystem.max_id;
    if (errnoCode(ioctl(target, uapi.BTRFS_IOC_DEV_INFO, @intFromPtr(&device))) != null) return false;
    device.path[device.path.len - 1] = 0;
    const loop_opened = openAt(at_fdcwd, @ptrCast(&device.path), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true });
    if (errnoCode(loop_opened) != null) return false;
    const loop: i32 = @intCast(loop_opened);
    defer _ = linux.close(loop);
    const loop_status = status(loop);
    var backing = std.mem.zeroes(uapi.struct_loop_info64);
    return (loop_status.stx_mode & uapi.S_IFMT) == uapi.S_IFBLK and loop_status.stx_rdev_major == 7 and
        errnoCode(ioctl(loop, uapi.LOOP_GET_STATUS64, @intFromPtr(&backing))) == null and
        backing.lo_device == deviceNumber(image.stx_dev_major, image.stx_dev_minor) and backing.lo_inode == image.stx_ino and
        backing.lo_offset == 0 and backing.lo_sizelimit == 0 and backing.lo_encrypt_type == 0 and (backing.lo_flags & uapi.LO_FLAGS_READ_ONLY) == 0;
}

fn attachLoop(image: i32, path_buffer: *[64]u8) i32 {
    const control: i32 = @intCast(checked(openAt(at_fdcwd, "/dev/loop-control", .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true }), "open loop-control"));
    defer _ = linux.close(control);
    for (0..20) |_| {
        const number = checked(ioctl(control, uapi.LOOP_CTL_GET_FREE, 0), "allocate loop device");
        var path = std.mem.printSentinel(path_buffer, "/dev/block/loop{d}", .{number}, 0) catch unreachable;
        var opened = openAt(at_fdcwd, path, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true });
        if (errnoCode(opened) == uapi.ENOENT) {
            path = std.mem.printSentinel(path_buffer, "/dev/loop{d}", .{number}, 0) catch unreachable;
            opened = openAt(at_fdcwd, path, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true });
        }
        if (errnoCode(opened) == uapi.ENOENT) {
            const delay = [2]i64{ 0, 100_000_000 };
            _ = linux.syscall4(.clock_nanosleep, 1, 0, @intFromPtr(&delay), 0);
            continue;
        }
        const loop: i32 = @intCast(checked(opened, "open loop device"));
        const metadata = status(loop);
        var identity_buffer: [64]u8 = undefined;
        const identity_path = std.mem.printSentinel(&identity_buffer, "/sys/block/loop{d}/dev", .{number}, 0) catch unreachable;
        const identity = readPath(identity_path);
        defer allocator.free(identity);
        var fields = std.mem.splitScalar(u8, std.mem.trim(u8, identity, "\r\n"), ':');
        const major = std.fmt.parseInt(u32, fields.next() orelse fail("invalid kernel loop identity", .{}), 10) catch fail("invalid kernel loop identity", .{});
        const minor = std.fmt.parseInt(u32, fields.next() orelse fail("invalid kernel loop identity", .{}), 10) catch fail("invalid kernel loop identity", .{});
        if (fields.next() != null or major != 7 or (metadata.stx_mode & uapi.S_IFMT) != uapi.S_IFBLK or metadata.stx_rdev_major != major or metadata.stx_rdev_minor != minor)
            fail("unexpected loop device identity", .{});
        var setup = std.mem.zeroes(uapi.struct_loop_config);
        setup.fd = @intCast(image);
        setup.info.lo_flags = uapi.LO_FLAGS_AUTOCLEAR;
        const result = ioctl(loop, uapi.LOOP_CONFIGURE, @intFromPtr(&setup));
        if (errnoCode(result)) |code| {
            _ = linux.close(loop);
            if (code == uapi.EBUSY) continue;
            fail("configure loop device: errno {d}", .{code});
        }
        return loop;
    }
    fail("no loop device became available", .{});
}

pub fn run(arguments: []const [*:0]const u8, initial_namespace: ?i32) void {
    const check = arguments.len == 2 and std.mem.eql(u8, std.mem.span(arguments[1]), "--check");
    const mode = arguments.len == 2 and std.mem.eql(u8, std.mem.span(arguments[1]), "--mode");
    if (arguments.len != 1 and !check and !mode) fail("usage: nns-storage [--check|--mode]", .{});
    if (linux.geteuid() != 0 or linux.getegid() != 0) fail("root is required", .{});
    if (initial_namespace != null and !inInitNamespace(initial_namespace)) fail("init mount namespace is required", .{});
    const opened = openAt(at_fdcwd, storage_directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true });
    if (errnoCode(opened)) |code| {
        if (code != uapi.ENOENT) fail("open storage directory: errno {d}", .{code});
        if (mode) message("directory\n");
        return;
    }
    const directory: i32 = @intCast(opened);
    defer _ = linux.close(directory);
    requirePrivate(status(directory), true);
    _ = checked(linux.syscall2(.flock, @intCast(directory), 2), "lock storage directory");
    requireAvailableKey(directory);
    const configuration = readConfiguration(directory) orelse {
        if (mode) message("directory\n");
        return;
    };
    if (mode) {
        message("btrfs\n");
        return;
    }
    if (initial_namespace == null and !inInitNamespace(null)) fail("init mount namespace is required", .{});
    const image: i32 = @intCast(checked(openAt(directory, &configuration.image, .{ .ACCMODE = if (check) .RDONLY else .RDWR, .NOFOLLOW = true, .NONBLOCK = true, .NOATIME = true, .CLOEXEC = true }), "open configured image"));
    defer _ = linux.close(image);
    const image_status = status(image);
    requirePrivate(image_status, false);
    var superblock: [4096]u8 = undefined;
    if (checked(linux.syscall4(.pread64, @intCast(image), @intFromPtr(&superblock), superblock.len, 65536), "read Btrfs primary superblock") != superblock.len)
        fail("cannot read Btrfs primary superblock", .{});
    if (!std.mem.eql(u8, superblock[0x40..0x48], "_BHRfS_M") or !std.mem.eql(u8, superblock[0x20..0x30], &configuration.uuid) or std.mem.readInt(u64, superblock[0x88..][0..8], .little) != 1)
        fail("image must contain the selected single-device Btrfs filesystem", .{});
    if (mountCount(target_directory) != 0) {
        if (!verifyMount(configuration, image_status)) fail("conflicting storage mount, image, subvolume or flags", .{});
        message("nns-storage: existing Btrfs backing retained\n");
        return;
    }
    if (check) fail("configured Btrfs backing is not mounted", .{});
    if (mountCount("/nix") != 0) fail("refusing to replace backing after /nix is bound", .{});
    const target: i32 = @intCast(checked(openAt(at_fdcwd, target_directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }), "open existing empty mountpoint"));
    defer _ = linux.close(target);
    const target_status = status(target);
    if (target_status.stx_uid != 0 or target_status.stx_gid != 0 or (target_status.stx_mode & 0o022) != 0)
        fail("mountpoint must be root-owned and not writable by other users", .{});
    requireEmpty(target);
    var loop_path: [64]u8 = undefined;
    const loop = attachLoop(image, &loop_path);
    var target_path_buffer: [64]u8 = undefined;
    const target_path = std.mem.printSentinel(&target_path_buffer, "/proc/self/fd/{d}", .{target}, 0) catch unreachable;
    var options_buffer: [128]u8 = undefined;
    const options = std.mem.printSentinel(&options_buffer, "subvolid={d},compress=zstd:3,nodiscard", .{configuration.subvolume}, 0) catch unreachable;
    const result = linux.mount(@ptrCast(&loop_path), target_path, "btrfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr(options.ptr));
    _ = linux.close(loop); // AUTOCLEAR retains the device only while mounted.
    _ = checked(result, "mount Btrfs backing");
    if (!verifyMount(configuration, image_status)) fail("mounted backing did not pass verification; NNS startup refused", .{});
    message("nns-storage: Btrfs backing mounted\n");
}

pub fn main(init: std.process.Init.Minimal) void {
    run(init.args.vector, null);
}
