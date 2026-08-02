package test_ui

import "core:os"
import "core:testing"

import "src:render"
import "src:trace/model"
import "src:ui"

// The timeline panel.
//
// These assert what the panel would paint, without a window. docs/01 makes
// several appearance rules normative rather than cosmetic — colour is never
// the sole carrier of status, and partial replay is never shown as complete —
// so they are testable claims.

@(private)
PANEL_BOUNDS :: render.Rect{0, 0, 1000, 200}

@(private)
panel_state :: proc(viewport: ui.Viewport) -> ui.Panel_State {
	return ui.Panel_State {
		viewport = viewport,
		layout = ui.Lane_Layout{origin_y = 0, lane_height = 24, padding = 3},
		bounds = PANEL_BOUNDS,
		theme = ui.DARK_THEME,
		selection = model.NO_EVENT,
	}
}

@(private)
count_kind :: proc(list: ^render.Draw_List, kind: render.Command_Kind) -> int {
	total := 0
	for command in list.commands {
		if command.kind == kind {
			total += 1
		}
	}
	return total
}

@(private)
count_layer :: proc(list: ^render.Draw_List, layer: u16) -> int {
	total := 0
	for command in list.commands {
		if command.layer == layer {
			total += 1
		}
	}
	return total
}

@(test)
the_panel_draws_every_visible_event :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 10 {
		add(&builder, .File_Modify, i64(index) * SECOND, SECOND / 2)
	}

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	// Every event contributes at least one command in the event layer.
	testing.expect(t, count_layer(&list, ui.LAYER_EVENTS) >= len(set.events))
}

@(test)
failures_get_a_shape_not_only_a_colour :: proc(t: ^testing.T) {
	// docs/01: "colour is never the sole carrier of status." A user who cannot
	// distinguish red from green must still see which event failed, so a
	// failure gets an extra marker in its own layer.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .Test_Run_Start, SECOND)
	add_failing_test(&builder, 2 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	// One failure, so exactly one marker.
	testing.expect_value(t, count_layer(&list, ui.LAYER_FAILURES), 1)
}

@(test)
a_session_without_failures_draws_no_markers :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 5 {
		add(&builder, .File_Modify, i64(index) * SECOND)
	}

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	testing.expect_value(t, count_layer(&list, ui.LAYER_FAILURES), 0)
}

@(test)
the_selection_is_drawn_above_its_event :: proc(t: ^testing.T) {
	// A selection ring under its event would be invisible, so painter's order
	// is a correctness property here rather than a preference.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	first := add(&builder, .File_Modify, SECOND, SECOND)
	add(&builder, .File_Modify, 3 * SECOND, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	state := panel_state(viewport)
	state.selection = first

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &set)

	testing.expect_value(t, count_layer(&list, ui.LAYER_SELECTION), 1)
	testing.expect(t, ui.LAYER_SELECTION > ui.LAYER_EVENTS)
}

@(test)
no_selection_draws_no_ring :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, SECOND, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	testing.expect_value(t, count_layer(&list, ui.LAYER_SELECTION), 0)
}

@(test)
selecting_an_offscreen_event_draws_nothing :: proc(t: ^testing.T) {
	// A selection outside the view must not paint a ring at the edge, which
	// would claim the event is there.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	far := add(&builder, .File_Modify, 500 * SECOND)
	add(&builder, .File_Modify, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	state := panel_state(viewport)
	state.selection = far

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &set)

	testing.expect_value(t, count_layer(&list, ui.LAYER_SELECTION), 0)
}

@(test)
the_playhead_uses_the_same_transform_as_events :: proc(t: ^testing.T) {
	// If the playhead were positioned by different math it would drift from
	// the events it separates, which is the drift docs/07 prohibits.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, 5 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	state := panel_state(viewport)
	state.has_playhead = true
	state.playhead_ns = 5 * SECOND

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &set)

	// The playhead sits at the event's own left edge.
	expected := ui.time_to_x(viewport, 5 * SECOND)
	found := false
	for command in list.commands {
		if command.layer == ui.LAYER_PLAYHEAD {
			found = true
			testing.expect_value(t, command.rect.x0, expected)
			testing.expect_value(t, command.rect.x0, set.events[0].bounds.x0)
		}
	}
	testing.expect(t, found, "the playhead must be drawn")
}

@(test)
an_unset_playhead_is_not_drawn :: proc(t: ^testing.T) {
	// A session opens with no time chosen; drawing a playhead at zero would
	// claim a selection the user has not made.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	testing.expect_value(t, count_layer(&list, ui.LAYER_PLAYHEAD), 0)
}

