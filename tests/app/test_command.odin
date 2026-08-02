package test_app

import "core:testing"

import "src:app"
import "src:trace/codec"
import "src:trace/model"
import "src:ui"

// Application state and command routing.
//
// docs/09 lists command routing, selection synchronization, filter semantics
// and keyboard navigation as things tested below the GPU boundary. None of
// these open a window.

SECOND :: i64(1_000_000_000)

Fixture :: struct {
	trace: codec.Trace,
	state: app.State,
}

@(private)
fixture_destroy :: proc(fixture: ^Fixture) {
	codec.trace_destroy(&fixture.trace)
}

// make_fixture builds a session with a mix of event kinds, one per second.
//
// The pattern repeats every five events, so a test can predict which indices
// are mutations and which are outcomes.
@(private)
make_fixture :: proc(fixture: ^Fixture, count := 20) {
	t := &fixture.trace
	model.string_table_init(&t.strings)
	model.blob_table_init(&t.blobs)
	model.payload_tables_init(&t.payloads)
	t.entities = make([dynamic]model.Entity, 0, 4)
	t.spans = make([dynamic]model.Span, 0, 2)
	t.events = make([dynamic]model.Event, 0, count)
	t.edges = make([dynamic]model.Edge, 0, 2)
	t.mutations = make([dynamic]model.Mutation, 0, 4)
	t.directory = make([dynamic]codec.Directory_Entry, 0, 2)

	append(&t.entities, model.Entity{id = 1, kind = .Path, name = 0})

	kinds := []model.Event_Kind {
		.User_Message,
		.Tool_Call,
		.File_Modify,
		.Command_Start,
		.Test_Case_Result,
	}
	for index in 0 ..< count {
		append(
			&t.events,
			model.Event {
				id = model.Event_Id(index + 1),
				sequence = model.Sequence(index + 1),
				kind = kinds[index % len(kinds)],
				flags = {.Has_Wall_Time},
				wall_time_ns = i64(index) * SECOND,
				primary_entity_id = 1,
			},
		)
	}

	app.state_init(&fixture.state, t, 1000)
}

@(private)
press :: proc(fixture: ^Fixture, key: app.Key, modifiers: app.Modifiers = {}) -> bool {
	command := app.command_for_key(key, modifiers, fixture.state.selection)
	return app.apply(&fixture.state, &fixture.trace, command)
}

// ---------------------------------------------------------------------------
// Keyboard bindings
// ---------------------------------------------------------------------------

@(test)
arrow_keys_step_between_events :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, press(&fixture, .Right))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))

	testing.expect(t, press(&fixture, .Right))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(2))

	testing.expect(t, press(&fixture, .Left))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))
}

@(test)
shift_arrows_step_between_mutations :: proc(t: ^testing.T) {
	// docs/01: Shift + Left/Right is previous or next mutation. The fixture
	// makes every third event a File_Modify.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, press(&fixture, .Right, {.Shift}))
	first := fixture.state.selection.event
	kind := fixture.trace.events[int(first) - 1].kind
	testing.expect(t, model.is_mutation(kind), "the first stop must be a mutation")

	testing.expect(t, press(&fixture, .Right, {.Shift}))
	second := fixture.state.selection.event
	testing.expect(t, second > first)
	testing.expect(
		t,
		model.is_mutation(fixture.trace.events[int(second) - 1].kind),
		"every stop must be a mutation",
	)
}

@(test)
primary_arrows_step_between_outcomes :: proc(t: ^testing.T) {
	// docs/01: Command + Left/Right is previous or next outcome. Named
	// Primary so the same binding is Control on Linux without a second table.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, press(&fixture, .Right, {.Primary}))
	selected := fixture.state.selection.event
	testing.expect(
		t,
		model.is_outcome(fixture.trace.events[int(selected) - 1].kind),
		"the stop must be an outcome",
	)
}

@(test)
navigation_stops_at_the_ends :: proc(t: ^testing.T) {
	// Reaching the end must report no change, or the frame loop redraws an
	// identical frame on every further press.
	fixture: Fixture
	make_fixture(&fixture, 5)
	defer fixture_destroy(&fixture)

	for _ in 0 ..< 10 {
		press(&fixture, .Right)
	}
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(5))
	testing.expect(t, !press(&fixture, .Right), "stepping past the end must report no change")

	for _ in 0 ..< 10 {
		press(&fixture, .Left)
	}
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))
	testing.expect(t, !press(&fixture, .Left), "stepping before the start must report no change")
}

@(test)
space_toggles_playback :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, !fixture.state.playback.running)
	press(&fixture, .Space)
	testing.expect(t, fixture.state.playback.running)
	press(&fixture, .Space)
	testing.expect(t, !fixture.state.playback.running)
}

