package ui

import "src:trace/model"

// Timeline viewport transforms.
//
// docs/07-rendering.md: timeline coordinates use nanoseconds mapped through a
// viewport transform, and hit testing uses the same transforms as drawing —
// "approximate duplicate math in the UI layer is prohibited because it creates
// selection drift."
//
// That rule is why this file exists as a separate unit. There is exactly one
// conversion in each direction, both derived from the same fields, and both
// the renderer and the input handler call them. A panel that computed pixel
// positions itself would drift from what the user clicks the moment either
// formula changed.

// Viewport maps a time interval onto a pixel span.
//
// `start_ns` and `span_ns` describe the visible interval; `width` is the pixel
// width of the timeline area. Coordinates are logical pixels: docs/07 keeps
// window coordinates logical and applies display scale at rasterization, so
// hit testing never has to know the scale factor.
Viewport :: struct {
	start_ns: i64,
	span_ns:  i64,
	width:    f32,
	// Pixel offset of the timeline area from the left edge of the window.
	origin_x: f32,
}

// MIN_SPAN_NS bounds how far the timeline can be zoomed in.
//
// One microsecond across the full width is already far beyond the resolution
// of recorded agent activity. Allowing an arbitrarily small span would let
// floating-point conversion lose the ordering between adjacent events.
MIN_SPAN_NS :: i64(1_000)

// viewport_make builds a valid viewport, clamping degenerate inputs.
//
// A zero or negative span would make every conversion a division by zero, and
// a zero width would do the same in the inverse direction. Clamping here means
// no caller has to guard, and no frame can produce infinities.
viewport_make :: proc(start_ns: i64, span_ns: i64, width: f32, origin_x: f32 = 0) -> Viewport {
	span := span_ns
	if span < MIN_SPAN_NS {
		span = MIN_SPAN_NS
	}
	pixel_width := width
	if pixel_width < 1 {
		pixel_width = 1
	}
	return Viewport{start_ns = start_ns, span_ns = span, width = pixel_width, origin_x = origin_x}
}

// end_ns is the first instant after the visible interval.
end_ns :: proc "contextless" (viewport: Viewport) -> i64 {
	return viewport.start_ns + viewport.span_ns
}

// time_to_x converts a timestamp to a logical pixel position.
//
// The result is unclamped: an event before or after the visible interval maps
// outside the viewport, which is what a caller needs in order to decide the
// event is not visible. Clamping here would collapse everything off-screen
// onto the edges and make them all appear at the boundary.
time_to_x :: proc "contextless" (viewport: Viewport, time_ns: i64) -> f32 {
	offset := f64(time_ns - viewport.start_ns)
	fraction := offset / f64(viewport.span_ns)
	return viewport.origin_x + f32(fraction * f64(viewport.width))
}

// x_to_time converts a logical pixel position back to a timestamp.
//
// This is the exact inverse of time_to_x. Both derive from the same three
// fields in the same order, so a change to one is a change to both.
x_to_time :: proc "contextless" (viewport: Viewport, x: f32) -> i64 {
	fraction := f64(x - viewport.origin_x) / f64(viewport.width)
	return viewport.start_ns + i64(fraction * f64(viewport.span_ns))
}

// duration_to_width converts a duration to a pixel width.
duration_to_width :: proc "contextless" (viewport: Viewport, duration_ns: i64) -> f32 {
	fraction := f64(duration_ns) / f64(viewport.span_ns)
	return f32(fraction * f64(viewport.width))
}

// ns_per_pixel reports the timeline's current resolution.
//
// The zoom-level decision in docs/01 (far, medium, near) is a function of this
// value, and so is the minimum-width rule below.
ns_per_pixel :: proc "contextless" (viewport: Viewport) -> f64 {
	return f64(viewport.span_ns) / f64(viewport.width)
}

// MIN_EVENT_WIDTH is the smallest pixel width an event may occupy.
//
// An instantaneous event has zero duration and would otherwise be invisible
// and unclickable. Widening it is a display decision, so hit testing must use
// the same widened rectangle — which is why both go through event_bounds
// rather than each computing its own.
MIN_EVENT_WIDTH :: f32(2)

