package app

import "src:core"
import "src:trace/codec"
import "src:trace/model"
import "src:analysis"
import "src:ui"

// Commands.
//
// docs/07-rendering.md: "input produces commands, commands update application
// state, and panels render the resulting state." The indirection buys two
// things. Input handling can be tested without a window, because a command is
// a value. And a keybinding, a menu item, and a script all produce the same
// command, so they cannot drift into behaving differently.

// Command_Kind enumerates every state change the application can perform.
Command_Kind :: enum u8 {
	None = 0,

	// Navigation, from the keyboard table in docs/01.
	Next_Event,
	Previous_Event,
	Next_Mutation,
	Previous_Mutation,
	Next_Outcome,
	Previous_Outcome,

	// Time.
	Set_Playhead,
	Toggle_Playback,

	// Selection.
	Select_Event,
	Focus_Selected,
	Clear,

	// Comparison range.
	Set_Range_Start,
	Set_Range_End,

	// Viewport.
	Pan,
	Zoom,
	Fit_Session,

	// Filters.
	Toggle_Lane,

	// Search. docs/01 requires search over event text, paths, commands,
	// diagnostics, tools, and identifiers, with filters shown as removable
	// chips.
	Search_Open,
	Search_Close,
	Search_Set_Text,
	Search_Next,
	Search_Previous,
	Search_Toggle_Kind,
	Search_Toggle_Failed_Only,
	Search_Scope_To_Focus,
	Search_Clear_Filters,

	// Diff panel.
	Cycle_Diff_Mode,
	Scroll_Diff,

	// Lifecycle.
	Quit,
}

// Command is one state change, with whatever parameters it needs.
Command :: struct {
	kind: Command_Kind,
	// Time for Set_Playhead and the range commands.
	time_ns: i64,
	// Event for Select_Event.
	event: model.Event_Id,
	// Pixel delta for Pan; anchor position for Zoom.
	delta: f32,
	anchor: f32,
	// Scale factor for Zoom, below one to zoom in.
	factor: f64,
	// Lane for Toggle_Lane.
	lane: ui.Lane,
	// Line delta for Scroll_Diff.
	lines: int,
	// Query text for Search_Set_Text. Borrowed for the duration of the call;
	// the state clones what it keeps.
	text: string,
	// Family for Search_Toggle_Kind.
	family: analysis.Kind_Filter,
}

// Modifiers carried by a key event.
Modifier :: enum u8 {
	Shift   = 0,
	Control = 1,
	Alt     = 2,
	// The platform's primary modifier: Command on macOS, Control elsewhere.
	// Named by role rather than by key so docs/01's "Command + Left" maps to
	// the right key on every platform without a per-platform table.
	Primary = 3,
}

Modifiers :: bit_set[Modifier; u8]

// Key is the subset of keys the application binds.
//
// A small enum rather than a raw scancode: the platform layer translates once,
// and everything above it is free of SDL types.
Key :: enum u8 {
	None = 0,
	Left,
	Right,
	Up,
	Down,
	Space,
	Escape,
	Bracket_Left,
	Bracket_Right,
	F,
	Home,
	End,
	Digit_1,
	Digit_2,
	Digit_3,
	Digit_4,
	Digit_5,
	Digit_6,
	Digit_7,
	D,
	Page_Up,
	Page_Down,
	Slash,
	N,
	Return,
}

