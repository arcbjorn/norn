package graphics_spike

import "core:fmt"
import "core:math"
import "core:os"
import "core:time"

import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

// Phase-zero graphics spike.
//
// docs/11-roadmap.md phase zero: open an SDL3 window and render batched
// primitives through WGPU on macOS, keep timeline pan and zoom interactive
// with 100,000 generated events, and run for 30 minutes without resource
// growth or validation errors.
//
// This code is deliberately throwaway. docs/11: "the spike code may be
// discarded. Its measurements and decisions remain." Nothing in src/ depends
// on it, and it exists to answer whether decision 002 survives contact with
// the platform.
//
// Run with:  scripts/spike.sh graphics [--frames N] [--events N]

// EVENT_COUNT matches the reference workload in docs/07.
DEFAULT_EVENT_COUNT :: 100_000

// Instance is one timeline event as the GPU sees it.
//
// Structure-of-arrays would suit the trace store, but a renderer instance
// buffer wants each instance contiguous: the GPU reads all of one instance's
// attributes together. This is the array-of-structures side of the tradeoff
// docs/10 describes.
Instance :: struct {
	// Position and size in normalized device coordinates.
	rect:  [4]f32,
	color: [4]f32,
}

// Event is the CPU-side generated event this spike renders.
Event :: struct {
	time_ns:  i64,
	lane:     int,
	duration: i64,
	kind:     int,
}

Viewport :: struct {
	// Visible time interval in nanoseconds.
	start_ns: i64,
	span_ns:  i64,
	// Framebuffer size in pixels.
	width:  f32,
	height: f32,
}

// LANE_COUNT matches the swimlanes docs/01 specifies.
LANE_COUNT :: 7

SHADER :: `
struct Instance {
    @location(0) rect: vec4<f32>,
    @location(1) color: vec4<f32>,
};

struct VertexOutput {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(
    @builtin(vertex_index) vertex_index: u32,
    instance: Instance,
) -> VertexOutput {
    // Two triangles forming a unit quad, expanded per instance. Generating
    // the corners here avoids uploading a vertex buffer at all.
    var corners = array<vec2<f32>, 6>(
        vec2<f32>(0.0, 0.0), vec2<f32>(1.0, 0.0), vec2<f32>(0.0, 1.0),
        vec2<f32>(1.0, 0.0), vec2<f32>(1.0, 1.0), vec2<f32>(0.0, 1.0),
    );
    let corner = corners[vertex_index];
    let position = instance.rect.xy + corner * instance.rect.zw;

    var out: VertexOutput;
    out.position = vec4<f32>(position, 0.0, 1.0);
    out.color = instance.color;
    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    return in.color;
}
`

State :: struct {
	window:  ^sdl.Window,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	pipeline: wgpu.RenderPipeline,
	config:   wgpu.SurfaceConfiguration,

	instance_buffer:   wgpu.Buffer,
	instance_capacity: int,

	events:   []Event,
	viewport: Viewport,
	visible:  [dynamic]Instance,
}

main :: proc() {
	frames := 0 // Zero means run until the window closes.
	event_count := DEFAULT_EVENT_COUNT

	arguments := os.args[1:]
	for index := 0; index < len(arguments); index += 1 {
		switch arguments[index] {
		case "--frames":
			index += 1
			if index < len(arguments) {
				frames = parse_int(arguments[index])
			}
		case "--events":
			index += 1
			if index < len(arguments) {
				event_count = parse_int(arguments[index])
			}
		}
	}

	state: State
	if !init(&state, event_count) {
		fmt.eprintln("spike: initialization failed")
		os.exit(1)
	}
	defer shutdown(&state)

	report_capabilities(&state)
	run(&state, frames)
}

@(private)
parse_int :: proc(text: string) -> int {
	value := 0
	for c in text {
		if c < '0' || c > '9' {
			return value
		}
		value = value * 10 + int(c - '0')
	}
	return value
}