@(test)
the_panel_clips_to_its_bounds :: proc(t: ^testing.T) {
	// A long event must not paint over a neighbouring panel.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .Command_Start, 0, 1000 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, render.Rect{0, 0, 1920, 1080})

	ui.draw_timeline(&list, panel_state(viewport), &set)

	for command in list.commands {
		clip := list.clips[command.clip]
		testing.expect(
			t,
			clip.x1 <= PANEL_BOUNDS.x1 && clip.y1 <= PANEL_BOUNDS.y1,
			"every command must be clipped to the panel",
		)
	}
}

@(test)
the_panel_batches_into_few_draw_calls :: proc(t: ^testing.T) {
	// The point of batching: a busy timeline should not become hundreds of
	// state changes.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	kinds := []model.Event_Kind {
		.User_Message,
		.Tool_Call,
		.File_Modify,
		.Command_Start,
		.Test_Run_Start,
	}
	for index in 0 ..< 2000 {
		add(&builder, kinds[index % len(kinds)], i64(index) * SECOND / 100)
	}

	viewport := ui.viewport_make(0, 20 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)
	ui.draw_timeline(&list, panel_state(viewport), &set)

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	stats := render.frame_stats(&list, &frame)
	testing.expect(t, stats.commands > 1000, "the fixture must be busy enough to matter")
	testing.expectf(
		t,
		stats.draw_calls <= 12,
		"%d commands became %d draw calls",
		stats.commands,
		stats.draw_calls,
	)
}

@(test)
aggregation_draws_bins_and_keeps_failures :: proc(t: ^testing.T) {
	// docs/07: aggregation must preserve the visibility of failures. A failure
	// averaged into a density bar is a failure the user cannot find.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 1000 {
		add(&builder, .Test_Run_Start, i64(index) * SECOND / 10)
	}
	add_failing_test(&builder, 50 * SECOND)

	viewport := ui.viewport_make(0, 100 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	bins := ui.aggregate(&set, viewport, ui.Lane.Outcomes)
	defer ui.aggregate_set_destroy(&bins)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_aggregated(&list, panel_state(viewport), &bins, ui.Lane.Outcomes)

	testing.expect(t, count_layer(&list, ui.LAYER_EVENTS) > 0, "bins must be drawn")
	testing.expect_value(t, count_layer(&list, ui.LAYER_FAILURES), 1)
}

@(test)
every_lane_has_a_distinct_colour :: proc(t: ^testing.T) {
	// docs/01: an event retains the same colour family at every zoom level,
	// which requires each lane to have one in the first place.
	seen := make([dynamic]render.Color)
	defer delete(seen)

	for lane in ui.Lane {
		color := ui.lane_color(ui.DARK_THEME, lane)
		for existing in seen {
			testing.expectf(
				t,
				existing != color,
				"lane %v reuses another lane's colour",
				lane,
			)
		}
		append(&seen, color)
	}
	testing.expect_value(t, len(seen), ui.LANE_COUNT)
}

@(test)
lane_labels_are_complete_at_every_display_scale :: proc(t: ^testing.T) {
	// The label box must be sized in the same units the glyphs were
	// rasterized in. Sizing it from an unscaled constant while the atlas is
	// built at 2x silently truncates the longer names on every high-DPI
	// display, which is exactly the kind of defect that survives a casual look
	// at the window.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, SECOND)

	expected := 0
	for lane in ui.Lane {
		expected += len(ui.lane_name(lane))
	}

	for scale in ([]f32{1, 1.5, 2}) {
		atlas := render.get_atlas(
			&fonts,
			render.Atlas_Key{font = .Interface, size = 12, scale = scale},
		)
		gutter := ui.LABEL_GUTTER * scale
		lane_height := 40 * scale
		bounds := render.Rect{0, 0, 1000 + gutter, f32(ui.LANE_COUNT) * lane_height}

		viewport := ui.viewport_make(0, 20 * SECOND, 1000, gutter)
		set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
		defer ui.visible_set_destroy(&set)

		list: render.Draw_List
		render.draw_list_init(&list)
		defer render.draw_list_destroy(&list)
		render.draw_list_reset(&list, bounds)

		ui.draw_timeline(
			&list,
			ui.Panel_State {
				viewport = viewport,
				layout = ui.Lane_Layout {
					origin_y = bounds.y0,
					lane_height = lane_height,
					padding = 6 * scale,
				},
				bounds = bounds,
				theme = ui.DARK_THEME,
				fonts = &fonts,
				atlas = atlas,
			},
			&set,
		)

		glyphs := count_kind(&list, .Glyph)
		testing.expectf(
			t,
			glyphs == expected,
			"at %.1fx scale only %d of %d label glyphs were drawn",
			scale,
			glyphs,
			expected,
		)
	}
}

