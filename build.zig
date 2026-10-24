const std = @import("std");
const Translator = @import("translate_c").Translator;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .os_tag = .linux, .abi = .musl } });
    const optimize = b.standardOptimizeOption(.{});
    const arch = b.option(std.Target.Cpu.Arch, "arch", "Android CPU architecture") orelse target.result.cpu.arch;
    if (arch != .aarch64 and arch != .x86_64) @panic("NNS supports aarch64 and x86_64");
    const sysroot = b.option([]const u8, "android-sysroot", "NDK toolchain/sysroot for Android binaries");
    const headers = b.option([]const u8, "linux-headers", "Target Linux UAPI include directory");
    const translate_c = b.dependency("translate_c", .{ .optimize = .small });
    const all = b.step("all", "Install all native artifacts (requires Android sysroot and Linux headers)");
    const tests = b.step("test", "Run sandbox-safe native tests");
    const host = b.resolveTargetQuery(.{ .cpu_arch = b.graph.host.result.cpu.arch, .os_tag = .linux, .abi = .musl });

    const launcher = executable(b, "nix-enter", "module/src/nix-enter.zig", target, optimize, false);
    install(b, all, "nix-enter", launcher);
    const launcher_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("module/src/nix-enter.zig"),
        .target = host,
        .optimize = .debug,
    }) });
    const test_launcher = b.step("test-nix-enter", "Run launcher allocation and environment unit tests");
    test_launcher.dependOn(&b.addRunArtifact(launcher_tests).step);
    tests.dependOn(test_launcher);
    const namespace_launcher = executable(b, "nix-enter-test", "module/src/nix-enter.zig", host, .debug, false);
    const namespace_tests = pythonTest(b, "tests/test-userns.py", namespace_launcher);
    b.step("test-userns", "Run launcher tests outside the Nix sandbox (requires user namespaces)").dependOn(&namespace_tests.step);

    const glibc = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .gnu });
    const bridge = addBridge(b, "nns-dns", glibc, optimize);
    const dns = b.step("dns", "Install the libc-neutral preload and Android resolver");
    dns.dependOn(&b.addInstallArtifact(bridge, .{}).step);
    all.dependOn(dns);
    const terminal_step = b.step("rish-terminal", "Install the Android terminal supervisor");
    all.dependOn(terminal_step);
    if (sysroot) |root| {
        const triple = b.fmt("{s}-linux-android", .{@tagName(arch)});
        const android = b.resolveTargetQuery(.{ .cpu_arch = arch, .os_tag = .linux, .abi = .android, .android_api_level = 29 });
        const libdir = b.fmt("{s}/usr/lib/{s}/29", .{ root, triple });
        const libc_file = b.addWriteFiles().add("android-libc.conf", b.fmt(
            \\include_dir={s}/usr/include
            \\sys_include_dir={s}/usr/include/{s}
            \\crt_dir={s}
            \\cc_dir={s}
            \\msvc_lib_dir=
            \\kernel32_lib_dir=
            \\darwin_sdk_dir=
            \\
        , .{ root, root, triple, libdir, libdir }));
        inline for (.{
            .{ "nns-resolver", "module/src/dns-resolver.zig", "module/src/dns-resolver.h", dns },
            .{ "nns-rish-terminal", "integrations/shizuku/rish-terminal.zig", "integrations/shizuku/rish-terminal.h", terminal_step },
        }) |artifact| {
            const exe = executable(b, artifact[0], artifact[1], android, optimize, true);
            exe.linkage = .dynamic;
            exe.setLibCFile(libc_file);
            exe.root_module.addLibraryPath(.{ .cwd_relative = libdir });
            const translation: Translator = .init(translate_c, .{
                .c_source_file = b.path(artifact[2]),
                .target = android,
                .optimize = optimize,
                .libc_file = libc_file,
            });
            exe.root_module.addImport("c", translation.mod);
            artifact[3].dependOn(&b.addInstallArtifact(exe, .{}).step);
        }
    } else {
        const missing = b.addFail("pass -Dandroid-sysroot=/path/to/ndk/toolchain/sysroot");
        dns.dependOn(&missing.step);
        terminal_step.dependOn(&missing.step);
    }

    const wire_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("module/src/dns-wire.zig"),
        .target = b.graph.host,
        .optimize = .debug,
    }) });
    const test_dns = b.step("test-dns", "Run wire validation and host glibc preload tests");
    test_dns.dependOn(&b.addRunArtifact(wire_tests).step);
    test_dns.dependOn(&pythonTest(b, "tests/test-dns.py", addBridge(b, "nns-dns-test", b.graph.host, .debug)).step);
    tests.dependOn(test_dns);

    const terminal = terminalExecutable(b, translate_c, "nns-rish-terminal-host", host, .debug);
    const test_terminal = b.step("test-rish-terminal", "Run native terminal transport tests");
    test_terminal.dependOn(&pythonTest(b, "tests/test-rish-terminal.py", terminal).step);
    tests.dependOn(test_terminal);
    const control = controlExecutable(b, translate_c, "nns-service-control", target, optimize);
    install(b, all, "service-control", control);
    const test_control = b.step("test-service-control", "Run the FIFO client against real runsv");
    const control_run = b.addSystemCommand(&.{"env"});
    control_run.addArtifactArg2(controlExecutable(b, translate_c, "nns-service-control-test", host, .debug), .{ .prefix = "NNS_SERVICE_CONTROL=" });
    control_run.addArg("python3");
    control_run.addFileArg2(b.path("experiments/activation/test-service-control.py"), .{});
    test_control.dependOn(&control_run.step);
    tests.dependOn(test_control);

    const storage_step = b.step("storage", "Install the storage helper and controllers");
    all.dependOn(storage_step);
    if (headers) |include| {
        const translation: Translator = .init(translate_c, .{
            .c_source_file = b.path("module/src/storage-linux.h"),
            .target = target,
            .optimize = optimize,
            .link_libc = false,
        });
        translation.addSystemIncludePath(.{ .cwd_relative = include });
        const storage_module = b.createModule(.{
            .root_source_file = b.path("module/src/nns-storage.zig"),
            .target = target,
            .optimize = optimize,
            .pic = true,
        });
        storage_module.addImport("linux_uapi", translation.mod);
        const storage_namespace_tests = b.addTest(.{ .root_module = storage_module });
        const test_storage_namespace = b.step("test-storage-namespace", "Test inherited storage namespace identity");
        test_storage_namespace.dependOn(&b.addRunArtifact(storage_namespace_tests).step);
        const supervisor = executable(b, "nns-storage-supervisor", "integrations/module/storage/supervisor.zig", target, optimize, false);
        supervisor.root_module.addImport("linux_uapi", translation.mod);
        storage_step.dependOn(&b.addInstallArtifact(supervisor, .{}).step);
        const module_controller = executable(b, "nns-storage-module-controller", "integrations/module/storage/controller.zig", target, optimize, false);
        module_controller.root_module.addImport("linux_uapi", translation.mod);
        module_controller.root_module.addImport("storage", storage_module);
        storage_step.dependOn(&b.addInstallArtifact(module_controller, .{}).step);
        const handoff_fixture = executable(b, "nns-storage-handoff-fixture", "tests/module-storage/handoff.zig", target, optimize, false);
        handoff_fixture.root_module.addImport("linux_uapi", translation.mod);
        const handoff_fixture_step = b.step("storage-handoff-fixture", "Install the storage handoff test executable");
        handoff_fixture_step.dependOn(&b.addInstallArtifact(handoff_fixture, .{}).step);
        const storage = executable(b, "nns-storage", "module/src/nns-storage.zig", target, optimize, false);
        storage.root_module.addImport("linux_uapi", translation.mod);
        storage_step.dependOn(&b.addInstallArtifact(storage, .{}).step);
    } else storage_step.dependOn(&b.addFail("pass -Dlinux-headers=/path/to/target/linux/include").step);

    const probes = b.step("native-probes", "Install static namespace and storage probes");
    all.dependOn(probes);
    inline for (.{ "fscrypt-policy", "storage-execution" }) |name| {
        const probe = cExecutable(b, name, target, optimize, &.{b.fmt("tests/android/{s}.c", .{name})});
        probe.root_module.addCMacro("_GNU_SOURCE", "1");
        if (headers) |include| probe.root_module.addSystemIncludePath(.{ .cwd_relative = include });
        install(b, probes, name, probe);
    }
    b.getInstallStep().dependOn(all);
}

