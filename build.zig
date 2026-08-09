const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Core library module - pure domain logic, no I/O
    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core.zig"),
        .target = target,
    });

    // I/O module - file operations with atomic writes
    const io_mod = b.addModule("io", .{
        .root_source_file = b.path("src/io.zig"),
        .target = target,
    });

    // MCP module - JSON-RPC protocol handling
    const mcp_mod = b.addModule("mcp", .{
        .root_source_file = b.path("src/mcp.zig"),
        .target = target,
    });

    // CLI executable
    const exe = b.addExecutable(.{
        .name = "devjournal",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "core", .module = core_mod },
                .{ .name = "io", .module = io_mod },
                .{ .name = "mcp", .module = mcp_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run devjournal");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step - runs all tests
    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const io_tests = b.addTest(.{
        .root_module = io_mod,
    });
    const run_io_tests = b.addRunArtifact(io_tests);

    const mcp_tests = b.addTest(.{
        .root_module = mcp_mod,
    });
    const run_mcp_tests = b.addRunArtifact(mcp_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_io_tests.step);
    test_step.dependOn(&run_mcp_tests.step);
}
