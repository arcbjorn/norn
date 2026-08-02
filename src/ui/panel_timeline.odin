package ui

import "src:render"
import "src:trace/model"

// The timeline panel.
//
// Turns a visible set into draw commands. This is where docs/01's rules about
// appearance become concrete: events keep the same color family and shape at
// every zoom level, and "color is never the sole carrier of status."
//
// The panel emits draw data and reads nothing back. It has no GPU types and no
// side effects, so a test can assert what it would paint without a window.

// Theme collects every color the timeline uses.
//
// Grouped in one struct so a light theme is a different value rather than a
// different code path, and so the contrast requirement in docs/01 can be
// checked against a theme rather than hunted through call sites.
Theme :: struct {
	background:      render.Color,
	lane_background: render.Color,
	lane_separator:  render.Color,
	lane_label:      render.Color,

	// One color family per lane, per docs/01.
	conversation: render.Color,
	tools:        render.Color,
	files:        render.Color,
	commands:     render.Color,
	outcomes:     render.Color,
	errors:       render.Color,
	annotations:  render.Color,

	// Status colors, applied on top of the lane family.
	failure:   render.Color,
	selection: render.Color,
	playhead:  render.Color,
	// Fill for aggregation bins, scaled by density.
	density: render.Color,
}

// DARK_THEME is the default. Values target WCAG AA contrast against the
// background, which docs/01 requires for text.
DARK_THEME :: Theme {
	background      = render.Color{0.09, 0.10, 0.12, 1.0},
	lane_background = render.Color{0.12, 0.13, 0.16, 1.0},
	lane_separator  = render.Color{0.20, 0.21, 0.25, 1.0},
	lane_label      = render.Color{0.72, 0.74, 0.78, 1.0},
	conversation    = render.Color{0.42, 0.62, 0.92, 1.0},
	tools           = render.Color{0.55, 0.58, 0.86, 1.0},
	files           = render.Color{0.45, 0.78, 0.55, 1.0},
	commands        = render.Color{0.92, 0.72, 0.36, 1.0},
	outcomes        = render.Color{0.40, 0.80, 0.78, 1.0},
	errors          = render.Color{0.88, 0.44, 0.44, 1.0},
	annotations     = render.Color{0.68, 0.55, 0.86, 1.0},
	failure         = render.Color{0.95, 0.35, 0.35, 1.0},
	selection       = render.Color{1.00, 1.00, 1.00, 1.0},
	playhead        = render.Color{0.95, 0.95, 0.98, 1.0},
	density         = render.Color{0.50, 0.55, 0.65, 1.0},
}

// lane_color returns the color family for a lane.
lane_color :: proc "contextless" (theme: Theme, lane: Lane) -> render.Color {
	switch lane {
	case .Conversation: return theme.conversation
	case .Tools:        return theme.tools
	case .Files:        return theme.files
	case .Commands:     return theme.commands
	case .Outcomes:     return theme.outcomes
	case .Errors:       return theme.errors
	case .Annotations:  return theme.annotations
	}
	return theme.conversation
}

// Layer ordering. Painter's order matters here: a selection ring drawn under
// its event would be invisible, and a playhead under the events would be lost
// in a dense region.
LAYER_BACKGROUND :: u16(0)
LAYER_EVENTS     :: u16(1)
LAYER_FAILURES   :: u16(2)
LAYER_SELECTION  :: u16(3)
LAYER_PLAYHEAD   :: u16(4)

// LABEL_GUTTER is the width reserved for lane names, in device pixels.
//
// Lane labels are the difference between a timeline and a set of coloured
// bars. docs/01 requires the interface to be readable, and a lane whose
// meaning the user has to remember is not.
LABEL_GUTTER :: f32(96)

