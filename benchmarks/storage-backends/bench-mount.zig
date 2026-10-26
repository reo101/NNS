// Scratch Btrfs benchmark mount. Uses the caller's mount namespace, not init's.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("storage-bench-mount: " ++ format ++ "\n", arguments);
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

fn ioctl(descriptor: i32, request: usize, argument: usize) usize {
    return linux.syscall3(.ioctl, @intCast(descriptor), request, argument);
}

fn attach(image_path: [*:0]const u8, target_path: [*:0]const u8, subvolume: []const u8, option_override: ?[]const u8) void {
    if (linux.geteuid() != 0) fail("root is required", .{});
    const image: i32 = @intCast(checked(linux.openat(-100, image_path, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .NONBLOCK = true, .CLOEXEC = true }, 0), "open image"));
    var loop_name: [64]u8 = undefined;
    var loop_path: [:0]const u8 = undefined;
    var loop: i32 = -1;
    var number: u32 = 0;
    scan: for (0..64) |candidate| {
        // This device has static device nodes, so LOOP_CTL_GET_FREE cannot publish one.
        loop_path = std.mem.printSentinel(&loop_name, "/dev/block/loop{d}", .{candidate}, 0) catch fail("loop path too long", .{});
        const opened = linux.openat(-100, loop_path, .{ .ACCMODE = .RDWR, .NOFOLLOW = true, .CLOEXEC = true }, 0);
        if (errnoCode(opened) == uapi.ENOENT) continue;
        if (errnoCode(opened)) |code| fail("open loop device {d}: errno {d}", .{ candidate, code });
        var configuration = std.mem.zeroes(uapi.struct_loop_config);
        configuration.fd = @intCast(image);
        configuration.info.lo_flags = @intCast(uapi.LO_FLAGS_AUTOCLEAR);
        const configured = ioctl(@intCast(opened), uapi.LOOP_CONFIGURE, @intFromPtr(&configuration));
        if (errnoCode(configured) == uapi.EBUSY) {
            _ = linux.close(@intCast(opened));
            continue;
        }
        _ = checked(configured, "configure loop device");
        loop = @intCast(opened);
        number = @intCast(candidate);
        break :scan;
    } else fail("no free loop device", .{});
    var options: [192]u8 = undefined;
    const requested = if (option_override) |value| value else "subvolid=256,compress=zstd:3,nodiscard";
    const direct_io = std.mem.indexOf(u8, requested, "loop_direct_io") != null;
    var cleaned: [192]u8 = undefined;
    var length: usize = 0;
    var parts = std.mem.splitScalar(u8, requested, ',');
    var first = true;
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "loop_direct_io")) continue;
        if (!first) {
            cleaned[length] = ',';
            length += 1;
        }
        @memcpy(cleaned[length .. length + part.len], part);
        length += part.len;
        first = false;
    }
    const text = std.mem.printSentinel(&options, "{s}", .{cleaned[0..length]}, 0) catch fail("options too long", .{});
    _ = checked(linux.mount(loop_path.ptr, target_path, "btrfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr(text.ptr)), "mount Btrfs");
    if (direct_io) _ = checked(ioctl(loop, 0x4c08, 1), "enable direct I/O on loop"); // LOOP_SET_DIRECT_IO
    _ = linux.close(loop); // AUTOCLEAR keeps the device while mounted.
    _ = linux.close(image);
    var status = std.mem.zeroes(uapi.struct_statfs);
    const mounted: i32 = @intCast(checked(linux.openat(-100, target_path, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open mountpoint"));
    _ = checked(linux.syscall2(.fstatfs, @intCast(mounted), @intFromPtr(&status)), "stat mounted filesystem");
    _ = linux.close(mounted);
    var output: [256]u8 = undefined;
    const line = std.mem.printSentinel(&output, "loop={s} index={d} filesystem={x} subvolid={s}\n", .{ loop_path, number, status.f_type, subvolume }, 0) catch unreachable;
    _ = checked(linux.write(1, line.ptr, line.len), "write result");
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    if (args.len == 5 and std.mem.eql(u8, std.mem.span(args[1]), "attach")) return attach(args[2], args[3], std.mem.span(args[4]), null);
    if (args.len == 6 and std.mem.eql(u8, std.mem.span(args[1]), "attach")) return attach(args[2], args[3], std.mem.span(args[4]), std.mem.span(args[5]));
    if (args.len == 3 and std.mem.eql(u8, std.mem.span(args[1]), "detach")) {
        if (linux.geteuid() != 0) fail("root is required", .{});
        _ = checked(linux.umount2(args[2], 0), "unmount Btrfs");
        return;
    }
    fail("usage: storage-bench-mount attach IMAGE MOUNTPOINT SUBVOLUME | detach MOUNTPOINT", .{});
}
