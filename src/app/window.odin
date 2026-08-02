package app

import "core:fmt"
import "core:time"

import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

import "src:core"
import "src:render"
import "src:trace/codec"
import "src:ui"

// The window and frame loop.
//
// docs/07-rendering.md fixes the frame order:
//
//   platform events -> application commands -> selection/filter update
//   -> visible-data queries -> layout -> draw-list generation
//   -> GPU batching -> submit and present
//
// This file is that loop. It is the only place SDL types appear, which keeps
// the command layer above it testable without a window.

// Window owns the platform and GPU resources for one open trace.
Window :: struct {
	handle:   ^sdl.Window,
	instance: wgpu.Instance,
	surface:  wgpu.Surface,
	adapter:  wgpu.Adapter,
	device:   wgpu.Device,
	queue:    wgpu.Queue,
	config:   wgpu.SurfaceConfiguration,
	backend:  render.Backend,

	list:  render.Draw_List,
	frame: render.Batched_Frame,

	// Framebuffer size in pixels and the display scale that produced it.
	width, height: f32,
	scale:         f32,

	// The revision last drawn, so an unchanged frame is not redrawn.
	drawn_revision: u64,
	// Forces a redraw regardless of revision, after a resize or a device
	// reinitialization where the previous frame's pixels are gone.
	needs_redraw: bool,
}

// TIMELINE_MARGIN is the space reserved around the timeline panel.
//
// The other panels docs/01 specifies are not built yet, so the timeline uses
// the window. The margin keeps it from touching the edges, which makes the
// unbuilt panels' eventual arrival a layout change rather than a visual shock.
TIMELINE_MARGIN :: f32(16)

// open creates a window and GPU resources for a trace.
open :: proc(window: ^Window, title: cstring) -> core.Error {
	if !sdl.Init({.VIDEO}) {
		return core.err_make(.Io_Failure, "could not initialize the window system")
	}

	window.handle = sdl.CreateWindow(title, 1280, 720, {.RESIZABLE, .HIGH_PIXEL_DENSITY})
	if window.handle == nil {
		return core.err_make(.Io_Failure, "could not create a window")
	}

	window.instance = wgpu.CreateInstance(nil)
	if window.instance == nil {
		return core.err_make(.Io_Failure, "could not initialize the GPU instance")
	}

	window.surface = sdl3glue.GetSurface(window.instance, window.handle)
	if window.surface == nil {
		return core.err_make(.Io_Failure, "could not create a GPU surface for the window")
	}

	if err := acquire_device(window); !core.ok(err) {
		return err
	}

	render.draw_list_init(&window.list)
	render.batched_frame_init(&window.frame)
	window.needs_redraw = true
	return nil
}

// acquire_device requests an adapter and device and builds the backend.
//
// Separated from `open` because device loss re-runs exactly this, per docs/07:
// "device loss tears down GPU resources and attempts one clean
// reinitialization. CPU-side application state survives."
@(private)
acquire_device :: proc(window: ^Window) -> core.Error {
	wgpu.InstanceRequestAdapter(
		window.instance,
		&wgpu.RequestAdapterOptions{compatibleSurface = window.surface},
		{callback = on_adapter, userdata1 = window},
	)
	if window.adapter == nil {
		return core.err_make(.Io_Failure, "no compatible GPU adapter is available")
	}

	wgpu.AdapterRequestDevice(window.adapter, nil, {callback = on_device, userdata1 = window})
	if window.device == nil {
		return core.err_make(.Io_Failure, "could not create a GPU device")
	}
	window.queue = wgpu.DeviceGetQueue(window.device)

	update_metrics(window)

	capabilities, status := wgpu.SurfaceGetCapabilities(window.surface, window.adapter)
	if status != .Success {
		return core.err_make(.Io_Failure, "could not query GPU surface capabilities")
	}
	defer wgpu.SurfaceCapabilitiesFreeMembers(capabilities)

	window.config = wgpu.SurfaceConfiguration {
		device      = window.device,
		format      = capabilities.formats[0],
		usage       = {.RenderAttachment},
		width       = u32(window.width),
		height      = u32(window.height),
		presentMode = .Fifo,
		alphaMode   = .Opaque,
	}
	wgpu.SurfaceConfigure(window.surface, &window.config)

	if !render.backend_init(&window.backend, window.device, window.queue, capabilities.formats[0]) {
		return core.err_make(.Io_Failure, "could not create GPU pipelines")
	}
	return nil
}

@(private)
on_adapter :: proc "c" (
	status: wgpu.RequestAdapterStatus,
	adapter: wgpu.Adapter,
	message: string,
	userdata1, userdata2: rawptr,
) {
	if status == .Success {
		(cast(^Window)userdata1).adapter = adapter
	}
}

@(private)
on_device :: proc "c" (
	status: wgpu.RequestDeviceStatus,
	device: wgpu.Device,
	message: string,
	userdata1, userdata2: rawptr,
) {
	if status == .Success {
		(cast(^Window)userdata1).device = device
	}
}

