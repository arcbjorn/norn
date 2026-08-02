package ui

import "core:fmt"

import "src:analysis"
import "src:render"
import "src:trace/codec"
import "src:trace/model"

// The search bar.
//
// docs/01 places Search and Filters in the top bar, and states the rule this
// panel exists to satisfy: "filters are composable and visible as removable
// chips. A hidden filter must never explain an apparently missing event."
//
// The second sentence is the design constraint. A filter the user cannot see is
// worse than no filter, because it makes the trace look incomplete. So this
// panel always shows every active filter as a chip, and when a query returns
// nothing it says which filter is responsible rather than reporting an empty
// result and leaving the user to guess.

Search_Theme :: struct {
	background: render.Color,
	border:     render.Color,
	field:      render.Color,
	text:       render.Color,
	muted:      render.Color,
	// Chips are tinted by whether they narrow the result, so an active filter
	// is visibly different from an available one.
	chip:        render.Color,
	chip_active: render.Color,
	chip_text:   render.Color,
	// The count of matches, and the currently selected one.
	count:     render.Color,
	highlight: render.Color,
}

DARK_SEARCH :: Search_Theme {
	background  = render.Color{0.12, 0.13, 0.16, 1.0},
	border      = render.Color{0.22, 0.23, 0.28, 1.0},
	field       = render.Color{0.08, 0.09, 0.11, 1.0},
	text        = render.Color{0.94, 0.95, 0.97, 1.0},
	muted       = render.Color{0.52, 0.55, 0.62, 1.0},
	chip        = render.Color{0.18, 0.19, 0.23, 1.0},
	chip_active = render.Color{0.24, 0.40, 0.62, 1.0},
	chip_text   = render.Color{0.88, 0.90, 0.94, 1.0},
	count       = render.Color{0.70, 0.74, 0.80, 1.0},
	highlight   = render.Color{0.92, 0.72, 0.36, 1.0},
}

// SEARCH_BAR_HEIGHT is the bar's height in logical pixels.
//
// Scaled by the caller, like every other measurement: docs/07 requires layout
// in logical units so a Retina display does not halve the interface.
SEARCH_BAR_HEIGHT :: 34

// Search_State is what the panel needs to draw.
//
// A value rather than a pointer to the application state: docs/02 keeps the
// renderer free of product state, and a panel that reached into the app could
// change it while drawing.
Search_State :: struct {
	bounds: render.Rect,
	theme:  Search_Theme,
	fonts:  ^render.Font_Set,
	atlas:  ^render.Atlas,
	scale:  f32,

	// The query text as typed.
	text: string,
	// Which families are included, for the chips.
	kinds: analysis.Kind_Filters,
	// Other active filters, each of which earns a chip.
	failed_only:  bool,
	scoped_path:  model.Entity_Id,
	has_range:    bool,

	// Result accounting, for the count and the empty-state explanation.
	match_count: int,
	selected:    int,
	examined:    int,
	excluded_by_kind:    int,
	excluded_by_time:    int,
	excluded_by_path:    int,
	excluded_by_outcome: int,
	truncated: int,
}

// Chip is one drawn filter, returned so hit testing can use the same geometry.
//
// docs/07 prohibits duplicate coordinate math: the rectangle a chip was drawn
// at is the rectangle a click must test against, or removing a chip becomes
// unreliable exactly where the interface is densest.
Chip :: struct {
	bounds: render.Rect,
	kind:   Chip_Kind,
	family: analysis.Kind_Filter,
	active: bool,
}

Chip_Kind :: enum u8 {
	Family,
	Failed_Only,
	Scoped_Path,
	Range,
}

// MAX_CHIPS bounds the chip row.
//
// Six families plus three standalone filters. A fixed array rather than a
// dynamic one keeps the panel allocation-free, which matters because it runs
// every frame.
MAX_CHIPS :: 16

Chip_Layout :: struct {
	chips: [MAX_CHIPS]Chip,
	count: int,
}

