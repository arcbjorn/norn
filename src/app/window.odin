package app

import "core:fmt"
import "core:time"

import sdl "vendor:sdl3"
import "vendor:wgpu"
import "vendor:wgpu/sdl3glue"

import "src:analysis"
import "src:core"
import "src:render"
import "src:replay"
import "src:trace/codec"
import "src:trace/model"
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

	// Typefaces and the atlases derived from them. `fonts_loaded` is false
	// when no usable face was found, which degrades to an unlabelled timeline
	// rather than preventing the window from opening.
	fonts:        render.Font_Set,
	fonts_loaded: bool,
	// The monospace atlas, held because the diff panel needs it every frame
	// and the scale can change between them.
	mono_atlas: ^render.Atlas,
	// The repository map, borrowed from the frame loop so the input handler
	// can hit test against the same layout the frame drew.
	graph: ^analysis.Graph,

	// Framebuffer size in pixels and the display scale that produced it.
	width, height: f32,
	scale:         f32,

	// Height reserved at the top for the search bar, zero when it is closed.
	// Every panel's origin is offset by it, so opening search moves the
	// workspace down rather than drawing over it.
	top_offset: f32,
	// Where the filter chips were drawn, so a click resolves against the same
	// rectangles. docs/07 prohibits a second copy of the geometry.
	chips: ui.Chip_Layout,

	// The revision last drawn, so an unchanged frame is not redrawn.
	drawn_revision: u64,
	// Forces a redraw regardless of revision, after a resize or a device
	// reinitialization where the previous frame's pixels are gone.
	needs_redraw: bool,
}

// WARNINGS_WIDTH and WARNINGS_HEIGHT size the import-notes overlay, in logical
// pixels. Wide enough for a full sentence per line, since every line states a
// consequence rather than a category name.
WARNINGS_WIDTH :: f32(560)
WARNINGS_HEIGHT :: f32(420)

// TIMELINE_MARGIN is the space reserved around the timeline panel.
TIMELINE_MARGIN :: f32(16)

// INSPECTOR_WIDTH is the inspector's width in logical pixels.
//
// docs/01 puts the inspector on the right of the workspace. A fixed width
// rather than a fraction: the panel shows labelled fields, and a proportional
// column would leave them cramped on a small window and stretched on a large
// one.
INSPECTOR_WIDTH :: f32(320)

// DIFF_HEIGHT_FRACTION is how much of the window the diff panel occupies.
//
// docs/01 puts it along the bottom, spanning the workspace. A fraction rather
// than a fixed height because its content is many short lines: more window
// means more lines visible, which is the useful direction to scale.
DIFF_HEIGHT_FRACTION :: f32(0.38)

// MINIMUM_DIFF_HEIGHT is the height below which the diff panel is hidden.
MINIMUM_DIFF_HEIGHT :: f32(120)

// MAP_WIDTH is the repository map's width in logical pixels.
//
// docs/01 places it on the left of the workspace. Narrower than the inspector
// because the map is read spatially rather than as labelled rows.
MAP_WIDTH :: f32(260)

// MINIMUM_TIMELINE_WIDTH is the width below which the inspector is hidden.
//
// A window too narrow for both panels should show the timeline, which is the
// primary surface. Squeezing both would make neither usable.
MINIMUM_TIMELINE_WIDTH :: f32(360)

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
	left := margin
	if map_visible(window) {
		left = map_bounds(window).x1 + margin
	}
	right := window.width - margin
	if inspector_visible(window) {
		right = inspector_bounds(window).x0 - margin
	}
	bottom := window.height - margin
	if diff_visible(window) {
		bottom = diff_bounds(window).y0 - margin
	}
	return render.Rect{x0 = left, y0 = window.top_offset + margin, x1 = right, y1 = bottom}
}

// search_bounds returns the top bar's rectangle.
//
// docs/01 places Search and Filters in the top bar, spanning the full width
// above every other panel.
search_bounds :: proc(window: ^Window) -> render.Rect {
	return render.Rect {
		x0 = 0,
		y0 = 0,
		x1 = window.width,
		y1 = ui.SEARCH_BAR_HEIGHT * window.scale,
	}
}