@(private)
update_metrics :: proc(window: ^Window) {
	pixel_width, pixel_height: i32
	sdl.GetWindowSizeInPixels(window.handle, &pixel_width, &pixel_height)
	logical_width, _: i32
	sdl.GetWindowSize(window.handle, &logical_width, nil)

	window.width = f32(pixel_width)
	window.height = f32(pixel_height)
	window.scale = f32(pixel_width) / f32(max(logical_width, 1))
}

// timeline_bounds returns the rectangle the timeline occupies.
//
// In framebuffer pixels, because the draw list is built in the same space the
// shader's transform expects. The scale factor is applied once, here, rather
// than by every panel.
@(private)
timeline_bounds :: proc(window: ^Window) -> render.Rect {
	margin := TIMELINE_MARGIN * window.scale
	return render.Rect {
		x0 = margin,
		y0 = margin,
		x1 = window.width - margin,
		y1 = window.height - margin,
	}
}

// run drives the frame loop until the user quits.
run :: proc(window: ^Window, state: ^State, trace: ^codec.Trace) {
	index := ui.build_index(trace)
	bounds := timeline_bounds(window)
	resize(state, render.rect_width(bounds))
	state.viewport.origin_x = bounds.x0

	previous := time.tick_now()

	for !state.quitting {
		now := time.tick_now()
		delta := time.duration_seconds(time.tick_since(previous))
		previous = now

		// 1. Platform events become commands.
		pump_events(window, state, trace)
		if state.quitting {
			break
		}

		// 2. Playback advances the selection between events.
		advance_playback(state, trace, delta)

		// 3. Redraw only when something changed. An idle window costs the
		//    vsync wait and nothing else, which matters for a tool a user
		//    leaves open beside their editor.
		if state.revision == window.drawn_revision && !window.needs_redraw {
			sdl.Delay(4)
			continue
		}

		draw_frame(window, state, trace, index)
		window.drawn_revision = state.revision
		window.needs_redraw = false
	}
}

// pump_events translates platform events into commands and applies them.
@(private)
pump_events :: proc(window: ^Window, state: ^State, trace: ^codec.Trace) {
	event: sdl.Event
	for sdl.PollEvent(&event) {
		#partial switch event.type {
		case .QUIT:
			state.quitting = true
			return

		case .KEY_DOWN:
			key := translate_key(event.key.scancode)
			if key == .None {
				continue
			}
			command := command_for_key(key, translate_modifiers(event.key.mod), state.selection)
			apply(state, trace, command)

		case .WINDOW_PIXEL_SIZE_CHANGED:
			handle_resize(window, state)

		case .MOUSE_WHEEL:
			// Vertical wheel zooms about the cursor, which is what a user
			// expects from a timeline; horizontal scrolls it.
			mouse_x, _: f32
			_ = sdl.GetMouseState(&mouse_x, nil)
			anchor := mouse_x * window.scale

			if event.wheel.y != 0 {
				factor := 1.0 - f64(event.wheel.y) * 0.1
				apply(state, trace, Command{kind = .Zoom, anchor = anchor, factor = factor})
			}
			if event.wheel.x != 0 {
				apply(state, trace, Command{kind = .Pan, delta = event.wheel.x * 20})
			}

		case .MOUSE_MOTION:
			// Dragging with the left button held pans.
			if .LEFT in event.motion.state {
				apply(
					state,
					trace,
					Command{kind = .Pan, delta = event.motion.xrel * window.scale},
				)
			}
		}
	}
}

@(private)
translate_modifiers :: proc "contextless" (mod: sdl.Keymod) -> Modifiers {
	result: Modifiers
	if .LSHIFT in mod || .RSHIFT in mod {
		result += {.Shift}
	}
	if .LCTRL in mod || .RCTRL in mod {
		result += {.Control}
	}
	if .LALT in mod || .RALT in mod {
		result += {.Alt}
	}

	// docs/01 writes the outcome binding as "Command + Left". On macOS that is
	// the GUI key; elsewhere the same role belongs to Control. Mapping by role
	// here means the binding table above needs no per-platform branch.
	when ODIN_OS == .Darwin {
		if .LGUI in mod || .RGUI in mod {
			result += {.Primary}
		}
	} else {
		if .LCTRL in mod || .RCTRL in mod {
			result += {.Primary}
		}
	}
	return result
}

@(private)
translate_key :: proc "contextless" (scancode: sdl.Scancode) -> Key {
	#partial switch scancode {
	case .LEFT:          return .Left
	case .RIGHT:         return .Right
	case .UP:            return .Up
	case .DOWN:          return .Down
	case .SPACE:         return .Space
	case .ESCAPE:        return .Escape
	case .LEFTBRACKET:   return .Bracket_Left
	case .RIGHTBRACKET:  return .Bracket_Right
	case .F:             return .F
	case .HOME:          return .Home
	case .END:           return .End
	case ._1:            return .Digit_1
	case ._2:            return .Digit_2
	case ._3:            return .Digit_3
	case ._4:            return .Digit_4
	case ._5:            return .Digit_5
	case ._6:            return .Digit_6
	case ._7:            return .Digit_7
	}
	return .None
}

