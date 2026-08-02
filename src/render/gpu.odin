package render

import "core:fmt"

import "vendor:wgpu"

// The WGPU backend.
//
// docs/07-rendering.md fixes the resource lifetimes this file implements:
// static pipelines live for the application, trace-specific buffers live for
// the open trace, visible instance buffers use a ring sized for frames in
// flight, resizing recreates only size-dependent targets, and device loss
// tears down GPU resources and attempts one clean reinitialization.
//
// This is the only file in the project that names a GPU type. Everything above
// it produces draw lists, which is what lets the rest of the renderer be
// tested without a device.

// FRAMES_IN_FLIGHT sizes the instance buffer ring.
//
// docs/07: "resource destruction follows backend completion guarantees; Norn
// does not free in-flight buffers based on frame count guesses." The ring
// exists so a frame never writes into a buffer the GPU may still be reading —
// three is one more than the two frames a Fifo swapchain typically holds.
FRAMES_IN_FLIGHT :: 3

// Instance is the per-primitive data the shaders consume.
//
// One layout serves every pipeline. A shape ignores the UV fields and a glyph
// ignores the border width, which wastes a few bytes per instance but means
// one vertex layout, one buffer, and no repacking between batches.
Instance :: struct {
	// Rectangle in logical pixels: x0, y0, x1, y1.
	rect: [4]f32,
	color: [4]f32,
	color2: [4]f32,
	// Texture coordinates for glyph and texture pipelines.
	uv: [4]f32,
	// Corner radius or line thickness.
	extent: f32,
	// Border thickness for outlined shapes.
	border: f32,
	// Command kind, so one shader can branch between shape variants.
	kind: u32,
	padding: f32,
}

SHADER :: `
struct Uniforms {
    // Framebuffer size in logical pixels, for the pixel-to-clip transform.
    surface: vec2<f32>,
    padding: vec2<f32>,
};

struct Instance {
    @location(0) rect: vec4<f32>,
    @location(1) color: vec4<f32>,
    @location(2) color2: vec4<f32>,
    @location(3) uv: vec4<f32>,
    @location(4) params: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
    // Position within the primitive, for rounded corners and borders.
    @location(2) local: vec2<f32>,
    @location(3) size: vec2<f32>,
    @location(4) params: vec4<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    instance: Instance,
) -> VertexOutput {
    // Corners generated here rather than uploaded: a unit quad is the same
    // for every instance, so a vertex buffer for it would be pure overhead.
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0),
    );
    let corner = corners[vertex_index];

    let origin = instance.rect.xy;
    let size = instance.rect.zw - instance.rect.xy;
    let pixel = origin + corner * size;

    // Logical pixels to clip space, with Y downward as the UI expects.
    let clip = vec2<f32>(
        pixel.x / uniforms.surface.x * 2.0 - 1.0,
        1.0 - pixel.y / uniforms.surface.y * 2.0,
    );

    var out: VertexOutput;
    out.position = vec4<f32>(clip, 0.0, 1.0);
    out.color = instance.color;
    out.uv = mix(instance.uv.xy, instance.uv.zw, corner);
    out.local = corner * size;
    out.size = size;
    out.params = instance.params;
    return out;
}

// rounded_box_distance returns the signed distance to a rounded rectangle.
fn rounded_box_distance(point: vec2<f32>, half_size: vec2<f32>, radius: f32) -> f32 {
    let q = abs(point) - half_size + vec2<f32>(radius);
    return length(max(q, vec2<f32>(0.0))) + min(max(q.x, q.y), 0.0) - radius;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let kind = u32(in.params.z);
    let radius = in.params.x;
    let border = in.params.y;

    // Kinds match Command_Kind: 0 rect, 1 outline, 2 rounded, 6 circle.
    if (kind == 2u || kind == 6u) {
        let half_size = in.size * 0.5;
        let centred = in.local - half_size;
        let distance = rounded_box_distance(centred, half_size, radius);

        // One pixel of analytic antialiasing along the edge. Without it a
        // rounded corner stairsteps, which is the most visible artefact in an
        // interface made of small rectangles.
        let coverage = 1.0 - smoothstep(-0.5, 0.5, distance);
        return vec4<f32>(in.color.rgb, in.color.a * coverage);
    }

    if (kind == 1u) {
        // An outline is the region within the border width of any edge.
        let inside = in.local.x >= border && in.local.y >= border &&
                     in.local.x <= in.size.x - border &&
                     in.local.y <= in.size.y - border;
        if (inside) {
            discard;
        }
        return in.color;
    }

    return in.color;
}
`