// Bounds is a horizontal pixel range on the timeline.
Bounds :: struct {
	x0: f32,
	x1: f32,
}

// event_bounds returns the pixel range an event occupies.
//
// This is the single definition used by both drawing and hit testing. It
// applies the minimum width so a zero-duration event is selectable at exactly
// the position it is drawn.
event_bounds :: proc "contextless" (
	viewport: Viewport,
	time_ns: i64,
	duration_ns: i64,
) -> Bounds {
	x0 := time_to_x(viewport, time_ns)
	width := duration_to_width(viewport, duration_ns)
	if width < MIN_EVENT_WIDTH {
		width = MIN_EVENT_WIDTH
	}
	return Bounds{x0 = x0, x1 = x0 + width}
}

// bounds_contains reports whether a pixel position falls inside a range.
bounds_contains :: proc "contextless" (bounds: Bounds, x: f32) -> bool {
	return x >= bounds.x0 && x <= bounds.x1
}

// intersects reports whether a time interval overlaps the visible one.
//
// An instantaneous event uses its minimum drawn width, so an event just past
// the right edge whose marker would still be visible counts as intersecting.
intersects :: proc "contextless" (
	viewport: Viewport,
	time_ns: i64,
	duration_ns: i64,
) -> bool {
	bounds := event_bounds(viewport, time_ns, duration_ns)
	return bounds.x1 >= viewport.origin_x && bounds.x0 <= viewport.origin_x + viewport.width
}

// ---------------------------------------------------------------------------
// Navigation
// ---------------------------------------------------------------------------

// pan_by_pixels shifts the visible interval by a pixel delta.
//
// Panning is expressed in pixels rather than nanoseconds because that is what
// a drag produces, and converting through the viewport keeps the content under
// the cursor moving exactly with it.
pan_by_pixels :: proc "contextless" (viewport: Viewport, delta_x: f32) -> Viewport {
	result := viewport
	shift := i64(f64(delta_x) * ns_per_pixel(viewport))
	result.start_ns -= shift
	return result
}

// zoom_at_pixel scales the visible interval around a fixed pixel position.
//
// The instant under `anchor_x` stays under `anchor_x` afterwards, which is
// what makes wheel-zoom feel like it is zooming toward the cursor rather than
// toward the centre. A factor below one zooms in.
zoom_at_pixel :: proc "contextless" (
	viewport: Viewport,
	anchor_x: f32,
    factor: f64,
) -> Viewport {
	if factor <= 0 {
		return viewport
	}

	// The instant to hold fixed, resolved before the span changes.
	anchor_ns := x_to_time(viewport, anchor_x)

	span := i64(f64(viewport.span_ns) * factor)
	if span < MIN_SPAN_NS {
		span = MIN_SPAN_NS
	}

	// Where the anchor sits within the width, as a fraction. Recomputing the
	// start from this keeps the anchor pinned regardless of the new span.
	fraction := f64(anchor_x - viewport.origin_x) / f64(viewport.width)

	result := viewport
	result.span_ns = span
	result.start_ns = anchor_ns - i64(fraction * f64(span))
	return result
}

// clamp_to_session keeps the viewport within a session's extent.
//
// Scrolling far past the end of a session leaves the user staring at nothing
// with no indication of which direction holds the content. The viewport may
// still be wider than the session, in which case it is anchored at the start.
clamp_to_session :: proc "contextless" (
	viewport: Viewport,
	session_start_ns: i64,
	session_end_ns: i64,
) -> Viewport {
	result := viewport
	duration := session_end_ns - session_start_ns
	if duration <= 0 {
		result.start_ns = session_start_ns
		return result
	}

	if result.span_ns >= duration {
		// The whole session fits; show it from the beginning.
		result.start_ns = session_start_ns
		return result
	}

	latest := session_end_ns - result.span_ns
	if result.start_ns > latest {
		result.start_ns = latest
	}
	if result.start_ns < session_start_ns {
		result.start_ns = session_start_ns
	}
	return result
}

