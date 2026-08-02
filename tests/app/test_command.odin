package test_app

import "core:testing"

import "src:analysis"
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
	app.state_destroy(&fixture.state)
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
	command := app.command_for_key(
		key,
		modifiers,
		fixture.state.selection,
		fixture.state.search_open,
	)
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

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------
//
// docs/01 requires search over event text, paths, commands, diagnostics, tools,
// and identifiers, with composable filters shown as removable chips — and the
// rule that "a hidden filter must never explain an apparently missing event."
//
// These cover the app layer: that the commands route, that stepping results
// moves the global selection, and that closing search restores the unfiltered
// view rather than leaving a filter behind that nothing displays.

@(private)
searchable_fixture :: proc(fixture: ^Fixture) {
	t := &fixture.trace
	model.string_table_init(&t.strings)
	model.blob_table_init(&t.blobs)
	model.payload_tables_init(&t.payloads)
	t.entities = make([dynamic]model.Entity, 0, 4)
	t.spans = make([dynamic]model.Span, 0, 2)
	t.events = make([dynamic]model.Event, 0, 8)
	t.edges = make([dynamic]model.Edge, 0, 2)
	t.mutations = make([dynamic]model.Mutation, 0, 4)
	t.directory = make([dynamic]codec.Directory_Entry, 0, 2)

	intern :: proc(t: ^codec.Trace, value: string) -> model.String_Id {
		id, _ := model.string_intern(&t.strings, value)
		return id
	}

	append(&t.entities, model.Entity{id = 1, kind = .Path, name = intern(t, "src/main.odin")})
	append(&t.entities, model.Entity{id = 2, kind = .Path, name = intern(t, "src/other.odin")})

	summaries := []string{"alpha here", "beta here", "alpha again", "gamma", "alpha last"}
	kinds := []model.Event_Kind {
		.User_Message,
		.File_Modify,
		.User_Message,
		.Command_Start,
		.File_Modify,
	}
	entities := []model.Entity_Id{model.NO_ENTITY, 1, model.NO_ENTITY, model.NO_ENTITY, 2}

	for summary, index in summaries {
		append(
			&t.events,
			model.Event {
				id = model.Event_Id(index + 1),
				sequence = model.Sequence(index + 1),
				kind = kinds[index],
				flags = {.Has_Wall_Time},
				wall_time_ns = i64(index) * SECOND,
				primary_entity_id = entities[index],
				summary_string_id = intern(t, summary),
			},
		)
	}

	app.state_init(&fixture.state, t, 1000)
}

@(private)
type_query :: proc(fixture: ^Fixture, text: string) -> bool {
	return app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Set_Text, text = text},
	)
}

// type_text delivers text the way the platform does: one decoded chunk per
// keystroke, appended to whatever is already there.
@(private)
type_text :: proc(fixture: ^Fixture, text: string) {
	for index in 0 ..< len(text) {
		app.apply(
			&fixture.state,
			&fixture.trace,
			app.Command{kind = .Search_Append, text = text[index:index + 1]},
		)
	}
}

@(test)
slash_opens_search :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	testing.expect(t, !fixture.state.search_open)
	testing.expect(t, press(&fixture, .Slash))
	testing.expect(t, fixture.state.search_open)

	// Opening twice changes nothing, so it must not cost a redraw.
	testing.expect(t, !press(&fixture, .Slash))
}

@(test)
typing_a_query_produces_matches :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	testing.expect(t, type_query(&fixture, "alpha"))
	testing.expect_value(t, len(fixture.state.search_results.matches), 3)
}

@(test)
stepping_matches_moves_the_global_selection :: proc(t: ^testing.T) {
	// docs/01 keeps every panel synchronized to the selection, so stepping
	// results has to move the workspace rather than just a list cursor.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")

	press(&fixture, .Return)
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))
	testing.expect(t, fixture.state.selection.has_playhead, "the playhead must follow")

	press(&fixture, .Return)
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(3))

	press(&fixture, .Return)
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(5))

	// Stops at the end rather than wrapping: a wrap makes a user lose track of
	// whether they have seen every result.
	testing.expect(t, !press(&fixture, .Return))
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(5))
}

