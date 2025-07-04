const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const translate_c_tweaks = b.addExecutable(.{
        .name = "tc_tweaks",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/translate_c_tweaks.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    b.installArtifact(translate_c_tweaks);

    const mod_tests = b.addTest(.{ .root_module = translate_c_tweaks.root_module });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);

    const example = b.addExecutable(.{
        .name = "translate_c_strip_example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/example.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(example);

    const translate_c_example = b.addTranslateC(.{
        .root_source_file = b.path("src/test.h"),
        .target = target,
        .optimize = optimize,
    });

    const tweaked_c_mod = tweakTranslateC(b, .{
        .tweaks_artifact = translate_c_tweaks,
        .translate_c_step = translate_c_example,
        .prefix_trim_string = "SDL_",
    });
    example.root_module.addImport("sdl", tweaked_c_mod);
    example.root_module.addCSourceFile(.{ .file = b.path("src/test.c") });

    const run_step = b.step("example", "Run the example");
    const run_cmd = b.addRunArtifact(example);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}

pub fn tweakTranslateC(b: *std.Build, options: struct {
    dependency_name: []const u8 = "translate_c_tweaks",
    /// override fetching the tweaks artifact from your dependencies
    tweaks_artifact: ?*std.Build.Step.Compile = null,
    target: ?std.Build.ResolvedTarget = null,
    optimize: ?std.builtin.OptimizeMode = null,
    translate_c_step: *std.Build.Step.TranslateC,
    prefix_trim_string: []const u8,
}) *std.Build.Module {
    const tweak_exe = tweak_exe: {
        if (options.tweaks_artifact) |tweak_exe| break :tweak_exe tweak_exe;

        has_dep_info: {
            break :tweak_exe b.dependency(options.dependency_name, .{
                .target = options.target orelse break :has_dep_info,
                .optimize = options.optimize orelse break :has_dep_info,
            }).artifact("tc_tweaks");
        }

        break :tweak_exe b.dependency(options.dependency_name, .{}).artifact("tc_tweaks");
    };

    const run_tc_tweaks = b.addRunArtifact(tweak_exe);

    run_tc_tweaks.addFileArg(options.translate_c_step.getOutput());

    const tweaked_tc_mod = b.createModule(.{
        .root_source_file = run_tc_tweaks.addOutputFileArg("translate_c_tweaked.zig"),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });

    run_tc_tweaks.addArg(options.prefix_trim_string);

    return tweaked_tc_mod;
}
