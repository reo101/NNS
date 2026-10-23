const std = @import("std");
const c = @import("c");

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

    // FIFO commands are documented by runsv(8), not a runit library ABI.
    _ = c.signal(c.SIGPIPE, @ptrCast(std.posix.SIG.IGN));
    const descriptor = c.open(path.ptr, c.O_WRONLY | c.O_NONBLOCK | c.O_NOFOLLOW | c.O_CLOEXEC);
    if (descriptor < 0) fail("cannot open supervise/control FIFO");
    defer _ = c.close(descriptor);
    const file: std.Io.File = .{ .handle = descriptor, .flags = .{ .nonblocking = true } };
    const metadata = file.stat(init.io) catch fail("cannot inspect supervise/control");
    if (metadata.kind != .named_pipe) fail("supervise/control is not a FIFO");
    if (c.write(descriptor, &command, 1) != 1) fail("cannot write control command");
    // A successful write is a submitted request, not acknowledged completion.
}