// Panel_State is what the timeline needs beyond the trace itself.
Panel_State :: struct {
	viewport:  Viewport,
	layout:    Lane_Layout,
	bounds:    render.Rect,
	theme:     Theme,
	// Fonts for lane labels. Nil draws no text, which is what happens when no
	// typeface could be loaded — better than boxes that look like data.
	fonts: ^render.Font_Set,
	atlas: ^render.Atlas,
	// The currently selected event, or NO_EVENT.
	selection: model.Event_Id,
	// The playhead time. docs/01 makes the selected time control every panel.
	playhead_ns: i64,
	// Whether the playhead is set at all; a session opens with no time chosen.
	has_playhead: bool,

	// Why the panel might be empty. docs/01: "empty panels explain why they are
	// empty: no events, filtered out, unsupported record, replay gap, or
	// missing repository." The panel can see that its visible set is empty but
	// not why, and the difference is what the user needs: a filtered view has
	// something to undo, an empty trace does not.
	total_events: int,
	// True when a lane filter, a search, or both are narrowing what is shown.
	filtering: bool,
	// Scale, for text placed in the empty state.
	scale: f32,

	// A one-line summary of the session's import warnings, empty when there
	// are none. docs/01 keeps warnings "part of the session metadata" rather
	// than letting them vanish with the import dialog, and an overlay a user
	// must already know about is nearly as invisible as no overlay at all.
	warning_summary: string,
	// True when a warning limits what can be concluded rather than only
	// reducing completeness, so the notice can carry more weight.
	warning_serious: bool,
}

// FAILURE_MARKER_HEIGHT is the height of the tick drawn above a failure.
//
// docs/01: "color is never the sole carrier of status." A failing event gets a
// distinct shape as well as a distinct color, so the timeline stays readable
// for a user who cannot distinguish red from green.
FAILURE_MARKER_HEIGHT :: f32(3)

// draw_timeline emits the commands for one frame of the timeline.
draw_timeline :: proc(
	list: ^render.Draw_List,
	state: Panel_State,
	set: ^Visible_Set,
) {
	// Everything the panel draws is confined to its bounds, so a long event
	// cannot paint over a neighbouring panel.
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	draw_lane_backgrounds(list, state)

	if len(set.events) == 0 {
		draw_empty_state(list, state)
		// The playhead still draws: it is a property of the selection rather
		// than of the events, and hiding it would make an empty view look
		// like a different moment.
		draw_playhead(list, state)
		return
	}

	draw_events(list, state, set)
	draw_selection(list, state, set)
	draw_playhead(list, state)
	draw_warning_notice(list, state)
}

// draw_warning_notice puts the session's import warnings where they cannot be
// missed.
//
// Bottom-left of the timeline, out of the way of the lanes but always present.
// A trace can be quietly incomplete — records dropped, timestamps repaired —
// and every panel would still render confidently. This is the standing reminder
// that some of what is not shown was not absent from the session.
@(private)
draw_warning_notice :: proc(list: ^render.Draw_List, state: Panel_State) {
	if state.warning_summary == "" || state.fonts == nil || state.atlas == nil {
		return
	}

	scale := state.scale if state.scale > 0 else 1
	colour := state.theme.failure if state.warning_serious else state.theme.lane_label

	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		state.warning_summary,
		state.bounds.x0 + 8 * scale,
		state.bounds.y1 - 16 * scale,
		render.rect_width(state.bounds) - 16 * scale,
		colour,
	)
}

// draw_empty_state says why the timeline has nothing to show.
//
// docs/01 lists the reasons a panel can be empty and requires it to name one.
// The distinction that matters here is between a view the user narrowed and a
// trace that holds nothing: the first has something to undo, and a blank panel
// that did not say so reads as a broken program.
@(private)
draw_empty_state :: proc(list: ^render.Draw_List, state: Panel_State) {
	if state.fonts == nil || state.atlas == nil {
		return
	}

	message: string
	switch {
	case state.total_events == 0:
		message = "This session recorded no events."
	case state.filtering:
		message = "No events match the current filters."
	case:
		// Events exist and nothing is filtered, so the viewport is simply
		// somewhere the session is not. Naming the remedy beats naming the
		// state, because the state is not what the user wants to know.
		message = "No events in this time range. Press Home to fit the session."
	}

	scale := state.scale if state.scale > 0 else 1
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		message,
		state.bounds.x0 + 16 * scale,
		state.bounds.y0 + 16 * scale,
		render.rect_width(state.bounds) - 32 * scale,
		state.theme.lane_label,
	)
}

