const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // Define the zflag library module with src/main.zig as the root source file.
    const mod = b.addModule("zflag", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
    });

    // Create a test executable from the module.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Register the "test" step.
    const test_step = b.step("test", "Run all zflag tests");
    test_step.dependOn(&run_mod_tests.step);
}
