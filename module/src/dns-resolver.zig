// Linked to Bionic, not glibc. The Android loader initializes libc normally;
// getaddrinfo then uses Android's resolver under the caller's unchanged UID.
const std = @import("std");
const wire = @import("dns-wire.zig");
const c = @cImport({
    @cDefine("_Nonnull", "");
    @cDefine("_Nullable", "");
    @cInclude("netdb.h");
    @cInclude("errno.h");
});

pub export fn main(argc: c_int, argv: [*]const [*:0]const u8) c_int {
    resolve(argc, argv) catch return 1;
    return 0;
}

fn resolve(argc: c_int, argv: [*]const [*:0]const u8) !void {
    if (argc != 9) return error.Arguments;
    var hints: c.struct_addrinfo = std.mem.zeroes(c.struct_addrinfo);
    hints.ai_flags = try std.fmt.parseInt(c_int, std.mem.span(argv[1]), 10);
    hints.ai_family = try std.fmt.parseInt(c_int, std.mem.span(argv[2]), 10);
    hints.ai_socktype = try std.fmt.parseInt(c_int, std.mem.span(argv[3]), 10);
    hints.ai_protocol = try std.fmt.parseInt(c_int, std.mem.span(argv[4]), 10);
    const node = if (std.mem.eql(u8, std.mem.span(argv[5]), "1")) argv[6] else null;
    const service = if (std.mem.eql(u8, std.mem.span(argv[7]), "1")) argv[8] else null;
    var result: [*c]c.struct_addrinfo = null;
    const rc = c.getaddrinfo(node, service, &hints, &result);
    const saved_errno = c.__errno().*;
    defer if (result != null) c.freeaddrinfo(result);
    var header: wire.Header = .{ .status = wire.glibcError(rc), .err = if (rc == c.EAI_SYSTEM) saved_errno else 0 };
    var records: [wire.max_results]wire.Record = undefined;
    var ai = result;
    while (rc == 0 and ai != null) : (ai = ai.*.ai_next) {
        if (header.count == records.len) return error.TooManyResults;
        var r: wire.Record = .{ .family = ai.*.ai_family, .socktype = ai.*.ai_socktype, .protocol = ai.*.ai_protocol, .addrlen = ai.*.ai_addrlen };
        if (r.addrlen > r.addr.len or ai.*.ai_addr == null) return error.InvalidAddress;
        @memcpy(r.addr[0..r.addrlen], @as([*]const u8, @ptrCast(ai.*.ai_addr))[0..r.addrlen]);
        if (ai.*.ai_canonname != null) {
            const name = std.mem.span(ai.*.ai_canonname);
            if (name.len >= r.canon.len) return error.NameTooLong;
            r.canonlen = @intCast(name.len);
            @memcpy(r.canon[0..name.len], name);
        }
        if (!r.valid()) return error.InvalidAddress;
        records[header.count] = r;
        header.count += 1;
    }
    try wire.writeAll(1, std.mem.asBytes(&header));
    for (records[0..header.count]) |*r| try wire.writeAll(1, std.mem.asBytes(r));
}
