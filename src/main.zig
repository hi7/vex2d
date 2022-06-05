const std = @import("std");
const mach = @import("mach");
const gpu = @import("gpu");
const glfw = @import("glfw");

const App = @This();

const Vertex = struct {
    pos: @Vector(4, f32),
    uv: @Vector(2, f32),
};

const vertices = [_]Vertex{
    .{ .pos = .{ -1, -1, 0, 1 }, .uv = .{ 0, 0 } },
    .{ .pos = .{ 1, -1, 0, 1 }, .uv = .{ 1, 0 } },
    .{ .pos = .{ 1, 1, 0, 1 }, .uv = .{ 1, 1 } },
    .{ .pos = .{ -1, 1, 0, 1 }, .uv = .{ 0, 1 } },
};
const indices = [_]u16{ 0, 1, 2, 2, 3, 0 };

const UniformBufferObject = struct {
    resolution: @Vector(2, f32),
    time: f32,
};

var timer: std.time.Timer = undefined;

pipeline: gpu.RenderPipeline,
queue: gpu.Queue,
vertex_buffer: gpu.Buffer,
index_buffer: gpu.Buffer,
uniform_buffer: gpu.Buffer,
bind_group: gpu.BindGroup,

fragment_shader_file: std.fs.File,
fragment_shader_code: [:0]const u8,
last_mtime: i128,

pub fn init(app: *App, engine: *mach.Engine) !void {
    timer = try std.time.Timer.start();

    // On linux if we don't set a minimum size, you can squish the window to 0 pixels of width and height,
    // this makes some strange effects when that happens, so it's better to leave a minimum size to avoid that,
    // this doesn't prevent you from minimizing the window.
    try engine.setOptions(.{
        .size_min = .{ .width = 20, .height = 20 },
    });

    var fragment_file: std.fs.File = undefined;
    var last_mtime: i128 = undefined;
    if (std.fs.cwd().openFile("src/frag.wgsl", .{ .mode = .read_only })) |file| {
        fragment_file = file;
        if (file.stat()) |stat| {
            last_mtime = stat.mtime;
        } else |err| {
            std.debug.print("Something went wrong when attempting to stat file: {}\n", .{err});
            return;
        }
    } else |e| {
        std.debug.print("Something went wrong when attempting to open file: {}\n", .{e});
        return;
    }
    var code = try fragment_file.readToEndAllocOptions(engine.allocator, std.math.maxInt(u16), null, 1, 0);

    const queue = engine.device.getQueue();

    const vertex_buffer = engine.device.createBuffer(&.{
        .usage = .{ .vertex = true },
        .size = @sizeOf(Vertex) * vertices.len,
        .mapped_at_creation = true,
    });
    var vertex_mapped = vertex_buffer.getMappedRange(Vertex, 0, vertices.len);
    std.mem.copy(Vertex, vertex_mapped, vertices[0..]);
    vertex_buffer.unmap();

    const index_buffer = engine.device.createBuffer(&.{
        .usage = .{ .index = true },
        .size = @sizeOf(u16) * indices.len,
        .mapped_at_creation = true,
    });
    var index_mapped = index_buffer.getMappedRange(@TypeOf(indices[0]), 0, indices.len);
    std.mem.copy(u16, index_mapped, indices[0..]);
    index_buffer.unmap();

    // We need a bgl to bind the UniformBufferObject, but it is also needed for creating
    // the RenderPipeline, so we pass it to recreatePipeline as a pointer
    var bgl: gpu.BindGroupLayout = undefined;
    const pipeline = recreatePipeline(engine, code, &bgl);

    const uniform_buffer = engine.device.createBuffer(&.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(UniformBufferObject),
        .mapped_at_creation = false,
    });
    const bind_group = engine.device.createBindGroup(
        &gpu.BindGroup.Descriptor{
            .layout = bgl,
            .entries = &.{
                gpu.BindGroup.Entry.buffer(0, uniform_buffer, 0, @sizeOf(UniformBufferObject)),
            },
        },
    );

    app.pipeline = pipeline;
    app.queue = queue;
    app.vertex_buffer = vertex_buffer;
    app.index_buffer = index_buffer;
    app.uniform_buffer = uniform_buffer;
    app.bind_group = bind_group;

    app.fragment_shader_file = fragment_file;
    app.fragment_shader_code = code;
    app.last_mtime = last_mtime;

    bgl.release();
}

