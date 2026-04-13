// Copyright (c) 2026 Greg Turner <gmt@be-evil.net>
//
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = parseTestFilters(b, b.args);
    const opt_stress_tests = b.option(bool, "stress-tests", "Enable heavyweight Zig stress tests [default: false]") orelse false;

    // --------------------------------------------------
    // Feature options (mirroring pkgbuild configure flags)
    // --------------------------------------------------
    const opt_systemd = b.option(bool, "systemd", "Enable systemd integration [default: true on Linux]") orelse
        (target.result.os.tag == .linux);
    const opt_utempter = b.option(bool, "utempter", "Enable libutempter support [default: true on Linux]") orelse
        (target.result.os.tag == .linux);
    const opt_sixel = b.option(bool, "sixel", "Enable sixel image support [default: true]") orelse true;
    const opt_utf8proc = b.option(bool, "utf8proc", "Enable utf8proc for Unicode width [default: false]") orelse false;
    const opt_fuzzing = b.option(bool, "fuzzing", "Build fuzz targets [default: false]") orelse false;

    // --------------------------------------------------
    // Build-options module
    // --------------------------------------------------
    const build_options = addBuildOptions(b, .{
        .target = target,
        .opt_systemd = opt_systemd,
        .opt_utempter = opt_utempter,
        .opt_sixel = opt_sixel,
        .opt_utf8proc = opt_utf8proc,
        .stress_tests = opt_stress_tests,
    });

    // --------------------------------------------------
    // Shared C compile flags
    // --------------------------------------------------
    const common_cflags: []const []const u8 = &.{
        "-std=gnu99",
        "-O2",
        "-Wall",
        "-Wno-unused-result",
        "-Isrc/compat",
        "-D_DEFAULT_SOURCE",
    };

    // --------------------------------------------------
    // Main executable
    // --------------------------------------------------
    const exe = b.addExecutable(.{
        .name = "zmux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zmux.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Attach build-options
    exe.root_module.addOptions("build_options", build_options);

    // C source bridges
    exe.root_module.addIncludePath(b.path("src/compat"));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg.c"), .flags = common_cflags });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg-buffer.c"), .flags = common_cflags });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/compat/freezero.c"), .flags = common_cflags });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/compat/explicit_bzero.c"), .flags = common_cflags });
    exe.root_module.addCSourceFile(.{ .file = b.path("src/compat/zmux-regex.c"), .flags = common_cflags });

    // System libraries  (link_libc + system libs must go on the exe's root_module or the exe directly)
    exe.linkLibC();
    exe.linkSystemLibrary("event_core");
    exe.linkSystemLibrary("ncursesw");

    if (opt_systemd) exe.linkSystemLibrary("systemd");
    if (opt_utempter) exe.linkSystemLibrary("utempter");
    if (opt_utf8proc) exe.linkSystemLibrary("utf8proc");

    // image.zig and image-sixel.zig are pure Zig; no addCSourceFile needed.
    // They are conditionally reachable via the enable_sixel build option.

    b.installArtifact(exe);

    const smoke_shell = b.addExecutable(.{
        .name = "hello-shell-ansi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/hello-shell-ansi.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(smoke_shell);

    // --------------------------------------------------
    // `zig build run`
    // --------------------------------------------------
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zmux").dependOn(&run_cmd.step);

    // --------------------------------------------------
    // `zig build smoke` – fast harness against zmux
    // --------------------------------------------------
    const smoke_step = b.step("smoke", "Run the fast smoke harness against zig-out/bin/zmux");
    smoke_step.dependOn(b.getInstallStep());
    const smoke_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-fast" });
    smoke_cmd.step.dependOn(b.getInstallStep());
    smoke_step.dependOn(&smoke_cmd.step);

    // --------------------------------------------------
    // `zig build smoke-oracle` – oracle harness against installed tmux
    // --------------------------------------------------
    const oracle_step = b.step("smoke-oracle", "Run the oracle smoke harness against installed tmux");
    const oracle_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-oracle" });
    oracle_cmd.step.dependOn(b.getInstallStep());
    oracle_step.dependOn(&oracle_cmd.step);

    // --------------------------------------------------
    // `zig build smoke-recursive-attach` – nested recursive attach characterization
    // --------------------------------------------------
    const recursive_attach_step = b.step(
        "smoke-recursive-attach",
        "Run the nested recursive attach characterization harness",
    );
    recursive_attach_step.dependOn(b.getInstallStep());
    const recursive_attach_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-recursive" });
    recursive_attach_cmd.step.dependOn(b.getInstallStep());
    recursive_attach_step.dependOn(&recursive_attach_cmd.step);

    // --------------------------------------------------
    // `zig build smoke-soak` – heavy soak harness against zmux
    // --------------------------------------------------
    const soak_step = b.step("smoke-soak", "Run the heavy soak harness against zig-out/bin/zmux");
    soak_step.dependOn(b.getInstallStep());
    const soak_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-soak" });
    soak_cmd.step.dependOn(b.getInstallStep());
    soak_step.dependOn(&soak_cmd.step);

    // --------------------------------------------------
    // `zig build smoke-docker` – Docker + SSH harness against system tmux
    // --------------------------------------------------
    const docker_step = b.step("smoke-docker", "Run the Docker + SSH smoke harness");
    const docker_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-docker" });
    docker_cmd.step.dependOn(b.getInstallStep());
    docker_step.dependOn(&docker_cmd.step);

    // --------------------------------------------------
    // `zig build smoke-all` – fast local + oracle + docker suites
    // --------------------------------------------------
    const smoke_all_step = b.step("smoke-all", "Run fast local, oracle, and Docker smoke suites");
    smoke_all_step.dependOn(b.getInstallStep());
    const smoke_all_cmd = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "smoke-all" });
    smoke_all_cmd.step.dependOn(b.getInstallStep());
    smoke_all_step.dependOn(&smoke_all_cmd.step);

    // --------------------------------------------------
    // `zig build test`
    // --------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zmux.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
        // Timed orchestration is handled by regress/test_orchestrator.py,
        // which runs each test individually in its own sandbox.
        .test_runner = .{
            .path = b.path("src/test-runner.zig"),
            .mode = .server,
        },
    });
    unit_tests.root_module.addOptions("build_options", build_options);
    unit_tests.root_module.addIncludePath(b.path("src/compat"));
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg.c"), .flags = common_cflags });
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg-buffer.c"), .flags = common_cflags });
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/freezero.c"), .flags = common_cflags });
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/explicit_bzero.c"), .flags = common_cflags });
    unit_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/zmux-regex.c"), .flags = common_cflags });
    unit_tests.linkLibC();
    unit_tests.linkSystemLibrary("event_core");
    unit_tests.linkSystemLibrary("ncursesw");
    const test_step = b.step("test", "Run Zig unit tests");
    const run_unit_tests = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "zig-unit", "--zig-test-binary" });
    run_unit_tests.step.dependOn(b.getInstallStep());
    run_unit_tests.addFileArg(unit_tests.getEmittedBin());
    addTestFilterArgs(run_unit_tests, test_filters);
    test_step.dependOn(&run_unit_tests.step);

    const test_compile_step = b.step("test-compile", "Compile Zig unit tests without running");
    test_compile_step.dependOn(&unit_tests.step);

    const stress_build_options = addBuildOptions(b, .{
        .target = target,
        .opt_systemd = opt_systemd,
        .opt_utempter = opt_utempter,
        .opt_sixel = opt_sixel,
        .opt_utf8proc = opt_utf8proc,
        .stress_tests = true,
    });
    const stress_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/zmux.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = test_filters,
        .test_runner = .{
            .path = b.path("src/test-runner.zig"),
            .mode = .server,
        },
    });
    stress_tests.root_module.addOptions("build_options", stress_build_options);
    stress_tests.root_module.addIncludePath(b.path("src/compat"));
    stress_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg.c"), .flags = common_cflags });
    stress_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/imsg-buffer.c"), .flags = common_cflags });
    stress_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/freezero.c"), .flags = common_cflags });
    stress_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/explicit_bzero.c"), .flags = common_cflags });
    stress_tests.root_module.addCSourceFile(.{ .file = b.path("src/compat/zmux-regex.c"), .flags = common_cflags });
    stress_tests.linkLibC();
    stress_tests.linkSystemLibrary("event_core");
    stress_tests.linkSystemLibrary("ncursesw");
    const stress_test_step = b.step("test-stress", "Run heavyweight Zig stress tests");
    const run_stress_tests = b.addSystemCommand(&.{ "python3", "regress/test_orchestrator.py", "zig-stress", "--zig-test-binary" });
    run_stress_tests.step.dependOn(b.getInstallStep());
    run_stress_tests.addFileArg(stress_tests.getEmittedBin());
    addTestFilterArgs(run_stress_tests, test_filters);
    stress_test_step.dependOn(&run_stress_tests.step);

    const stress_test_compile_step = b.step("test-stress-compile", "Compile Zig stress tests without running");
    stress_test_compile_step.dependOn(&stress_tests.step);

    // --------------------------------------------------
    // `zig build fuzz`
    // --------------------------------------------------
    if (opt_fuzzing) {
        // The fuzz target imports from the zmux source tree
        const zmux_mod = b.createModule(.{
            .root_source_file = b.path("src/zmux.zig"),
            .target = target,
            .optimize = optimize,
        });
        zmux_mod.addOptions("build_options", build_options);
        zmux_mod.addIncludePath(b.path("src/compat"));
        zmux_mod.addCSourceFile(.{ .file = b.path("src/compat/imsg.c"), .flags = common_cflags });
        zmux_mod.addCSourceFile(.{ .file = b.path("src/compat/imsg-buffer.c"), .flags = common_cflags });
        zmux_mod.addCSourceFile(.{ .file = b.path("src/compat/freezero.c"), .flags = common_cflags });
        zmux_mod.addCSourceFile(.{ .file = b.path("src/compat/explicit_bzero.c"), .flags = common_cflags });
        zmux_mod.addCSourceFile(.{ .file = b.path("src/compat/zmux-regex.c"), .flags = common_cflags });

        const fuzz_input = b.addExecutable(.{
            .name = "zmux-input-fuzzer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("fuzz/input-fuzzer.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zmux", .module = zmux_mod },
                },
            }),
        });
        fuzz_input.linkLibC();
        fuzz_input.linkSystemLibrary("event_core");
        fuzz_input.linkSystemLibrary("ncursesw");
        b.installArtifact(fuzz_input);

        const fuzz_cmd_preprocess = b.addExecutable(.{
            .name = "zmux-cmd-preprocess-fuzzer",
            .root_module = b.createModule(.{
                .root_source_file = b.path("fuzz/cmd-preprocess-fuzzer.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zmux", .module = zmux_mod },
                },
            }),
        });
        fuzz_cmd_preprocess.linkLibC();
        fuzz_cmd_preprocess.linkSystemLibrary("event_core");
        fuzz_cmd_preprocess.linkSystemLibrary("ncursesw");
        b.installArtifact(fuzz_cmd_preprocess);

        const fuzz_step = b.step("fuzz", "Build fuzz targets (-Dfuzzing=true required)");
        fuzz_step.dependOn(&fuzz_input.step);
        fuzz_step.dependOn(&fuzz_cmd_preprocess.step);

        const fuzz_smoke = b.step("fuzz-smoke", "Timed corpus replay for the fuzz targets (requires install + -Dfuzzing=true)");
        const fuzz_smoke_cmd = b.addSystemCommand(&.{
            "python3",
            "regress/test_orchestrator.py",
            "fuzz-smoke",
            "--input-fuzzer",
        });
        fuzz_smoke_cmd.step.dependOn(b.getInstallStep());
        fuzz_smoke_cmd.addFileArg(fuzz_input.getEmittedBin());
        fuzz_smoke_cmd.addArg("--cmd-preprocess-fuzzer");
        fuzz_smoke_cmd.addFileArg(fuzz_cmd_preprocess.getEmittedBin());
        fuzz_smoke.dependOn(&fuzz_smoke_cmd.step);
    }
}