// map_bounds returns the rectangle the repository map occupies.
//
// It stops above the diff panel rather than spanning the full height, so the
// two do not overlap on a short window.
@(private)
map_bounds :: proc(window: ^Window) -> render.Rect {
	bottom := window.height
	if diff_visible(window) {
		bottom = diff_bounds(window).y0
	}
	return render.Rect {
		x0 = 0,
		y0 = window.top_offset,
		x1 = MAP_WIDTH * window.scale,
		y1 = bottom,
	}
}

// map_visible reports whether the window is wide enough for the map.
//
// The timeline is the primary surface, so it keeps its minimum width and the
// map is the first thing dropped as the window narrows.
@(private)
map_visible :: proc(window: ^Window) -> bool {
	needed :=
		(MAP_WIDTH + INSPECTOR_WIDTH + MINIMUM_TIMELINE_WIDTH + TIMELINE_MARGIN * 4) *
		window.scale
	return window.width >= needed
}

// diff_bounds returns the rectangle the diff panel occupies.
//
// It spans the full window width rather than stopping at the inspector: a diff
// is read line by line, and the extra width is worth more here than a clean
// column edge.
@(private)
diff_bounds :: proc(window: ^Window) -> render.Rect {
	height := window.height * DIFF_HEIGHT_FRACTION
	return render.Rect {
		x0 = 0,
		y0 = window.height - height,
		x1 = window.width,
		y1 = window.height,
	}
}

// warnings_bounds returns the rectangle the import-notes overlay occupies.
//
// An overlay rather than a reserved band: the notes are read once when a
// question arises about the trace's completeness, not watched continuously.
// Giving them permanent space would cost the timeline every session, including
// the ones that imported cleanly.
warnings_bounds :: proc(window: ^Window) -> render.Rect {
	width := min(WARNINGS_WIDTH * window.scale, window.width - 32 * window.scale)
	height := min(WARNINGS_HEIGHT * window.scale, window.height - 32 * window.scale)
	x := (window.width - width) * 0.5
	y := (window.height - height) * 0.5
	return render.Rect{x0 = x, y0 = y, x1 = x + width, y1 = y + height}
}

// diff_visible reports whether the window is tall enough for the diff panel.
@(private)
diff_visible :: proc(window: ^Window) -> bool {
	return window.height * DIFF_HEIGHT_FRACTION >= MINIMUM_DIFF_HEIGHT * window.scale
}

// inspector_bounds returns the rectangle the inspector occupies.
@(private)
inspector_bounds :: proc(window: ^Window) -> render.Rect {
	width := INSPECTOR_WIDTH * window.scale
	return render.Rect {
		x0 = window.width - width,
		y0 = window.top_offset,
		x1 = window.width,
		y1 = window.height,
	}
}

// inspector_visible reports whether the window is wide enough for both panels.
@(private)
inspector_visible :: proc(window: ^Window) -> bool {
	needed := (INSPECTOR_WIDTH + MINIMUM_TIMELINE_WIDTH + TIMELINE_MARGIN * 2) * window.scale
	return window.width >= needed
}