pub fn deinit(app: *App, engine: *mach.Engine) void {
    app.fragment_shader_file.close();
    engine.allocator.free(app.fragment_shader_code);

    app.vertex_buffer.release();
    app.index_buffer.release();
    app.uniform_buffer.release();
    app.bind_group.release();
}

pub fn update(app: *App, engine: *mach.Engine) !bool {
    while (engine.pollEvent()) |event| {
        switch (event) {
            .key_press => |ev| {
                if (ev.key == .space)
                    engine.setShouldClose(true);
            },
            else => {},
        }
    }

    if (app.fragment_shader_file.stat()) |stat| {
        if (app.last_mtime < stat.mtime) {
            std.log.info("The fragment shader has been changed", .{});
            app.last_mtime = stat.mtime;
            app.fragment_shader_file.seekTo(0) catch unreachable;
            app.fragment_shader_code = app.fragment_shader_file.readToEndAllocOptions(engine.allocator, std.math.maxInt(u32), null, 1, 0) catch |err| {
                std.log.err("Err: {}", .{err});
                return false;
            };
            app.pipeline = recreatePipeline(engine, app.fragment_shader_code, null);
        }
    } else |err| {
        std.log.err("Something went wrong when attempting to stat file: {}\n", .{err});
    }

    const back_buffer_view = engine.swap_chain.?.getCurrentTextureView();
    const color_attachment = gpu.RenderPassColorAttachment{
        .view = back_buffer_view,
        .resolve_target = null,
        .clear_value = std.mem.zeroes(gpu.Color),
        .load_op = .clear,
        .store_op = .store,
    };

    const encoder = engine.device.createCommandEncoder(null);
    const render_pass_info = gpu.RenderPassEncoder.Descriptor{
        .color_attachments = &.{color_attachment},
        .depth_stencil_attachment = null,
    };

    const time = @intToFloat(f32, timer.read()) / @as(f32, std.time.ns_per_s);
    const ubo = UniformBufferObject{
        .resolution = .{ @intToFloat(f32, engine.current_desc.width), @intToFloat(f32, engine.current_desc.height) },
        .time = time,
    };
    encoder.writeBuffer(app.uniform_buffer, 0, UniformBufferObject, &.{ubo});

    const pass = encoder.beginRenderPass(&render_pass_info);
    pass.setVertexBuffer(0, app.vertex_buffer, 0, @sizeOf(Vertex) * vertices.len);
    pass.setIndexBuffer(app.index_buffer, .uint16, 0, @sizeOf(u16) * indices.len);
    pass.setPipeline(app.pipeline);
    pass.setBindGroup(0, app.bind_group, &.{0});
    pass.drawIndexed(indices.len, 1, 0, 0, 0);
    pass.end();
    pass.release();

    var command = encoder.finish(null);
    encoder.release();

    app.queue.submit(&.{command});
    command.release();
    engine.swap_chain.?.present();
    back_buffer_view.release();

    return true;
}