@(private)
draw_lane_backgrounds :: proc(list: ^render.Draw_List, state: Panel_State) {
	previous_layer := render.set_layer(list, LAYER_BACKGROUND)
	defer render.set_layer(list, previous_layer)

	render.fill_rect(list, state.bounds, state.theme.background)

	for lane in Lane {
		top := state.layout.origin_y + f32(int(lane)) * state.layout.lane_height
		bottom := top + state.layout.lane_height

		// Alternating bands give the eye a horizontal guide across a wide
		// timeline without needing gridlines.
		if int(lane) % 2 == 1 {
			render.fill_rect(
				list,
				render.Rect{x0 = state.bounds.x0, y0 = top, x1 = state.bounds.x1, y1 = bottom},
				state.theme.lane_background,
			)
		}

		render.draw_line(
			list,
			state.bounds.x0,
			bottom,
			state.bounds.x1,
			bottom,
			state.theme.lane_separator,
		)
	}

	draw_lane_labels(list, state)
}

// draw_lane_labels names each swimlane in the gutter.
@(private)
draw_lane_labels :: proc(list: ^render.Draw_List, state: Panel_State) {
	if state.fonts == nil || state.atlas == nil {
		return
	}

	// The gutter is the space between the panel's left edge and where the
	// viewport begins. Deriving it from the viewport rather than from the
	// LABEL_GUTTER constant is what keeps it correct on a high-DPI display:
	// the caller scales the constant when it places the viewport, and reading
	// the unscaled constant here would size the label box in logical pixels
	// while the glyphs were rasterized in device pixels.
	gutter := state.viewport.origin_x - state.bounds.x0
	if gutter <= 0 {
		return
	}

	for lane in Lane {
		top := state.layout.origin_y + f32(int(lane)) * state.layout.lane_height
		box := render.Rect {
			x0 = state.bounds.x0 + 6,
			y0 = top,
			x1 = state.bounds.x0 + gutter - 6,
			y1 = top + state.layout.lane_height,
		}

		// The label is tinted with its lane's colour rather than drawn in the
		// neutral text colour, which ties the name to the bars beneath it
		// without relying on position alone.
		color := lane_color(state.theme, lane)
		render.draw_text_aligned(
			list,
			state.fonts,
			state.atlas,
			lane_name(lane),
			box,
			.Left,
			render.with_alpha(color, 0.85),
		)
	}
}

@(private)
draw_events :: proc(list: ^render.Draw_List, state: Panel_State, set: ^Visible_Set) {
	previous_layer := render.set_layer(list, LAYER_EVENTS)
	defer render.set_layer(list, previous_layer)

	for event in set.events {
		y0, y1 := lane_bounds(state.layout, event.lane)
		rect := render.Rect{x0 = event.bounds.x0, y0 = y0, x1 = event.bounds.x1, y1 = y1}

		color := lane_color(state.theme, event.lane)
		if event.is_failure {
			color = state.theme.failure
		}

		// A narrow event is drawn square: rounding a two-pixel bar removes the
		// pixels that make it visible at all.
		if event.bounds.x1 - event.bounds.x0 >= 6 {
			render.fill_rounded_rect(list, rect, color, 2)
		} else {
			render.fill_rect(list, rect, color)
		}
	}

	draw_failure_markers(list, state, set)
}