// run drives the frame loop until the user quits.
run :: proc(window: ^Window, state: ^State, trace: ^codec.Trace) {
	index := ui.build_index(trace)

	// The outcome index is derived from immutable trace data, so it is built
	// once rather than per frame.
	outcomes := analysis.build_outcome_index(trace)
	defer analysis.outcome_index_destroy(&outcomes)

	// The repository map. Built once per trace: docs/07 requires the layout to
	// be deterministic for a given trace, and rebuilding it per frame would
	// also cost the 38 ms the layout takes at the node budget.
	graph := analysis.build_graph(trace)
	defer analysis.graph_destroy(&graph)
	window.graph = &graph

	// Replay for the open trace. A trace with no mutations has nothing to
	// reconstruct, which the diff panel reports rather than treating as a
	// failure to open.
	session: Replay_Session
	replay_session_init(&session, trace)
	defer replay_session_destroy(&session)
	if !load_fonts(window) {
		fmt.eprintln("norn: no usable font was found; the timeline will draw without labels")
	}

	bounds := timeline_bounds(window)
	apply_layout(window, state, bounds)

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

		draw_frame(window, state, trace, index, &outcomes, &session, &graph)
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
			was_open := state.search_open
			command := command_for_key(
				key,
				translate_modifiers(event.key.mod),
				state.selection,
				state.search_open,
				state.warnings_open,
			)
			apply(state, trace, command)

			// SDL only delivers TEXT_INPUT while text input is started, and
			// starting it is what lets the platform run an input method. Kept
			// in step with the panel here rather than at the command layer,
			// which knows nothing about SDL.
			if state.search_open != was_open {
				// The result is ignored deliberately. If the platform refuses
				// to start text input the field cannot be typed into, but the
				// filter chips still work — and failing to open search at all
				// would remove those too.
				if state.search_open {
					_ = sdl.StartTextInput(window.handle)
				} else {
					_ = sdl.StopTextInput(window.handle)
				}
			}

		case .TEXT_INPUT:
			// Decoded by the platform, so this receives characters rather than
			// scancodes: a layout that produces `/` on a different physical key
			// still types the right thing, and an input method can deliver
			// several characters at once.
			if state.search_open && event.text.text != nil {
				apply(
					state,
					trace,
					Command{kind = .Search_Append, text = string(event.text.text)},
				)
			}

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

		case .MOUSE_BUTTON_DOWN:
			if event.button.button == 1 {
				select_at_pointer(window, state, trace, event.button.x, event.button.y)
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

// select_at_pointer selects the event under a click.
//
// Hit testing runs against the same visible set the frame drew, using the
// bounds computed there. docs/07 prohibits recomputing this: two formulas
// drift, and the symptom is a click selecting the neighbour of what the user
// pointed at.
@(private)
select_at_pointer :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	logical_x, logical_y: f32,
) {
	x := logical_x * window.scale
	y := logical_y * window.scale

	// The search bar is drawn above everything, so it claims clicks first.
	// Removing a chip must work wherever it was drawn, including over the area
	// a panel would otherwise own.
	if state.search_open && render.rect_contains(search_bounds(window), x, y) {
		toggle_chip_at(window, state, trace, x, y)
		return
	}

	// The map claims clicks in its own area. Focusing a file there is what
	// gives the diff panel its subject.
	if map_visible(window) && render.rect_contains(map_bounds(window), x, y) {
		select_in_map(window, state, trace, x, y)
		return
	}

	bounds := timeline_bounds(window)
	if !render.rect_contains(bounds, x, y) {
		return
	}

	index := ui.build_index(trace)
	set := ui.query_visible(trace, index, state.viewport, state.lanes, context.temp_allocator)
	defer ui.visible_set_destroy(&set)

	lane_height := render.rect_height(bounds) / f32(ui.LANE_COUNT)
	layout := ui.Lane_Layout {
		origin_y    = bounds.y0,
		lane_height = lane_height,
		padding     = lane_height * 0.15,
	}

	hit := ui.hit_test(&set, layout, x, y)
	if hit.found {
		apply(state, trace, Command{kind = .Select_Event, event = hit.event})
		return
	}

	// Clicking empty timeline moves the playhead without changing the
	// selection, which is how a user scrubs to a moment between events.
	apply(state, trace, Command{kind = .Set_Playhead, time_ns = ui.x_to_time(state.viewport, x)})
}

// select_in_map focuses the file under a click on the repository map.
@(private)
select_in_map :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	x, y: f32,
) {
	graph := window.graph
	if graph == nil {
		return
	}

	entity, found := ui.hit_test_map(
		ui.Map_State {
			bounds = map_bounds(window),
			scale = window.scale,
			filter = state.map_filter,
		},
		graph,
		x,
		y,
	)
	if !found {
		return
	}

	state.selection.focus_kind = .Entity
	state.selection.focus_entity = entity
	state.revision += 1
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
	case .D:             return .D
	case .SLASH:         return .Slash
	case .N:             return .N
	case .RETURN:        return .Return
	case .BACKSPACE:     return .Backspace
	case .W:             return .W
	case .PAGEUP:        return .Page_Up
	case .PAGEDOWN:      return .Page_Down
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
	apply_layout(window, state, bounds)
	window.needs_redraw = true
}