@(test)
brackets_set_the_comparison_range :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Right)
	press(&fixture, .Right)
	press(&fixture, .Bracket_Left)
	start := fixture.state.selection.playhead_ns

	press(&fixture, .Right)
	press(&fixture, .Right)
	press(&fixture, .Bracket_Right)

	testing.expect(t, app.has_range(fixture.state.selection))
	from, to := app.range_bounds(fixture.state.selection)
	testing.expect_value(t, from, start)
	testing.expect(t, to > from)
}

@(test)
a_range_marked_backwards_is_ordered :: proc(t: ^testing.T) {
	// The brackets can be pressed in either order, and a user who marks the
	// end first means the same range.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	for _ in 0 ..< 5 {
		press(&fixture, .Right)
	}
	press(&fixture, .Bracket_Right)
	later := fixture.state.selection.playhead_ns

	press(&fixture, .Left)
	press(&fixture, .Left)
	press(&fixture, .Bracket_Left)
	earlier := fixture.state.selection.playhead_ns

	from, to := app.range_bounds(fixture.state.selection)
	testing.expect_value(t, from, earlier)
	testing.expect_value(t, to, later)
}

@(test)
an_incomplete_range_is_not_a_range :: proc(t: ^testing.T) {
	// A range with only a start is a user midway through setting one.
	// Computing a comparison from it would show a diff they did not ask for.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Right)
	press(&fixture, .Bracket_Left)

	testing.expect(t, !app.has_range(fixture.state.selection))
	testing.expect(t, fixture.state.selection.has_range_start)
}

@(test)
f_focuses_the_selected_entity :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Right)
	testing.expect(t, press(&fixture, .F))

	testing.expect(t, app.has_focus(fixture.state.selection))
	testing.expect_value(t, fixture.state.selection.focus_entity, model.Entity_Id(1))
}

@(test)
escape_clears_focus_then_range :: proc(t: ^testing.T) {
	// docs/01: "Escape — clear focus, then clear range." Two presses do two
	// different things, which is what a key that backs out one layer at a
	// time should do.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Right)
	press(&fixture, .Bracket_Left)
	press(&fixture, .Right)
	press(&fixture, .Bracket_Right)
	press(&fixture, .F)

	testing.expect(t, app.has_focus(fixture.state.selection))
	testing.expect(t, app.has_range(fixture.state.selection))

	// First press clears focus and leaves the range alone.
	testing.expect(t, press(&fixture, .Escape))
	testing.expect(t, !app.has_focus(fixture.state.selection))
	testing.expect(t, app.has_range(fixture.state.selection))

	// Second press clears the range.
	testing.expect(t, press(&fixture, .Escape))
	testing.expect(t, !app.has_range(fixture.state.selection))

	// A third has nothing left to do.
	testing.expect(t, !press(&fixture, .Escape))
}

@(test)
an_unbound_key_produces_no_command :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	command := app.command_for_key(.Up, {}, fixture.state.selection)
	testing.expect_value(t, command.kind, app.Command_Kind.None)
	testing.expect(t, !app.apply(&fixture.state, &fixture.trace, command))
}

// ---------------------------------------------------------------------------
// Selection synchronization
// ---------------------------------------------------------------------------

@(test)
selecting_an_event_moves_the_playhead :: proc(t: ^testing.T) {
	// docs/01: the application must not allow the timeline to show one moment
	// while another panel shows a different one. A selection that left the
	// playhead behind would do exactly that.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Select_Event, event = model.Event_Id(7)},
	)

	testing.expect(t, fixture.state.selection.has_playhead)
	testing.expect_value(t, fixture.state.selection.playhead_ns, 6 * SECOND)
}

@(test)
the_playhead_is_unset_until_the_user_chooses :: proc(t: ^testing.T) {
	// Zero is a real instant, so an unset playhead cannot be represented by
	// one. Drawing a playhead at zero would claim a selection nobody made.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, !fixture.state.selection.has_playhead)
}

@(test)
navigation_keeps_the_selection_visible :: proc(t: ^testing.T) {
	// Pressing an arrow with nothing visibly happening is the failure this
	// prevents.
	fixture: Fixture
	make_fixture(&fixture, 200)
	defer fixture_destroy(&fixture)

	// Zoom in so most of the session is off screen.
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Zoom, anchor = 500, factor = 0.05},
	)

	for _ in 0 ..< 60 {
		press(&fixture, .Right)
		playhead := fixture.state.selection.playhead_ns
		testing.expectf(
			t,
			playhead >= fixture.state.viewport.start_ns &&
			playhead <= ui.end_ns(fixture.state.viewport),
			"selection at %d fell outside the viewport",
			playhead,
		)
	}
}

// ---------------------------------------------------------------------------
// Viewport commands
// ---------------------------------------------------------------------------

@(test)
panning_stays_inside_the_session :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Zoom, anchor = 500, factor = 0.2},
	)
	for _ in 0 ..< 100 {
		app.apply(&fixture.state, &fixture.trace, app.Command{kind = .Pan, delta = -500})
	}

	testing.expect(t, fixture.state.viewport.start_ns >= fixture.state.session_start_ns)
	testing.expect(t, ui.end_ns(fixture.state.viewport) <= fixture.state.session_end_ns)
}

