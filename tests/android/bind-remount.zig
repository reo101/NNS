// Bind-remount probe: remount /nix with one permission mask and nothing else.
// The caller supplies a mask that must fit the four supported flags.
const std = @import("std");
const linux = std.os.linux;

const allowed: u32 = linux.MS.RDONLY | linux.MS.NOSUID | linux.MS.NODEV | linux.MS.NOEXEC;

pub fn main(init: std.process.Init.Minimal) void {
    const arguments = init.args.vector;
    if (arguments.len != 2) std.process.exit(2);
    const mask = std.fmt.parseInt(u32, std.mem.span(arguments[1]), 0) catch std.process.exit(2);
    if (mask & ~allowed != 0) std.process.exit(2);
    const result = linux.mount(null, "/nix", null, linux.MS.BIND | linux.MS.REMOUNT | mask, 0);
    if (std.posix.errno(result) != .SUCCESS) {
        std.debug.print("bind-remount: {t}\n", .{std.posix.errno(result)});
        std.process.exit(1);
    }
}