// apply_layout sizes the viewport to the timeline area.
//
// The label gutter is subtracted here rather than inside the panel, because
// the viewport transform is what hit testing uses: an event drawn past the
// gutter must also be clickable there, and two different notions of where the
// timeline starts is exactly the drift docs/07 prohibits.
@(private)
apply_layout :: proc(window: ^Window, state: ^State, bounds: render.Rect) {
	gutter := ui.LABEL_GUTTER * window.scale if window.fonts_loaded else 0
	state.viewport.origin_x = bounds.x0 + gutter
	resize(state, render.rect_width(bounds) - gutter)
}

// load_fonts loads the interface and monospace faces.
//
// The candidates are macOS system fonts. docs/13 records that bundling a face
// or discovering one per platform is an open packaging question; until it is
// answered, a missing font degrades to an unlabelled timeline rather than
// preventing the application from opening.
@(private)
load_fonts :: proc(window: ^Window) -> bool {
	render.font_set_init(&window.fonts)

	interface_candidates := []string {
		"/System/Library/Fonts/SFNS.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
		"/System/Library/Fonts/Supplemental/Arial.ttf",
	}
	monospace_candidates := []string {
		"/System/Library/Fonts/SFNSMono.ttf",
		"/System/Library/Fonts/Menlo.ttc",
		"/System/Library/Fonts/Supplemental/Andale Mono.ttf",
	}

	for path in interface_candidates {
		if render.load_face(&window.fonts, .Interface, path) {
			break
		}
	}
	for path in monospace_candidates {
		if render.load_face(&window.fonts, .Monospace, path) {
			break
		}
	}

	window.fonts_loaded = render.has_face(&window.fonts, .Interface)
	return window.fonts_loaded
}

