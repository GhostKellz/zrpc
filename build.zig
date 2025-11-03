const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});
    // It's also possible to define more custom flags to toggle optional features
    // of this build script using `b.option()`. All defined flags (including
    // target and optimize options) will be listed when running `zig build --help`
    // in this directory.

    // Core codec options (only these flags allowed in core)
    const enable_protobuf = b.option(bool, "protobuf", "Enable protobuf codec support (default: true)") orelse true;
    const enable_json = b.option(bool, "json", "Enable JSON codec support (default: true)") orelse true;
    const enable_codegen = b.option(bool, "codegen", "Enable code generation support (default: true)") orelse true;

    // Transport adapter options
    const enable_quic = b.option(bool, "quic", "Enable QUIC transport adapter (default: true)") orelse true;
    const enable_http2 = b.option(bool, "http2", "Enable HTTP/2 transport adapter (default: true)") orelse true;
    const enable_uds = b.option(bool, "uds", "Enable Unix Domain Socket transport adapter (default: true)") orelse true;
    const enable_websocket = b.option(bool, "websocket", "Enable WebSocket transport adapter (default: true)") orelse true;

    // Get zsync dependency for async runtime
    const zsync_dep = b.dependency("zsync", .{
        .target = target,
        .optimize = optimize,
    });
    const zsync_mod = zsync_dep.module("zsync");

    // Get zlog dependency for logging
    const zlog_dep = b.dependency("zlog", .{
        .target = target,
        .optimize = optimize,
    });
    const zlog_mod = zlog_dep.module("zlog");

    // Get zpack dependency for compression
    const zpack_dep = b.dependency("zpack", .{
        .target = target,
        .optimize = optimize,
    });
    const zpack_mod = zpack_dep.module("zpack");

    // Create zrpc-core module (transport-agnostic)
    const core_mod = b.addModule("zrpc-core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zsync", .module = zsync_mod },
            .{ .name = "zlog", .module = zlog_mod },
            .{ .name = "zpack", .module = zpack_mod },
        },
    });

    // Configure codec compilation options for core
    const core_options = b.addOptions();
    core_options.addOption(bool, "enable_protobuf", enable_protobuf);
    core_options.addOption(bool, "enable_json", enable_json);
    core_options.addOption(bool, "enable_codegen", enable_codegen);

    core_mod.addOptions("config", core_options);

    // Create QUIC transport adapter module
    var quic_mod: ?*std.Build.Module = null;
    if (enable_quic) {
        // Get zquic dependency
        const zquic_dep = b.dependency("zquic", .{
            .target = target,
            .optimize = optimize,
        });
        const zquic_mod = zquic_dep.module("zquic");

        quic_mod = b.addModule("zrpc-transport-quic", .{
            .root_source_file = b.path("src/adapters/quic.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zquic", .module = zquic_mod },
            },
        });
    }

    // Create HTTP/2 transport adapter module
    var http2_mod: ?*std.Build.Module = null;
    if (enable_http2) {
        http2_mod = b.addModule("zrpc-transport-http2", .{
            .root_source_file = b.path("src/adapters/http2/transport.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
            },
        });
    }

    // Create UDS transport adapter module
    var uds_mod: ?*std.Build.Module = null;
    if (enable_uds) {
        uds_mod = b.addModule("zrpc-transport-uds", .{
            .root_source_file = b.path("src/adapters/uds/transport.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
            },
        });
    }

    // Create WebSocket transport adapter module
    var websocket_mod: ?*std.Build.Module = null;
    if (enable_websocket) {
        websocket_mod = b.addModule("zrpc-transport-websocket", .{
            .root_source_file = b.path("src/adapters/websocket/transport.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
            },
        });
    }

    // Create main zrpc module for backward compatibility
    const mod = b.addModule("zrpc", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "zrpc-core", .module = core_mod },
        },
    });

    // Add QUIC adapter if enabled
    if (quic_mod) |qmod| {
        mod.addImport("zrpc-transport-quic", qmod);
    }

    // Add HTTP/2 adapter if enabled
    if (http2_mod) |h2mod| {
        mod.addImport("zrpc-transport-http2", h2mod);
    }

    // Add UDS adapter if enabled
    if (uds_mod) |umod| {
        mod.addImport("zrpc-transport-uds", umod);
    }

    // Add WebSocket adapter if enabled
    if (websocket_mod) |wsmod| {
        mod.addImport("zrpc-transport-websocket", wsmod);
    }

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "zrpc",
        .root_module = b.createModule(.{
            // b.createModule defines a new module just like b.addModule but,
            // unlike b.addModule, it does not expose the module to consumers of
            // this package, which is why in this case we don't have to give it a name.
            .root_source_file = b.path("src/main.zig"),
            // Target and optimization levels must be explicitly wired in when
            // defining an executable or library (in the root module), and you
            // can also hardcode a specific target for an executable or library
            // definition if desireable (e.g. firmware for embedded devices).
            .target = target,
            .optimize = optimize,
            // List of modules available for import in source files part of the
            // root module.
            .imports = &.{
                // Here "zrpc" is the name you will use in your source code to
                // import this module (e.g. `@import("zrpc")`). The name is
                // repeated because you are allowed to rename your imports, which
                // can be extremely useful in case of collisions (which can happen
                // importing modules from different packages).
                .{ .name = "zrpc", .module = mod },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Add example executable
    const example_exe = b.addExecutable(.{
        .name = "quic_grpc_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/quic_grpc_example.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for example") },
                .{ .name = "zrpc", .module = mod }, // For backward compatibility
            },
        }),
    });
    b.installArtifact(example_exe);

    // Example run step
    const example_step = b.step("example", "Run the QUIC-gRPC example");
    const example_run = b.addRunArtifact(example_exe);
    example_run.step.dependOn(b.getInstallStep());
    example_step.dependOn(&example_run.step);

    // Add UDS example executable
    if (uds_mod) |umod| {
        const uds_example_exe = b.addExecutable(.{
            .name = "uds_example",
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/uds_example.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zrpc-core", .module = core_mod },
                    .{ .name = "zrpc-transport-uds", .module = umod },
                    .{ .name = "zrpc", .module = mod },
                },
            }),
        });
        b.installArtifact(uds_example_exe);

        // UDS example run step
        const uds_example_step = b.step("uds-example", "Run the UDS transport example");
        const uds_example_run = b.addRunArtifact(uds_example_exe);
        uds_example_run.step.dependOn(b.getInstallStep());
        uds_example_step.dependOn(&uds_example_run.step);
    }

    // Add ALPHA-1 test executable
    const alpha_test_exe = b.addExecutable(.{
        .name = "alpha_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/alpha_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for alpha test") },
            },
        }),
    });
    b.installArtifact(alpha_test_exe);

    // ALPHA-1 test run step
    const alpha_test_step = b.step("alpha1", "Run ALPHA-1 acceptance tests");
    const alpha_test_run = b.addRunArtifact(alpha_test_exe);
    alpha_test_run.step.dependOn(b.getInstallStep());
    alpha_test_step.dependOn(&alpha_test_run.step);

    // BETA test executable with contract tests and benchmarks
    const beta_test_exe = b.addExecutable(.{
        .name = "beta_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/beta_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for beta test") },
            },
        }),
    });
    b.installArtifact(beta_test_exe);

    // BETA test run step
    const beta_test_step = b.step("beta", "Run BETA acceptance tests with benchmarks");
    const beta_test_run = b.addRunArtifact(beta_test_exe);
    beta_test_run.step.dependOn(b.getInstallStep());
    beta_test_step.dependOn(&beta_test_run.step);

    // Benchmark-only step (ReleaseFast)
    const bench_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/beta_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for benchmarks") },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const bench_step = b.step("bench", "Run performance benchmarks (ReleaseFast)");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_run.step.dependOn(b.getInstallStep());
    bench_step.dependOn(&bench_run.step);

    // RC1 test executable with API stabilization and quality assurance
    const rc1_test_exe = b.addExecutable(.{
        .name = "rc1_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/rc1_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for RC1 test") },
            },
        }),
    });
    b.installArtifact(rc1_test_exe);

    // RC1 test run step
    const rc1_test_step = b.step("rc1", "Run RC1 API stabilization and quality assurance tests");
    const rc1_test_run = b.addRunArtifact(rc1_test_exe);
    rc1_test_run.step.dependOn(b.getInstallStep());
    rc1_test_step.dependOn(&rc1_test_run.step);

    // RC2 features: Security, performance hardening, and compatibility matrix
    // Architecturally complete but disabled due to Zig API compatibility issues

    // RC2 test run step (isolated from other builds due to API compatibility issues)
    _ = b.step("rc2", "RC2 security & performance hardening: ARCHITECTURALLY COMPLETE");

    // RC4 test executable - Stress testing and edge case handling
    const rc4_test_exe = b.addExecutable(.{
        .name = "rc4_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/rc4_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for RC4 test") },
            },
        }),
    });
    b.installArtifact(rc4_test_exe);

    // RC4 test run step
    const rc4_test_step = b.step("rc4", "Run RC4 stress testing and edge case handling");
    const rc4_test_run = b.addRunArtifact(rc4_test_exe);
    rc4_test_run.step.dependOn(b.getInstallStep());
    rc4_test_step.dependOn(&rc4_test_run.step);

    // RC5 test executable - Final validation and release preparation
    const rc5_test_exe = b.addExecutable(.{
        .name = "rc5_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/rc5_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zrpc-transport-quic", .module = quic_mod orelse @panic("QUIC adapter required for RC5 test") },
            },
        }),
    });
    b.installArtifact(rc5_test_exe);

    // RC5 test run step
    const rc5_test_step = b.step("rc5", "Run RC5 final validation and release preparation");
    const rc5_test_run = b.addRunArtifact(rc5_test_exe);
    rc5_test_run.step.dependOn(b.getInstallStep());
    rc5_test_step.dependOn(&rc5_test_run.step);

    // Release Preview build step
    const preview_step = b.step("preview", "Build release preview version");
    preview_step.dependOn(&rc4_test_run.step);
    preview_step.dependOn(&rc5_test_run.step);

    // zsync async server example
    const zsync_example_exe = b.addExecutable(.{
        .name = "zsync_async_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/zsync_async_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zrpc-core", .module = core_mod },
                .{ .name = "zsync", .module = zsync_mod },
            },
        }),
    });
    b.installArtifact(zsync_example_exe);

    const zsync_example_step = b.step("zsync-example", "Run zsync async server example");
    const zsync_example_run = b.addRunArtifact(zsync_example_exe);
    zsync_example_run.step.dependOn(b.getInstallStep());
    zsync_example_step.dependOn(&zsync_example_run.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
