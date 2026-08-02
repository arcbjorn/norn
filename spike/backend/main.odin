package backend_spike

import "core:fmt"
import "core:os"
import "core:time"

import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

import "src:render"
import "src:trace/codec"
import "src:trace/model"
import "src:ui"

// Backend validation.
//
// Confirms that the pipelines in src/render/gpu.odin compile on a real device
// and that a timeline frame reaches the screen. The draw list and batching
// layers are covered by unit tests; this exercises the one file those tests
// cannot reach, because it is the one that needs a GPU.
//
// Run with:  scripts/norn.sh spike backend [--frames N]

SECOND :: i64(1_000_000_000)

State :: struct {
	window:   ^sdl.Window,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	config:   wgpu.SurfaceConfiguration,
	backend:  render.Backend,

	trace: codec.Trace,
	index: ui.Timeline_Index,
	list:  render.Draw_List,
	frame: render.Batched_Frame,

	width, height: f32,
}

main :: proc() {
	frames := 120
	arguments := os.args[1:]
	for i := 0; i < len(arguments); i += 1 {
		if arguments[i] == "--frames" && i + 1 < len(arguments) {
			i += 1
			frames = parse_int(arguments[i])
		}
	}

	state: State
	if !init(&state) {
		fmt.eprintln("spike: initialization failed")
		os.exit(1)
	}
	defer shutdown(&state)
	run(&state, frames)
}

parse_int :: proc(text: string) -> int {
	value := 0
	for c in text {
		if c < '0' || c > '9' { return value }
		value = value * 10 + int(c - '0')
	}
	return value
}