GLYPH_SHADER :: `
struct Uniforms {
    surface: vec2<f32>,
    padding: vec2<f32>,
};

struct Instance {
    @location(0) rect: vec4<f32>,
    @location(1) color: vec4<f32>,
    @location(2) color2: vec4<f32>,
    @location(3) uv: vec4<f32>,
    @location(4) params: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
    @location(1) uv: vec2<f32>,
};

@group(0) @binding(0) var<uniform> uniforms: Uniforms;
@group(1) @binding(0) var atlas_texture: texture_2d<f32>;
@group(1) @binding(1) var atlas_sampler: sampler;

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    instance: Instance,
) -> VertexOutput {
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0),
    );
    let corner = corners[vertex_index];

    let origin = instance.rect.xy;
    let size = instance.rect.zw - instance.rect.xy;
    let pixel = origin + corner * size;

    let clip = vec2<f32>(
        pixel.x / uniforms.surface.x * 2.0 - 1.0,
        1.0 - pixel.y / uniforms.surface.y * 2.0,
    );

    var out: VertexOutput;
    out.position = vec4<f32>(clip, 0.0, 1.0);
    out.color = instance.color;
    out.uv = mix(instance.uv.xy, instance.uv.zw, corner);
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let coverage = textureSample(atlas_texture, atlas_sampler, in.uv).r;
    return vec4<f32>(in.color.rgb, in.color.a * coverage);
}
`

Uniforms :: struct {
	surface: [2]f32,
	padding: [2]f32,
}

// Ring_Buffer is one slot's instance storage.
Ring_Buffer :: struct {
	buffer:   wgpu.Buffer,
	capacity: int,
}

// Backend owns every GPU resource.
Backend :: struct {
	device: wgpu.Device,
	queue:  wgpu.Queue,
	format: wgpu.TextureFormat,

	// Static for the application lifetime, per docs/07.
	shape_pipeline: wgpu.RenderPipeline,
	glyph_pipeline: wgpu.RenderPipeline,
	uniform_layout: wgpu.BindGroupLayout,
	atlas_layout:   wgpu.BindGroupLayout,
	uniform_buffer: wgpu.Buffer,
	uniform_group:  wgpu.BindGroup,
	sampler:        wgpu.Sampler,

	// Instance ring, one slot per frame in flight.
	ring:  [FRAMES_IN_FLIGHT]Ring_Buffer,
	slot:  int,

	// Atlas resources by atlas identifier. Textures and views are held
	// alongside the bind groups so an atlas that gains a glyph can be
	// re-uploaded without recreating its binding.
	atlas_groups:   map[u32]wgpu.BindGroup,
	atlas_textures: map[u32]wgpu.Texture,
	atlas_views:    map[u32]wgpu.TextureView,

	// Scratch for converting commands to instances, reused each frame.
	instances: [dynamic]Instance,

	// Set when the device was lost, so the caller can reinitialize once.
	device_lost: bool,
}