@(test)
shift_return_steps_backward :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")

	press(&fixture, .Return)
	press(&fixture, .Return)
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(3))

	press(&fixture, .Return, {.Shift})
	testing.expect_value(t, fixture.state.selection.event, model.Event_Id(1))
}

@(test)
escape_closes_search_before_clearing_focus :: proc(t: ^testing.T) {
	// Escape backs out one layer at a time, and search is the outermost.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")
	press(&fixture, .Return)

	selected := fixture.state.selection.event

	testing.expect(t, press(&fixture, .Escape))
	testing.expect(t, !fixture.state.search_open)
	// The selection survives: closing the search box is not a reason to lose
	// the event the user navigated to.
	testing.expect_value(t, fixture.state.selection.event, selected)
}

@(test)
closing_search_leaves_no_hidden_filter :: proc(t: ^testing.T) {
	// docs/01: "a hidden filter must never explain an apparently missing
	// event." A filter that outlived its panel is precisely that — nothing on
	// screen would account for the events it removed.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Toggle_Kind, family = .File},
	)
	testing.expect(t, app.search_active(&fixture.state))

	press(&fixture, .Escape)

	testing.expect(t, !app.search_active(&fixture.state))
	testing.expect_value(t, fixture.state.search_query.kinds, analysis.ALL_KINDS)
	testing.expect_value(t, len(fixture.state.search_results.matches), 0)
}

@(test)
toggling_a_family_narrows_and_restores :: proc(t: ^testing.T) {
	// Chips are removable, so every filter must be reversible in place.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "here")
	testing.expect_value(t, len(fixture.state.search_results.matches), 2)

	// Remove conversation, leaving only the file event.
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Toggle_Kind, family = .Conversation},
	)
	testing.expect_value(t, len(fixture.state.search_results.matches), 1)
	testing.expect(t, fixture.state.search_results.excluded_by_kind > 0)

	// Put it back.
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Toggle_Kind, family = .Conversation},
	)
	testing.expect_value(t, len(fixture.state.search_results.matches), 2)
}

@(test)
clearing_filters_keeps_the_query_text :: proc(t: ^testing.T) {
	// Clearing chips is not the same as clearing the search, and a user who
	// meant both can do both.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Toggle_Kind, family = .Conversation},
	)
	testing.expect(t, analysis.active_filter_count(fixture.state.search_query) > 0)

	app.apply(&fixture.state, &fixture.trace, app.Command{kind = .Search_Clear_Filters})

	testing.expect_value(t, analysis.active_filter_count(fixture.state.search_query), 0)
	testing.expect_value(t, len(fixture.state.search_results.matches), 3)
	testing.expect(t, fixture.state.search_open, "clearing chips must not close the panel")
}

@(test)
a_query_matching_nothing_selects_nothing :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "nonexistent")

	testing.expect_value(t, len(fixture.state.search_results.matches), 0)
	testing.expect(t, !press(&fixture, .Return), "stepping an empty result must do nothing")
	testing.expect_value(t, fixture.state.search_selected, -1)
}

@(test)
refining_a_query_keeps_the_cursor_in_range :: proc(t: ^testing.T) {
	// A user narrowing a query expects to stay near where they were rather than
	// jump back to the first hit on every keystroke.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_query(&fixture, "alpha")
	press(&fixture, .Return)
	press(&fixture, .Return)
	press(&fixture, .Return)
	testing.expect_value(t, fixture.state.search_selected, 2)

	// Now only one match remains; the cursor must clamp rather than dangle.
	type_query(&fixture, "alpha last")
	testing.expect_value(t, len(fixture.state.search_results.matches), 1)
	testing.expect_value(t, fixture.state.search_selected, 0)
}