// draw_frame performs the remaining stages of the documented frame order.
@(private)
draw_frame :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	index: ui.Timeline_Index,
	outcomes: ^analysis.Outcome_Index,
	session: ^Replay_Session,
	graph: ^analysis.Graph,
) {
	// docs/01: dragging the playhead updates the virtual repository and all
	// derived panels. Seeking here, before any panel reads it, is what keeps
	// the diff and the timeline describing the same moment.
	if state.selection.has_playhead {
		seek_to(session, trace, state.selection.playhead_ns)
	}
	// The search bar reserves its band before any bounds are computed, so every
	// panel below it is positioned once rather than drawn and then moved.
	window.top_offset = ui.SEARCH_BAR_HEIGHT * window.scale if state.search_open else 0
	apply_layout(window, state, timeline_bounds(window))

	// 4. Visible-data query.
	set := ui.query_visible(trace, index, state.viewport, state.lanes)
	defer ui.visible_set_destroy(&set)

	// 5 and 6. Layout and draw-list generation.
	bounds := timeline_bounds(window)
	surface := render.Rect{0, 0, window.width, window.height}
	render.draw_list_reset(&window.list, surface)

	lane_height := render.rect_height(bounds) / f32(ui.LANE_COUNT)

	// The atlas is fetched per frame rather than cached on the window: the
	// scale factor changes when the window moves between displays, and the
	// cache key includes it, so asking each frame is what keeps text crisp
	// after such a move.
	atlas: ^render.Atlas
	heading: ^render.Atlas
	if window.fonts_loaded {
		atlas = render.get_atlas(
			&window.fonts,
			render.Atlas_Key{font = .Interface, size = 12, scale = window.scale},
		)
		heading = render.get_atlas(
			&window.fonts,
			render.Atlas_Key{font = .Interface, size = 15, scale = window.scale},
		)
		window.mono_atlas = render.get_atlas(
			&window.fonts,
			render.Atlas_Key{font = .Monospace, size = 12, scale = window.scale},
		)
	}

	ui.draw_timeline(
		&window.list,
		ui.Panel_State {
			viewport = state.viewport,
			fonts = &window.fonts if window.fonts_loaded else nil,
			atlas = atlas,
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
			scale = window.scale,
			// docs/01 requires an empty panel to say why. Only the caller knows
			// whether the view was narrowed or the trace is simply empty.
			total_events = len(trace.events),
			filtering = state.lanes != ui.ALL_LANES || search_active(state),
			// Hidden while the overlay is open, since it says the same thing
			// at length two hundred pixels away.
			warning_summary = "" if state.warnings_open else warning_notice(trace),
			warning_serious = ui.has_serious_warnings(&trace.metadata),
		},
		&set,
	)

	if inspector_visible(window) {
		ui.draw_inspector(
			&window.list,
			ui.Inspector_State {
				bounds = inspector_bounds(window),
				theme = ui.DARK_INSPECTOR,
				fonts = &window.fonts if window.fonts_loaded else nil,
				atlas = atlas,
				heading_atlas = heading,
				scale = window.scale,
				selection = state.selection.event,
				scroll = state.inspector_scroll,
			},
			trace,
			outcomes,
		)
	}

	if state.search_open {
		window.chips = ui.draw_search(
			&window.list,
			ui.Search_State {
				bounds = search_bounds(window),
				theme = ui.DARK_SEARCH,
				fonts = &window.fonts if window.fonts_loaded else nil,
				atlas = atlas,
				scale = window.scale,
				text = string(state.search_text[:]),
				kinds = state.search_query.kinds,
				failed_only = state.search_query.failed_only,
				scoped_path = state.search_query.path,
				has_range = state.search_query.start_ns != 0 ||
					state.search_query.end_ns != 0,
				match_count = len(state.search_results.matches),
				selected = state.search_selected,
				examined = state.search_results.examined,
				excluded_by_kind = state.search_results.excluded_by_kind,
				excluded_by_time = state.search_results.excluded_by_time,
				excluded_by_path = state.search_results.excluded_by_path,
				excluded_by_outcome = state.search_results.excluded_by_outcome,
				truncated = state.search_results.truncated,
			},
		)
	} else {
		window.chips = {}
	}

	if map_visible(window) {
		ui.draw_map(
			&window.list,
			ui.Map_State {
				bounds = map_bounds(window),
				theme = ui.DARK_MAP,
				fonts = &window.fonts if window.fonts_loaded else nil,
				atlas = atlas,
				scale = window.scale,
				selection = state.selection.focus_entity,
				focus = state.selection.focus_entity,
				has_focus = false,
				filter = state.map_filter,
			},
			graph,
			trace,
		)
	}

	if diff_visible(window) {
		draw_diff_panel(window, state, trace, session, heading)
	}

	// Last, so the overlay sits above every panel it covers.
	if state.warnings_open {
		state.warnings_height = ui.draw_warnings(
			&window.list,
			ui.Warning_State {
				bounds = warnings_bounds(window),
				theme = ui.DARK_WARNINGS,
				fonts = &window.fonts if window.fonts_loaded else nil,
				atlas = atlas,
				heading_atlas = heading,
				scale = window.scale,
				scroll = state.warnings_scroll,
			},
			&trace.metadata,
		)
	}

	// 7. GPU batching.
	render.build_batches(&window.list, &window.frame)

	// Glyphs are rasterized lazily during draw-list generation, so the atlas
	// is uploaded after the panel has run and before anything samples it.
	render.upload_atlas(&window.backend, atlas)
	render.upload_atlas(&window.backend, heading)
	render.upload_atlas(&window.backend, window.mono_atlas)

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

// draw_diff_panel renders the file content for the focused path.
//
// The panel shows what the replay engine produced and nothing else. docs/01
// forbids filling a gap with an unlabelled substitution, so every state the
// engine can report — a gap, a deletion, unverified content — is passed
// through rather than smoothed over.
@(private)
draw_diff_panel :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	session: ^Replay_Session,
	heading: ^render.Atlas,
) {
	bounds := diff_bounds(window)
	panel := ui.Diff_Panel_State {
		bounds       = bounds,
		theme        = ui.DARK_DIFF,
		fonts        = &window.fonts if window.fonts_loaded else nil,
		mono         = window.mono_atlas,
		heading      = heading,
		scale        = window.scale,
		scroll_lines = state.diff_scroll_lines,
	}

	// No focused file means no subject. Picking one would present arbitrary
	// content as the thing the user is investigating.
	if state.selection.focus_kind != .Entity {
		ui.draw_diff(
			&window.list,
			panel,
			ui.Diff_Content{mode = .At_Playhead, status = .Unknown_Path},
		)
		return
	}

	path := state.selection.focus_entity
	resolved := resolve_path(session, path)

	content := ui.Diff_Content {
		path      = entity_path(trace, path),
		mode      = state.diff_mode,
		status    = resolved.status,
		gap_event = u64(resolved.gap_event),
	}

	// Without displayable content there is nothing to compare, and the status
	// already explains why. Showing an empty diff instead would suggest the
	// file was unchanged rather than unknown.
	if !replay.has_content(resolved) {
		ui.draw_diff(&window.list, panel, content)
		return
	}

	if state.diff_mode == .At_Playhead {
		content.lines = replay.split_lines(resolved.content, context.temp_allocator)
		ui.draw_diff(&window.list, panel, content)
		return
	}

	before, available := comparison_baseline(session, state, trace, path)
	if !available {
		// A comparison with no earlier state to compare against. Falling back
		// to the plain view is honest — the content is real — but the mode
		// label would then claim a comparison that did not happen, so the
		// panel is told it is showing state alone.
		content.mode = .At_Playhead
		content.lines = replay.split_lines(resolved.content, context.temp_allocator)
		ui.draw_diff(&window.list, panel, content)
		return
	}
	defer delete(before, context.temp_allocator)

	diff := replay.diff_text(before, resolved.content, context.temp_allocator)
	defer replay.diff_destroy(&diff)
	content.diff = &diff

	ui.draw_diff(&window.list, panel, content)
}