// backend_init creates the static resources.
//
// Returns false rather than aborting: a caller may want to report the failure
// and continue running headless, which the CLI already does.
backend_init :: proc(
	backend: ^Backend,
	device: wgpu.Device,
	queue: wgpu.Queue,
	format: wgpu.TextureFormat,
	allocator := context.allocator,
) -> bool {
	backend.device = device
	backend.queue = queue
	backend.format = format
	backend.atlas_groups = make(map[u32]wgpu.BindGroup, 8, allocator)
	backend.atlas_textures = make(map[u32]wgpu.Texture, 8, allocator)
	backend.atlas_views = make(map[u32]wgpu.TextureView, 8, allocator)
	backend.instances = make([dynamic]Instance, 0, 4096, allocator)

	backend.uniform_buffer = wgpu.DeviceCreateBuffer(
		device,
		&wgpu.BufferDescriptor{usage = {.Uniform, .CopyDst}, size = size_of(Uniforms)},
	)

	uniform_entry := wgpu.BindGroupLayoutEntry {
		binding    = 0,
		visibility = {.Vertex},
		buffer     = {type = .Uniform, minBindingSize = size_of(Uniforms)},
	}
	backend.uniform_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&wgpu.BindGroupLayoutDescriptor{entryCount = 1, entries = &uniform_entry},
	)

	uniform_binding := wgpu.BindGroupEntry {
		binding = 0,
		buffer  = backend.uniform_buffer,
		size    = size_of(Uniforms),
	}
	backend.uniform_group = wgpu.DeviceCreateBindGroup(
		device,
		&wgpu.BindGroupDescriptor {
			layout = backend.uniform_layout,
			entryCount = 1,
			entries = &uniform_binding,
		},
	)

	atlas_entries := []wgpu.BindGroupLayoutEntry {
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	backend.atlas_layout = wgpu.DeviceCreateBindGroupLayout(
		device,
		&wgpu.BindGroupLayoutDescriptor {
			entryCount = len(atlas_entries),
			entries = raw_data(atlas_entries),
		},
	)

	backend.sampler = wgpu.DeviceCreateSampler(
		device,
		&wgpu.SamplerDescriptor {
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			magFilter = .Linear,
			minFilter = .Linear,
			mipmapFilter = .Nearest,
			maxAnisotropy = 1,
		},
	)

	if !create_pipelines(backend) {
		return false
	}

	for index in 0 ..< FRAMES_IN_FLIGHT {
		grow_ring_slot(backend, index, 4096)
	}
	return true
}

@(private)
instance_attributes :: proc() -> []wgpu.VertexAttribute {
	@(static) attributes := [5]wgpu.VertexAttribute {
		{format = .Float32x4, offset = 0, shaderLocation = 0},   // rect
		{format = .Float32x4, offset = 16, shaderLocation = 1},  // color
		{format = .Float32x4, offset = 32, shaderLocation = 2},  // color2
		{format = .Float32x4, offset = 48, shaderLocation = 3},  // uv
		{format = .Float32x4, offset = 64, shaderLocation = 4},  // params
	}
	return attributes[:]
}

@(private)
create_pipelines :: proc(backend: ^Backend) -> bool {
	attributes := instance_attributes()
	layout := wgpu.VertexBufferLayout {
		arrayStride    = size_of(Instance),
		stepMode       = .Instance,
		attributeCount = len(attributes),
		attributes     = raw_data(attributes),
	}

	blend := wgpu.BlendState {
		color = {srcFactor = .SrcAlpha, dstFactor = .OneMinusSrcAlpha, operation = .Add},
		alpha = {srcFactor = .One, dstFactor = .OneMinusSrcAlpha, operation = .Add},
	}

	// Shape pipeline: uniforms only.
	shape_module := wgpu.DeviceCreateShaderModule(
		backend.device,
		&wgpu.ShaderModuleDescriptor {
			nextInChain = &wgpu.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = SHADER,
			},
		},
	)
	if shape_module == nil {
		return false
	}
	defer wgpu.ShaderModuleRelease(shape_module)

	shape_layout := wgpu.DeviceCreatePipelineLayout(
		backend.device,
		&wgpu.PipelineLayoutDescriptor {
			bindGroupLayoutCount = 1,
			bindGroupLayouts = &backend.uniform_layout,
		},
	)
	defer wgpu.PipelineLayoutRelease(shape_layout)

	backend.shape_pipeline = wgpu.DeviceCreateRenderPipeline(
		backend.device,
		&wgpu.RenderPipelineDescriptor {
			layout = shape_layout,
			vertex = {
				module = shape_module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &layout,
			},
			fragment = &wgpu.FragmentState {
				module = shape_module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = backend.format,
					blend = &blend,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = ~u32(0)},
		},
	)
	if backend.shape_pipeline == nil {
		return false
	}

	// Glyph pipeline: uniforms plus an atlas.
	glyph_module := wgpu.DeviceCreateShaderModule(
		backend.device,
		&wgpu.ShaderModuleDescriptor {
			nextInChain = &wgpu.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = GLYPH_SHADER,
			},
		},
	)
	if glyph_module == nil {
		return false
	}
	defer wgpu.ShaderModuleRelease(glyph_module)

	glyph_layouts := []wgpu.BindGroupLayout{backend.uniform_layout, backend.atlas_layout}
	glyph_layout := wgpu.DeviceCreatePipelineLayout(
		backend.device,
		&wgpu.PipelineLayoutDescriptor {
			bindGroupLayoutCount = len(glyph_layouts),
			bindGroupLayouts = raw_data(glyph_layouts),
		},
	)
	defer wgpu.PipelineLayoutRelease(glyph_layout)

	backend.glyph_pipeline = wgpu.DeviceCreateRenderPipeline(
		backend.device,
		&wgpu.RenderPipelineDescriptor {
			layout = glyph_layout,
			vertex = {
				module = glyph_module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &layout,
			},
			fragment = &wgpu.FragmentState {
				module = glyph_module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = backend.format,
					blend = &blend,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = ~u32(0)},
		},
	)
	return backend.glyph_pipeline != nil
}