@(test)
search_state_survives_repeated_queries :: proc(t: ^testing.T) {
	// Each query replaces the previous results. Retaining them would attribute
	// stale matches to the current query, and leak besides.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	for text in ([]string{"alpha", "beta", "gamma", "alpha", ""}) {
		type_query(&fixture, text)
	}

	// The empty query matches everything, which is the documented filter-only
	// behaviour rather than "no results".
	testing.expect_value(t, len(fixture.state.search_results.matches), 5)
}

@(test)
typed_characters_reach_the_query :: proc(t: ^testing.T) {
	// The gap this closed: `/` opened the field and nothing could type into it.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alpha")

	testing.expect_value(t, string(fixture.state.search_text[:]), "alpha")
	testing.expect_value(t, len(fixture.state.search_results.matches), 3)
}

@(test)
backspace_removes_one_character :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alphax")
	testing.expect_value(t, len(fixture.state.search_results.matches), 0)

	press(&fixture, .Backspace)
	testing.expect_value(t, string(fixture.state.search_text[:]), "alpha")
	testing.expect_value(t, len(fixture.state.search_results.matches), 3)
}

@(test)
backspace_deletes_a_whole_rune :: proc(t: ^testing.T) {
	// Byte-wise deletion would split a multi-byte character and leave the query
	// invalid UTF-8. The matcher compares bytes, so a split sequence stops
	// matching text the user can still see in the field.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	app.apply(
		&fixture.state,
		&fixture.trace,
		app.Command{kind = .Search_Append, text = "café"},
	)
	testing.expect_value(t, string(fixture.state.search_text[:]), "café")

	press(&fixture, .Backspace)
	testing.expect_value(t, string(fixture.state.search_text[:]), "caf")
}

@(test)
backspace_on_an_empty_field_does_nothing :: proc(t: ^testing.T) {
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	testing.expect(t, !press(&fixture, .Backspace))
	testing.expect_value(t, len(fixture.state.search_text), 0)
}

@(test)
the_field_swallows_keys_that_are_characters :: proc(t: ^testing.T) {
	// Without this, `n` in a filename steps to the next match and `d` cycles
	// the diff panel. The symptom reads as dropped keystrokes rather than as a
	// binding conflict, which is why it is worth asserting directly.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alpha")
	press(&fixture, .Return)
	selected := fixture.state.selection.event
	mode := fixture.state.diff_mode

	// `n` would otherwise step the match; `d` would cycle the diff.
	press(&fixture, .N)
	press(&fixture, .D)

	testing.expect_value(t, fixture.state.selection.event, selected)
	testing.expect_value(t, fixture.state.diff_mode, mode)
}

@(test)
navigation_keys_still_work_while_typing :: proc(t: ^testing.T) {
	// docs/01's keyboard table stays available for everything that cannot be
	// part of a query, or opening search would trap the user in the field.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alpha")

	testing.expect(t, press(&fixture, .Right), "arrows must still step events")
	testing.expect(t, fixture.state.selection.event != model.NO_EVENT)

	testing.expect(t, press(&fixture, .Bracket_Left), "brackets must still set the range")
	testing.expect(t, fixture.state.selection.has_range_start)
}

@(test)
a_modified_key_is_a_shortcut_not_a_character :: proc(t: ^testing.T) {
	// Command+Left is "previous outcome" whether or not a field has focus.
	// Shift is excluded from that rule, because Shift+letter is how capitals
	// are typed.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alpha")

	before := string(fixture.state.search_text[:])
	press(&fixture, .N, {.Primary})
	testing.expect_value(t, string(fixture.state.search_text[:]), before)
}

@(test)
closing_the_field_restores_the_bindings :: proc(t: ^testing.T) {
	// The field only owns the keyboard while it is open.
	fixture: Fixture
	searchable_fixture(&fixture)
	defer fixture_destroy(&fixture)

	press(&fixture, .Slash)
	type_text(&fixture, "alpha")
	press(&fixture, .Escape)

	mode := fixture.state.diff_mode
	testing.expect(t, press(&fixture, .D), "D must cycle the diff once search is closed")
	testing.expect(t, fixture.state.diff_mode != mode)
}
