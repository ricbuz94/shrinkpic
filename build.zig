const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("shrinkpic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/imports.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("turbojpeg", .{});
    translate_c.linkSystemLibrary("png", .{});

    const c_mod = translate_c.createModule();
    c_mod.linkSystemLibrary("turbojpeg", .{});
    c_mod.linkSystemLibrary("png", .{});

    const exe = b.addExecutable(.{
        .name = "shrinkpic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "shrinkpic", .module = mod },
                .{ .name = "c_api", .module = c_mod },
            },
        }),
    });
    exe.root_module.linkSystemLibrary("turbojpeg", .{});
    exe.root_module.linkSystemLibrary("png", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
