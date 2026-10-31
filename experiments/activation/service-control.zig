// FIFO command client for a runit supervisor. The only platform interfaces are
// POSIX open/write/sigaction and the typed file stat from std.Io.
const std = @import("std");
const linux = std.os.linux;

fn fail(message: []const u8) noreturn {
    std.debug.print("nns-service-control: {s}\n", .{message});
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arguments = init.minimal.args.vector;
    if (arguments.len != 3) fail("usage: nns-service-control SERVICE_DIRECTORY up|down|once|exit");

    const commands = std.StaticStringMap(u8).initComptime(.{
        .{ "up", 'u' }, .{ "down", 'd' }, .{ "once", 'o' }, .{ "exit", 'x' },
    });
    const command = commands.get(std.mem.span(arguments[2])) orelse fail("invalid command");
    const path = try allocator.printSentinel("{s}/supervise/control", .{std.mem.span(arguments[1])}, 0);
    defer allocator.free(path);

    // FIFO commands are documented by runsv(8), not a runit library ABI. A
    // closed reader raises SIGPIPE; the write must fail with EPIPE instead.
    std.posix.sigaction(.PIPE, &.{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);
    const descriptor = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .NONBLOCK = true, .NOFOLLOW = true, .CLOEXEC = true }, 0) catch
        fail("cannot open supervise/control FIFO");
    const file: std.Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = true } };
    defer file.close(init.io);
    const metadata = file.stat(init.io) catch fail("cannot inspect supervise/control");
    if (metadata.kind != .named_pipe) fail("supervise/control is not a FIFO");
    const written = linux.write(descriptor, &.{command}, 1);
    if (std.posix.errno(written) != .SUCCESS) fail("cannot write control command");
    if (written != 1) fail("short control command");
    // A successful write is a submitted request, not acknowledged completion.
}
