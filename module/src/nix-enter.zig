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
    const r1 = linux.unshare(0x10000000 | 0x00020000);
    if (@as(isize, @bitCast(r1)) < 0) {
        // An inherited seccomp filter can reject the combined flags; split
        // the calls. A NEWUSER failure surfaces on the uid_map write below.
        const r2 = linux.unshare(0x10000000);
        if (@as(isize, @bitCast(r2)) >= 0) {
            const r3 = linux.unshare(0x00020000);
            if (@as(isize, @bitCast(r3)) < 0) {
                std.debug.print("nix-enter: unshare NEWNS: errno {d}\n", .{-@as(isize, @bitCast(r3))});
                std.process.exit(1);
            }
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

fn mount(op: []const u8, source: ?[*:0]const u8, target: [*:0]const u8, kind: ?[*:0]const u8, flags: u32, data: usize) void {
    var m_buf: [96]u8 = undefined;
    const mop = std.fmt.bufPrint(&m_buf, "mount {s}", .{op}) catch op;
    _ = checked2(linux.mount(source, target, kind, flags, data), mop);
}

fn checked2(rc: usize, op: []const u8) usize {
    const signed: isize = @bitCast(rc);
    if (signed < 0 and signed >= -4095) {
        std.debug.print("nix-enter: {s}: errno {d}\n", .{ op, -signed });
        std.process.exit(1);
    }
    return rc;
}

fn mountPrivateVar(init: std.process.Init, root: []const u8) !void {
    // /var/empty belongs to this synthetic root, not Android's read-only
    // rootfs. Preserve the remaining /var entries without writing through
    // a bind mount into the host. In particular, never reuse host empty/.
    const previous_umask = checked(linux.syscall1(.umask, 0), "set namespace umask");
    defer _ = linux.syscall1(.umask, previous_umask);
    var var_buf: [4096]u8 = undefined;
    const var_root = path(&var_buf, root, "var");
    _ = checked(linux.mkdirat(-100, var_root.ptr, 0o755), "create private /var");
    var destination_buf: [4096]u8 = undefined;
    _ = checked(linux.mkdirat(-100, path(&destination_buf, var_root, "empty").ptr, 0o755), "create private /var/empty");
    var original: ?std.Io.Dir = std.Io.Dir.openDirAbsolute(init.io, "/var", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (original) |*directory| {
        defer directory.close(init.io);
        var entries = directory.iterate();
        var source_buf: [4096]u8 = undefined;
        var target_buf: [4096]u8 = undefined;
        while (try entries.next(init.io)) |entry| {
            if (std.mem.eql(u8, entry.name, "empty")) continue;
            const destination = path(&destination_buf, var_root, entry.name);
            if (entry.kind == .directory) {
                _ = checked(linux.mkdirat(-100, destination.ptr, 0o755), "mirror /var directory");
                mount("bind /var mirror", path(&source_buf, "/var", entry.name).ptr, destination.ptr, null, linux.MS.BIND | linux.MS.REC, 0);
            } else {
                const target = path(&target_buf, "../.nns-host/var", entry.name);
                _ = checked(linux.symlinkat(target.ptr, -100, destination.ptr), "mirror /var entry");
            }
        }
    }
}

fn mountCallerEtc(init: std.process.Init, root: []const u8, uid: u32, gid: u32) !void {
    const previous_umask = checked(linux.syscall1(.umask, 0), "set namespace umask");
    defer _ = linux.syscall1(.umask, previous_umask);
    var etc_buf: [4096]u8 = undefined;
    const etc_root = path(&etc_buf, root, "etc");
    _ = checked(linux.mkdirat(-100, etc_root.ptr, 0o755), "create private /etc");
    var destination_buf: [4096]u8 = undefined;
    var original: ?std.Io.Dir = std.Io.Dir.openDirAbsolute(init.io, "/etc", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (original) |*directory| {
        defer directory.close(init.io);
        var entries = directory.iterate();
        var source_buf: [4096]u8 = undefined;
        var target_buf: [4096]u8 = undefined;
        while (try entries.next(init.io)) |entry| {
            if (std.mem.eql(u8, entry.name, "passwd") or std.mem.eql(u8, entry.name, "group")) continue;
            const destination = path(&destination_buf, etc_root, entry.name);
            if (entry.kind == .directory) {
                _ = checked(linux.mkdirat(-100, destination.ptr, 0o755), "mirror /etc directory");
                mount("bind /etc mirror", path(&source_buf, "/etc", entry.name).ptr, destination.ptr, null, linux.MS.BIND | linux.MS.REC, 0);
            } else {
                _ = checked(linux.symlinkat(path(&target_buf, "../.nns-host/etc", entry.name).ptr, -100, destination.ptr), "mirror /etc entry");
            }
        }
    }
    const inherited_name = init.environ_map.get("USER") orelse "";
    const name = if (uid == 0) "root" else if (inherited_name.len != 0) inherited_name else
        try std.fmt.allocPrint(init.gpa, "uid{d}", .{uid});
    const group = if (gid == 0) "root" else try std.fmt.allocPrint(init.gpa, "gid{d}", .{gid});
    const home = init.environ_map.get("HOME") orelse "/";
    const inherited_shell = init.environ_map.get("SHELL") orelse "";
    const shell = if (inherited_shell.len == 0) "/bin/sh" else inherited_shell;
    for ([_][]const u8{ name, home, shell }) |field| {
        if (std.mem.indexOfAny(u8, field, ":\r\n") != null) return error.InvalidAccountEnvironment;
    }
    const passwd = try std.fmt.allocPrint(init.gpa, "{s}:x:{d}:{d}:NNS caller:{s}:{s}\n", .{ name, uid, gid, home, shell });
    const groups = try std.fmt.allocPrint(init.gpa, "{s}:x:{d}:\n", .{ group, gid });
    for ([_]struct { name: []const u8, contents: []const u8 }{
        .{ .name = "passwd", .contents = passwd },
        .{ .name = "group", .contents = groups },
    }) |file| {
        const destination = path(&destination_buf, etc_root, file.name);
        const fd: i32 = @intCast(checked(linux.openat(-100, destination.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o644), "create caller account file"));
        defer _ = linux.close(fd);
        if (checked(linux.write(fd, file.contents.ptr, file.contents.len), "write caller account file") != file.contents.len) return error.ShortAccountWrite;
    }
}

fn profilePath(init: std.process.Init, profile: []const u8, generation: ?[]const u8) [:0]u8 {
    var candidate_buf: [4096]u8 = undefined;
    const candidate = if (profile.len > 0 and profile[0] == '/') blk: {
        if (generation != null) {
            std.debug.print("nix-enter: --generation requires a named profile\n", .{});
            std.process.exit(2);
        }
        break :blk std.fmt.bufPrintZ(&candidate_buf, "{s}", .{profile}) catch unreachable;
    } else blk: {
        var name = profile;
        if (name.len == 0 or !std.ascii.isAlphanumeric(name[0])) {
            std.debug.print("nix-enter: invalid profile name\n", .{});
            std.process.exit(2);
        }
        for (name) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') {
                std.debug.print("nix-enter: invalid profile name\n", .{});
                std.process.exit(2);
            }
        }
        if (generation) |number| {
            name = std.fmt.allocPrint(init.gpa, "{s}-{s}-link", .{ name, number }) catch @panic("out of memory");
        }
        break :blk std.fmt.bufPrintZ(&candidate_buf, "/nix/var/nix/profiles/{s}", .{name}) catch unreachable;
    };
    const fd = linux.openat(-100, candidate.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(fd)) < 0) {
        std.debug.print("nix-enter: profile not found or not a directory: {s}\n", .{candidate});
        std.process.exit(1);
    }
    defer _ = linux.close(@intCast(fd));
    var fd_path_buf: [64]u8 = undefined;
    const fd_path = std.fmt.bufPrintZ(&fd_path_buf, "/proc/self/fd/{d}", .{fd}) catch unreachable;
    var resolved_buf: [4096]u8 = undefined;
    const resolved_len = linux.readlinkat(-100, fd_path.ptr, &resolved_buf, resolved_buf.len);
    if (@as(isize, @bitCast(resolved_len)) < 0 or resolved_len >= resolved_buf.len) {
        std.debug.print("nix-enter: cannot resolve profile: {s}\n", .{candidate});
        std.process.exit(1);
    }
    const raw_resolved = resolved_buf[0..resolved_len];
    // The mirrored host root exposes the same bind-mounted store at this alias.
    const host_prefix = "/.nns-host";
    const resolved = if (std.mem.startsWith(u8, raw_resolved, host_prefix)) raw_resolved[host_prefix.len..] else raw_resolved;
    if (!std.mem.startsWith(u8, resolved, "/nix/store/") or resolved.len <= "/nix/store/".len) {
        std.debug.print("nix-enter: profile target is not immutable store path: {s}\n", .{resolved});
        std.process.exit(1);
    }
    var bin_buf: [4096]u8 = undefined;
    const bin = path(&bin_buf, resolved, "bin");
    const bin_fd = linux.openat(-100, bin.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(bin_fd)) < 0) {
        std.debug.print("nix-enter: profile has no bin directory: {s}\n", .{resolved});
        std.process.exit(1);
    }
    _ = linux.close(@intCast(bin_fd));
    return std.fmt.allocPrintSentinel(init.gpa, "{s}", .{resolved}, 0) catch @panic("out of memory");
}