init :: proc(state: ^State, event_count: int) -> bool {
	if !sdl.Init({.VIDEO}) {
		fmt.eprintfln("spike: SDL_Init failed: %s", sdl.GetError())
		return false
	}

	// High-DPI is requested explicitly: docs/07 requires crisp text at
	// standard and high-DPI scales, and a window that silently renders at
	// logical resolution would make the spike prove nothing about that.
	state.window = sdl.CreateWindow(
		"Norn graphics spike",
		1280,
		720,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY},
	)
	if state.window == nil {
		fmt.eprintfln("spike: CreateWindow failed: %s", sdl.GetError())
		return false
	}

	state.instance = wgpu.CreateInstance(nil)
	if state.instance == nil {
		fmt.eprintln("spike: wgpu.CreateInstance returned nil")
		return false
	}

	state.surface = sdl3glue.GetSurface(state.instance, state.window)
	if state.surface == nil {
		fmt.eprintln("spike: could not create a WGPU surface for the SDL window")
		return false
	}

	// Adapter and device requests are callback-based. The spike blocks on
	// them because there is nothing else to do until the GPU is ready.
	wgpu.InstanceRequestAdapter(
		state.instance,
		&wgpu.RequestAdapterOptions{compatibleSurface = state.surface},
		{callback = on_adapter, userdata1 = state},
	)
	if state.adapter == nil {
		fmt.eprintln("spike: no compatible GPU adapter")
		return false
	}

	wgpu.AdapterRequestDevice(state.adapter, nil, {callback = on_device, userdata1 = state})
	if state.device == nil {
		fmt.eprintln("spike: could not create a GPU device")
		return false
	}

	state.queue = wgpu.DeviceGetQueue(state.device)

	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)

	capabilities, capabilities_status := wgpu.SurfaceGetCapabilities(state.surface, state.adapter)
	if capabilities_status != .Success {
		fmt.eprintln("spike: could not query surface capabilities")
		return false
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)

	state.config = wgpu.SurfaceConfiguration {
		device      = state.device,
		format      = capabilities.formats[0],
		usage       = {.RenderAttachment},
		width       = u32(width),
		height      = u32(height),
		presentMode = .Fifo,
		alphaMode   = .Opaque,
	}
	wgpu.SurfaceConfigure(state.surface, &state.config)

	if !create_pipeline(state, capabilities.formats[0]) {
		return false
	}

	state.events = generate_events(event_count)
	state.visible = make([dynamic]Instance, 0, 4096)
	state.viewport = Viewport {
		start_ns = 0,
		span_ns  = session_duration(state.events),
		width    = f32(width),
		height   = f32(height),
	}

	return true
}

@(private)
on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: string,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	state := cast(^State)userdata1
	if status == .Success {
		state.adapter = adapter
	}
}

@(private)
on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: string,
	userdata1: rawptr,
	userdata2: rawptr,
) {
	state := cast(^State)userdata1
	if status == .Success {
		state.device = device
	}
}

create_pipeline :: proc(state: ^State, format: wgpu.TextureFormat) -> bool {
	module := wgpu.DeviceCreateShaderModule(
		state.device,
		&wgpu.ShaderModuleDescriptor {
			nextInChain = &wgpu.ShaderSourceWGSL{
				chain = {sType = .ShaderSourceWGSL},
				code = SHADER,
			},
		},
	)
	if module == nil {
		fmt.eprintln("spike: shader compilation failed")
		return false
	}
	defer wgpu.ShaderModuleRelease(module)

	attributes := []wgpu.VertexAttribute {
		{format = .Float32x4, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = 16, shaderLocation = 1},
	}
	layout := wgpu.VertexBufferLayout {
		arrayStride    = size_of(Instance),
		stepMode       = .Instance,
		attributeCount = len(attributes),
		attributes     = raw_data(attributes),
	}

	state.pipeline = wgpu.DeviceCreateRenderPipeline(
		state.device,
		&wgpu.RenderPipelineDescriptor {
			vertex = {
				module = module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &layout,
			},
			fragment = &wgpu.FragmentState {
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &wgpu.ColorTargetState {
					format = format,
					writeMask = wgpu.ColorWriteMaskFlags_All,
				},
			},
			primitive = {topology = .TriangleList},
			multisample = {count = 1, mask = ~u32(0)},
		},
	)
	return state.pipeline != nil
}

// generate_events produces a deterministic synthetic session.
//
// Deterministic so that two runs measure the same workload; a random session
// would make frame timings incomparable between runs.
generate_events :: proc(count: int) -> []Event {
	events := make([]Event, count)
	cursor := i64(0)
	seed := u64(0x9E3779B97F4A7C15)

	for index in 0 ..< count {
		// xorshift, inline, so the spike depends on nothing for its data.
		seed ~= seed << 13
		seed ~= seed >> 7
		seed ~= seed << 17

		gap := i64(seed % 5_000_000) + 100_000
		cursor += gap

		events[index] = Event {
			time_ns  = cursor,
			lane     = int(seed % LANE_COUNT),
			duration = i64(seed % 2_000_000),
			kind     = int(seed % 5),
		}
	}
	return events
}

