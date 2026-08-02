package test_ui

import "core:math"
import "core:math/rand"
import "core:testing"

import "src:trace/model"
import "src:ui"

// Viewport transforms.
//
// docs/07: hit testing uses the same transforms as drawing, and approximate
// duplicate math is prohibited because it creates selection drift. These tests
// assert the two directions are genuine inverses, because that is the property
// a user experiences as "clicking selects what I clicked".

@(private)
SECOND :: i64(1_000_000_000)

@(test)
time_maps_to_the_expected_pixel :: proc(t: ^testing.T) {
	// A ten-second window across 1000 pixels: one second is 100 pixels.
	viewport := ui.viewport_make(0, 10 * SECOND, 1000)

	testing.expect_value(t, ui.time_to_x(viewport, 0), f32(0))
	testing.expect_value(t, ui.time_to_x(viewport, 5 * SECOND), f32(500))
	testing.expect_value(t, ui.time_to_x(viewport, 10 * SECOND), f32(1000))
}

@(test)
pixel_maps_back_to_the_expected_time :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(0, 10 * SECOND, 1000)

	testing.expect_value(t, ui.x_to_time(viewport, 0), i64(0))
	testing.expect_value(t, ui.x_to_time(viewport, 500), 5 * SECOND)
	testing.expect_value(t, ui.x_to_time(viewport, 1000), 10 * SECOND)
}

@(test)
the_transforms_are_inverses :: proc(t: ^testing.T) {
	// The central anti-drift property. Any timestamp converted to a pixel and
	// back must land within the resolution of one pixel — no further, or a
	// click near an event's edge would select its neighbour.
	viewport := ui.viewport_make(1_700_000_000 * SECOND, 3600 * SECOND, 1440)
	tolerance := i64(ui.ns_per_pixel(viewport)) + 1

	generator := rand.create(0xA17E)
	context.random_generator = rand.default_random_generator(&generator)

	for _ in 0 ..< 1000 {
		offset := i64(rand.uint64() % u64(viewport.span_ns))
		original := viewport.start_ns + offset

		x := ui.time_to_x(viewport, original)
		returned := ui.x_to_time(viewport, x)

		difference := returned - original
		if difference < 0 {
			difference = -difference
		}
		testing.expectf(
			t,
			difference <= tolerance,
			"round trip moved %d ns (tolerance %d)",
			difference,
			tolerance,
		)
	}
}

@(test)
the_transforms_are_inverses_with_an_origin_offset :: proc(t: ^testing.T) {
	// A timeline panel does not start at the window's left edge. An origin
	// applied in one direction but not the other is exactly the kind of
	// mismatch that produces a constant selection offset.
	viewport := ui.viewport_make(0, 60 * SECOND, 800, 240)

	testing.expect_value(t, ui.time_to_x(viewport, 0), f32(240))
	testing.expect_value(t, ui.x_to_time(viewport, 240), i64(0))
	testing.expect_value(t, ui.time_to_x(viewport, 30 * SECOND), f32(640))
	testing.expect_value(t, ui.x_to_time(viewport, 640), 30 * SECOND)
}

@(test)
positions_outside_the_view_are_not_clamped :: proc(t: ^testing.T) {
	// Clamping would collapse every off-screen event onto the edges, making
	// them all appear at the boundary instead of being culled.
	viewport := ui.viewport_make(10 * SECOND, 10 * SECOND, 1000)

	testing.expect(t, ui.time_to_x(viewport, 0) < 0, "an earlier event maps left of zero")
	testing.expect(
		t,
		ui.time_to_x(viewport, 30 * SECOND) > 1000,
		"a later event maps right of the width",
	)
}

@(test)
degenerate_viewports_are_clamped_not_infinite :: proc(t: ^testing.T) {
	// A zero span or width would divide by zero in every conversion. Clamping
	// at construction means no caller has to guard and no frame produces NaN.
	zero_span := ui.viewport_make(0, 0, 1000)
	testing.expect(t, zero_span.span_ns >= ui.MIN_SPAN_NS)
	testing.expect(t, !math.is_nan(ui.time_to_x(zero_span, 500)))

	zero_width := ui.viewport_make(0, SECOND, 0)
	testing.expect(t, zero_width.width >= 1)
	testing.expect(t, !math.is_nan(f32(ui.x_to_time(zero_width, 10))))

	negative := ui.viewport_make(0, -5, -100)
	testing.expect(t, negative.span_ns >= ui.MIN_SPAN_NS)
	testing.expect(t, negative.width >= 1)
}

