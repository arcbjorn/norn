package test_ui

import "core:testing"

import "src:trace/codec"
import "src:trace/model"
import "src:ui"

// Timeline virtualization and hit testing.
//
// docs/09 requires viewport range queries and visible-row virtualization to be
// tested below the GPU boundary, which is what these do: no window is opened
// and no frame is drawn.

Builder :: struct {
	trace:    codec.Trace,
	next:     model.Event_Id,
	sequence: model.Sequence,
	clock:    i64,
}

@(private)
builder_init :: proc(builder: ^Builder) {
	model.string_table_init(&builder.trace.strings)
	model.blob_table_init(&builder.trace.blobs)
	model.payload_tables_init(&builder.trace.payloads)
	builder.trace.entities = make([dynamic]model.Entity, 0, 4)
	builder.trace.spans = make([dynamic]model.Span, 0, 2)
	builder.trace.events = make([dynamic]model.Event, 0, 64)
	builder.trace.edges = make([dynamic]model.Edge, 0, 2)
	builder.trace.mutations = make([dynamic]model.Mutation, 0, 4)
	builder.trace.directory = make([dynamic]codec.Directory_Entry, 0, 2)
	builder.next = 1
	builder.sequence = 1
	builder.clock = 0
}

@(private)
builder_destroy :: proc(builder: ^Builder) {
	codec.trace_destroy(&builder.trace)
}

// add adds an event at an explicit time.
@(private)
add :: proc(
	builder: ^Builder,
	kind: model.Event_Kind,
	time_ns: i64,
	duration_ns: i64 = 0,
) -> model.Event_Id {
	id := builder.next
	builder.next += 1

	flags := model.Event_Flags{.Has_Wall_Time}
	if duration_ns > 0 {
		flags += {.Has_Duration}
	}

	append(
		&builder.trace.events,
		model.Event {
			id = id,
			sequence = builder.sequence,
			kind = kind,
			flags = flags,
			wall_time_ns = time_ns,
			duration_ns = duration_ns,
		},
	)
	builder.sequence += 1
	return id
}

// add_failing_test adds a test result that failed.
@(private)
add_failing_test :: proc(builder: ^Builder, time_ns: i64) -> model.Event_Id {
	payload := model.add_test(
		&builder.trace.payloads,
		model.Test_Payload{status = .Failed},
	)
	id := add(builder, .Test_Case_Result, time_ns)
	builder.trace.events[len(builder.trace.events) - 1].payload = payload
	return id
}

@(test)
a_query_returns_only_visible_events :: proc(t: ^testing.T) {
	// docs/07: only events intersecting the visible interval generate draw
	// instances, and the panel does not scan the full session each frame.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 100 {
		add(&builder, .File_Modify, i64(index) * SECOND)
	}

	// A window covering seconds 10 through 20.
	viewport := ui.viewport_make(10 * SECOND, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	testing.expect(t, len(set.events) > 0)
	testing.expect(
		t,
		len(set.events) <= 13,
		"only events near the window should be returned",
	)

	for event in set.events {
		testing.expect(
			t,
			event.bounds.x1 >= 0 && event.bounds.x0 <= 1000,
			"every returned event must intersect the viewport",
		)
	}
}

@(test)
an_empty_trace_yields_an_empty_query :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	viewport := ui.viewport_make(0, SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	testing.expect_value(t, len(set.events), 0)
	testing.expect_value(t, set.total_in_range, 0)
}

