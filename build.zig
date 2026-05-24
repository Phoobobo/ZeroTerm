const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .os_tag = .macos },
    });
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // macOS frameworks — AppKit for the window/event loop, Core Text + Metal
    // are linked ahead of the renderer landing so the build doesn't churn
    // when rendering work begins.
    const frameworks = [_][]const u8{
        "AppKit",
        "Foundation",
        "CoreGraphics",
        "CoreText",
        "QuartzCore",
        "Metal",
        "MetalKit",
    };
    for (frameworks) |fw| root_module.linkFramework(fw, .{});
    // libobjc.A.dylib comes in transitively via AppKit/Foundation; an
    // explicit linkSystemLibrary("objc") would require an SDK lib search path.

    // Point at the macOS SDK. Zig 0.16 doesn't auto-detect Xcode/CLT, so we
    // either honour $SDKROOT or fall back to the CLT location. The CLT SDK
    // ships frameworks, headers, and libraries needed by linkLibC and
    // linkFramework.
    const sdk_path = b.graph.environ_map.get("SDKROOT") orelse
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk";
    const fw_dir = b.pathJoin(&.{ sdk_path, "System/Library/Frameworks" });
    const inc_dir = b.pathJoin(&.{ sdk_path, "usr/include" });
    const lib_dir = b.pathJoin(&.{ sdk_path, "usr/lib" });
    root_module.addSystemFrameworkPath(.{ .cwd_relative = fw_dir });
    root_module.addSystemIncludePath(.{ .cwd_relative = inc_dir });
    root_module.addLibraryPath(.{ .cwd_relative = lib_dir });

    const exe = b.addExecutable(.{
        .name = "zeroterm",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run ZeroTerm");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest(.{ .root_module = root_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
