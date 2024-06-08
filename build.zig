const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "echo_tcp_server",
        .target = target,
        .optimize = optimize,
        .root_source_file = b.path("echo_tcp_server.zig"),
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Start echo tcp server");
    run_step.dependOn(&run_cmd.step);
}