// command_for_key translates a keystroke into a command.
//
// This is the whole binding table from docs/01, in one place. `has_focus` and
// `has_range` are passed because Escape's behaviour depends on what is set,
// and resolving that here keeps the state machine visible rather than spread
// between the input layer and the handler.
command_for_key :: proc(
	key: Key,
	modifiers: Modifiers,
	selection: Selection,
	// Whether the search panel is open. Escape backs out one layer at a time,
	// and search is the outermost, so the binding depends on it.
	search_open := false,
) -> Command {
	#partial switch key {
	case .Left:
		if .Primary in modifiers {
			return Command{kind = .Previous_Outcome}
		}
		if .Shift in modifiers {
			return Command{kind = .Previous_Mutation}
		}
		return Command{kind = .Previous_Event}

	case .Right:
		if .Primary in modifiers {
			return Command{kind = .Next_Outcome}
		}
		if .Shift in modifiers {
			return Command{kind = .Next_Mutation}
		}
		return Command{kind = .Next_Event}

	case .Space:
		return Command{kind = .Toggle_Playback}

	case .Bracket_Left:
		return Command{kind = .Set_Range_Start, time_ns = selection.playhead_ns}

	case .Bracket_Right:
		return Command{kind = .Set_Range_End, time_ns = selection.playhead_ns}

	case .F:
		return Command{kind = .Focus_Selected}

	case .Slash:
		// docs/01 fixes the keyboard table but names no search binding, so this
		// follows the convention every editor and pager shares. Chosen rather
		// than invented: a user who has to look up how to search has already
		// lost the thread they were following.
		return Command{kind = .Search_Open}

	case .N:
		// Next and previous match, the companion convention to `/`.
		if .Shift in modifiers {
			return Command{kind = .Search_Previous}
		}
		return Command{kind = .Search_Next}

	case .Return:
		return Command{kind = .Search_Next}

	case .Escape:
		// docs/01: "Escape — clear focus, then clear range." Two presses do
		// two different things, which is what a user expects from a key that
		// backs out of state one layer at a time. Search is the outermost
		// layer, so it closes first — and closing it restores the unfiltered
		// view, because docs/01 forbids a hidden filter explaining a missing
		// event.
		if search_open {
			return Command{kind = .Search_Close}
		}
		return Command{kind = .Clear}

	case .Home:
		return Command{kind = .Fit_Session}

	case .D:
		return Command{kind = .Cycle_Diff_Mode}

	case .Page_Up:
		return Command{kind = .Scroll_Diff, lines = -20}

	case .Page_Down:
		return Command{kind = .Scroll_Diff, lines = 20}

	case .Digit_1: return Command{kind = .Toggle_Lane, lane = .Conversation}
	case .Digit_2: return Command{kind = .Toggle_Lane, lane = .Tools}
	case .Digit_3: return Command{kind = .Toggle_Lane, lane = .Files}
	case .Digit_4: return Command{kind = .Toggle_Lane, lane = .Commands}
	case .Digit_5: return Command{kind = .Toggle_Lane, lane = .Outcomes}
	case .Digit_6: return Command{kind = .Toggle_Lane, lane = .Errors}
	case .Digit_7: return Command{kind = .Toggle_Lane, lane = .Annotations}
	}

	return Command{kind = .None}
}

// Playback_State tracks automatic traversal.
//
// docs/01: "playback is an inspection aid, not a video. It advances between
// meaningful events and scales long idle gaps down." So playback steps from
// event to event rather than advancing a clock, and an hour of agent
// inactivity does not become an hour of watching nothing.
Playback_State :: struct {
	running: bool,
	// Seconds of real time per step. Slow enough to read, fast enough that a
	// long session does not take a working day.
	step_interval: f64,
	// Accumulated time since the last step.
	elapsed: f64,
}

DEFAULT_STEP_INTERVAL :: 0.25

// State is everything the application owns.
//
// docs/02: application state owns the global selection, open panels, active
// filters, theme, and ephemeral layout state. The main thread is its only
// writer.
State :: struct {
	selection: Selection,
	viewport:  ui.Viewport,
	lanes:     ui.Lane_Filter,
	playback:  Playback_State,

	// Session extent, for clamping and fitting.
	session_start_ns: i64,
	session_end_ns:   i64,

	// Vertical scroll offset of the inspector, in device pixels.
	inspector_scroll: f32,
	// Vertical scroll of the diff panel, in lines.
	diff_scroll_lines: int,
	// Which comparison the diff panel shows.
	diff_mode: ui.Diff_Mode,
	// Which activity categories the repository map shows.
	map_filter: analysis.Node_Filter,

	// Search. Open is separate from a non-empty query because a user who
	// clears the box has not closed the panel, and closing it must restore the
	// unfiltered view rather than leave a hidden filter behind — docs/01
	// forbids a filter that silently explains a missing event.
	search_open:     bool,
	search_query:    analysis.Query,
	search_results:  analysis.Results,
	search_selected: int,
	// Owned copy of the query text, because the caller's buffer is transient.
	search_text: [dynamic]u8,

	// Set when the user asked to quit.
	quitting: bool,

	// Bumped whenever a command changes anything a panel draws. The frame loop
	// uses it to skip redrawing an unchanged frame, which is what keeps an
	// idle window off the CPU.
	revision: u64,
}

