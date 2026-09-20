// Static Linux namespace launcher. No su, no global mounts, no libc.
// Non-root callers get an identity-preserving user namespace; root callers
// retain the privileged mount-only path unless --userns is explicit.
const std = @import("std");
const linux = std.os.linux;

fn checked(rc: usize, operation: []const u8) usize {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed >= -4095) {
        std.debug.print("nix-enter: {s}: errno {d}\n", .{ operation, -signed });
        std.process.exit(1);
    }
    return rc;
}

fn path(buf: []u8, base: []const u8, name: []const u8) [:0]u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ base, name }) catch {
        std.debug.print("nix-enter: path too long\n", .{});
        std.process.exit(1);
    };
}

fn writeProc(name: [*:0]const u8, value: []const u8) void {
    const fd: i32 = @intCast(checked(linux.openat(-100, name, .{ .ACCMODE = .WRONLY }, 0), std.mem.span(name)));
    defer _ = linux.close(fd);
    var op_buf: [64]u8 = undefined;
    const op = std.fmt.bufPrint(&op_buf, "write {s}", .{std.mem.span(name)}) catch "write namespace mapping";
    if (checked(linux.write(fd, value.ptr, value.len), op) != value.len) {
        std.debug.print("nix-enter: short namespace mapping write\n", .{});
        std.process.exit(1);
    }
}

fn enterUserns(uid: u32, gid: u32) void {
    var st_buf: [4096]u8 = undefined;
    const sfd: i32 = @intCast(checked(linux.openat(-100, "/proc/self/status", .{ .ACCMODE = .RDONLY }, 0), "open status"));
    const n = checked(linux.read(sfd, &st_buf, st_buf.len), "read status");
    _ = linux.close(sfd);
    var it = std.mem.splitScalar(u8, st_buf[0..@intCast(n)], '\n');
    while (it.next()) |l| {
        if (std.mem.startsWith(u8, l, "Seccomp:") or std.mem.startsWith(u8, l, "CapEff:") or std.mem.startsWith(u8, l, "NoNewPrivs:"))
            std.debug.print("{s}\n", .{l});
    }
    const afd: i32 = @intCast(checked(linux.openat(-100, "/proc/self/attr/current", .{ .ACCMODE = .RDONLY }, 0), "open attr"));
    const an = checked(linux.read(afd, &st_buf, st_buf.len), "read attr");
    _ = linux.close(afd);
    std.debug.print("domain={s}\n", .{std.mem.trimEnd(u8, st_buf[0..@intCast(an)], "\x00\n")});
    const r1 = linux.unshare(0x10000000 | 0x00020000);
    std.debug.print("unshare NEWUSER|NEWNS: {d}\n", .{@as(isize, @bitCast(r1))});
    if (@as(isize, @bitCast(r1)) < 0) {
        const r2 = linux.unshare(0x10000000);
        std.debug.print("unshare NEWUSER retry: {d}\n", .{@as(isize, @bitCast(r2))});
        if (@as(isize, @bitCast(r2)) == 0) {
            const r3 = linux.unshare(0x00020000);
            std.debug.print("unshare NEWNS retry: {d}\n", .{@as(isize, @bitCast(r3))});
            if (@as(isize, @bitCast(r3)) < 0) std.process.exit(1);
        }
    }
    // Android's init userns has setgroups enabled and a fresh userns inherits
    // that flag, which blocks the own-gid map. Denying setgroups (still legal
    // before any gid_map write) clears it and is safe for a single-identity
    // store mount.
    writeProc("/proc/self/setgroups", "deny");
    var buf: [96]u8 = undefined;
    // Capture IDs BEFORE unshare. Preserve numeric identity for Android/glibc.
    // The kernel compares the opener's kuid with the namespace owner kuid, so
    // the child may write its own maps.
    const uid_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ uid, uid }) catch unreachable;
    writeProc("/proc/self/uid_map", uid_map);
    const gid_map = std.fmt.bufPrint(&buf, "{d} {d} 1\n", .{ gid, gid }) catch unreachable;
    writeProc("/proc/self/gid_map", gid_map);
    _ = checked(linux.syscall5(.prctl, 38, 1, 0, 0, 0), "no_new_privs");
}

fn mount(source: ?[*:0]const u8, target: [*:0]const u8, kind: ?[*:0]const u8, flags: u32, data: usize) void {
    _ = checked(linux.mount(source, target, kind, flags, data), "mount");
}

fn exec(init: std.process.Init, args: []const [*:0]const u8) noreturn {
    const argv = init.gpa.allocSentinel(?[*:0]const u8, args.len, null) catch @panic("out of memory");
    for (args, 0..) |arg, i| argv[i] = arg;
    const env: [*:null]const ?[*:0]const u8 = @ptrCast(init.minimal.environ.block.view().slice.ptr);
    if (std.mem.indexOfScalar(u8, std.mem.span(args[0]), '/') == null) {
        var dirs = std.mem.splitScalar(u8, init.environ_map.get("PATH") orelse "/system/bin:/bin:/usr/bin", ':');
        var buf: [4096]u8 = undefined;
        while (dirs.next()) |dir| {
            const executable = path(&buf, if (dir.len == 0) "." else dir, std.mem.span(args[0]));
            _ = linux.execve(executable.ptr, argv.ptr, env);
        }
    } else {
        _ = checked(linux.execve(args[0], argv.ptr, env), "exec");
    }
    std.debug.print("nix-enter: cannot execute {s}\n", .{args[0]});
    std.process.exit(127);
}