@(private)
grow_ring_slot :: proc(backend: ^Backend, slot: int, capacity: int) {
	if backend.ring[slot].buffer != nil {
		wgpu.BufferRelease(backend.ring[slot].buffer)
	}
	backend.ring[slot].buffer = wgpu.DeviceCreateBuffer(
		backend.device,
		&wgpu.BufferDescriptor {
			usage = {.Vertex, .CopyDst},
			size = u64(capacity * size_of(Instance)),
		},
	)
	backend.ring[slot].capacity = capacity
}

// upload_atlas uploads a glyph atlas and registers it for glyph batches.
//
// Idempotent: an atlas whose pixels have not changed since its last upload is
// skipped, so calling this every frame costs a boolean test. That is the
// intended usage, because a glyph rasterized lazily mid-frame invalidates the
// texture and the next frame must re-upload without the caller tracking which.
upload_atlas :: proc(backend: ^Backend, atlas: ^Atlas) {
	if atlas == nil || atlas.uploaded {
		return
	}

	texture, exists := backend.atlas_textures[atlas.id]
	if !exists {
		texture = wgpu.DeviceCreateTexture(
			backend.device,
			&wgpu.TextureDescriptor {
				usage = {.TextureBinding, .CopyDst},
				dimension = ._2D,
				size = {ATLAS_SIZE, ATLAS_SIZE, 1},
				format = .R8Unorm,
				mipLevelCount = 1,
				sampleCount = 1,
			},
		)
		backend.atlas_textures[atlas.id] = texture

		view := wgpu.TextureCreateView(texture, nil)
		backend.atlas_views[atlas.id] = view
		register_atlas(backend, atlas.id, view)
	}

	wgpu.QueueWriteTexture(
		backend.queue,
		&wgpu.TexelCopyTextureInfo{texture = texture, mipLevel = 0, aspect = .All},
		raw_data(atlas.pixels),
		uint(len(atlas.pixels)),
		&wgpu.TexelCopyBufferLayout{bytesPerRow = ATLAS_SIZE, rowsPerImage = ATLAS_SIZE},
		&wgpu.Extent3D{ATLAS_SIZE, ATLAS_SIZE, 1},
	)
	atlas.uploaded = true
}

// register_atlas makes a texture available to glyph batches.
register_atlas :: proc(backend: ^Backend, atlas: u32, view: wgpu.TextureView) {
	if existing, found := backend.atlas_groups[atlas]; found {
		wgpu.BindGroupRelease(existing)
	}
	entries := []wgpu.BindGroupEntry {
		{binding = 0, textureView = view},
		{binding = 1, sampler = backend.sampler},
	}
	backend.atlas_groups[atlas] = wgpu.DeviceCreateBindGroup(
		backend.device,
		&wgpu.BindGroupDescriptor {
			layout = backend.atlas_layout,
			entryCount = len(entries),
			entries = raw_data(entries),
		},
	)
}