// draw_failure_markers adds the non-color status indicator.
@(private)
draw_failure_markers :: proc(list: ^render.Draw_List, state: Panel_State, set: ^Visible_Set) {
	previous_layer := render.set_layer(list, LAYER_FAILURES)
	defer render.set_layer(list, previous_layer)

	for event in set.events {
		if !event.is_failure {
			continue
		}
		y0, _ := lane_bounds(state.layout, event.lane)

		// A tick above the bar, wider than the bar itself for a narrow event
		// so it remains visible where the event is only a couple of pixels.
		width := max(event.bounds.x1 - event.bounds.x0, f32(4))
		centre := (event.bounds.x0 + event.bounds.x1) * 0.5

		render.fill_rect(
			list,
			render.Rect {
				x0 = centre - width * 0.5,
				y0 = y0 - FAILURE_MARKER_HEIGHT - 1,
				x1 = centre + width * 0.5,
				y1 = y0 - 1,
			},
			state.theme.failure,
		)
	}
}

@(private)
draw_selection :: proc(list: ^render.Draw_List, state: Panel_State, set: ^Visible_Set) {
	if state.selection == model.NO_EVENT {
		return
	}

	previous_layer := render.set_layer(list, LAYER_SELECTION)
	defer render.set_layer(list, previous_layer)

	for event in set.events {
		if event.id != state.selection {
			continue
		}
		y0, y1 := lane_bounds(state.layout, event.lane)

		// An outline rather than a fill, so the event's own color still
		// communicates its kind while selected.
		render.stroke_rect(
			list,
			render.Rect {
				x0 = event.bounds.x0 - 1,
				y0 = y0 - 1,
				x1 = event.bounds.x1 + 1,
				y1 = y1 + 1,
			},
			state.theme.selection,
			2,
		)
		return
	}
}

@(private)
draw_playhead :: proc(list: ^render.Draw_List, state: Panel_State) {
	if !state.has_playhead {
		return
	}

	previous_layer := render.set_layer(list, LAYER_PLAYHEAD)
	defer render.set_layer(list, previous_layer)

	// Positioned through the same transform the events used, so the playhead
	// lands exactly between the events it separates.
	x := time_to_x(state.viewport, state.playhead_ns)
	render.draw_line(list, x, state.bounds.y0, x, state.bounds.y1, state.theme.playhead, 1)
}

// draw_aggregated emits binned density instead of individual events.
//
// docs/07: at distant zoom, events aggregate into fixed screen-space bins, and
// aggregation "must preserve the visibility of failures". Failures are drawn
// individually on top of the bins for exactly that reason.
draw_aggregated :: proc(
	list: ^render.Draw_List,
	state: Panel_State,
	bins: ^Aggregate_Set,
	lane: Lane,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	y0, y1 := lane_bounds(state.layout, lane)
	height := y1 - y0

	peak := peak_density(bins)
	if peak <= 0 {
		return
	}

	previous_layer := render.set_layer(list, LAYER_EVENTS)
	for bin in bins.bins {
		if bin.total == 0 {
			continue
		}
		// Bar height encodes density. Every non-empty bin gets at least one
		// pixel: a bin drawn as nothing would read as a gap in the session.
		fraction := f32(bin.total) / f32(peak)
		bar := max(height * fraction, 1)

		render.fill_rect(
			list,
			render.Rect{x0 = bin.x0, y0 = y1 - bar, x1 = bin.x1, y1 = y1},
			state.theme.density,
		)
	}
	render.set_layer(list, previous_layer)

	// Failures survive aggregation as individual marks.
	previous_layer = render.set_layer(list, LAYER_FAILURES)
	for failure in bins.failures {
		centre := (failure.bounds.x0 + failure.bounds.x1) * 0.5
		render.fill_rect(
			list,
			render.Rect{x0 = centre - 2, y0 = y0, x1 = centre + 2, y1 = y1},
			state.theme.failure,
		)
	}
	render.set_layer(list, previous_layer)
}