fn recreatePipeline(engine: *mach.Engine, fragment_shader_code: [:0]const u8, bgl: ?*gpu.BindGroupLayout) gpu.RenderPipeline {
    const vs_module = engine.device.createShaderModule(&.{
        .label = "vertex shader",
        .code = .{ .wgsl = @embedFile("vert.wgsl") },
    });
    defer vs_module.release();
    const vertex_attributes = [_]gpu.VertexAttribute{
        .{ .format = .float32x4, .offset = @offsetOf(Vertex, "pos"), .shader_location = 0 },
        .{ .format = .float32x2, .offset = @offsetOf(Vertex, "uv"), .shader_location = 1 },
    };
    const vertex_buffer_layout = gpu.VertexBufferLayout{
        .array_stride = @sizeOf(Vertex),
        .step_mode = .vertex,
        .attribute_count = vertex_attributes.len,
        .attributes = &vertex_attributes,
    };

    // Check wether the fragment shader code compiled successfully, if not
    // print the validation layer error and show a black screen
    engine.device.pushErrorScope(.validation);
    var fs_module = engine.device.createShaderModule(&gpu.ShaderModule.Descriptor{
        .label = "fragment shader",
        .code = .{ .wgsl = fragment_shader_code },
    });
    var error_occurred: bool = false;
    // popErrorScope() returns always true, (unless maybe it fails to capture the error scope?)
    _ = engine.device.popErrorScope(&gpu.ErrorCallback.init(*bool, &error_occurred, struct {
        fn callback(ctx: *bool, typ: gpu.ErrorType, message: [*:0]const u8) void {
            if (typ != .noError) {
                std.debug.print("🔴🔴🔴🔴:\n{s}\n", .{message});
                ctx.* = true;
            }
        }
    }.callback));
    if (error_occurred) {
        fs_module = engine.device.createShaderModule(&gpu.ShaderModule.Descriptor{
            .label = "black screen fragment shader",
            .code = .{ .wgsl = @embedFile("black_screen_frag.wgsl") },
        });
    }
    defer fs_module.release();

    const blend = gpu.BlendState{
        .color = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .zero,
        },
        .alpha = .{
            .operation = .add,
            .src_factor = .one,
            .dst_factor = .zero,
        },
    };
    const color_target = gpu.ColorTargetState{
        .format = engine.swap_chain_format,
        .blend = &blend,
        .write_mask = gpu.ColorWriteMask.all,
    };
    const fragment = gpu.FragmentState{
        .module = fs_module,
        .entry_point = "main",
        .targets = &.{color_target},
        .constants = null,
    };

    const bgle = gpu.BindGroupLayout.Entry.buffer(0, .{ .fragment = true }, .uniform, true, 0);
    // bgl is needed outside, for the creation of the uniform_buffer in main
    const bgl_tmp = engine.device.createBindGroupLayout(
        &gpu.BindGroupLayout.Descriptor{
            .entries = &.{bgle},
        },
    );
    defer {
        // In frame we don't need to use bgl, so we can release it inside this function, else we pass bgl
        if (bgl == null) {
            bgl_tmp.release();
        } else {
            bgl.?.* = bgl_tmp;
        }
    }

    const bind_group_layouts = [_]gpu.BindGroupLayout{bgl_tmp};
    const pipeline_layout = engine.device.createPipelineLayout(&.{
        .bind_group_layouts = &bind_group_layouts,
    });
    defer pipeline_layout.release();

    const pipeline_descriptor = gpu.RenderPipeline.Descriptor{
        .fragment = &fragment,
        .layout = pipeline_layout,
        .depth_stencil = null,
        .vertex = .{
            .module = vs_module,
            .entry_point = "main",
            .buffers = &.{vertex_buffer_layout},
        },
        .multisample = .{
            .count = 1,
            .mask = 0xFFFFFFFF,
            .alpha_to_coverage_enabled = false,
        },
        .primitive = .{
            .front_face = .ccw,
            .cull_mode = .none,
            .topology = .triangle_list,
            .strip_index_format = .none,
        },
    };

    // Create the render pipeline. Even if the shader compilation succeeded, this could fail if the
    // shader is missing a `main` entrypoint.
    engine.device.pushErrorScope(.validation);
    const pipeline = engine.device.createRenderPipeline(&pipeline_descriptor);
    // popErrorScope() returns always true, (unless maybe it fails to capture the error scope?)
    _ = engine.device.popErrorScope(&gpu.ErrorCallback.init(*bool, &error_occurred, struct {
        fn callback(ctx: *bool, typ: gpu.ErrorType, message: [*:0]const u8) void {
            if (typ != .noError) {
                std.debug.print("🔴🔴🔴🔴:\n{s}\n", .{message});
                ctx.* = true;
            }
        }
    }.callback));
    if (error_occurred) {
        // Retry with black_screen_frag which we know will work.
        return recreatePipeline(engine, @embedFile("black_screen_frag.wgsl"), bgl);
    }
    return pipeline;
}