// handle_resize reconfigures the surface for a new size.
//
// docs/07: "resizing recreates only size-dependent targets." The pipelines,
// atlases, and instance ring are unaffected, so only the surface is
// reconfigured.
@(private)
handle_resize :: proc(window: ^Window, state: ^State) {
	update_metrics(window)
	if window.width <= 0 || window.height <= 0 {
		return
	}

	window.config.width = u32(window.width)
	window.config.height = u32(window.height)
	wgpu.SurfaceConfigure(window.surface, &window.config)

	bounds := timeline_bounds(window)
	state.viewport.origin_x = bounds.x0
	resize(state, render.rect_width(bounds))
	window.needs_redraw = true
}

// draw_frame performs the remaining stages of the documented frame order.
@(private)
draw_frame :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	index: ui.Timeline_Index,
) {
	// 4. Visible-data query.
	set := ui.query_visible(trace, index, state.viewport, state.lanes)
	defer ui.visible_set_destroy(&set)

	// 5 and 6. Layout and draw-list generation.
	bounds := timeline_bounds(window)
	surface := render.Rect{0, 0, window.width, window.height}
	render.draw_list_reset(&window.list, surface)

	lane_height := render.rect_height(bounds) / f32(ui.LANE_COUNT)
	ui.draw_timeline(
		&window.list,
		ui.Panel_State {
			viewport = state.viewport,
			layout = ui.Lane_Layout {
				origin_y = bounds.y0,
				lane_height = lane_height,
				padding = lane_height * 0.15,
			},
			bounds = bounds,
			theme = ui.DARK_THEME,
			selection = state.selection.event,
			playhead_ns = state.selection.playhead_ns,
			has_playhead = state.selection.has_playhead,
		},
		&set,
	)

	// 7. GPU batching.
	render.build_batches(&window.list, &window.frame)

	// 8. Submit and present.
	texture := wgpu.SurfaceGetCurrentTexture(window.surface)
	switch texture.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// Proceed.
	case .Occluded:
		if texture.texture != nil {
			wgpu.TextureRelease(texture.texture)
		}
		return
	case .Timeout, .Outdated, .Lost:
		if texture.texture != nil {
			wgpu.TextureRelease(texture.texture)
		}
		handle_resize(window, state)
		return
	case .Error:
		if texture.texture != nil {
			wgpu.TextureRelease(texture.texture)
		}
		recover_device(window, state)
		return
	}
	defer wgpu.TextureRelease(texture.texture)

	view := wgpu.TextureCreateView(texture.texture, nil)
	defer wgpu.TextureViewRelease(view)

	render.submit(
		&window.backend,
		&window.list,
		&window.frame,
		view,
		window.width,
		window.height,
		ui.DARK_THEME.background,
	)
	wgpu.SurfacePresent(window.surface)
}

// recover_device attempts one clean reinitialization after device loss.
//
// docs/07 allows exactly one attempt. A second failure means the GPU is not
// coming back, and looping would spin rather than telling the user.
@(private)
recover_device :: proc(window: ^Window, state: ^State) {
	if window.backend.device_lost {
		fmt.eprintln("norn: the GPU device was lost and could not be restored")
		state.quitting = true
		return
	}

	fmt.eprintln("norn: the GPU device was lost; reinitializing")
	render.handle_device_loss(&window.backend)

	// The device, queue, and adapter belong to the lost device and cannot be
	// reused. Application state is untouched, which is the point: the user's
	// selection, viewport, and filters survive.
	if window.queue != nil {
		wgpu.QueueRelease(window.queue)
		window.queue = nil
	}
	if window.device != nil {
		wgpu.DeviceRelease(window.device)
		window.device = nil
	}
	if window.adapter != nil {
		wgpu.AdapterRelease(window.adapter)
		window.adapter = nil
	}

	if err := acquire_device(window); !core.ok(err) {
		fmt.eprintfln("norn: %s", core.error_message(err))
		state.quitting = true
		return
	}

	window.backend.device_lost = false
	window.needs_redraw = true
}

close :: proc(window: ^Window) {
	render.backend_destroy(&window.backend)
	render.draw_list_destroy(&window.list)
	render.batched_frame_destroy(&window.frame)

	if window.queue != nil {
		wgpu.QueueRelease(window.queue)
	}
	if window.device != nil {
		wgpu.DeviceRelease(window.device)
	}
	if window.adapter != nil {
		wgpu.AdapterRelease(window.adapter)
	}
	if window.surface != nil {
		wgpu.SurfaceRelease(window.surface)
	}
	if window.instance != nil {
		wgpu.InstanceRelease(window.instance)
	}
	if window.handle != nil {
		sdl.DestroyWindow(window.handle)
	}
	sdl.Quit()
	window^ = {}
}