@(test)
zero_duration_events_stay_selectable :: proc(t: ^testing.T) {
	// An instantaneous event has no width, so it would be invisible and
	// unclickable. The widening is a display decision, so hit testing must use
	// the same widened bounds — which is why both call event_bounds.
	viewport := ui.viewport_make(0, 3600 * SECOND, 1000)
	bounds := ui.event_bounds(viewport, 1800 * SECOND, 0)

	testing.expect(t, bounds.x1 - bounds.x0 >= ui.MIN_EVENT_WIDTH)
	testing.expect(t, ui.bounds_contains(bounds, bounds.x0))
	testing.expect(t, ui.bounds_contains(bounds, bounds.x1))
}

@(test)
event_bounds_reflect_duration_when_wide_enough :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	bounds := ui.event_bounds(viewport, 2 * SECOND, 3 * SECOND)

	testing.expect_value(t, bounds.x0, f32(200))
	testing.expect_value(t, bounds.x1, f32(500))
}

@(test)
intersects_matches_visible_bounds :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(10 * SECOND, 10 * SECOND, 1000)

	testing.expect(t, ui.intersects(viewport, 15 * SECOND, 0), "inside the view")
	testing.expect(t, ui.intersects(viewport, 5 * SECOND, 10 * SECOND), "spanning the left edge")
	testing.expect(t, ui.intersects(viewport, 19 * SECOND, 5 * SECOND), "spanning the right edge")
	testing.expect(t, !ui.intersects(viewport, 0, 0), "well before the view")
	testing.expect(t, !ui.intersects(viewport, 100 * SECOND, 0), "well after the view")
}

@(test)
zoom_holds_the_anchor_instant_fixed :: proc(t: ^testing.T) {
	// Wheel-zoom should feel like zooming toward the cursor. The instant under
	// the anchor pixel must stay under it, or the content slides away from
	// where the user is pointing.
	viewport := ui.viewport_make(0, 100 * SECOND, 1000)
	anchor_x := f32(750)
	before := ui.x_to_time(viewport, anchor_x)

	for factor in ([]f64{0.5, 0.25, 2.0, 4.0}) {
		zoomed := ui.zoom_at_pixel(viewport, anchor_x, factor)
		after := ui.x_to_time(zoomed, anchor_x)

		tolerance := i64(ui.ns_per_pixel(zoomed)) + 1
		difference := after - before
		if difference < 0 {
			difference = -difference
		}
		testing.expectf(
			t,
			difference <= tolerance,
			"zoom by %.2f moved the anchor by %d ns",
			factor,
			difference,
		)
	}
}

@(test)
zoom_respects_the_minimum_span :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(0, SECOND, 1000)
	for _ in 0 ..< 50 {
		viewport = ui.zoom_at_pixel(viewport, 500, 0.5)
	}
	testing.expect(t, viewport.span_ns >= ui.MIN_SPAN_NS)
}

@(test)
zoom_ignores_a_nonpositive_factor :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(0, SECOND, 1000)
	testing.expect_value(t, ui.zoom_at_pixel(viewport, 500, 0).span_ns, viewport.span_ns)
	testing.expect_value(t, ui.zoom_at_pixel(viewport, 500, -1).span_ns, viewport.span_ns)
}

@(test)
panning_moves_content_with_the_cursor :: proc(t: ^testing.T) {
	// Dragging right should move content right, which means the visible
	// interval moves earlier by the same number of pixels.
	viewport := ui.viewport_make(100 * SECOND, 10 * SECOND, 1000)
	instant := ui.x_to_time(viewport, 500)

	panned := ui.pan_by_pixels(viewport, 100)
	moved := ui.time_to_x(panned, instant)

	tolerance := f32(1)
	testing.expectf(
		t,
		abs(moved - 600) <= tolerance,
		"the instant under the cursor moved to %f, expected 600",
		moved,
	)
}

@(test)
panning_round_trips :: proc(t: ^testing.T) {
	viewport := ui.viewport_make(100 * SECOND, 10 * SECOND, 1000)
	there := ui.pan_by_pixels(viewport, 250)
	back := ui.pan_by_pixels(there, -250)

	tolerance := i64(ui.ns_per_pixel(viewport)) + 1
	difference := back.start_ns - viewport.start_ns
	if difference < 0 {
		difference = -difference
	}
	testing.expect(t, difference <= tolerance)
}