init :: proc(state: ^State) -> bool {
	if !sdl.Init({.VIDEO}) { return false }
	state.window = sdl.CreateWindow("Norn backend spike", 1280, 400,
		{.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if state.window == nil { return false }

	state.instance = wgpu.CreateInstance(nil)
	state.surface = sdl3glue.GetSurface(state.instance, state.window)
	if state.surface == nil { return false }

	wgpu.InstanceRequestAdapter(state.instance,
		&wgpu.RequestAdapterOptions{compatibleSurface = state.surface},
		{callback = on_adapter, userdata1 = state})
	if state.adapter == nil { return false }

	wgpu.AdapterRequestDevice(state.adapter, nil, {callback = on_device, userdata1 = state})
	if state.device == nil { return false }
	state.queue = wgpu.DeviceGetQueue(state.device)

	w, h: i32
	sdl.GetWindowSizeInPixels(state.window, &w, &h)
	state.width = f32(w); state.height = f32(h)

	caps, status := wgpu.SurfaceGetCapabilities(state.surface, state.adapter)
	if status != .Success { return false }
	defer wgpu.SurfaceCapabilitiesFreeMembers(caps)

	state.config = wgpu.SurfaceConfiguration{
		device = state.device, format = caps.formats[0], usage = {.RenderAttachment},
		width = u32(w), height = u32(h), presentMode = .Fifo, alphaMode = .Opaque,
	}
	wgpu.SurfaceConfigure(state.surface, &state.config)

	if !render.backend_init(&state.backend, state.device, state.queue, caps.formats[0]) {
		fmt.eprintln("spike: pipeline creation failed")
		return false
	}

	build_trace(state)
	state.index = ui.build_index(&state.trace)
	render.draw_list_init(&state.list)
	render.batched_frame_init(&state.frame)

	info, _ := wgpu.AdapterGetInfo(state.adapter)
	defer wgpu.AdapterInfoFreeMembers(info)
	report := render.backend_report(&state.backend)
	defer delete(report)

	fmt.println("=== backend ===")
	fmt.printfln("adapter:  %s (%v)", info.device, info.backendType)
	fmt.printfln("format:   %v", caps.formats[0])
	fmt.printfln("pipelines: shape + glyph compiled")
	fmt.printfln("resources: %s", report)
	fmt.printfln("events:   %d", len(state.trace.events))
	fmt.println()
	return true
}

on_adapter :: proc "c" (s: wgpu.RequestAdapterStatus, a: wgpu.Adapter, m: string, u1, u2: rawptr) {
	if s == .Success { (cast(^State)u1).adapter = a }
}
on_device :: proc "c" (s: wgpu.RequestDeviceStatus, d: wgpu.Device, m: string, u1, u2: rawptr) {
	if s == .Success { (cast(^State)u1).device = d }
}

build_trace :: proc(state: ^State) {
	t := &state.trace
	model.string_table_init(&t.strings); model.blob_table_init(&t.blobs)
	model.payload_tables_init(&t.payloads)
	t.events = make([dynamic]model.Event, 0, 20_000)
	t.entities = make([dynamic]model.Entity); t.spans = make([dynamic]model.Span)
	t.edges = make([dynamic]model.Edge); t.mutations = make([dynamic]model.Mutation)
	t.directory = make([dynamic]codec.Directory_Entry)

	kinds := []model.Event_Kind{
		.User_Message, .Tool_Call, .File_Modify, .Command_Start, .Test_Run_Start, .Tool_Error,
	}
	for i in 0..<20_000 {
		kind := kinds[i % len(kinds)]
		duration := i64(0)
		if kind == .Command_Start { duration = SECOND / 4 }
		append(&t.events, model.Event{
			id = model.Event_Id(i+1), sequence = model.Sequence(i+1), kind = kind,
			flags = duration > 0 ? {.Has_Wall_Time, .Has_Duration} : {.Has_Wall_Time},
			wall_time_ns = i64(i) * SECOND / 20, duration_ns = duration,
		})
	}
}

run :: proc(state: ^State, limit: int) {
	total, worst := 0.0, 0.0
	measured := 0
	span := i64(300) * SECOND
	start_ns := i64(0)

	for frame in 0..<limit {
		event: sdl.Event
		for sdl.PollEvent(&event) {
			#partial switch event.type {
			case .QUIT: return
			case .KEY_DOWN: if event.key.scancode == .ESCAPE { return }
			}
		}

		// Sweep the viewport so a different slice is drawn each frame, which
		// exercises the ring rather than resubmitting one identical buffer.
		// Wrapping keeps the view inside the session, so every frame carries a
		// realistic instance count rather than trailing off into emptiness.
		session_end := i64(20_000) * SECOND / 20
		start_ns += span / 60
		if start_ns + span > session_end {
			start_ns = 0
		}

		began := time.tick_now()
		vp := ui.viewport_make(start_ns, span, state.width)
		set := ui.query_visible(&state.trace, state.index, vp)
		defer ui.visible_set_destroy(&set)

		surface := render.Rect{0, 0, state.width, state.height}
		render.draw_list_reset(&state.list, surface)
		ui.draw_timeline(&state.list, ui.Panel_State{
			viewport = vp,
			layout = ui.Lane_Layout{origin_y = 20, lane_height = 40, padding = 5},
			bounds = surface, theme = ui.DARK_THEME,
			selection = set.events[0].id if len(set.events) > 0 else model.NO_EVENT,
			has_playhead = true, playhead_ns = start_ns + span / 2,
		}, &set)
		render.build_batches(&state.list, &state.frame)

		texture := wgpu.SurfaceGetCurrentTexture(state.surface)
		#partial switch texture.status {
		case .SuccessOptimal, .SuccessSuboptimal:
		case:
			if texture.texture != nil { wgpu.TextureRelease(texture.texture) }
			continue
		}
		view := wgpu.TextureCreateView(texture.texture, nil)

		render.submit(&state.backend, &state.list, &state.frame, view,
			state.width, state.height, ui.DARK_THEME.background)

		wgpu.TextureViewRelease(view)
		wgpu.TextureRelease(texture.texture)
		wgpu.SurfacePresent(state.surface)

		elapsed := time.duration_milliseconds(time.tick_since(began))
		if frame >= 10 {
			measured += 1; total += elapsed
			if elapsed > worst { worst = elapsed }
		}
	}

	if measured == 0 { return }
	stats := render.frame_stats(&state.list, &state.frame)
	_ = start_ns
	fmt.println("=== frame ===")
	fmt.printfln("commands:   %d", stats.commands)
	fmt.printfln("draw calls: %d", stats.draw_calls)
	fmt.printfln("mean:       %s ms", fmt.tprintf("%.3f", total / f64(measured)))
	fmt.printfln("worst:      %s ms", fmt.tprintf("%.3f", worst))

	// The ring must have grown past its initial capacity to hold this frame,
	// and must have stopped growing once it did.
	final := render.backend_report(&state.backend)
	defer delete(final)
	fmt.printfln("resources:  %s", final)
}

shutdown :: proc(state: ^State) {
	render.backend_destroy(&state.backend)
	render.draw_list_destroy(&state.list)
	render.batched_frame_destroy(&state.frame)
	codec.trace_destroy(&state.trace)
	if state.queue != nil { wgpu.QueueRelease(state.queue) }
	if state.device != nil { wgpu.DeviceRelease(state.device) }
	if state.adapter != nil { wgpu.AdapterRelease(state.adapter) }
	if state.surface != nil { wgpu.SurfaceRelease(state.surface) }
	if state.instance != nil { wgpu.InstanceRelease(state.instance) }
	if state.window != nil { sdl.DestroyWindow(state.window) }
	sdl.Quit()
}