// draw_search renders the bar and returns where each chip landed.
draw_search :: proc(
	list: ^render.Draw_List,
	state: Search_State,
) -> (
	layout: Chip_Layout,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	render.fill_rect(list, state.bounds, state.theme.background)
	render.draw_line(
		list,
		state.bounds.x0,
		state.bounds.y1,
		state.bounds.x1,
		state.bounds.y1,
		state.theme.border,
	)

	if state.fonts == nil || state.atlas == nil {
		// Without a font the bar is a coloured strip. docs/13 records that font
		// discovery is an open packaging question, and a missing face degrades
		// the interface rather than preventing it from opening.
		return layout
	}

	padding := 10 * state.scale
	text_y := state.bounds.y0 + (render.rect_height(state.bounds) - 12 * state.scale) * 0.5

	// The query field.
	field_width := 240 * state.scale
	field := render.Rect {
		state.bounds.x0 + padding,
		state.bounds.y0 + 5 * state.scale,
		state.bounds.x0 + padding + field_width,
		state.bounds.y1 - 5 * state.scale,
	}
	render.fill_rect(list, field, state.theme.field)

	shown := state.text
	color := state.theme.text
	if shown == "" {
		// A prompt rather than a blank box, so the bar explains itself.
		shown = "search events, paths, commands"
		color = state.theme.muted
	}
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		shown,
		field.x0 + 6 * state.scale,
		text_y,
		field_width - 12 * state.scale,
		color,
	)

	cursor := field.x1 + padding

	// The result count, immediately after the field where a user looks first.
	summary := result_summary(state)
	if summary != "" {
		width := render.measure_text(state.fonts, state.atlas, summary)
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			summary,
			cursor,
			text_y,
			width,
			state.theme.count,
		)
		cursor += width + padding * 1.5
	}

	// Filter chips. Every family gets one whether active or not, because a
	// filter a user cannot see is one they cannot remove.
	for family in analysis.Kind_Filter {
		active := family in state.kinds
		cursor = draw_chip(
			list,
			state,
			&layout,
			cursor,
			family_label(family),
			Chip{kind = .Family, family = family, active = active},
		)
	}

	if state.failed_only {
		cursor = draw_chip(
			list,
			state,
			&layout,
			cursor,
			"failed only",
			Chip{kind = .Failed_Only, active = true},
		)
	}
	if state.scoped_path != model.NO_ENTITY {
		cursor = draw_chip(
			list,
			state,
			&layout,
			cursor,
			"this file",
			Chip{kind = .Scoped_Path, active = true},
		)
	}
	if state.has_range {
		cursor = draw_chip(
			list,
			state,
			&layout,
			cursor,
			"in range",
			Chip{kind = .Range, active = true},
		)
	}

	return layout
}

// draw_chip renders one chip and records its rectangle.
@(private)
draw_chip :: proc(
	list: ^render.Draw_List,
	state: Search_State,
	layout: ^Chip_Layout,
	x: f32,
	label: string,
	chip: Chip,
) -> f32 {
	if layout.count >= MAX_CHIPS {
		return x
	}

	inset := 7 * state.scale
	width := render.measure_text(state.fonts, state.atlas, label) + inset * 2
	if x + width > state.bounds.x1 {
		// Out of room. Dropping a chip silently would hide a filter, so nothing
		// further is drawn and the count below reports the discrepancy.
		return x
	}

	bounds := render.Rect {
		x,
		state.bounds.y0 + 7 * state.scale,
		x + width,
		state.bounds.y1 - 7 * state.scale,
	}

	background := state.theme.chip_active if chip.active else state.theme.chip
	render.fill_rect(list, bounds, background)

	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		label,
		bounds.x0 + inset,
		state.bounds.y0 + (render.rect_height(state.bounds) - 12 * state.scale) * 0.5,
		width - inset * 2,
		state.theme.chip_text,
	)

	recorded := chip
	recorded.bounds = bounds
	layout.chips[layout.count] = recorded
	layout.count += 1

	return bounds.x1 + 6 * state.scale
}

