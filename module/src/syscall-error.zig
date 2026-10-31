// Raw Linux call results, decoded once for every freestanding NNS tool.
// These binaries carry no libc, so std.os.linux returns raw usize values;
// std.posix.errno decodes them without the libc-backed posix layer, and the
// typed error replaces the hand-rolled two's-complement range checks.
const std = @import("std");

pub const Errno = std.posix.E;

/// Decodes a raw call result. Returns null when the call succeeded.
pub fn errno(result: anytype) ?Errno {
    const code = std.posix.errno(result);
    return if (code == .SUCCESS) null else code;
}

/// Binds a program name to the shared failure policy: report the operation and
/// the typed error on stderr, then exit. Each tool keeps its own prefix without
/// duplicating the decoding or the exit rule.
pub fn Program(comptime name: []const u8) type {
    return struct {
        pub fn fail(comptime format: []const u8, arguments: anytype) noreturn {
            std.debug.print(name ++ ": " ++ format ++ "\n", arguments);
            std.process.exit(1);
        }

        pub fn check(result: usize, operation: []const u8) usize {
            if (errno(result)) |code| fail("{s}: {t}", .{ operation, code });
            return result;
        }
    };
}

test "raw results decode to typed errors" {
    try std.testing.expectEqual(@as(?Errno, null), errno(@as(usize, 0)));
    try std.testing.expectEqual(@as(?Errno, .NOENT), errno(@as(isize, -2)));
    try std.testing.expectEqual(@as(?Errno, .PERM), errno(@as(isize, -1)));
    try std.testing.expectEqual(@as(?Errno, .INTR), errno(@as(isize, -4)));
    // Values outside the errno window are ordinary results, not errors.
    try std.testing.expectEqual(@as(?Errno, null), errno(@as(isize, -4096)));
}