@(test)
clamping_keeps_the_view_inside_the_session :: proc(t: ^testing.T) {
	session_start := 1000 * SECOND
	session_end := 2000 * SECOND

	// Scrolled far past the end.
	far := ui.viewport_make(9000 * SECOND, 100 * SECOND, 1000)
	clamped := ui.clamp_to_session(far, session_start, session_end)
	testing.expect(t, ui.end_ns(clamped) <= session_end)
	testing.expect(t, clamped.start_ns >= session_start)

	// Scrolled before the start.
	early := ui.viewport_make(0, 100 * SECOND, 1000)
	clamped = ui.clamp_to_session(early, session_start, session_end)
	testing.expect_value(t, clamped.start_ns, session_start)
}

@(test)
a_view_wider_than_the_session_anchors_at_the_start :: proc(t: ^testing.T) {
	// Zooming out past the session's extent should show the session, not
	// leave it floating somewhere in an over-wide window.
	session_start := 1000 * SECOND
	session_end := 1100 * SECOND

	wide := ui.viewport_make(500 * SECOND, 10_000 * SECOND, 1000)
	clamped := ui.clamp_to_session(wide, session_start, session_end)
	testing.expect_value(t, clamped.start_ns, session_start)
}

@(test)
fit_session_shows_the_whole_session :: proc(t: ^testing.T) {
	viewport := ui.fit_session(100 * SECOND, 400 * SECOND, 1000)
	testing.expect_value(t, viewport.start_ns, 100 * SECOND)
	testing.expect_value(t, ui.end_ns(viewport), 400 * SECOND)

	// An empty session still yields a usable viewport rather than a zero span.
	degenerate := ui.fit_session(0, 0, 1000)
	testing.expect(t, degenerate.span_ns >= ui.MIN_SPAN_NS)
}

// ---------------------------------------------------------------------------
// Lanes
// ---------------------------------------------------------------------------

@(test)
every_event_kind_lands_in_a_lane :: proc(t: ^testing.T) {
	// An event with no lane would be invisible, and a silently invisible event
	// is worse than one in an imperfect lane: the user cannot tell it is gone.
	for kind in model.Event_Kind {
		lane := ui.lane_for_kind(kind)
		testing.expectf(
			t,
			int(lane) >= 0 && int(lane) < ui.LANE_COUNT,
			"kind %v produced an out-of-range lane",
			kind,
		)
	}
}

@(test)
lanes_have_stable_positions :: proc(t: ^testing.T) {
	// docs/01: events appear in stable swimlanes, so a lane's position must
	// not depend on session content.
	layout := ui.Lane_Layout{origin_y = 40, lane_height = 24, padding = 3}

	previous_bottom := f32(0)
	for lane in ui.Lane {
		y0, y1 := ui.lane_bounds(layout, lane)
		testing.expect(t, y1 > y0, "a lane must have positive height")
		testing.expect(t, y0 >= previous_bottom, "lanes must not overlap")
		previous_bottom = y1
	}
}

@(test)
lane_hit_testing_inverts_lane_bounds :: proc(t: ^testing.T) {
	layout := ui.Lane_Layout{origin_y = 40, lane_height = 24, padding = 3}

	for lane in ui.Lane {
		y0, y1 := ui.lane_bounds(layout, lane)
		middle := (y0 + y1) * 0.5

		found, ok := ui.lane_at_y(layout, middle)
		testing.expect(t, ok)
		testing.expectf(t, found == lane, "y %f resolved to %v, expected %v", middle, found, lane)
	}
}

@(test)
clicks_outside_the_lane_area_select_nothing :: proc(t: ^testing.T) {
	// A click below the timeline is not a click on the last lane. Clamping to
	// the nearest lane would select something the user did not point at.
	layout := ui.Lane_Layout{origin_y = 40, lane_height = 24, padding = 3}

	_, above := ui.lane_at_y(layout, 10)
	testing.expect(t, !above, "above the lane area")

	_, below := ui.lane_at_y(layout, 40 + ui.total_height(layout) + 10)
	testing.expect(t, !below, "below the lane area")
}