// build_instances converts a batched frame into GPU instances.
//
// Separated from submission so it can be measured on its own and so the
// conversion has no GPU calls in it.
build_instances :: proc(backend: ^Backend, list: ^Draw_List, frame: ^Batched_Frame) {
	clear(&backend.instances)
	for index in frame.order {
		command := list.commands[index]

		// An outline's colour lives in color2 so the shader can distinguish a
		// filled shape from a border without another field.
		fill := command.color
		if command.kind == .Rect_Outline {
			fill = command.color2
		}

		append(
			&backend.instances,
			Instance {
				rect = {command.rect.x0, command.rect.y0, command.rect.x1, command.rect.y1},
				color = transmute([4]f32)fill,
				color2 = transmute([4]f32)command.color2,
				uv = {
					command.source.u0,
					command.source.v0,
					command.source.u1,
					command.source.v1,
				},
				extent = command.extent,
				border = command.border,
				kind = u32(command.kind),
			},
		)
	}
}

// submit records and submits the draw calls for one frame.
//
// `surface_width` and `surface_height` are logical pixels: the shader's
// pixel-to-clip transform uses the same units the draw list was built in, so
// nothing has to know the display scale.
submit :: proc(
	backend: ^Backend,
	list: ^Draw_List,
	frame: ^Batched_Frame,
	target: wgpu.TextureView,
	surface_width: f32,
	surface_height: f32,
	clear_color: Color,
) {
	build_instances(backend, list, frame)

	uniforms := Uniforms{surface = {surface_width, surface_height}}
	wgpu.QueueWriteBuffer(backend.queue, backend.uniform_buffer, 0, &uniforms, size_of(Uniforms))

	// Advance the ring before writing, so this frame never touches the buffer
	// the previous frame may still be reading.
	backend.slot = (backend.slot + 1) % FRAMES_IN_FLIGHT
	slot := &backend.ring[backend.slot]

	count := len(backend.instances)
	if count > slot.capacity {
		grow_ring_slot(backend, backend.slot, max(count * 2, 4096))
		slot = &backend.ring[backend.slot]
	}
	if count > 0 {
		wgpu.QueueWriteBuffer(
			backend.queue,
			slot.buffer,
			0,
			raw_data(backend.instances),
			uint(count * size_of(Instance)),
		)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(backend.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&wgpu.RenderPassDescriptor {
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = target,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = {
					f64(clear_color.r),
					f64(clear_color.g),
					f64(clear_color.b),
					f64(clear_color.a),
				},
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			},
		},
	)

	if count > 0 {
		wgpu.RenderPassEncoderSetVertexBuffer(
			pass,
			0,
			slot.buffer,
			0,
			u64(count * size_of(Instance)),
		)
		wgpu.RenderPassEncoderSetBindGroup(pass, 0, backend.uniform_group)

		for batch in frame.batches {
			if !bind_batch(backend, pass, batch) {
				continue
			}
			apply_scissor(pass, list.clips[batch.clip], surface_width, surface_height)
			wgpu.RenderPassEncoderDraw(pass, 6, u32(batch.count), 0, u32(batch.first))
		}
	}

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	command := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(command)
	wgpu.QueueSubmit(backend.queue, {command})
}

// bind_batch selects the pipeline and resources a batch needs.
//
// Returns false when the batch cannot be drawn — a glyph batch naming an atlas
// that was never registered, for instance. Skipping is better than binding the
// wrong texture, which would paint another font's pixels.
@(private)
bind_batch :: proc(
	backend: ^Backend,
	pass: wgpu.RenderPassEncoder,
	batch: Batch,
) -> bool {
	switch batch.pipeline {
	case .Shape, .Line:
		// Lines share the shape pipeline for now: the shader treats them as
		// thin rectangles, which is correct for the axis-aligned separators
		// and playhead the timeline draws. A rotated-line pipeline arrives
		// with the graph panel, which is the first thing that needs one.
		wgpu.RenderPassEncoderSetPipeline(pass, backend.shape_pipeline)
		return true

	case .Glyph, .Texture:
		group, found := backend.atlas_groups[batch.atlas]
		if !found {
			return false
		}
		wgpu.RenderPassEncoderSetPipeline(pass, backend.glyph_pipeline)
		wgpu.RenderPassEncoderSetBindGroup(pass, 1, group)
		return true
	}
	return false
}

