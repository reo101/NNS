// Storage throughput fixture. Writes only its own files under a scratch directory.
const std = @import("std");
const linux = std.os.linux;
const uapi = @import("linux_uapi");
const chunk = 1024 * 1024;
const page = 4096;

fn fail(comptime format: []const u8, arguments: anytype) noreturn {
    std.debug.print("storage-throughput: " ++ format ++ "\n", arguments);
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

fn emit(comptime format: []const u8, arguments: anytype) void {
    var buffer: [2048]u8 = undefined;
    const text = std.mem.printSentinel(&buffer, format, arguments, 0) catch fail("result too long", .{});
    if (checked(linux.write(1, text.ptr, text.len), "write result") != text.len) fail("short result", .{});
}

fn monotonic() u64 {
    // clock_gettime writes two native words: seconds, then nanoseconds.
    var value: [2]i64 = .{ 0, 0 };
    _ = checked(linux.syscall2(.clock_gettime, 1, @intFromPtr(&value)), "read clock"); // CLOCK_MONOTONIC
    return @as(u64, @intCast(value[0])) * 1_000_000_000 + @as(u64, @intCast(value[1]));
}

fn number(text: []const u8) u64 {
    return std.fmt.parseInt(u64, text, 10) catch fail("invalid number: {s}", .{text});
}

fn openWrite(path: [*:0]const u8) i32 {
    return @intCast(checked(linux.openat(-100, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600), "open output"));
}

fn openRead(path: [*:0]const u8) i32 {
    return @intCast(checked(linux.openat(-100, path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open input"));
}

fn fill(buffer: []u8, seed: u64) void {
    var state = seed | 1;
    var offset: usize = 0;
    while (offset + 8 <= buffer.len) : (offset += 8) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        std.mem.writeInt(u64, buffer[offset..][0..8], state, .little);
    }
}

fn dropCache(descriptor: i32, length: u64) void {
    _ = linux.syscall4(.fadvise64, @intCast(descriptor), 0, @intCast(length), 4); // POSIX_FADV_DONTNEED
}

fn sequentialWrite(path: [*:0]const u8, total: u64, sync: bool, zeros: bool) void {
    const descriptor = openWrite(path);
    defer _ = linux.close(descriptor);
    const buffer = std.heap.page_allocator.alloc(u8, chunk) catch fail("allocation failed", .{});
    defer std.heap.page_allocator.free(buffer);
    if (zeros) @memset(buffer, 0) else fill(buffer, 0x9e3779b97f4a7c15);
    const started = monotonic();
    var written: u64 = 0;
    while (written < total) {
        const size: usize = @intCast(@min(total - written, buffer.len));
        var offset: usize = 0;
        while (offset < size) {
            const count = checked(linux.syscall4(.pwrite64, @intCast(descriptor), @intFromPtr(buffer.ptr + offset), size - offset, @intCast(written + offset)), "write data");
            if (count == 0) fail("zero-length write", .{});
            offset += count;
        }
        written += size;
    }
    if (sync) _ = checked(linux.syscall1(.fsync, @intCast(descriptor)), "sync data");
    const elapsed = monotonic() - started;
    emit("{{\"op\":\"seq-write\",\"zeros\":{s},\"sync\":{s},\"bytes\":{d},\"seconds\":{d:.6},\"mbps\":{d:.3}}}\n", .{
        if (zeros) "true" else "false", if (sync) "true" else "false", total,
        @as(f64, @floatFromInt(elapsed)) / 1e9,
        @as(f64, @floatFromInt(total)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
    });
}

fn sequentialRead(path: [*:0]const u8, total: u64) void {
    const descriptor = openRead(path);
    defer _ = linux.close(descriptor);
    const buffer = std.heap.page_allocator.alloc(u8, chunk) catch fail("allocation failed", .{});
    defer std.heap.page_allocator.free(buffer);
    dropCache(descriptor, total);
    const started = monotonic();
    var read: u64 = 0;
    while (read < total) {
        const size: usize = @intCast(@min(total - read, buffer.len));
        var offset: usize = 0;
        while (offset < size) {
            const count = checked(linux.syscall4(.pread64, @intCast(descriptor), @intFromPtr(buffer.ptr + offset), size - offset, @intCast(read + offset)), "read data");
            if (count == 0) break;
            offset += count;
        }
        if (offset == 0) break;
        read += offset;
    }
    const elapsed = monotonic() - started;
    emit("{{\"op\":\"seq-read\",\"bytes\":{d},\"seconds\":{d:.6},\"mbps\":{d:.3}}}\n", .{
        read, @as(f64, @floatFromInt(elapsed)) / 1e9,
        @as(f64, @floatFromInt(read)) / (@as(f64, @floatFromInt(elapsed)) / 1e9) / 1e6,
    });
}

fn randomWrites(path: [*:0]const u8, total: u64, operations: u64, sync: bool) void {
    const descriptor = openWrite(path);
    defer _ = linux.close(descriptor);
    _ = checked(linux.syscall4(.ftruncate, @intCast(descriptor), 0, @intCast(total), 0), "size file");
    var buffer: [page]u8 = undefined;
    fill(&buffer, 0x2545f4914f6cdd1d);
    var state: u64 = 0x2545f4914f6cdd1d;
    const slots = total / page;
    const started = monotonic();
    var index: u64 = 0;
    while (index < operations) : (index += 1) {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        const offset = (state % slots) * page;
        var written: usize = 0;
        while (written < buffer.len) {
            const count = checked(linux.syscall4(.pwrite64, @intCast(descriptor), @intFromPtr(&buffer) + written, buffer.len - written, @intCast(offset + written)), "random write");
            if (count == 0) fail("zero-length write", .{});
            written += count;
        }
        if (sync) _ = checked(linux.syscall1(.fdatasync, @intCast(descriptor)), "sync random write");
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"rand-4k-write\",\"sync_each\":{s},\"operations\":{d},\"seconds\":{d:.6},\"iops\":{d:.1}}}\n", .{
        if (sync) "true" else "false", operations, seconds, @as(f64, @floatFromInt(operations)) / seconds,
    });
}

fn metadata(directory: [*:0]const u8, count: u64) void {
    var name: [512]u8 = undefined;
    const started = monotonic();
    var created: u64 = 0;
    while (created < count) : (created += 1) {
        const path = std.mem.printSentinel(&name, "{s}/file-{d}", .{ directory, created }, 0) catch fail("path too long", .{});
        const descriptor = linux.openat(-100, @ptrCast(path.ptr), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600);
        if (errnoCode(descriptor)) |code| fail("create metadata file: errno {d}", .{code});
        _ = linux.close(@intCast(descriptor));
        var status = std.mem.zeroes(uapi.struct_statx);
        _ = checked(linux.syscall5(.statx, @bitCast(@as(isize, -100)), @intFromPtr(path.ptr), 0, uapi.STATX_BASIC_STATS, @intFromPtr(&status)), "stat metadata file");
        _ = checked(linux.unlinkat(-100, @ptrCast(path.ptr), 0), "remove metadata file");
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"create-stat-unlink\",\"files\":{d},\"seconds\":{d:.6},\"files_per_second\":{d:.1}}}\n", .{
        count, seconds, @as(f64, @floatFromInt(count)) / seconds,
    });
}

fn appendSync(path: [*:0]const u8, records: u64, record: usize) void {
    const descriptor = @as(i32, @intCast(checked(linux.openat(-100, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600), "open log")));
    defer _ = linux.close(descriptor);
    var buffer: [8192]u8 = undefined;
    if (record > buffer.len) fail("record too large", .{});
    fill(buffer[0..record], 0x243f6a8885a308d3);
    const started = monotonic();
    var index: u64 = 0;
    while (index < records) : (index += 1) {
        var offset: usize = 0;
        while (offset < record) {
            const count = checked(linux.syscall4(.pwrite64, @intCast(descriptor), @intFromPtr(&buffer) + offset, record - offset, @intCast(index * record + offset)), "append record");
            if (count == 0) fail("zero-length append", .{});
            offset += count;
        }
        _ = checked(linux.syscall1(.fdatasync, @intCast(descriptor)), "sync record");
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"append-fsync\",\"records\":{d},\"record_bytes\":{d},\"seconds\":{d:.6},\"commits_per_second\":{d:.1},\"ms_each\":{d:.3}}}\n", .{
        records, record, seconds, @as(f64, @floatFromInt(records)) / seconds, seconds * 1000 / @as(f64, @floatFromInt(records)),
    });
}

fn treeCreate(directory: [*:0]const u8, files: u64) void {
    const root: i32 = @intCast(checked(linux.openat(-100, directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open tree root"));
    defer _ = linux.close(root);
    var payload: [1024]u8 = undefined;
    fill(&payload, 0x13198a2e03707344);
    const started = monotonic();
    var index: u64 = 0;
    while (index < files) : (index += 1) {
        var directory_name: [32]u8 = undefined;
        const group = std.mem.printSentinel(&directory_name, "d{d}", .{index % 32}, 0) catch unreachable;
        const made = linux.mkdirat(root, group.ptr, 0o755);
        if (errnoCode(made)) |code| if (code != uapi.EEXIST) fail("create directory: errno {d}", .{code});
        var path: [96]u8 = undefined;
        const relative = std.mem.printSentinel(&path, "d{d}/f{d}", .{ index % 32, index }, 0) catch fail("path too long", .{});
        const descriptor: i32 = @intCast(checked(linux.openat(root, relative.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, 0o600), "create file"));
        var offset: usize = 0;
        while (offset < payload.len) {
            const count = checked(linux.write(descriptor, payload[0..].ptr + offset, payload.len - offset), "write file");
            offset += count;
        }
        _ = linux.close(descriptor);
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"tree-create\",\"files\":{d},\"seconds\":{d:.6},\"files_per_second\":{d:.1}}}\n", .{
        files, seconds, @as(f64, @floatFromInt(files)) / seconds,
    });
}

fn deleteDirectory(parent: i32, name: [*:0]const u8, files: *u64) void {
    const descriptor: i32 = @intCast(checked(linux.openat(parent, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open directory for deletion"));
    defer _ = linux.close(descriptor);
    var buffer: [4096]u8 align(8) = undefined;
    while (true) {
        const count = checked(linux.syscall3(.getdents64, @intCast(descriptor), @intFromPtr(&buffer), buffer.len), "read directory");
        if (count == 0) break;
        var offset: usize = 0;
        while (offset < count) {
            if (count - offset < 20) fail("invalid directory entry", .{});
            const length = std.mem.readInt(u16, buffer[offset + 16 ..][0..2], .little);
            if (length < 20 or length > count - offset) fail("invalid directory entry", .{});
            const entry_type = buffer[offset + 18];
            const raw = buffer[offset + 19 .. offset + length];
            const end = std.mem.indexOfScalar(u8, raw, 0) orelse fail("invalid entry name", .{});
            const entry = raw[0..end];
            offset += length;
            if (std.mem.eql(u8, entry, ".") or std.mem.eql(u8, entry, "..")) continue;
            var child: [300]u8 = undefined;
            @memcpy(child[0..entry.len], entry);
            child[entry.len] = 0;
            if (entry_type == 4) {
                deleteDirectory(descriptor, @ptrCast(child[0..entry.len :0]), files);
                _ = checked(linux.unlinkat(descriptor, @ptrCast(child[0..entry.len :0]), 0x200), "remove directory");
            } else {
                _ = checked(linux.unlinkat(descriptor, @ptrCast(child[0..entry.len :0]), 0), "remove file");
                files.* += 1;
            }
        }
    }
}

fn treeDelete(directory: [*:0]const u8) void {
    const root: i32 = @intCast(checked(linux.openat(-100, directory, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true }, 0), "open tree root"));
    defer _ = linux.close(root);
    var files: u64 = 0;
    const started = monotonic();
    var index: u64 = 0;
    while (index < 32) : (index += 1) {
        var name: [16]u8 = undefined;
        const group = std.mem.printSentinel(&name, "d{d}", .{index}, 0) catch unreachable;
        deleteDirectory(root, group.ptr, &files);
        _ = checked(linux.unlinkat(root, group.ptr, 0x200), "remove directory");
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"tree-delete\",\"files\":{d},\"seconds\":{d:.6},\"files_per_second\":{d:.1}}}\n", .{
        files, seconds, @as(f64, @floatFromInt(files)) / seconds,
    });
}

fn execLoop(count: u64, argv: []const [*:0]const u8) void {
    const started = monotonic();
    var completed: u64 = 0;
    var index: u64 = 0;
    while (index < count) : (index += 1) {
        const child = linux.syscall5(.clone, 17, 0, 0, 0, 0); // fork, SIGCHLD
        if (errnoCode(child)) |code| fail("fork: errno {d}", .{code});
        if (child == 0) {
            _ = linux.execve(argv[0], @ptrCast(argv.ptr), @ptrCast(std.c.environ));
            std.process.exit(127);
        }
        var status: u32 = 0;
        while (true) {
            const rc = linux.syscall4(.wait4, child, @intFromPtr(&status), 0, 0);
            if (errnoCode(rc) == uapi.EINTR) continue;
            _ = checked(rc, "wait for child");
            break;
        }
        if ((status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0) completed += 1;
    }
    const elapsed = monotonic() - started;
    const seconds = @as(f64, @floatFromInt(elapsed)) / 1e9;
    emit("{{\"op\":\"exec-loop\",\"count\":{d},\"completed\":{d},\"seconds\":{d:.6},\"ms_each\":{d:.3}}}\n", .{
        count, completed, seconds, seconds * 1000 / @as(f64, @floatFromInt(count)),
    });
}

pub fn main(init: std.process.Init.Minimal) void {
    const args = init.args.vector;
    if (args.len < 2) fail("usage: throughput-probe <action> ...", .{});
    const action = std.mem.span(args[1]);
    if (std.mem.eql(u8, action, "seq-write") and args.len == 5) {
        return sequentialWrite(args[2], number(std.mem.span(args[3])), std.mem.eql(u8, std.mem.span(args[4]), "sync"), false);
    }
    if (std.mem.eql(u8, action, "seq-write-zeros") and args.len == 5) {
        return sequentialWrite(args[2], number(std.mem.span(args[3])), std.mem.eql(u8, std.mem.span(args[4]), "sync"), true);
    }
    if (std.mem.eql(u8, action, "seq-read") and args.len == 4) return sequentialRead(args[2], number(std.mem.span(args[3])));
    if (std.mem.eql(u8, action, "rand-4k") and args.len == 6) {
        return randomWrites(args[2], number(std.mem.span(args[3])), number(std.mem.span(args[4])), std.mem.eql(u8, std.mem.span(args[5]), "sync"));
    }
    if (std.mem.eql(u8, action, "metadata") and args.len == 4) return metadata(args[2], number(std.mem.span(args[3])));
    if (std.mem.eql(u8, action, "append-sync") and args.len == 5) return appendSync(args[2], number(std.mem.span(args[3])), @intCast(number(std.mem.span(args[4]))));
    if (std.mem.eql(u8, action, "tree-create") and args.len == 4) return treeCreate(args[2], number(std.mem.span(args[3])));
    if (std.mem.eql(u8, action, "tree-delete") and args.len == 3) return treeDelete(args[2]);
    if (std.mem.eql(u8, action, "exec-loop") and args.len >= 5 and std.mem.eql(u8, std.mem.span(args[3]), "--")) {
        return execLoop(number(std.mem.span(args[2])), args[4..]);
    }
    fail("unknown or incomplete action", .{});
}
