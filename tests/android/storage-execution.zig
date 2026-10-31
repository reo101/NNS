// Execution probe: report the caller identity and the executable filesystem.
// Performs no writes; the exit status reports the filesystem type.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const syscall_error = @import("syscall_error");
const syscall = syscall_error.Program("storage-execution");

fn writeAll(fd: i32, bytes: []const u8) void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const result = linux.write(fd, bytes.ptr + offset, bytes.len - offset);
        if (std.posix.errno(result) == .INTR) continue;
        offset += syscall.check(result, "write result");
    }
}

fn readContext(buffer: []u8) []const u8 {
    const descriptor: i32 = @intCast(syscall.check(
        linux.openat(linux.AT.FDCWD, "/proc/self/attr/current", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0),
        "open caller SELinux context",
    ));
    defer _ = linux.close(descriptor);
    const count = syscall.check(linux.read(descriptor, buffer.ptr, buffer.len - 1), "read caller SELinux context");
    return std.mem.trim(u8, buffer[0..count], "\n\x00");
}

pub fn main(init: std.process.Init.Minimal) void {
    _ = init;
    const executable: i32 = @intCast(syscall.check(
        linux.openat(linux.AT.FDCWD, "/proc/self/exe", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0),
        "inspect executable filesystem",
    ));
    defer _ = linux.close(executable);
    var filesystem = std.mem.zeroes(uapi.struct_statfs);
    _ = syscall.check(linux.syscall2(.fstatfs, @intCast(executable), @intFromPtr(&filesystem)), "inspect executable filesystem");

    var context_buffer: [256]u8 = undefined;
    const context = readContext(&context_buffer);

    // Android app domains can deny namespace metadata without denying execution.
    var namespace = std.mem.zeroes(uapi.struct_statx);
    const namespace_available = syscall_error.errno(linux.syscall5(.statx, @bitCast(@as(isize, linux.AT.FDCWD)),
        @intFromPtr(@as([*:0]const u8, "/proc/self/ns/mnt")), 0, uapi.STATX_BASIC_STATS, @intFromPtr(&namespace))) == null;

    var line: [512]u8 = undefined;
    const text = std.mem.printSentinel(&line, "uid={d} gid={d} context={s} filesystem={x} namespace={d}\n", .{
        linux.getuid(),
        linux.getgid(),
        context,
        filesystem.f_type,
        if (namespace_available) namespace.stx_ino else 0,
    }, 0) catch syscall.fail("report too long", .{});
    writeAll(1, text[0..text.len]);

    if (filesystem.f_type != uapi.BTRFS_SUPER_MAGIC) std.process.exit(1);
}