session_duration :: proc(events: []Event) -> i64 {
	if len(events) == 0 {
		return 1
	}
	return events[len(events) - 1].time_ns + 1
}

// build_visible produces instances for the events intersecting the viewport.
//
// docs/07 timeline virtualization: only events intersecting the visible time
// interval generate draw instances, and the panel does not scan the full
// session each frame. Events are time-ordered, so the visible window is found
// by binary search rather than by scanning.
build_visible :: proc(state: ^State) {
	clear(&state.visible)

	view := state.viewport
	view_end := view.start_ns + view.span_ns

	first := lower_bound(state.events, view.start_ns)
	lane_height := 2.0 / f32(LANE_COUNT)

	palette := [5][4]f32 {
		{0.42, 0.62, 0.92, 1.0},
		{0.45, 0.78, 0.55, 1.0},
		{0.92, 0.72, 0.36, 1.0},
		{0.88, 0.44, 0.44, 1.0},
		{0.68, 0.55, 0.86, 1.0},
	}

	for index := first; index < len(state.events); index += 1 {
		event := state.events[index]
		if event.time_ns > view_end {
			break
		}

		start := f32(event.time_ns - view.start_ns) / f32(view.span_ns)
		width := f32(event.duration) / f32(view.span_ns)

		// A zero-duration event still needs to be visible and clickable, so
		// it is given a minimum width of roughly one pixel.
		minimum := 1.0 / view.width
		if width < minimum {
			width = minimum
		}

		// Normalized device coordinates run -1..1 with +Y upward.
		x := start * 2.0 - 1.0
		y := 1.0 - f32(event.lane + 1) * lane_height

		append(
			&state.visible,
			Instance {
				rect = {x, y + lane_height * 0.15, width * 2.0, lane_height * 0.7},
				color = palette[event.kind],
			},
		)
	}
}

// lower_bound returns the first index whose time is at or after `target`.
lower_bound :: proc(events: []Event, target: i64) -> int {
	low := 0
	high := len(events)
	for low < high {
		middle := low + (high - low) / 2
		if events[middle].time_ns < target {
			low = middle + 1
		} else {
			high = middle
		}
	}
	return low
}

ensure_capacity :: proc(state: ^State, count: int) {
	if count <= state.instance_capacity && state.instance_buffer != nil {
		return
	}

	if state.instance_buffer != nil {
		wgpu.BufferRelease(state.instance_buffer)
	}

	// Grow generously so a pan that reveals more events does not reallocate
	// every frame.
	capacity := max(count * 2, 4096)
	state.instance_buffer = wgpu.DeviceCreateBuffer(
		state.device,
		&wgpu.BufferDescriptor {
			usage = {.Vertex, .CopyDst},
			size = u64(capacity * size_of(Instance)),
		},
	)
	state.instance_capacity = capacity
}

Metrics :: struct {
	frames:        int,
	total_cpu_ms:  f64,
	worst_cpu_ms:  f64,
	peak_instances: int,
	// Time spent building the visible instance set and encoding commands,
	// excluding the present call.
	//
	// The distinction matters: a frame loop with vsync blocks in present for
	// whatever remains of the refresh interval, so wall-clock frame time
	// measures the display's cadence rather than Norn's cost. docs/07 budgets
	// "frame CPU time", which is this figure.
	total_work_ms: f64,
	worst_work_ms: f64,
	// Frames counted toward the steady-state figures.
	measured:  int,
	warmup_ms: f64,
	// Time spent producing the visible instance set, excluding every GPU
	// call. Under Fifo present mode the acquire and present calls block on
	// the display refresh, so they measure the monitor rather than Norn.
	total_build_ms: f64,
	worst_build_ms: f64,
}

// WARMUP_FRAMES are excluded from the steady-state measurement.
WARMUP_FRAMES :: 10