@(test)
labels_are_omitted_when_no_font_is_available :: proc(t: ^testing.T) {
	// A missing typeface must degrade to an unlabelled timeline rather than
	// to boxes, which would look like data.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, panel_state(viewport), &set)

	testing.expect_value(t, count_kind(&list, .Glyph), 0)
	testing.expect(t, render.command_count(&list) > 0, "the timeline itself still draws")
}

@(private)
load_ui_font :: proc(set: ^render.Font_Set) -> bool {
	render.font_set_init(set)
	candidates := []string {
		"/System/Library/Fonts/SFNS.ttf",
		"/System/Library/Fonts/Helvetica.ttc",
		"/System/Library/Fonts/Supplemental/Arial.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	}
	for path in candidates {
		if os.exists(path) && render.load_face(set, .Interface, path) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Empty states
// ---------------------------------------------------------------------------
//
// docs/01: "Empty panels explain why they are empty: no events, filtered out,
// unsupported record, replay gap, or missing repository."
//
// A blank timeline is indistinguishable from a broken program, and the three
// reasons it can be blank send a user to three different places: undo a filter,
// press Home, or accept that the trace holds nothing. The panel cannot tell
// them apart on its own, which is why the caller supplies the context.

@(private)
empty_timeline_text :: proc(
	t: ^testing.T,
	total_events: int,
	filtering: bool,
) -> int {
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	state := panel_state(ui.Viewport{start_ns = 0, span_ns = 1_000_000_000, width = 800})
	state.fonts = &fonts
	state.atlas = atlas
	state.scale = 1
	state.total_events = total_events
	state.filtering = filtering

	empty: ui.Visible_Set

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &empty)
	return count_kind(&list, .Glyph)
}

@(test)
an_empty_timeline_explains_itself :: proc(t: ^testing.T) {
	// Each case must produce text. A blank panel that said nothing would be
	// the failure docs/01 names.
	testing.expect(t, empty_timeline_text(t, 0, false) > 0, "an empty trace must say so")
	testing.expect(t, empty_timeline_text(t, 40, true) > 0, "a filtered view must say so")
	testing.expect(t, empty_timeline_text(t, 40, false) > 0, "an off-screen range must say so")
}

@(test)
the_empty_message_distinguishes_its_reasons :: proc(t: ^testing.T) {
	// Different reasons, different messages. One message for all three would
	// satisfy "explains why it is empty" in letter only, and would send a user
	// looking for a filter that is not applied.
	empty_trace := empty_timeline_text(t, 0, false)
	filtered := empty_timeline_text(t, 40, true)
	off_screen := empty_timeline_text(t, 40, false)

	// Glyph counts stand in for the text, which a draw list does not retain.
	// The three messages differ in length, so equal counts mean one message.
	testing.expect(t, empty_trace != filtered, "an empty trace and a filtered view must differ")
	testing.expect(t, filtered != off_screen, "a filtered view and an off-screen range must differ")
}

@(test)
a_populated_timeline_draws_no_empty_message :: proc(t: ^testing.T) {
	// The converse: an explanation on a panel that has content would be noise
	// drawn over the data.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	add(&builder, .File_Modify, SECOND)

	index := ui.build_index(&builder.trace)

	viewport := ui.Viewport{start_ns = 0, span_ns = 4 * SECOND, width = 800}
	set := ui.query_visible(&builder.trace, index, viewport, ui.ALL_LANES)
	defer ui.visible_set_destroy(&set)
	testing.expect(t, len(set.events) > 0, "the fixture must produce a visible event")

	state := panel_state(viewport)
	state.fonts = &fonts
	state.atlas = atlas
	state.scale = 1
	state.total_events = len(builder.trace.events)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &set)

	// Lane labels are the only text a populated timeline draws; the empty
	// message would add far more than the panel's seven short lane names.
	with_labels := count_kind(&list, .Glyph)
	testing.expect(t, with_labels < empty_timeline_text(t, 0, false) + 60)
}

@(test)
an_empty_timeline_without_a_font_still_draws :: proc(t: ^testing.T) {
	// docs/13 keeps font discovery an open question, so a missing face must
	// degrade rather than crash.
	state := panel_state(ui.Viewport{start_ns = 0, span_ns = SECOND, width = 800})
	state.total_events = 0

	empty: ui.Visible_Set

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, PANEL_BOUNDS)

	ui.draw_timeline(&list, state, &empty)

	testing.expect_value(t, count_kind(&list, .Glyph), 0)
	testing.expect(t, count_kind(&list, .Rect) > 0, "the lanes must still be drawn")
}