// state_init prepares the application for a trace.
state_init :: proc(state: ^State, trace: ^codec.Trace, width: f32) {
	state.lanes = ui.ALL_LANES
	state.search_query = analysis.query_default()
	state.search_text = make([dynamic]u8, 0, 64)
	state.search_selected = -1
	state.playback.step_interval = DEFAULT_STEP_INTERVAL

	start, end := session_extent(trace)
	state.session_start_ns = start
	state.session_end_ns = end
	state.viewport = ui.fit_session(start, end, width)
	state.revision = 1
}

// session_extent returns the first and last recorded instants.
//
// A session with no usable timestamps still needs an extent, so the sequence
// range stands in — the same fallback the timeline uses for placement, so the
// two agree.
session_extent :: proc(trace: ^codec.Trace) -> (start: i64, end: i64) {
	if len(trace.events) == 0 {
		return 0, 1
	}
	start = ui.event_time(trace.events[0])
	end = start

	for event in trace.events {
		time_ns := ui.event_time(event)
		if time_ns < start {
			start = time_ns
		}
		finish := time_ns + ui.event_duration(event)
		if finish > end {
			end = finish
		}
	}
	if end <= start {
		end = start + 1
	}
	return start, end
}

// state_destroy releases what the state owns.
//
// Only the search buffers: everything else is either borrowed from the trace or
// a value. Added when search introduced the first owned allocation, so a viewer
// that opens several traces in one process does not accumulate them.
state_destroy :: proc(state: ^State) {
	analysis.results_destroy(&state.search_results)
	delete(state.search_text)
	state^ = {}
}