@(test)
home_fits_the_whole_session :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Zoom, anchor = 500, factor = 0.01},
	)
	press(&fixture, .Home)

	testing.expect_value(t, fixture.state.viewport.start_ns, fixture.state.session_start_ns)
	testing.expect(t, ui.end_ns(fixture.state.viewport) >= fixture.state.session_end_ns)
}

@(test)
a_zoom_that_changes_nothing_reports_no_change :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(
		t,
		!app.apply(&fixture.state, &fixture.trace, app.Command{kind = .Zoom, factor = 1}),
	)
	testing.expect(
		t,
		!app.apply(&fixture.state, &fixture.trace, app.Command{kind = .Pan, delta = 0}),
	)
}

@(test)
resizing_preserves_the_visible_interval :: proc(t: ^testing.T) {
	// A window resize must not silently change which part of the session is
	// shown.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Zoom, anchor = 500, factor = 0.5},
	)
	before_start := fixture.state.viewport.start_ns
	before_span := fixture.state.viewport.span_ns

	app.resize(&fixture.state, 1600)

	testing.expect_value(t, fixture.state.viewport.width, f32(1600))
	testing.expect_value(t, fixture.state.viewport.start_ns, before_start)
	testing.expect_value(t, fixture.state.viewport.span_ns, before_span)
}

// ---------------------------------------------------------------------------
// Filters and playback
// ---------------------------------------------------------------------------

@(test)
digits_toggle_lanes :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, ui.Lane.Files in fixture.state.lanes)
	press(&fixture, .Digit_3)
	testing.expect(t, ui.Lane.Files not_in fixture.state.lanes)
	press(&fixture, .Digit_3)
	testing.expect(t, ui.Lane.Files in fixture.state.lanes)
}

@(test)
playback_advances_between_events :: proc(t: ^testing.T) {
	// docs/01: "playback is an inspection aid, not a video. It advances
	// between meaningful events and scales long idle gaps down." A step
	// happens per interval regardless of how far apart the events are.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Space)

	// Less than one interval: nothing happens yet.
	testing.expect(t, !app.advance_playback(&fixture.state, &fixture.trace, 0.1))

	// Past the interval: one step.
	testing.expect(t, app.advance_playback(&fixture.state, &fixture.trace, 0.3))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))

	testing.expect(t, app.advance_playback(&fixture.state, &fixture.trace, 0.3))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(2))
}

@(test)
playback_does_nothing_while_paused :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, !app.advance_playback(&fixture.state, &fixture.trace, 10))
	testing.expect_value(t, fixture.state.selection.event, model.NO_EVENT)
}

@(test)
playback_stops_at_the_end_rather_than_looping :: proc(t: ^testing.T) {
	// Looping would make the session appear to restart on its own.
	fixture: Fixture
	make_fixture(&fixture, 3)
	defer fixture_destroy(&fixture)

	press(&fixture, .Space)
	for _ in 0 ..< 10 {
		app.advance_playback(&fixture.state, &fixture.trace, 1.0)
	}

	testing.expect(t, !fixture.state.playback.running)
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(3))
}

@(test)
the_revision_advances_only_on_real_changes :: proc(t: ^testing.T) {
	// The frame loop skips redrawing when nothing changed, so a command that
	// mutates state without bumping the revision would never appear on screen.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	before := fixture.state.revision
	press(&fixture, .Right)
	testing.expect(t, fixture.state.revision > before, "a real change must bump the revision")

	after := fixture.state.revision
	app.apply(&fixture.state, &fixture.trace, app.Command{kind = .None})
	testing.expect_value(t, fixture.state.revision, after)
}

@(test)
an_empty_session_is_navigable_without_crashing :: proc(t: ^testing.T) {
	// Opening a trace with no events must not make every key press a hazard.
	fixture: Fixture
	make_fixture(&fixture, 0)
	defer fixture_destroy(&fixture)

	testing.expect(t, !press(&fixture, .Right))
	testing.expect(t, !press(&fixture, .Left))
	testing.expect(t, !press(&fixture, .F))
	press(&fixture, .Space)
	testing.expect(t, !app.advance_playback(&fixture.state, &fixture.trace, 1.0))
}

@(test)
session_extent_covers_event_durations :: proc(t: ^testing.T) {
	// A command still running at the last recorded timestamp extends the
	// session past it; fitting to the events alone would cut it off.
	fixture: Fixture
	make_fixture(&fixture, 3)
	defer fixture_destroy(&fixture)

	fixture.trace.events[2].flags += {.Has_Duration}
	fixture.trace.events[2].duration_ns = 100 * SECOND

	start, end := app.session_extent(&fixture.trace)
	testing.expect_value(t, start, i64(0))
	testing.expect_value(t, end, 102 * SECOND)
}
