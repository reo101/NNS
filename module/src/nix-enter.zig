// nix-enter — NNS (Native Nix Store)
//
// Runs a command inside a private mount namespace whose root contains a real,
// root-level /nix (bind of /data/nix). Everything the command spawns
// (fork/exec) inherits the view. Nothing outside the session is touched.
//
// The "dance" (validated empirically on cheetah / Android 16 / kernel 6.1):
//   / is RO ext4 (system-as-root, verity) -> /nix cannot be created there.
//   pivot_root needs every top-level submount moved into the new root first
//   (this kernel does not carry submounts), and shared propagation blocks
//   mount --move, hence make-rprivate. /data must be moved too, which breaks
//   paths under /data mid-dance, hence this binary is self-contained and only
//   touches paths that survive every step.
//
// Pure zig 0.16 (std.Io + std.os.linux wrappers), no libc. Static aarch64.
//
// Usage: nix-enter [command [args...]]   (default: /system/bin/sh -i)
// Root required (CAP_SYS_ADMIN in the init user ns). Grant the calling app
// in SukiSU, then: su -c /data/adb/modules/nix/bin/nix-enter <cmd>

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

const MS_BIND: u32 = 4096;
const MS_MOVE: u32 = 8192;
const MS_REC: u32 = 16384;
const MS_PRIVATE: u32 = 262144;
const MS_NOSUID: u32 = 2;
const CLONE_NEWNS: usize = 0x00020000;

const NIXSTORE = "/data/nix";
const LOGPATH = "/data/local/tmp/nix-enter.log";

fn failed(rc: usize) bool {
    return @as(isize, @bitCast(rc)) < 0;
}

fn errnoName(rc: usize) []const u8 {
    const neg: isize = @as(isize, @bitCast(rc));
    const e: posix.E = @enumFromInt(@as(u8, @truncate(@as(usize, @bitCast(-neg)))));
    return switch (e) {
        .NOENT => "No such file or directory",
        .PERM => "Operation not permitted",
        .BUSY => "Device or resource busy",
        .INVAL => "Invalid argument",
        .EXIST => "File exists",
        .NOTDIR => "Not a directory",
        .ACCES => "Permission denied",
        .NOSPC => "No space left on device",
        .NOMEM => "Out of memory",
        .NAMETOOLONG => "Name too long",
        else => "unknown error",
    };
}

/// log to stderr + best-effort append to /data/local/tmp/nix-enter.log
fn logf(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var msg: [512]u8 = undefined;
    const out = std.fmt.bufPrint(&msg, fmt ++ "\n", args) catch return;
    std.debug.print("{s}", .{out});
    var size: u64 = 0;
    var cwd_dir = std.Io.Dir.cwd();
    if (cwd_dir.statFile(io, LOGPATH, .{})) |st| {
        size = st.size;
    } else |_| {}
    if (std.Io.Dir.createFileAbsolute(io, LOGPATH, .{ .truncate = false })) |f| {
        defer f.close(io);
        f.writePositionalAll(io, out, size) catch {};
    } else |_| {}
}

fn die(io: std.Io, comptime what: []const u8, rc: anytype) noreturn {
    switch (@typeInfo(@TypeOf(rc))) {
        .int => logf(io, "FATAL: " ++ what ++ ": {s}", .{errnoName(@intCast(rc))}),
        .error_set => logf(io, "FATAL: " ++ what ++ ": {s}", .{@errorName(rc)}),
        else => @compileError("bad rc"),
    }
    std.process.exit(1);
}

fn mustOk(io: std.Io, rc: usize, comptime what: []const u8) void {
    if (failed(rc)) die(io, what, rc);
}

fn dirExists(io: std.Io, path: []const u8) bool {
    var d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return false;
    d.close(io);
    return true;
}