// fit_session returns a viewport showing an entire session.
fit_session :: proc "contextless" (
	session_start_ns: i64,
	session_end_ns: i64,
	width: f32,
	origin_x: f32 = 0,
) -> Viewport {
	duration := session_end_ns - session_start_ns
	if duration < MIN_SPAN_NS {
		duration = MIN_SPAN_NS
	}
	pixel_width := width
	if pixel_width < 1 {
		pixel_width = 1
	}
	return Viewport {
		start_ns = session_start_ns,
		span_ns  = duration,
		width    = pixel_width,
		origin_x = origin_x,
	}
}

// ---------------------------------------------------------------------------
// Lanes
// ---------------------------------------------------------------------------

// Lane enumerates the timeline swimlanes docs/01 fixes, in display order.
//
// The order is part of the interface: docs/01 says events appear in stable
// swimlanes, so a lane's vertical position must not depend on what a session
// happens to contain.
Lane :: enum u8 {
	Conversation = 0,
	Tools        = 1,
	Files        = 2,
	Commands     = 3,
	Outcomes     = 4,
	Errors       = 5,
	Annotations  = 6,
}

LANE_COUNT :: 7

lane_name :: proc "contextless" (lane: Lane) -> string {
	switch lane {
	case .Conversation: return "messages"
	case .Tools:        return "tools"
	case .Files:        return "files"
	case .Commands:     return "commands"
	case .Outcomes:     return "outcomes"
	case .Errors:       return "errors"
	case .Annotations:  return "annotations"
	}
	return "unknown"
}

// lane_for_kind assigns an event kind to its swimlane.
//
// Every kind lands somewhere: an event with no lane would be invisible, and a
// silently invisible event is worse than one in an imperfect lane because the
// user cannot tell it is missing.
lane_for_kind :: proc "contextless" (kind: model.Event_Kind) -> Lane {
	#partial switch kind {
	case .User_Message, .Agent_Message, .System_Message, .Summary:
		return .Conversation

	case .Tool_Call, .Tool_Result:
		return .Tools

	case .Tool_Error, .Explicit_Error, .Retry, .Rate_Limit:
		return .Errors

	case .File_Read,
	     .File_Create,
	     .File_Modify,
	     .File_Delete,
	     .File_Rename,
	     .Directory_Observe:
		return .Files

	case .Command_Start, .Command_Output, .Command_End, .Process_Spawn, .Process_Exit:
		return .Commands

	case .Test_Run_Start,
	     .Test_Case_Result,
	     .Test_Run_End,
	     .Diagnostic,
	     .Build_Result,
	     .Lint_Result:
		return .Outcomes

	case .Annotation, .Checkpoint:
		return .Annotations
	}

	// Session lifecycle, accounting, and extension events have no lane of
	// their own and appear alongside conversation, which is where a reader
	// looks for session structure.
	return .Conversation
}

// Lane_Layout describes the vertical arrangement of the timeline.
Lane_Layout :: struct {
	// Pixel offset of the lane area from the top of the window.
	origin_y: f32,
	// Height of one lane, including its padding.
	lane_height: f32,
	// Vertical padding inside a lane, above and below the event bar.
	padding: f32,
}

// lane_bounds returns the vertical pixel range an event bar occupies.
lane_bounds :: proc "contextless" (layout: Lane_Layout, lane: Lane) -> (y0: f32, y1: f32) {
	top := layout.origin_y + f32(int(lane)) * layout.lane_height
	return top + layout.padding, top + layout.lane_height - layout.padding
}

// lane_at_y returns the lane containing a pixel position.
//
// Returns false outside the lane area rather than clamping to the nearest
// lane, because a click below the timeline is not a click on the last lane.
lane_at_y :: proc "contextless" (layout: Lane_Layout, y: f32) -> (lane: Lane, ok: bool) {
	if layout.lane_height <= 0 || y < layout.origin_y {
		return .Conversation, false
	}
	index := int((y - layout.origin_y) / layout.lane_height)
	if index < 0 || index >= LANE_COUNT {
		return .Conversation, false
	}
	return Lane(index), true
}

// total_height is the pixel height of the whole lane area.
total_height :: proc "contextless" (layout: Lane_Layout) -> f32 {
	return f32(LANE_COUNT) * layout.lane_height
}
