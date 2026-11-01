// Android property adapter. Soong links the Zig archive to platform Bionic.
const std = @import("std");
const linux = std.os.linux;
const storage = @import("storage");
extern fn __system_property_set(name: [*:0]const u8, value: [*:0]const u8) c_int;
// Soong links this archive into Bionic. std.c is gated on link_libc, and the
// archive must not request musl, so the one libc symbol it reads is declared.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

fn inheritedNamespaceDescriptor() ?i32 {
    // Init's "file /proc/1/ns/mnt r" publishes this sanitized environment key.
    // android_get_control_file() resolves the original path, which would repeat
    // the process-inspection check that this descriptor handoff avoids.
    const text = std.mem.span(getenv("ANDROID_FILE__proc_1_ns_mnt") orelse return null);
    if (text.len == 0) return null;
    for (text) |character| if (!std.ascii.isDigit(character)) return null;
    const descriptor = std.fmt.parseInt(i32, text, 10) catch return null;
    if (std.posix.errno(linux.fcntl(@intCast(descriptor), linux.F.GETFD, 0)) != .SUCCESS) return null;
    return descriptor;
}

comptime {
    @export(&controllerMain, .{ .name = "main" });
}

fn controllerMain(argc: c_int, argv: [*]const [*:0]const u8) callconv(.c) c_int {
    if (argc != 1 and (argc != 2 or !std.mem.eql(u8, std.mem.span(argv[1]), "--check"))) {
        std.debug.print("usage: nns-storage [--check]\n", .{});
        return 1;
    }
    const opened = linux.openat(linux.AT.FDCWD, "/proc/self/attr/current", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (std.posix.errno(opened) == .SUCCESS) {
        const descriptor: i32 = @intCast(opened);
        defer _ = linux.close(descriptor);
        var buffer: [256]u8 = undefined;
        const count = linux.read(descriptor, &buffer, buffer.len);
        if (count <= buffer.len)
            std.debug.print("nns-storage: controller context={s}\n", .{std.mem.trim(u8, buffer[0..count], "\n\x00")});
    }
    // A stopped oneshot service does not establish that its mount succeeded.
    if (__system_property_set("sys.nns.storage.ready", "0") != 0) {
        std.debug.print("nns-storage: cannot clear readiness\n", .{});
        return 1;
    }
    const initial_namespace = inheritedNamespaceDescriptor() orelse {
        std.debug.print("nns-storage: init namespace descriptor is missing or invalid\n", .{});
        return 1;
    };
    storage.run(argv[0..@intCast(argc)], initial_namespace);
    if (__system_property_set("sys.nns.storage.ready", "1") != 0) {
        std.debug.print("nns-storage: cannot publish readiness\n", .{});
        return 1;
    }
    return 0;
}
