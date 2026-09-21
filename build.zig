const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const sysroot = b.option([]const u8, "android-sysroot", "NDK toolchain/sysroot (required for the Android helper)");
    const android = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android, .android_api_level = 29 });
    const glibc = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu });

    const bridge = addBridge(b, "nns-dns", glibc, optimize);
    b.installArtifact(bridge);
    if (sysroot) |root| {
        // Zig knows the Android ABI, but the NDK supplies Bionic headers, link
        // stubs and CRT objects. Generate its libc descriptor in the build
        // cache instead of checking machine-specific paths into the repo.
        const libdir = b.fmt("{s}/usr/lib/aarch64-linux-android/29", .{root});
        const libc_file = b.addWriteFiles().add("android-libc.conf", b.fmt(
            \\include_dir={s}/usr/include
            \\sys_include_dir={s}/usr/include/aarch64-linux-android
            \\crt_dir={s}
            \\static_crt_dir=
            \\gcc_dir=
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\
        , .{ root, root, libdir }));
        const resolver = b.addExecutable(.{
            .name = "nns-resolver",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("module/src/dns-resolver.zig"),
                .target = android,
                .optimize = optimize,
                .link_libc = true,
                .strip = true,
            }),
        });
        resolver.setLibCFile(libc_file);
        resolver.root_module.addLibraryPath(.{ .cwd_relative = libdir });
        b.installArtifact(resolver);
    } else {
        b.getInstallStep().dependOn(&b.addFail("pass -Dandroid-sysroot=/path/to/ndk/toolchains/llvm/prebuilt/<host>/sysroot").step);
    }

    const tests = b.step("test", "Run wire validation and host glibc preload integration tests (no NDK needed)");
    const unit = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("module/src/dns-wire.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }) });
    tests.dependOn(&b.addRunArtifact(unit).step);
    const host_bridge = addBridge(b, "nns-dns-host", b.graph.host, .Debug);
    const integration = b.addSystemCommand(&.{"python3"});
    integration.addFileArg(b.path("tests/test-dns.py"));
    integration.addArtifactArg(host_bridge);
    tests.dependOn(&integration.step);
}

fn addBridge(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const library = b.addLibrary(.{
        .name = name,
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("module/src/dns-bridge.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
    // Resolve the small shared C ABI from the loading process. Linking glibc
    // here would make LD_PRELOAD fatal for Android/Bionic shell children.
    library.linker_allow_shlib_undefined = true;
    return library;
}