fn replaceEnv(init: std.process.Init, env: *[*:null]const ?[*:0]const u8, name: []const u8, value: []const u8) void {
    const entry = std.fmt.allocPrintSentinel(init.gpa, "{s}={s}", .{ name, value }, 0) catch @panic("out of memory");
    const entries = init.gpa.allocSentinel(?[*:0]const u8, std.mem.len(env.*) + 2, null) catch @panic("out of memory");
    var count: usize = 0;
    for (std.mem.span(env.*)) |item| {
        const span = std.mem.span(item.?);
        if (std.mem.startsWith(u8, span, name) and span.len > name.len and span[name.len] == '=') continue;
        entries[count] = item;
        count += 1;
    }
    entries[count] = entry.ptr;
    entries[count + 1] = null;
    env.* = entries.ptr;
}

fn exec(init: std.process.Init, args: []const [*:0]const u8, store: [*:0]const u8, profile_arg: ?[]const u8, generation: ?[]const u8) noreturn {
    const argv = init.gpa.allocSentinel(?[*:0]const u8, args.len, null) catch @panic("out of memory");
    for (args, 0..) |arg, i| argv[i] = arg;
    var env: [*:null]const ?[*:0]const u8 = @ptrCast(init.minimal.environ.block.view().slice.ptr);
    // Bionic's linker namespace permits /data, not /nix. Use the physical
    // backing path; the libc-neutral bridge passes Bionic calls through.
    var bridge_buf: [4096]u8 = undefined;
    const bridge = path(&bridge_buf, std.mem.span(store), "lib/libnns-dns.so");
    const fd = linux.openat(-100, bridge.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(fd)) >= 0) {
        _ = linux.close(@intCast(fd));
        const previous = init.environ_map.get("LD_PRELOAD") orelse "";
        var tokens = std.mem.tokenizeAny(u8, previous, " :");
        var present = false;
        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, bridge)) present = true;
        }
        if (!present) {
            const entry = std.fmt.allocPrintSentinel(init.gpa, "LD_PRELOAD={s}{s}{s}",
                .{ bridge, if (previous.len == 0) "" else ":", previous }, 0) catch @panic("out of memory");
            const entries = init.gpa.allocSentinel(?[*:0]const u8, std.mem.len(env) + 1, null) catch @panic("out of memory");
            var count: usize = 0;
            for (std.mem.span(env)) |item| {
                if (std.mem.startsWith(u8, std.mem.span(item.?), "LD_PRELOAD=")) continue;
                entries[count] = item;
                count += 1;
            }
            entries[count] = entry.ptr;
            entries[count + 1] = null;
            env = entries.ptr;
        }
    }
    const selected_profile = if (profile_arg) |selected|
        profilePath(init, selected, generation)
    else
        "/nix/var/nix/profiles/system-profile";
    const helpers = "/data/nix/var/nns/bin";
    const profile_bin = std.fmt.allocPrint(init.gpa, "{s}/bin", .{selected_profile}) catch @panic("out of memory");
    const system_bin = "/nix/var/nix/profiles/system-profile/bin";
    const previous_path = init.environ_map.get("PATH") orelse "";
    const constructed_path = std.fmt.allocPrint(init.gpa, "{s}:{s}:{s}{s}{s}", .{
        helpers, profile_bin, system_bin, if (previous_path.len == 0) "" else ":", previous_path,
    }) catch @panic("out of memory");
    replaceEnv(init, &env, "PATH", constructed_path);
    replaceEnv(init, &env, "NNS_PROFILE", selected_profile);
    // Interactive shells may source the profile's generated environment snippet.
    const env_profile = "/data/nix/etc/profile";
    if (init.environ_map.get("ENV") == null or init.environ_map.get("ENV").?.len == 0) {
        replaceEnv(init, &env, "ENV", env_profile);
    }
    {
        const uid = linux.geteuid();
        const needed = [_]struct { name: []const u8, value: []const u8 } {
            .{ .name = "NIX_CONF_DIR", .value = "/data/nix/etc/nix" },
            .{ .name = "NIX_REMOTE", .value = if (uid == 0) "local" else "daemon" },
        };
        for (needed) |item| {
            if (init.environ_map.get(item.name) == null) {
                replaceEnv(init, &env, item.name, item.value);
            }
        }
    }
    if (std.mem.indexOfScalar(u8, std.mem.span(args[0]), '/') == null) {
        var dirs = std.mem.splitScalar(u8, constructed_path, ':');
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
    var profile: []const u8 = "system-profile";
    var profile_set = false;
    var generation: ?[]const u8 = null;
    var etcdir: [*:0]const u8 = "";
    var userns = linux.geteuid() != 0;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = std.mem.span(args[i]);
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        } else if (std.mem.eql(u8, arg, "--userns")) {
            userns = true;
        } else if (std.mem.eql(u8, arg, "--profile") or std.mem.eql(u8, arg, "--generation") or std.mem.eql(u8, arg, "--store") or std.mem.eql(u8, arg, "--tmpdir") or std.mem.eql(u8, arg, "--etc")) {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            if (std.mem.eql(u8, arg, "--store")) {
                store = args[i];
            } else if (std.mem.eql(u8, arg, "--tmpdir")) {
                tmpdir = std.mem.span(args[i]);
            } else if (std.mem.eql(u8, arg, "--etc")) {
                etcdir = args[i];
            } else if (std.mem.eql(u8, arg, "--profile")) {
                profile = std.mem.span(args[i]);
                profile_set = true;
            } else {
                const value = std.mem.span(args[i]);
                if (value.len == 0) return error.InvalidGeneration;
                for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidGeneration;
                const parsed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidGeneration;
                if (parsed == 0) return error.InvalidGeneration;
                generation = std.fmt.allocPrint(init.gpa, "{d}", .{parsed}) catch @panic("out of memory");
            }
        } else if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: nix-enter [--userns] [--profile NAME|/absolute/path] [--generation NUMBER] [--store PATH] [--tmpdir DIR] [--etc DIR] -- COMMAND [ARG...]\n", .{});
            return 0;
        } else break;
    }
    if (i == args.len) return error.CommandRequired;
    if (generation != null and (!profile_set or profile.len == 0 or profile[0] == '/')) return error.InvalidGeneration;
    if (store[0] != '/' or tmpdir.len == 0 or tmpdir[0] != '/' or (etcdir[0] != 0 and etcdir[0] != '/')) return error.AbsolutePathRequired;

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
    mount("make / private", null, "/", null, linux.MS.PRIVATE | linux.MS.REC, 0);

    var cwd: [4096]u8 = undefined;
    _ = checked(linux.syscall2(.getcwd, @intFromPtr(&cwd), cwd.len), "getcwd");
    mount("mount scratch tmpfs", "tmpfs", root.ptr, "tmpfs", linux.MS.NOSUID | linux.MS.NODEV, @intFromPtr("mode=755,size=16m"));
    var buf: [4096]u8 = undefined;
    for ([_][]const u8{ ".nns-host", ".nns-detach", "nix" }) |name| {
        const target = path(&buf, root, name);
        _ = checked(linux.mkdirat(-100, target.ptr, 0o755), "mkdir in new root");
    }
    // Copy the inherited mount tree as a unit. Moving individual inherited
    // mounts fails in less-privileged user namespaces because they are locked.
    mount("bind host tree", "/", path(&buf, root, ".nns-host").ptr, null, linux.MS.BIND | linux.MS.REC, 0);
    mount("bind store", store, path(&buf, root, "nix").ptr, null, linux.MS.BIND | linux.MS.REC, 0);
    // Default account records describe only the caller. Explicit --etc keeps
    // the supplied tree authoritative for NoD and supervised services.
    // The original /etc remains reachable at /.nns-host/etc.
    if (etcdir[0] != 0) {
        const dest = path(&buf, root, "etc");
        _ = checked(linux.mkdirat(-100, dest.ptr, 0o755), "mkdir etc in new root");
        mount("bind etc", etcdir, dest.ptr, null, linux.MS.BIND, 0);
    } else {
        try mountCallerEtc(init, root, uid, gid);
    }
    var original = try std.Io.Dir.openDirAbsolute(init.io, "/", .{ .iterate = true });
    var entries = original.iterate();
    var target_buf: [4096]u8 = undefined;
    var source_buf: [4096]u8 = undefined;
    var has_tmp = false;
    while (try entries.next(init.io)) |entry| {
        if (std.mem.eql(u8, entry.name, "nix") or std.mem.eql(u8, entry.name, "var") or
            std.mem.eql(u8, entry.name, ".nns-host") or std.mem.eql(u8, entry.name, ".nns-detach") or
            std.mem.eql(u8, entry.name, "etc")) continue;
        if (std.mem.eql(u8, entry.name, "tmp")) has_tmp = true;
        const target = path(&target_buf, ".nns-host", entry.name);
        const dest = path(&buf, root, entry.name);
        if (entry.kind == .directory) {
            // Real mountpoints preserve cwd/getcwd and paths reported by Git.
            _ = checked(linux.mkdirat(-100, dest.ptr, 0o755), "mirror directory");
            mount("bind mirror", path(&source_buf, root, target).ptr, dest.ptr, null, linux.MS.BIND | linux.MS.REC, 0);
        } else {
            _ = checked(linux.symlinkat(target.ptr, -100, dest.ptr), "mirror root entry");
        }
    }
    original.close(init.io);
    try mountPrivateVar(init, root);
    if (!has_tmp) _ = checked(linux.mkdirat(-100, path(&buf, root, "tmp").ptr, 0o1777), "create /tmp");
    _ = checked(linux.chdir(root.ptr), "chdir new root");
    _ = checked(linux.pivot_root(".", ".nns-detach"), "pivot_root");
    _ = checked(linux.chdir("/"), "chdir root");
    _ = checked(linux.umount2("/.nns-detach", 2), "detach original root");
    _ = checked(linux.unlinkat(-100, "/.nns-detach", 0x200), "remove old root mountpoint");
    // A host nscd socket would bypass this namespace's passwd/group files.
    const nscd = linux.openat(-100, "/var/run/nscd", .{ .ACCMODE = .RDONLY, .DIRECTORY = true }, 0);
    if (@as(isize, @bitCast(nscd)) >= 0) {
        _ = linux.close(@intCast(nscd));
        mount("hide host NSS cache", "/var/empty", "/var/run/nscd", null, linux.MS.BIND, 0);
    }
    _ = checked(linux.chdir(@ptrCast(&cwd)), "restore working directory");
    exec(init, args[i..], store, if (profile_set) profile else null, generation);
}