/// mkdir -p, ignoring "already exists" style errors
fn mkdirAll(io: std.Io, path: []const u8) void {
    var root = std.Io.Dir.openDirAbsolute(io, "/", .{}) catch return;
    defer root.close(io);
    // strip the leading '/' so the path is relative to root
    _ = root.createDirPath(io, path[1..]) catch {};
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;

    // args come from the OS as null-terminated C strings; steal them directly
    const argv_all: []const [*:0]const u8 = init.minimal.args.vector;
    const cmd_raw: []const [*:0]const u8 = argv_all[1..];

    // default: interactive shell
    var default_cmd = [_][*:0]const u8{ "/system/bin/sh", "-i" };
    const cmd: []const [*:0]const u8 = if (cmd_raw.len == 0) &default_cmd else cmd_raw;

    // ---- guards -------------------------------------------------------------
    mustOk(io, linux.unshare(CLONE_NEWNS), "unshare(CLONE_NEWNS)");
    mustOk(io, linux.mount(null, "/", null, MS_PRIVATE | MS_REC, 0), "make-rprivate /");

    mkdirAll(io, NIXSTORE ++ "/store");
    mkdirAll(io, NIXSTORE ++ "/var");
    mkdirAll(io, NIXSTORE ++ "/tmp");

    // ---- new root ------------------------------------------------------------
    var nr_buf: [64]u8 = undefined;
    const nr = std.fmt.bufPrintZ(&nr_buf, "/tmp/nixroot.{d}", .{linux.getpid()}) catch unreachable;
    mkdirAll(io, nr);

    const data_arg: [*:0]const u8 = "size=8m,mode=755";
    mustOk(io, linux.mount("tmpfs", nr.ptr, "tmpfs", MS_NOSUID, @intFromPtr(data_arg)), "tmpfs on new root");
    mustOk(io, linux.mount(null, nr.ptr, null, MS_PRIVATE, 0), "make-private new root");

    var buf_dst: [512]u8 = undefined;

    // Dir handle ON the new root (tmpfs) — old/ and nix/ must be created there
    var newroot = std.Io.Dir.openDirAbsolute(io, nr, .{}) catch |e| die(io, "open new root", e);
    defer newroot.close(io);
    _ = newroot.createDir(io, "old", .default_dir) catch {};
    _ = newroot.createDir(io, "nix", .default_dir) catch {};

    var root = std.Io.Dir.openDirAbsolute(io, "/", .{ .iterate = true }) catch |e| die(io, "open /", e);
    defer root.close(io);
    _ = root.createDir(io, "old", .default_dir) catch {};
    _ = root.createDir(io, "nix", .default_dir) catch {};

    // /proc files report st_size=0, so the Io reader must not be used here —
    // read the raw fd until EOF instead.
    const mntinfo: []const u8 = blk: {
        const fd: i32 = @intCast(linux.openat(-100, "/proc/self/mountinfo", .{}, 0));
        if (failed(@intCast(fd))) die(io, "open /proc/self/mountinfo", fd);
        defer _ = linux.close(fd);
        var buf: [262144]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const n = linux.read(@intCast(fd), buf[total..].ptr, buf.len - total);
            if (failed(n)) break;
            if (n == 0) break;
            total += n;
        }
        const copy = init.gpa.alloc(u8, total) catch unreachable;
        @memcpy(copy, buf[0..total]);
        break :blk copy;
    };
    var mounts: [64][256]u8 = undefined;
    var mounts_len: [64]usize = undefined;
    var n_mounts: usize = 0;

    var lines = std.mem.splitScalar(u8, mntinfo, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = std.mem.splitScalar(u8, line, ' ');
        // fields: 0:id 1:parent 2:maj:min 3:root 4:mountpoint
        var idx: usize = 0;
        var mntpnt: []const u8 = "";
        while (it.next()) |field| : (idx += 1) {
            if (idx == 4) {
                mntpnt = field;
                break;
            }
        }
        if (idx < 4) continue;
        // top-level only: exactly one '/', not "/" itself, not "/tmp"
        if (mntpnt.len < 2) continue;
        if (std.mem.indexOfScalarPos(u8, mntpnt, 1, '/') != null) continue;
        if (std.mem.eql(u8, mntpnt, "/tmp")) continue;
        if (n_mounts >= mounts.len) break;

        @memcpy(mounts[n_mounts][0..mntpnt.len], mntpnt);
        mounts[n_mounts][mntpnt.len] = 0;
        mounts_len[n_mounts] = mntpnt.len;
        n_mounts += 1;
    }
    logf(io, "top-level submounts: {d}", .{n_mounts});
    // ---- move every top-level submount into the new root -----------------------
    // One move per unique mountpoint: stacked same-path mounts (e.g. the
    // /linkerconfig base + its /default bind on top) travel with their parent
    // automatically; moving them again unstacks them.
    var mi: usize = 0;
    while (mi < n_mounts) : (mi += 1) {
        // dedupe: skip if an earlier entry had the same mountpoint
        var dup = false;
        var mj: usize = 0;
        while (mj < mi) : (mj += 1) {
            if (mounts_len[mj] == mounts_len[mi] and
                std.mem.eql(u8, mounts[mi][0..mounts_len[mi]], mounts[mj][0..mounts_len[mj]]))
            {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        const mp = &mounts[mi];
        const src: [*:0]const u8 = @ptrCast(mp);
        const dst = std.fmt.bufPrintZ(&buf_dst, "{s}{s}", .{ nr, std.mem.span(src) }) catch unreachable;
        mkdirAll(io, dst);
        const rc = linux.mount(src, @ptrCast(dst), null, MS_MOVE, 0);
        if (failed(rc)) {
            logf(io, "WARN: move {s}: {s}", .{ std.mem.span(src), errnoName(rc) });
        }
    }
    // sanity: every moved mountpoint must exist under nr
    for (mounts[0..n_mounts]) |*mp| {
        const mpname: [*:0]const u8 = @ptrCast(mp);
        const chk = std.fmt.bufPrint(&buf_dst, "{s}{s}", .{ nr, std.mem.span(mpname) }) catch unreachable;
        if (!dirExists(io, chk)) {
            logf(io, "POST-MOVE MISSING: {s}", .{chk});
        }
    }

    // ---- symlink the dm-0 leftovers ---------------------------------------------
    // everything left on the old root gets a symlink through /old; relative
    // targets keep it simple: e.g. /system -> old/system
    var it = root.iterate();
    while (true) {
        const entry = it.next(io) catch break orelse break;
        const name = entry.name;
        if (name.len == 0 or name[0] == '.') continue;
        if (std.mem.eql(u8, name, "tmp")) continue;
        var found = false;
        for (mounts[0..n_mounts], 0..) |*mp, mpidx| {
            _ = mpidx;
            const mpname: [*:0]const u8 = @ptrCast(mp);
            if (std.mem.eql(u8, std.mem.span(mpname), name)) {
                found = true;
                break;
            }
        }
        if (found) continue;
        var tgt_buf: [512]u8 = undefined;
        var lnk_buf: [512]u8 = undefined;
        const target = std.fmt.bufPrint(&tgt_buf, "old/{s}", .{name}) catch unreachable;
        const link = std.fmt.bufPrint(&lnk_buf, "{s}/{s}", .{ nr, name }) catch unreachable;
        if (!dirExists(io, link)) {
            // link path is absolute; symLinkAbsolute asserts that
            std.Io.Dir.symLinkAbsolute(io, target, link, .{}) catch |e| {
                if (e != error.PathAlreadyExists) {
                    logf(io, "WARN: symlink {s}: {s}", .{ name, @errorName(e) });
                }
            };
        }
    }

    // ---- pivot -------------------------------------------------------------------
    mustOk(io, linux.chdir(nr.ptr), "chdir new root");
    mustOk(io, linux.pivot_root(".", "old"), "pivot_root");
    mustOk(io, linux.chdir("/"), "chdir /");

    // ---- the store -----------------------------------------------------------------
    mkdirAll(io, NIXSTORE ++ "/store");
    mkdirAll(io, NIXSTORE ++ "/var");
    mkdirAll(io, NIXSTORE ++ "/tmp");
    logf(io, "pre-bind: {s} exists={d}, /nix exists={d}", .{
        NIXSTORE,
        @intFromBool(dirExists(io, NIXSTORE)),
        @intFromBool(dirExists(io, "/nix")),
    });
    mustOk(io, linux.mount(NIXSTORE, "/nix", null, MS_BIND, 0), "bind store -> /nix");

    // fresh /tmp (the symlink points into /old, which is read-only)
    std.Io.Dir.deleteFileAbsolute(io, "/tmp") catch {};
    _ = linux.mkdirat(-100, "/tmp", 0o1777);
    _ = linux.mount("tmpfs", "/tmp", "tmpfs", MS_NOSUID, @intFromPtr("mode=1777"));

    // ---- exec -------------------------------------------------------------------------
    logf(io, "session up, exec {s}", .{std.mem.span(cmd[0])});

    var exec_argv_buf: [64]?[*:0]const u8 = undefined;
    var i: usize = 0;
    while (i < cmd.len and i < 63) : (i += 1) exec_argv_buf[i] = cmd[i];
    exec_argv_buf[i] = null;
    const exec_argv: [*:null]const ?[*:0]const u8 = @ptrCast(&exec_argv_buf);

    const envp: [*:null]const ?[*:0]const u8 = @ptrCast(init.minimal.environ.block.view().slice.ptr);

    // bare names (no '/') go through the usual PATH lookup
    const rc = linux.execve(cmd[0], exec_argv, envp);
    if (failed(rc) and std.mem.indexOfScalar(u8, std.mem.span(cmd[0]), '/') == null) {
        // PATH is unreliable post-pivot; try the standard bins explicitly
        var path_buf: [128]u8 = undefined;
        const alt = std.fmt.bufPrintZ(&path_buf, "/system/bin/{s}", .{std.mem.span(cmd[0])}) catch unreachable;
        const rc2 = linux.execve(alt, exec_argv, envp);
        if (failed(rc2)) {
            const alt2 = std.fmt.bufPrintZ(&path_buf, "/system/xbin/{s}", .{std.mem.span(cmd[0])}) catch unreachable;
            _ = linux.execve(alt2, exec_argv, envp);
        }
        logf(io, "exec {s} failed: {s}", .{ std.mem.span(cmd[0]), errnoName(rc) });
        std.process.exit(127);
    }
    if (failed(rc)) {
        logf(io, "exec {s} failed: {s}", .{ std.mem.span(cmd[0]), errnoName(rc) });
        std.process.exit(127);
    }
    unreachable;
}