// apply performs a command, returning whether anything changed.
//
// The return value drives redraw: a command that changed nothing should not
// cost a frame. Every branch that mutates state marks it, so a new command
// that forgets to is a command whose effect never appears.
apply :: proc(state: ^State, trace: ^codec.Trace, command: Command) -> (changed: bool) {
	switch command.kind {
	case .None:
		return false

	case .Quit:
		state.quitting = true
		return true

	case .Next_Event:
		return step_selection(state, trace, .Any, forward = true)
	case .Previous_Event:
		return step_selection(state, trace, .Any, forward = false)
	case .Next_Mutation:
		return step_selection(state, trace, .Mutation, forward = true)
	case .Previous_Mutation:
		return step_selection(state, trace, .Mutation, forward = false)
	case .Next_Outcome:
		return step_selection(state, trace, .Outcome, forward = true)
	case .Previous_Outcome:
		return step_selection(state, trace, .Outcome, forward = false)

	case .Set_Playhead:
		if state.selection.has_playhead && state.selection.playhead_ns == command.time_ns {
			return false
		}
		state.selection.playhead_ns = command.time_ns
		state.selection.has_playhead = true

	case .Toggle_Playback:
		// A session with nothing to play cannot be played. Starting anyway
		// would leave playback running with no way to advance, and the first
		// tick would immediately stop it again.
		if !state.playback.running && len(trace.events) == 0 {
			return false
		}
		state.playback.running = !state.playback.running
		state.playback.elapsed = 0

	case .Select_Event:
		if state.selection.event == command.event {
			return false
		}
		state.selection.event = command.event
		// Selecting an event moves the playhead to it, because docs/01 makes
		// the selected time control every panel: a selection that left the
		// playhead elsewhere would show the inspector and the diff describing
		// different moments.
		if time_ns, found := event_time_by_id(trace, command.event); found {
			state.selection.playhead_ns = time_ns
			state.selection.has_playhead = true
		}

	case .Focus_Selected:
		entity, found := selected_entity(state, trace)
		if !found {
			return false
		}
		state.selection.focus_kind = .Entity
		state.selection.focus_entity = entity

	case .Clear:
		// Two-stage, per docs/01: focus first, then range. Clearing both at
		// once would make one press destroy work the user may still want.
		if has_focus(state.selection) {
			clear_focus(&state.selection)
		} else if state.selection.has_range_start || state.selection.has_range_end {
			clear_range(&state.selection)
		} else {
			return false
		}

	case .Set_Range_Start:
		state.selection.range_start_ns = command.time_ns
		state.selection.has_range_start = true

	case .Set_Range_End:
		state.selection.range_end_ns = command.time_ns
		state.selection.has_range_end = true

	case .Pan:
		if command.delta == 0 {
			return false
		}
		state.viewport = ui.pan_by_pixels(state.viewport, command.delta)
		state.viewport = ui.clamp_to_session(
			state.viewport,
			state.session_start_ns,
			state.session_end_ns,
		)

	case .Zoom:
		if command.factor <= 0 || command.factor == 1 {
			return false
		}
		state.viewport = ui.zoom_at_pixel(state.viewport, command.anchor, command.factor)
		state.viewport = ui.clamp_to_session(
			state.viewport,
			state.session_start_ns,
			state.session_end_ns,
		)

	case .Fit_Session:
		state.viewport = ui.fit_session(
			state.session_start_ns,
			state.session_end_ns,
			state.viewport.width,
			state.viewport.origin_x,
		)

	case .Search_Open:
		if state.search_open {
			return false
		}
		state.search_open = true
		state.revision += 1
		return true

	case .Search_Close:
		if !state.search_open {
			return false
		}
		// Closing discards the filters as well as the panel. docs/01 forbids a
		// hidden filter explaining a missing event, and a filter that survived
		// a closed search box is exactly that.
		state.search_open = false
		state.search_query = analysis.query_default()
		clear(&state.search_text)
		analysis.results_destroy(&state.search_results)
		state.search_selected = -1
		state.revision += 1
		return true

	case .Search_Set_Text:
		if string(state.search_text[:]) == command.text {
			return false
		}
		clear(&state.search_text)
		append(&state.search_text, ..transmute([]byte)command.text)
		run_search(state, trace)
		state.revision += 1
		return true

	case .Search_Toggle_Kind:
		if command.family in state.search_query.kinds {
			state.search_query.kinds -= {command.family}
		} else {
			state.search_query.kinds += {command.family}
		}
		run_search(state, trace)
		state.revision += 1
		return true

	case .Search_Toggle_Failed_Only:
		state.search_query.failed_only = !state.search_query.failed_only
		run_search(state, trace)
		state.revision += 1
		return true

	case .Search_Scope_To_Focus:
		// Scoping to what the user already focused is the common narrowing, and
		// making it a command keeps the filter visible as a chip rather than an
		// implicit consequence of the focus.
		wanted := model.NO_ENTITY
		if state.selection.focus_kind == .Entity {
			wanted = state.selection.focus_entity
		}
		if state.search_query.path == wanted {
			return false
		}
		state.search_query.path = wanted
		run_search(state, trace)
		state.revision += 1
		return true

	case .Search_Clear_Filters:
		// The text survives: clearing chips is not the same as clearing the
		// query, and a user who meant both can do both.
		text := state.search_query.text
		state.search_query = analysis.query_default()
		state.search_query.text = text
		run_search(state, trace)
		state.revision += 1
		return true

	case .Search_Next:
		return step_search(state, trace, forward = true)
	case .Search_Previous:
		return step_search(state, trace, forward = false)

	case .Toggle_Lane:
		if command.lane in state.lanes {
			state.lanes -= {command.lane}
		} else {
			state.lanes += {command.lane}
		}

	case .Cycle_Diff_Mode:
		state.diff_mode = next_diff_mode(state.diff_mode)
		// A new comparison is a different document, so the previous scroll
		// position means nothing in it.
		state.diff_scroll_lines = 0

	case .Scroll_Diff:
		if command.lines == 0 {
			return false
		}
		scrolled := state.diff_scroll_lines + command.lines
		if scrolled < 0 {
			scrolled = 0
		}
		if scrolled == state.diff_scroll_lines {
			return false
		}
		state.diff_scroll_lines = scrolled
	}

	state.revision += 1
	return true
}