const BuildOptionsConfig = struct {
    target: std.Build.ResolvedTarget,
    opt_systemd: bool,
    opt_utempter: bool,
    opt_sixel: bool,
    opt_utf8proc: bool,
    stress_tests: bool,
};

fn addBuildOptions(b: *std.Build, config: BuildOptionsConfig) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "have_systemd", config.opt_systemd);
    options.addOption(bool, "have_utempter", config.opt_utempter);
    options.addOption(bool, "enable_sixel", config.opt_sixel);
    options.addOption(bool, "have_utf8proc", config.opt_utf8proc);
    options.addOption(bool, "stress_tests", config.stress_tests);
    options.addOption([]const u8, "version", "3.6a-dev");
    options.addOption([]const u8, "zmux_conf", "/etc/zmux.conf:~/.zmux.conf:$XDG_CONFIG_HOME/zmux/zmux.conf:~/.config/zmux/zmux.conf");
    options.addOption([]const u8, "zmux_sock", "$ZMUX_TMPDIR:/tmp");
    options.addOption([]const u8, "zmux_term", "tmux-256color");
    options.addOption([]const u8, "zmux_lock_cmd", "vlock");
    _ = config.target;
    return options;
}

fn parseTestFilters(b: *std.Build, maybe_args: ?[]const []const u8) []const []const u8 {
    const args = maybe_args orelse return &.{};

    var filters: std.ArrayList([]const u8) = .{};
    errdefer filters.deinit(b.allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--test-filter")) {
            i += 1;
            if (i >= args.len) {
                std.debug.panic("zig build test: missing value after --test-filter", .{});
            }
            filters.append(b.allocator, args[i]) catch @panic("OOM");
            continue;
        }
        std.debug.panic("zig build test: unsupported extra argument: {s}", .{arg});
    }

    return filters.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn addTestFilterArgs(cmd: *std.Build.Step.Run, filters: []const []const u8) void {
    for (filters) |filter| {
        cmd.addArg("--test-filter");
        cmd.addArg(filter);
    }
}