@(test)
long_running_events_spanning_the_left_edge_are_included :: proc(t: ^testing.T) {
	// A command that started before the window but is still running must
	// appear. Starting the scan exactly at the left edge would drop it.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .Command_Start, 0, 60 * SECOND)
	add(&builder, .File_Modify, 30 * SECOND)

	viewport := ui.viewport_make(20 * SECOND, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	found := false
	for event in set.events {
		if event.kind == .Command_Start {
			found = true
		}
	}
	testing.expect(t, found, "an event spanning the left edge must be visible")
}

@(test)
a_lane_filter_reports_what_it_hid :: proc(t: ^testing.T) {
	// docs/01: a hidden filter must never explain an apparently missing event.
	// The count is what lets the interface say so.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND)
	add(&builder, .User_Message, 2 * SECOND)
	add(&builder, .Command_Start, 3 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport, ui.Lane_Filter{.Files})
	defer ui.visible_set_destroy(&set)

	testing.expect_value(t, len(set.events), 1)
	testing.expect_value(t, set.events[0].lane, ui.Lane.Files)
	testing.expect_value(t, set.filtered_out, 2)
}

@(test)
an_empty_filter_shows_every_lane :: proc(t: ^testing.T) {
	// A filter nobody configured should not hide the whole timeline.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND)
	add(&builder, .User_Message, 2 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport, ui.Lane_Filter{})
	defer ui.visible_set_destroy(&set)

	testing.expect_value(t, len(set.events), 2)
	testing.expect_value(t, set.filtered_out, 0)
}

@(test)
events_without_timestamps_still_appear :: proc(t: ^testing.T) {
	// docs/03 allows an absent wall time. Dropping such an event would hide a
	// recorded fact because its clock was unreliable.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	append(
		&builder.trace.events,
		model.Event{id = 1, sequence = 1, kind = .File_Modify},
	)

	viewport := ui.viewport_make(0, 100, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	testing.expect_value(t, len(set.events), 1)
}

@(test)
binary_search_finds_the_window_start :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 50 {
		add(&builder, .File_Modify, i64(index) * SECOND)
	}

	events := builder.trace.events[:]
	testing.expect_value(t, ui.first_at_or_after(events, 0), 0)
	testing.expect_value(t, ui.first_at_or_after(events, 25 * SECOND), 25)
	// A time between two events lands on the later one.
	testing.expect_value(t, ui.first_at_or_after(events, 25 * SECOND + 1), 26)
	// Past the end returns the length rather than an invalid index.
	testing.expect_value(t, ui.first_at_or_after(events, 1000 * SECOND), 50)
}

// ---------------------------------------------------------------------------
// Hit testing
// ---------------------------------------------------------------------------

@(test)
clicking_an_event_selects_that_event :: proc(t: ^testing.T) {
	// The property docs/07 protects: what is drawn at a position is what a
	// click at that position selects.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	ids: [10]model.Event_Id
	for index in 0 ..< 10 {
		ids[index] = add(&builder, .File_Modify, i64(index) * SECOND, SECOND / 2)
	}

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	layout := ui.Lane_Layout{origin_y = 0, lane_height = 20, padding = 2}

	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	files_y0, files_y1 := ui.lane_bounds(layout, ui.Lane.Files)
	middle_y := (files_y0 + files_y1) * 0.5

	// Click the centre of each drawn event and expect that event back.
	for event in set.events {
		centre := (event.bounds.x0 + event.bounds.x1) * 0.5
		hit := ui.hit_test(&set, layout, centre, middle_y)

		testing.expectf(t, hit.found, "no hit at the centre of event %d", u64(event.id))
		testing.expectf(
			t,
			hit.event == event.id,
			"clicking event %d selected %d",
			u64(event.id),
			u64(hit.event),
		)
	}
}

@(test)
clicking_the_wrong_lane_selects_nothing :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	layout := ui.Lane_Layout{origin_y = 0, lane_height = 20, padding = 2}
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	// The event is in the files lane; click at the same x in commands.
	commands_y0, commands_y1 := ui.lane_bounds(layout, ui.Lane.Commands)
	hit := ui.hit_test(&set, layout, 150, (commands_y0 + commands_y1) * 0.5)

	testing.expect(t, !hit.found, "a different lane must not select the event")
}

@(test)
clicking_empty_space_selects_nothing :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND, SECOND / 10)

	viewport := ui.viewport_make(0, 100 * SECOND, 1000)
	layout := ui.Lane_Layout{origin_y = 0, lane_height = 20, padding = 2}
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	files_y0, files_y1 := ui.lane_bounds(layout, ui.Lane.Files)
	hit := ui.hit_test(&set, layout, 900, (files_y0 + files_y1) * 0.5)

	testing.expect(t, !hit.found)
}