run :: proc(state: ^State, frame_limit: int) {
	metrics: Metrics
	dragging := false
	running := true

	for running {
		frame_start := time.tick_now()

		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT:
				running = false

			case .KEY_DOWN:
				if event.key.scancode == .ESCAPE {
					running = false
				}

			case .WINDOW_PIXEL_SIZE_CHANGED:
				resize(state)

			case .MOUSE_BUTTON_DOWN:
				dragging = true
			case .MOUSE_BUTTON_UP:
				dragging = false

			case .MOUSE_MOTION:
				if dragging {
					// Pan: convert pixel motion to a time delta through the
					// same transform drawing uses, so the content tracks the
					// cursor exactly.
					delta := f64(event.motion.xrel) / f64(state.viewport.width)
					state.viewport.start_ns -= i64(delta * f64(state.viewport.span_ns))
				}

			case .MOUSE_WHEEL:
				zoom(state, event.wheel.y)
			}
		}

		work_start := time.tick_now()
		build_visible(state)
		if len(state.visible) > metrics.peak_instances {
			metrics.peak_instances = len(state.visible)
		}
		build_ms := time.duration_milliseconds(time.tick_since(work_start))
		metrics.total_build_ms += build_ms
		if build_ms > metrics.worst_build_ms {
			metrics.worst_build_ms = build_ms
		}

		render(state)
		work := time.duration_milliseconds(time.tick_since(work_start))
		elapsed := time.duration_milliseconds(time.tick_since(frame_start))
		metrics.frames += 1

		// docs/07 budgets *steady-state* frame time. The first frames pay for
		// shader compilation, pipeline creation, and buffer allocation, which
		// happen once per session and are not what the budget describes.
		if metrics.frames > WARMUP_FRAMES {
			metrics.measured += 1
			metrics.total_work_ms += work
			metrics.total_cpu_ms += elapsed
			if work > metrics.worst_work_ms {
				metrics.worst_work_ms = work
			}
			if elapsed > metrics.worst_cpu_ms {
				metrics.worst_cpu_ms = elapsed
			}
		} else {
			metrics.warmup_ms += work
		}

		if frame_limit > 0 && metrics.frames >= frame_limit {
			running = false
		}
	}

	report_metrics(&metrics, len(state.events))
}

zoom :: proc(state: ^State, amount: f32) {
	if amount == 0 {
		return
	}
	factor := 1.0 - f64(amount) * 0.1
	if factor < 0.1 {
		factor = 0.1
	}

	// Zoom about the viewport centre so the content under the cursor stays
	// roughly in place.
	centre := state.viewport.start_ns + state.viewport.span_ns / 2
	span := i64(f64(state.viewport.span_ns) * factor)
	if span < 1000 {
		span = 1000
	}
	state.viewport.span_ns = span
	state.viewport.start_ns = centre - span / 2
}

resize :: proc(state: ^State) {
	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)
	if width <= 0 || height <= 0 {
		return
	}

	state.config.width = u32(width)
	state.config.height = u32(height)
	state.viewport.width = f32(width)
	state.viewport.height = f32(height)
	wgpu.SurfaceConfigure(state.surface, &state.config)
}

render :: proc(state: ^State) {
	surface_texture := wgpu.SurfaceGetCurrentTexture(state.surface)
	switch surface_texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// Proceed.
	case .Occluded:
		// An occluded surface yields no texture to draw into. Skipping the
		// frame is correct: there is nothing visible to update.
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		return
	case .Timeout, .Outdated, .Lost:
		// Recoverable: the surface needs reconfiguring against the new size.
		if surface_texture.texture != nil {
			wgpu.TextureRelease(surface_texture.texture)
		}
		resize(state)
		return
	case .Error:
		fmt.eprintfln("spike: surface acquisition failed: %v", surface_texture.status)
		return
	}
	defer wgpu.TextureRelease(surface_texture.texture)

	view := wgpu.TextureCreateView(surface_texture.texture, nil)
	defer wgpu.TextureViewRelease(view)

	count := len(state.visible)
	if count > 0 {
		ensure_capacity(state, count)
		wgpu.QueueWriteBuffer(
			state.queue,
			state.instance_buffer,
			0,
			raw_data(state.visible),
			uint(count * size_of(Instance)),
		)
	}

	encoder := wgpu.DeviceCreateCommandEncoder(state.device, nil)
	defer wgpu.CommandEncoderRelease(encoder)

	pass := wgpu.CommandEncoderBeginRenderPass(
		encoder,
		&wgpu.RenderPassDescriptor {
			colorAttachmentCount = 1,
			colorAttachments = &wgpu.RenderPassColorAttachment {
				view = view,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = {0.09, 0.10, 0.12, 1.0},
				depthSlice = wgpu.DEPTH_SLICE_UNDEFINED,
			},
		},
	)

	if count > 0 {
		wgpu.RenderPassEncoderSetPipeline(pass, state.pipeline)
		wgpu.RenderPassEncoderSetVertexBuffer(
			pass,
			0,
			state.instance_buffer,
			0,
			u64(count * size_of(Instance)),
		)
		// One draw call for every visible event: docs/07 requires timeline
		// events to be instanced rather than drawn individually.
		wgpu.RenderPassEncoderDraw(pass, 6, u32(count), 0, 0)
	}

	wgpu.RenderPassEncoderEnd(pass)
	wgpu.RenderPassEncoderRelease(pass)

	command := wgpu.CommandEncoderFinish(encoder, nil)
	defer wgpu.CommandBufferRelease(command)

	wgpu.QueueSubmit(state.queue, {command})
	wgpu.SurfacePresent(state.surface)
}