// apply_scissor restricts a batch to its clip rectangle.
//
// The scissor is the GPU's own clipping and costs nothing per fragment, unlike
// discarding in the shader. Coordinates are clamped to the surface because a
// scissor outside the render target is a validation error, and the draw list's
// root clip is deliberately unbounded.
@(private)
apply_scissor :: proc(
	pass: wgpu.RenderPassEncoder,
	clip: Rect,
	surface_width: f32,
	surface_height: f32,
) {
	x0 := clamp(clip.x0, 0, surface_width)
	y0 := clamp(clip.y0, 0, surface_height)
	x1 := clamp(clip.x1, 0, surface_width)
	y1 := clamp(clip.y1, 0, surface_height)

	width := x1 - x0
	height := y1 - y0
	if width <= 0 || height <= 0 {
		// An empty scissor would be rejected; the batch simply draws nothing.
		wgpu.RenderPassEncoderSetScissorRect(pass, 0, 0, 0, 0)
		return
	}

	wgpu.RenderPassEncoderSetScissorRect(pass, u32(x0), u32(y0), u32(width), u32(height))
}

// handle_device_loss tears down GPU resources after a lost device.
//
// docs/07: device loss tears down GPU resources and attempts one clean
// reinitialization, and CPU-side application state survives. This releases
// only the GPU side; the caller recreates a device and calls backend_init
// again, keeping every draw list and panel state it already had.
handle_device_loss :: proc(backend: ^Backend) {
	backend_release_gpu(backend)
	backend.device_lost = true
}

@(private)
backend_release_gpu :: proc(backend: ^Backend) {
	for _, group in backend.atlas_groups {
		wgpu.BindGroupRelease(group)
	}
	clear(&backend.atlas_groups)
	for _, view in backend.atlas_views {
		wgpu.TextureViewRelease(view)
	}
	clear(&backend.atlas_views)
	for _, texture in backend.atlas_textures {
		wgpu.TextureRelease(texture)
	}
	clear(&backend.atlas_textures)

	for index in 0 ..< FRAMES_IN_FLIGHT {
		if backend.ring[index].buffer != nil {
			wgpu.BufferRelease(backend.ring[index].buffer)
			backend.ring[index] = {}
		}
	}

	if backend.uniform_group != nil {
		wgpu.BindGroupRelease(backend.uniform_group)
		backend.uniform_group = nil
	}
	if backend.uniform_buffer != nil {
		wgpu.BufferRelease(backend.uniform_buffer)
		backend.uniform_buffer = nil
	}
	if backend.sampler != nil {
		wgpu.SamplerRelease(backend.sampler)
		backend.sampler = nil
	}
	if backend.shape_pipeline != nil {
		wgpu.RenderPipelineRelease(backend.shape_pipeline)
		backend.shape_pipeline = nil
	}
	if backend.glyph_pipeline != nil {
		wgpu.RenderPipelineRelease(backend.glyph_pipeline)
		backend.glyph_pipeline = nil
	}
	if backend.uniform_layout != nil {
		wgpu.BindGroupLayoutRelease(backend.uniform_layout)
		backend.uniform_layout = nil
	}
	if backend.atlas_layout != nil {
		wgpu.BindGroupLayoutRelease(backend.atlas_layout)
		backend.atlas_layout = nil
	}
}

backend_destroy :: proc(backend: ^Backend) {
	backend_release_gpu(backend)
	delete(backend.atlas_groups)
	delete(backend.atlas_textures)
	delete(backend.atlas_views)
	delete(backend.instances)
	backend^ = {}
}

// backend_report describes the backend for the developer overlay.
backend_report :: proc(backend: ^Backend, allocator := context.allocator) -> string {
	total := 0
	for slot in backend.ring {
		total += slot.capacity
	}
	return fmt.aprintf(
		"ring %d slots, %d instance capacity, %d atlases",
		FRAMES_IN_FLIGHT,
		total,
		len(backend.atlas_groups),
		allocator = allocator,
	)
}