// next_diff_mode advances through the comparisons docs/01 lists.
//
// A cycle rather than a menu: there are four, the order is meaningful — state,
// then progressively wider comparisons — and a single key is faster than
// hunting for a control while reading a diff.
next_diff_mode :: proc "contextless" (mode: ui.Diff_Mode) -> ui.Diff_Mode {
	switch mode {
	case .At_Playhead:            return .From_Previous_Mutation
	case .From_Previous_Mutation: return .From_Session_Start
	case .From_Session_Start:     return .Across_Range
	case .Across_Range:           return .At_Playhead
	}
	return .At_Playhead
}

// Step_Filter selects which events navigation stops at.
Step_Filter :: enum u8 {
	Any      = 0,
	Mutation = 1,
	Outcome  = 2,
}

@(private)
matches_filter :: proc "contextless" (kind: model.Event_Kind, filter: Step_Filter) -> bool {
	switch filter {
	case .Any:      return true
	case .Mutation: return model.is_mutation(kind)
	case .Outcome:  return model.is_outcome(kind)
	}
	return false
}

// step_selection moves the selection to the adjacent matching event.
//
// Navigation walks the trace rather than the visible set: docs/01's "next
// mutation" means the next one in the session, not the next one that happens
// to be on screen. The viewport follows the selection instead of bounding it.
@(private)
step_selection :: proc(
	state: ^State,
	trace: ^codec.Trace,
	filter: Step_Filter,
	forward: bool,
) -> bool {
	if len(trace.events) == 0 {
		return false
	}

	current := current_index(state, trace)

	if forward {
		for index := current + 1; index < len(trace.events); index += 1 {
			if matches_filter(trace.events[index].kind, filter) {
				return select_index(state, trace, index)
			}
		}
	} else {
		for index := current - 1; index >= 0; index -= 1 {
			if matches_filter(trace.events[index].kind, filter) {
				return select_index(state, trace, index)
			}
		}
	}

	// Already at the last match in that direction. Reporting no change keeps
	// the frame loop from redrawing an identical frame.
	return false
}

// current_index returns the index of the selected event.
//
// With nothing selected, navigation starts from the playhead so the first
// arrow press moves to the event nearest the current moment rather than
// jumping to the start of the session.
@(private)
current_index :: proc(state: ^State, trace: ^codec.Trace) -> int {
	if state.selection.event != model.NO_EVENT {
		position := int(state.selection.event) - 1
		if position >= 0 && position < len(trace.events) {
			return position
		}
	}
	if state.selection.has_playhead {
		return ui.first_at_or_after(trace.events[:], state.selection.playhead_ns) - 1
	}
	return -1
}

@(private)
select_index :: proc(state: ^State, trace: ^codec.Trace, index: int) -> bool {
	event := trace.events[index]
	state.selection.event = event.id
	state.selection.playhead_ns = ui.event_time(event)
	state.selection.has_playhead = true

	// Keep the selection on screen. A navigation that moved the selection out
	// of view would leave the user pressing a key with nothing visible
	// happening.
	state.viewport = ensure_visible(state.viewport, state.selection.playhead_ns)
	state.viewport = ui.clamp_to_session(
		state.viewport,
		state.session_start_ns,
		state.session_end_ns,
	)

	state.revision += 1
	return true
}

// ensure_visible scrolls the viewport so an instant is inside it.
//
// The instant is placed a little inside the edge rather than exactly on it,
// so repeated stepping does not leave the selection pinned to the boundary
// with no context on the leading side.
@(private)
ensure_visible :: proc(viewport: ui.Viewport, time_ns: i64) -> ui.Viewport {
	margin := viewport.span_ns / 10
	result := viewport

	if time_ns < viewport.start_ns + margin {
		result.start_ns = time_ns - margin
	} else if time_ns > ui.end_ns(viewport) - margin {
		result.start_ns = time_ns + margin - viewport.span_ns
	}
	return result
}

@(private)
event_time_by_id :: proc(
	trace: ^codec.Trace,
	id: model.Event_Id,
) -> (
	time_ns: i64,
	found: bool,
) {
	index := int(id) - 1
	if index < 0 || index >= len(trace.events) {
		return 0, false
	}
	return ui.event_time(trace.events[index]), true
}