report_capabilities :: proc(state: ^State) {
	info, _ := wgpu.AdapterGetInfo(state.adapter)
	defer wgpu.AdapterInfoFreeMembers(info)

	width, height: i32
	sdl.GetWindowSizeInPixels(state.window, &width, &height)
	logical_width, logical_height: i32
	sdl.GetWindowSize(state.window, &logical_width, &logical_height)

	fmt.println("=== stack ===")
	fmt.printfln("adapter:      %s", info.device)
	fmt.printfln("backend:      %v", info.backendType)
	fmt.printfln("adapter type: %v", info.adapterType)
	fmt.printfln("surface fmt:  %v", state.config.format)
	fmt.printfln(
		"window:       %dx%d logical, %dx%d pixels (scale %.1fx)",
		logical_width,
		logical_height,
		width,
		height,
		f64(width) / f64(max(logical_width, 1)),
	)
	fmt.println()
}

report_metrics :: proc(metrics: ^Metrics, event_count: int) {
	if metrics.measured == 0 {
		return
	}
	average := metrics.total_cpu_ms / f64(metrics.measured)
	work := metrics.total_work_ms / f64(metrics.measured)

	fmt.println("=== measurements ===")
	fmt.printfln("events:            %d", event_count)
	fmt.printfln("frames:            %d (%d measured after warm-up)", metrics.frames, metrics.measured)
	fmt.printfln("warm-up cost:      %.1f ms total", metrics.warmup_ms)
	fmt.printfln("peak instances:    %d", metrics.peak_instances)
	build := metrics.total_build_ms / f64(metrics.measured)
	fmt.printfln("mean build CPU:    %.3f ms", build)
	fmt.printfln("worst build CPU:   %.3f ms", metrics.worst_build_ms)
	fmt.printfln("mean incl. GPU:    %.3f ms", work)
	fmt.printfln("worst incl. GPU:   %.3f ms", metrics.worst_work_ms)
	fmt.printfln("mean wall (vsync): %.3f ms", average)
	fmt.printfln("worst wall:        %.3f ms", metrics.worst_cpu_ms)

	// docs/07 budget: steady-state frame CPU under 8 ms at p95. The wall time
	// above includes the vsync wait and is not the budgeted quantity.
	// The budgeted quantity is Norn's own per-frame CPU work. Acquire and
	// present block on the 120 Hz refresh under Fifo, so including them would
	// measure the display.
	verdict := "within budget" if build < 8.0 else "OVER BUDGET"
	fmt.printfln("budget (8 ms CPU): %s", verdict)
}

shutdown :: proc(state: ^State) {
	if state.instance_buffer != nil {
		wgpu.BufferRelease(state.instance_buffer)
	}
	if state.pipeline != nil {
		wgpu.RenderPipelineRelease(state.pipeline)
	}
	if state.queue != nil {
		wgpu.QueueRelease(state.queue)
	}
	if state.device != nil {
		wgpu.DeviceRelease(state.device)
	}
	if state.adapter != nil {
		wgpu.AdapterRelease(state.adapter)
	}
	if state.surface != nil {
		wgpu.SurfaceRelease(state.surface)
	}
	if state.instance != nil {
		wgpu.InstanceRelease(state.instance)
	}
	if state.window != nil {
		sdl.DestroyWindow(state.window)
	}
	delete(state.events)
	delete(state.visible)
	sdl.Quit()
}
