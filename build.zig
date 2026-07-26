const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("shrinkpic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/imports.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translate_c.addIncludePath(b.path("src"));
    translate_c.linkSystemLibrary("webp", .{});
    translate_c.linkSystemLibrary("turbojpeg", .{});

    const c_mod = translate_c.createModule();

    mod.addImport("c_api", c_mod);

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

    exe.root_module.linkSystemLibrary("webp", .{});
    exe.root_module.linkSystemLibrary("turbojpeg", .{});
    exe.root_module.addIncludePath(b.path("src"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/stb_impl.c"),
        .flags = &.{ "-std=c99", "-O3" },
    });

    b.installArtifact(exe);

    // Run
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    // Test
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "shrinkpic", .module = mod },
            .{ .name = "c_api", .module = c_mod },
        },
    }) });

    exe_tests.root_module.linkSystemLibrary("webp", .{});
    exe_tests.root_module.linkSystemLibrary("turbojpeg", .{});
    exe_tests.root_module.addIncludePath(b.path("src"));
    exe_tests.root_module.addCSourceFile(.{
        .file = b.path("src/stb_impl.c"),
        .flags = &.{ "-std=c99", "-O3" },
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
