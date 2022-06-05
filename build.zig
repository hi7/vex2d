const std = @import("std");
const App = @import("mach/build.zig").App;
const Options = @import("mach/build.zig").Options;
const gpu_dawn = @import("mach/gpu-dawn/build.zig");
const glfw = @import("mach/glfw/build.zig");

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    const app = App.init(b, .{
        .name = "vex2d",
        .src = "src/main.zig",
        .target = target,
        .deps = &[_]std.build.Pkg{},
    });
    app.setBuildMode(mode);
    app.link(.{});
    app.install();

    const run_cmd = app.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run vex2d");
    run_step.dependOn(&run_cmd.step);
}
