// Private protocol between same-architecture NNS binaries. No pointers or
// libc structs cross the boundary. Both endpoints are little-endian Linux.
const std = @import("std");
const linux = std.os.linux;
pub const magic = 0x31444e4e; // NND1
pub const max_results = 64;
pub const af_inet = 2;
pub const af_inet6 = 10;
pub const Header = extern struct { magic: u32 = magic, status: i32 = 0, err: i32 = 0, count: u32 = 0 };
pub const Record = extern struct {
    family: i32 = 0,
    socktype: i32 = 0,
    protocol: i32 = 0,
    addrlen: u32 = 0,
    canonlen: u32 = 0,
    addr: [28]u8 = @splat(0),
    canon: [256]u8 = @splat(0),

    pub fn valid(r: *const Record) bool {
        return ((r.family == af_inet and r.addrlen == 16) or (r.family == af_inet6 and r.addrlen == 28)) and
            std.mem.readInt(u16, r.addr[0..2], .little) == r.family and
            r.canonlen < r.canon.len and
            std.mem.indexOfScalar(u8, r.canon[0..r.canonlen], 0) == null;
    }
};

pub fn signed(rc: usize) isize {
    return @bitCast(rc);
}
pub fn writeAll(fd: i32, bytes: []const u8) !void {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = signed(linux.write(fd, bytes[pos..].ptr, bytes.len - pos));
        if (n == -4) continue;
        if (n <= 0) return error.Write;
        pos += @intCast(n);
    }
}

// glibc and Bionic disagree on AI_NUMERICSERV/ADDRCONFIG/ALL/V4MAPPED.
// GNU IDN extensions have no Bionic equivalent: reject, never fall back to
// glibc DNS (which could bypass the Android resolver's privacy policy).
const glibc_passive = 0x1;
const glibc_canonname = 0x2;
const glibc_numerichost = 0x4;
const glibc_v4mapped = 0x8;
const glibc_all = 0x10;
const glibc_addrconfig = 0x20;
const glibc_numericserv = 0x400;
const bionic_numericserv = 0x8;
const bionic_addrconfig = 0x400;
const bionic_v4mapped = 0x800;
const bionic_all = 0x100;

pub fn bionicFlags(flags: i32, family: i32) !i32 {
    const known: i32 = glibc_passive | glibc_canonname | glibc_numerichost | glibc_v4mapped |
        glibc_all | glibc_addrconfig | glibc_numericserv;
    if (flags & ~known != 0) return error.BadFlags;
    var result = flags & (glibc_passive | glibc_canonname | glibc_numerichost);
    if (flags & glibc_numericserv != 0) result |= bionic_numericserv;
    if (flags & glibc_addrconfig != 0) result |= bionic_addrconfig;
    // V4MAPPED/ALL have no effect unless AF_INET6 was requested.
    if (family == af_inet6) {
        if (flags & glibc_v4mapped != 0) result |= bionic_v4mapped;
        if (flags & glibc_all != 0) result |= bionic_all;
    }
    return result;
}
pub fn glibcError(rc: i32) i32 {
    return switch (rc) {
        0 => 0,
        1 => -9,
        2 => -3,
        3 => -1,
        4 => -4,
        5 => -6,
        6 => -10,
        7 => -5,
        8 => -2,
        9 => -8,
        10 => -7,
        11 => -11,
        12 => -1,
        13 => -8,
        14 => -12,
        else => -4,
    };
}

test "flags, errors and bounded IPv6 records" {
    try std.testing.expectEqual(@as(i32, 0x408), try bionicFlags(0x420, 0));
    try std.testing.expectEqual(@as(i32, 0x400), try bionicFlags(0x28, 0));
    try std.testing.expectEqual(@as(i32, 0x900), try bionicFlags(0x18, 10));
    try std.testing.expectError(error.BadFlags, bionicFlags(0x40, 0));
    try std.testing.expectEqual(@as(i32, -2), glibcError(8));
    try std.testing.expectEqual(@as(i32, -11), glibcError(11));
    var r: Record = .{ .family = 10, .addrlen = 28 };
    r.addr[0] = 10;
    r.addr[27] = 42; // preserve scope ID, not just sockaddr.sa_data
    try std.testing.expect(r.valid());
    r.addrlen = 16;
    try std.testing.expect(!r.valid());
    r.addrlen = 28;
    r.canonlen = 256;
    try std.testing.expect(!r.valid());
}