@(private)
entity_path :: proc(trace: ^codec.Trace, id: model.Entity_Id) -> string {
	if id == model.NO_ENTITY {
		return ""
	}
	index := int(id) - 1
	if index < 0 || index >= len(trace.entities) {
		return ""
	}
	name, ok := model.string_get(&trace.strings, trace.entities[index].name)
	if !ok {
		return ""
	}
	return name
}

// comparison_baseline returns the earlier state the selected mode compares to.
//
// Each mode names a different moment, and getting one wrong would show a diff
// against a time the user did not ask about — which reads as a real change
// that never happened.
@(private)
comparison_baseline :: proc(
	session: ^Replay_Session,
	state: ^State,
	trace: ^codec.Trace,
	path: model.Entity_Id,
) -> (
	content: []byte,
	available: bool,
) {
	#partial switch state.diff_mode {
	case .From_Previous_Mutation:
		return previous_mutation_content(session, trace, path, context.temp_allocator)

	case .From_Session_Start:
		return baseline_content(session, path, context.temp_allocator)

	case .Across_Range:
		// docs/01 sets this range with the bracket keys. Without both ends
		// there is no range, and guessing one would compare against an
		// arbitrary moment.
		if !has_range(state.selection) {
			return nil, false
		}
		from, _ := range_bounds(state.selection)
		return content_at(session, trace, path, from, context.temp_allocator)
	}
	return nil, false
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
	render.font_set_destroy(&window.fonts)

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

// toggle_chip_at removes or restores the filter a click landed on.
//
// Hit tested against the rectangles draw_search recorded, not against
// recomputed geometry. docs/07 prohibits the second copy: chips are laid out by
// measured text width, so a reimplementation would drift as soon as a label or
// a font changed, and the symptom would be clicks that do nothing.
@(private)
toggle_chip_at :: proc(
	window: ^Window,
	state: ^State,
	trace: ^codec.Trace,
	x, y: f32,
) {
	chip, found := ui.chip_at(&window.chips, x, y)
	if !found {
		return
	}

	switch chip.kind {
	case .Family:
		apply(state, trace, Command{kind = .Search_Toggle_Kind, family = chip.family})
	case .Failed_Only:
		apply(state, trace, Command{kind = .Search_Toggle_Failed_Only})
	case .Scoped_Path:
		// Clicking the chip removes the scope, which is what a removable chip
		// means. Scoping is re-applied from the focus, not from the chip.
		state.search_query.path = model.NO_ENTITY
		run_search(state, trace)
		state.revision += 1
	case .Range:
		state.search_query.start_ns = 0
		state.search_query.end_ns = 0
		run_search(state, trace)
		state.revision += 1
	}
}

// warning_notice builds the standing summary, with the key that opens the
// detail appended.
//
// The binding is included because the summary is the only place a user learns
// the detail exists. A notice that reported a problem without saying how to
// read it would be worse than none.
@(private)
warning_notice :: proc(trace: ^codec.Trace) -> string {
	summary := ui.warning_summary(&trace.metadata)
	if summary == "" {
		return ""
	}
	return fmt.tprintf("%s  ·  press W for detail", summary)
}