@(test)
zero_duration_events_are_clickable :: proc(t: ^testing.T) {
	// The minimum drawn width must also be the minimum clickable width, or an
	// instantaneous event would be visible but unselectable.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	id := add(&builder, .Explicit_Error, 1800 * SECOND)

	viewport := ui.viewport_make(0, 3600 * SECOND, 1000)
	layout := ui.Lane_Layout{origin_y = 0, lane_height = 20, padding = 2}
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	testing.expect_value(t, len(set.events), 1)
	errors_y0, errors_y1 := ui.lane_bounds(layout, ui.Lane.Errors)
	centre := (set.events[0].bounds.x0 + set.events[0].bounds.x1) * 0.5

	hit := ui.hit_test(&set, layout, centre, (errors_y0 + errors_y1) * 0.5)
	testing.expect(t, hit.found)
	testing.expect_value(t, hit.event, id)
}

@(test)
nearest_event_finds_a_neighbour :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND)
	target := add(&builder, .File_Modify, 5 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	// A position slightly right of the second event.
	hit := ui.nearest_event(&set, ui.Lane.Files, 520)
	testing.expect(t, hit.found)
	testing.expect_value(t, hit.event, target)
}

// ---------------------------------------------------------------------------
// Aggregation
// ---------------------------------------------------------------------------

@(test)
aggregation_bins_dense_events :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 5000 {
		add(&builder, .File_Modify, i64(index) * SECOND / 10)
	}

	viewport := ui.viewport_make(0, 500 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	bins := ui.aggregate(&set, viewport, ui.Lane.Files)
	defer ui.aggregate_set_destroy(&bins)

	// Far fewer bins than events, which is the point.
	testing.expect(t, len(bins.bins) < len(set.events))
	testing.expect(t, ui.peak_density(&bins) > 0)

	total := 0
	for bin in bins.bins {
		total += bin.total
	}
	testing.expect_value(t, total, len(set.events))
}

@(test)
aggregation_preserves_failures :: proc(t: ^testing.T) {
	// docs/07: aggregation must preserve the visibility of failures even when
	// density is high. A failure averaged into a bin is a failure the user
	// cannot find.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 500 {
		add(&builder, .Test_Run_Start, i64(index) * SECOND)
	}
	failure := add_failing_test(&builder, 250 * SECOND)

	viewport := ui.viewport_make(0, 500 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	bins := ui.aggregate(&set, viewport, ui.Lane.Outcomes)
	defer ui.aggregate_set_destroy(&bins)

	testing.expect_value(t, len(bins.failures), 1)
	testing.expect_value(t, bins.failures[0].id, failure)

	// The bin containing it also records that a failure is inside.
	found := false
	for bin in bins.bins {
		if bin.failures > 0 {
			found = true
			testing.expect_value(t, bin.first_failure, failure)
		}
	}
	testing.expect(t, found, "a bin must record the failure it contains")
}

@(test)
failures_are_marked_at_query_time :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .Test_Run_Start, SECOND)
	add_failing_test(&builder, 2 * SECOND)
	add(&builder, .Explicit_Error, 3 * SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	failures := 0
	for event in set.events {
		if event.is_failure {
			failures += 1
		}
	}
	testing.expect_value(t, failures, 2)
}

@(test)
a_dense_query_reports_that_it_needs_aggregation :: proc(t: ^testing.T) {
	// The cap exists because the graphics spike measured a million instances
	// at a 7.98 ms worst frame, too close to the 8 ms budget.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	add(&builder, .File_Modify, SECOND)

	viewport := ui.viewport_make(0, 10 * SECOND, 1000)
	set := ui.query_visible(&builder.trace, ui.build_index(&builder.trace), viewport)
	defer ui.visible_set_destroy(&set)

	testing.expect(t, !ui.needs_aggregation(set), "a small session needs no aggregation")
}