fn executable(b: *std.Build, name: []const u8, source: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, libc: bool) *std.Build.Step.Compile {
    return b.addExecutable(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
        .link_libc = libc,
    }), .name = name });
}

fn install(b: *std.Build, all: *std.Build.Step, name: []const u8, artifact: *std.Build.Step.Compile) void {
    const step = b.step(name, b.fmt("Install {s}", .{name}));
    step.dependOn(&b.addInstallArtifact(artifact, .{}).step);
    all.dependOn(step);
}

fn pythonTest(b: *std.Build, source: []const u8, artifact: *std.Build.Step.Compile) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{"python3"});
    run.addFileArg2(b.path(source), .{});
    run.addArtifactArg2(artifact, .{});
    return run;
}

fn terminalExecutable(b: *std.Build, translate_c: *std.Build.Dependency, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const exe = executable(b, name, "integrations/shizuku/rish-terminal.zig", target, optimize, true);
    const translation: Translator = .init(translate_c, .{ .c_source_file = b.path("integrations/shizuku/rish-terminal.h"), .target = target, .optimize = optimize });
    exe.root_module.addImport("c", translation.mod);
    return exe;
}

fn controlExecutable(b: *std.Build, translate_c: *std.Build.Dependency, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const exe = executable(b, name, "experiments/activation/service-control.zig", target, optimize, true);
    const translation: Translator = .init(translate_c, .{ .c_source_file = b.path("experiments/activation/service-control.h"), .target = target, .optimize = optimize });
    exe.root_module.addImport("c", translation.mod);
    return exe;
}

fn cExecutable(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize, sources: []const []const u8) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{ .name = name, .linkage = .static, .root_module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = optimize != .debug,
    }) });
    exe.root_module.addCSourceFiles(.{ .files = sources, .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" } });
    return exe;
}

fn addBridge(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Step.Compile {
    const library = b.addLibrary(.{ .name = name, .linkage = .dynamic, .root_module = b.createModule(.{
        .root_source_file = b.path("module/src/dns-bridge.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug,
    }) });
    // This library must resolve libc symbols in the loading process, not pin glibc.
    library.linker_allow_shlib_undefined = true;
    return library;
}