pub fn main(init: std.process.Init) !u8 {
    const args = init.minimal.args.vector;
    var store: [*:0]const u8 = "/data/nix";
    var tmpdir: []const u8 = init.environ_map.get("TMPDIR") orelse "/tmp";
    var userns = linux.geteuid() != 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, arg, "--userns")) {
            userns = true;
        } else if (std.mem.eql(u8, arg, "--store") or std.mem.eql(u8, arg, "--tmpdir")) {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, arg, "--store")) store = args[i] else tmpdir = std.mem.span(args[i]);
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: nix-enter [--userns] [--store PATH] [--tmpdir DIR] -- COMMAND [ARG...]\n", .{});
            return 0;
        } else break;
    }
    if (i == args.len) return error.CommandRequired;
    if (store[0] != '/' or tmpdir.len == 0 or tmpdir[0] != '/') return error.AbsolutePathRequired;

    // The parent owns only an empty scratch directory, and removes it after
    // the child exits. No mounts are ever made in the parent's namespace.
    var random: u64 = undefined;
    if (checked(linux.getrandom(std.mem.asBytes(&random).ptr, 8, 0), "getrandom") != 8) return error.ShortRandomRead;
    var root_buf: [4096]u8 = undefined;
    const root = std.fmt.bufPrintZ(&root_buf, "{s}/nns.{d}.{x}", .{ tmpdir, linux.getpid(), random }) catch return error.PathTooLong;
    _ = checked(linux.mkdirat(-100, root.ptr, 0o700), "create scratch directory");
    const parent_pid = linux.getpid();
    const child = linux.syscall5(.clone, 17, 0, 0, 0, 0); // fork, SIGCHLD; same ABI on arm64/x86_64.
    if (@as(isize, @bitCast(child)) < 0) {
        _ = linux.unlinkat(-100, root.ptr, 0x200);
        _ = checked(child, "fork");
    }
    if (child != 0) {
        var status: u32 = 0;
        while (true) {
            const rc = linux.syscall4(.wait4, child, @intFromPtr(&status), 0, 0);
            if (@as(isize, @bitCast(rc)) == -4) continue; // EINTR
            _ = checked(rc, "wait for command");
            break;
        }
        _ = checked(linux.unlinkat(-100, root.ptr, 0x200), "remove scratch directory");
        return if ((status & 0x7f) != 0) @intCast(128 + (status & 0x7f)) else @intCast((status >> 8) & 0xff);
    }

    _ = checked(linux.syscall5(.prctl, 1, 9, 0, 0, 0), "parent death signal");
    if (linux.getppid() != parent_pid) return 1;
    const uid = linux.getuid();
    const gid = linux.getgid();
    if (userns) {
        enterUserns(uid, gid);
    } else {
        _ = checked(linux.unshare(0x00020000), "unshare mount namespace");
    }
    mount(null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0);

    var cwd: [4096]u8 = undefined;
    _ = checked(linux.syscall2(.getcwd, @intFromPtr(&cwd), cwd.len), "getcwd");
    mount("tmpfs", root.ptr, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr("mode=755,size=16m"));
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ ".nns-host", ".nns-detach", "nix" }) |name| {
        const target = path(&buf, root, name);
        _ = checked(linux.mkdirat(-100, target.ptr, 0o755), "mkdir in new root");
    }
    // Copy the inherited mount tree as a unit. Moving individual inherited
    // mounts fails in less-privileged user namespaces because they are locked.
    mount("/", path(&buf, root, ".nns-host").ptr, null, linux.MS.BIND | linux.MS.REC, 0);
    mount(store, path(&buf, root, "nix").ptr, null, linux.MS.BIND | linux.MS.REC, 0);
    var original = try std.Io.Dir.openDirAbsolute(init.io, "/", .{ .iterate = true });
    var entries = original.iterate();
    var target_buf: [4096]u8 = undefined;
    var source_buf: [4096]u8 = undefined;
    var has_tmp = false;
    while (try entries.next(init.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "nix") or
            std.mem.eql(u8, entry.name, ".nns-host") or std.mem.eql(u8, entry.name, ".nns-detach")) continue;
        if (std.mem.eql(u8, entry.name, "tmp")) has_tmp = true;
        const target = path(&target_buf, ".nns-host", entry.name);
        const dest = path(&buf, root, entry.name);
        if (entry.kind == .directory) {
            // Real mountpoints preserve cwd/getcwd and paths reported by Git.
            _ = checked(linux.mkdirat(-100, dest.ptr, 0o755), "mirror directory");
            mount(path(&source_buf, root, target).ptr, dest.ptr, null, linux.MS.BIND | linux.MS.REC, 0);
        } else {
            _ = checked(linux.symlinkat(target.ptr, -100, dest.ptr), "mirror root entry");
        }
    }
    original.close(init.io);
    if (!has_tmp) _ = checked(linux.mkdirat(-100, path(&buf, root, "tmp").ptr, 0o1777), "create /tmp");
    _ = checked(linux.chdir(root.ptr), "chdir new root");
    _ = checked(linux.pivot_root(".", ".nns-detach"), "pivot_root");
    _ = checked(linux.chdir("/"), "chdir root");
    _ = checked(linux.umount2("/.nns-detach", 2), "detach original root");
    _ = checked(linux.unlinkat(-100, "/.nns-detach", 0x200), "remove old root mountpoint");
    _ = checked(linux.chdir(@ptrCast(&cwd)), "restore working directory");
    exec(init, args[i..]);
}