// selected_entity returns the entity the selected event concerns.
@(private)
selected_entity :: proc(
	state: ^State,
	trace: ^codec.Trace,
) -> (
	entity: model.Entity_Id,
	found: bool,
) {
	index := int(state.selection.event) - 1
	if index < 0 || index >= len(trace.events) {
		return model.NO_ENTITY, false
	}
	subject := trace.events[index].primary_entity_id
	if subject == model.NO_ENTITY {
		return model.NO_ENTITY, false
	}
	return subject, true
}

// advance_playback steps the selection when playback is running.
//
// `delta_seconds` is real elapsed time. Playback advances between events
// rather than along a clock, so a long idle gap costs one step rather than
// its real duration.
advance_playback :: proc(
	state: ^State,
	trace: ^codec.Trace,
	delta_seconds: f64,
) -> (
	changed: bool,
) {
	if !state.playback.running {
		return false
	}

	state.playback.elapsed += delta_seconds
	if state.playback.elapsed < state.playback.step_interval {
		return false
	}
	state.playback.elapsed = 0

	if !step_selection(state, trace, .Any, forward = true) {
		// Reaching the end stops playback rather than looping, which would
		// make the session appear to restart on its own.
		state.playback.running = false
		state.revision += 1
		return true
	}
	return true
}

// resize updates the viewport for a new panel width.
//
// The visible time interval is preserved rather than the scale, so a window
// resize does not silently change which part of the session is shown.
resize :: proc(state: ^State, width: f32) {
	if width <= 0 || width == state.viewport.width {
		return
	}
	state.viewport.width = width
	state.viewport = ui.clamp_to_session(
		state.viewport,
		state.session_start_ns,
		state.session_end_ns,
	)
	state.revision += 1
}

// run_search re-runs the query and keeps the selected result in range.
//
// Re-run on every change rather than incrementally narrowed: a filter can be
// removed as well as added, and an incremental result set cannot grow back.
@(private)
run_search :: proc(state: ^State, trace: ^codec.Trace) {
	analysis.results_destroy(&state.search_results)

	state.search_query.text = string(state.search_text[:])
	results, err := analysis.search(trace, state.search_query)
	if !core.ok(err) {
		// A failed query leaves an empty result rather than a stale one. Showing
		// the previous matches would attribute them to the current query.
		state.search_selected = -1
		return
	}
	state.search_results = results

	if len(results.matches) == 0 {
		state.search_selected = -1
		return
	}
	// Clamped rather than reset: a user refining a query expects to stay near
	// where they were, not to jump back to the first hit on every keystroke.
	//
	// An unset cursor stays unset. Pre-selecting the first match here would
	// make the first "next" press land on the *second* one, because stepping
	// advances from wherever the cursor already is — and it would claim a
	// selection the user has not made.
	if state.search_selected >= len(results.matches) {
		state.search_selected = len(results.matches) - 1
	}
}

// step_search moves to the next or previous match and selects it.
//
// Selecting the event is the point: docs/01 keeps every panel synchronized to
// the global selection, so stepping through results moves the whole workspace.
@(private)
step_search :: proc(state: ^State, trace: ^codec.Trace, forward: bool) -> bool {
	count := len(state.search_results.matches)
	if count == 0 {
		return false
	}

	next := state.search_selected
	if next < 0 {
		next = 0 if forward else count - 1
	} else {
		next += 1 if forward else -1
		if next < 0 || next >= count {
			// Stops at the ends rather than wrapping. A wrap makes a user lose
			// track of whether they have seen every result.
			return false
		}
	}

	state.search_selected = next
	match := state.search_results.matches[next]

	// Routed through apply rather than assigning the selection here: selecting
	// an event also moves the playhead and clamps the viewport, and a second
	// copy of that logic is one that drifts.
	apply(state, trace, Command{kind = .Select_Event, event = match.event})
	state.revision += 1
	return true
}

// search_active reports whether a query is narrowing what the user sees.
//
// docs/01: filters are visible as removable chips, and "a hidden filter must
// never explain an apparently missing event". A panel showing filtered content
// asks this to decide whether it owes the user an explanation.
search_active :: proc(state: ^State) -> bool {
	return state.search_open &&
		(len(state.search_text) > 0 || analysis.active_filter_count(state.search_query) > 0)
}