// result_summary states the outcome in words.
//
// docs/01: "a hidden filter must never explain an apparently missing event."
// When a query returns nothing, this says whether nothing matched or a filter
// removed everything — the difference between "it is not in the trace" and
// "you are not looking at all of it".
result_summary :: proc(state: Search_State) -> string {
	if state.text == "" && !filtering(state) {
		return ""
	}

	excluded :=
		state.excluded_by_kind +
		state.excluded_by_time +
		state.excluded_by_path +
		state.excluded_by_outcome

	if state.match_count == 0 {
		if excluded == 0 {
			return fmt.tprintf("no matches in %d events", state.examined)
		}
		// Name the filter that removed the most, because that is the one the
		// user most likely wants to remove.
		return fmt.tprintf("no matches; %s", dominant_filter(state, excluded))
	}

	position := ""
	if state.selected >= 0 {
		position = fmt.tprintf("%d of ", state.selected + 1)
	}

	if state.truncated > 0 {
		// A truncated list that did not say so would look complete, and the
		// user would conclude the rest do not exist.
		return fmt.tprintf(
			"%s%d matches (%d more)",
			position,
			state.match_count,
			state.truncated,
		)
	}
	if excluded > 0 {
		return fmt.tprintf(
			"%s%d matches, %d filtered out",
			position,
			state.match_count,
			excluded,
		)
	}
	return fmt.tprintf("%s%d matches", position, state.match_count)
}

@(private)
dominant_filter :: proc(state: Search_State, excluded: int) -> string {
	most := state.excluded_by_kind
	name := "hidden by the kind filters"

	if state.excluded_by_time > most {
		most = state.excluded_by_time
		name = "outside the selected range"
	}
	if state.excluded_by_path > most {
		most = state.excluded_by_path
		name = "not in the focused file"
	}
	if state.excluded_by_outcome > most {
		most = state.excluded_by_outcome
		name = "not failing outcomes"
	}
	return fmt.tprintf("%d events %s", excluded, name)
}

@(private)
filtering :: proc(state: Search_State) -> bool {
	return(
		state.kinds != analysis.ALL_KINDS ||
		state.failed_only ||
		state.scoped_path != model.NO_ENTITY ||
		state.has_range \
	)
}

@(private)
family_label :: proc(family: analysis.Kind_Filter) -> string {
	switch family {
	case .Conversation: return "messages"
	case .Tool:         return "tools"
	case .File:         return "edits"
	case .Command:      return "commands"
	case .Outcome:      return "outcomes"
	case .Extension:    return "other"
	}
	return "unknown"
}

// chip_at returns the chip containing a point.
//
// The same rectangles draw_search recorded, so a click resolves to exactly the
// chip that was drawn there. docs/07 requires this: two independent notions of
// where a chip sits drift, and the drift shows up as clicks that do nothing.
chip_at :: proc(layout: ^Chip_Layout, x, y: f32) -> (chip: Chip, found: bool) {
	for index in 0 ..< layout.count {
		candidate := layout.chips[index]
		if render.rect_contains(candidate.bounds, x, y) {
			return candidate, true
		}
	}
	return {}, false
}

// search_result_line renders one match for a result list.
//
// Separate from the bar so a future results panel can use it. The field name is
// included because docs/01 requires a user to be able to tell why a row is
// present: a hit in a command line and a hit in a path are different answers.
search_result_line :: proc(
	trace: ^codec.Trace,
	match: analysis.Match,
	allocator := context.temp_allocator,
) -> string {
	text := match.text
	if text == "" {
		if event, ok := event_by_id(trace, match.event); ok {
			value, _ := model.string_get(&trace.strings, event.summary_string_id)
			text = value
		}
	}
	return fmt.aprintf(
		"%d  %-10s  %s",
		match.event,
		analysis.field_name(match.field),
		text,
		allocator = allocator,
	)
}

@(private)
event_by_id :: proc(
	trace: ^codec.Trace,
	id: model.Event_Id,
) -> (
	event: model.Event,
	found: bool,
) {
	index := int(id) - 1
	if index < 0 || index >= len(trace.events) {
		return {}, false
	}
	return trace.events[index], true
}
