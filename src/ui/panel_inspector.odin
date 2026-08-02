package ui

import "core:fmt"

import "src:analysis"
import "src:render"
import "src:trace/codec"
import "src:trace/model"

// The event inspector.
//
// docs/01-user-experience.md places this beside the timeline, showing event
// details, evidence, and attributes. For an outcome it shows the evidence
// stack, whose order docs/01 fixes: the outcome, attached parents, mutations
// since the last comparable success, associated reads, ranked candidates, and
// finally uncertainty.
//
// Two rules from docs/01 shape everything here. The interface says "candidate
// contributor" rather than "cause" unless an explicit relationship licenses
// more. And an empty panel explains why it is empty rather than simply being
// blank, because a user cannot tell an absent selection from a broken panel.

// Inspector_Theme collects the colours the panel uses.
Inspector_Theme :: struct {
	background: render.Color,
	border:     render.Color,
	heading:    render.Color,
	label:      render.Color,
	value:      render.Color,
	muted:      render.Color,

	// One colour per evidence level, so a reader can tell a recorded fact from
	// a derived guess at a glance rather than by reading each row.
	explicit:      render.Color,
	reconstructed: render.Color,
	inferred:      render.Color,

	score_bar: render.Color,
	failure:   render.Color,
}

DARK_INSPECTOR :: Inspector_Theme {
	background    = render.Color{0.11, 0.12, 0.15, 1.0},
	border        = render.Color{0.20, 0.21, 0.25, 1.0},
	heading       = render.Color{0.94, 0.95, 0.97, 1.0},
	label         = render.Color{0.58, 0.61, 0.68, 1.0},
	value         = render.Color{0.86, 0.88, 0.92, 1.0},
	muted         = render.Color{0.50, 0.53, 0.60, 1.0},
	explicit      = render.Color{0.45, 0.78, 0.55, 1.0},
	reconstructed = render.Color{0.42, 0.62, 0.92, 1.0},
	inferred      = render.Color{0.92, 0.72, 0.36, 1.0},
	score_bar     = render.Color{0.92, 0.72, 0.36, 1.0},
	failure       = render.Color{0.95, 0.35, 0.35, 1.0},
}

// level_color returns the colour for an evidence level.
level_color :: proc "contextless" (
	theme: Inspector_Theme,
	level: analysis.Evidence_Level,
) -> render.Color {
	switch level {
	case .Explicit:      return theme.explicit
	case .Reconstructed: return theme.reconstructed
	case .Inferred:      return theme.inferred
	}
	return theme.muted
}

// Inspector_State is what the panel needs beyond the trace.
Inspector_State :: struct {
	bounds: render.Rect,
	theme:  Inspector_Theme,
	fonts:  ^render.Font_Set,
	// Body text and a slightly larger heading face.
	atlas:         ^render.Atlas,
	heading_atlas: ^render.Atlas,
	// Display scale, so spacing matches the glyphs' resolution.
	scale: f32,

	selection: model.Event_Id,
	// Vertical scroll offset in device pixels.
	scroll: f32,
}

// Cursor tracks vertical position while emitting rows.
//
// A running cursor rather than precomputed positions: the panel's content is
// variable-length, and computing a layout twice — once to measure and once to
// draw — is how the two drift apart.
@(private)
Cursor :: struct {
	x, y:      f32,
	width:     f32,
	line:      f32,
	limit:     f32,
}

// draw_inspector renders the panel for the current selection.
draw_inspector :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	trace: ^codec.Trace,
	outcomes: ^analysis.Outcome_Index,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	render.fill_rect(list, state.bounds, state.theme.background)
	render.draw_line(
		list,
		state.bounds.x0,
		state.bounds.y0,
		state.bounds.x0,
		state.bounds.y1,
		state.theme.border,
	)

	if state.fonts == nil || state.atlas == nil {
		// Without a font the panel can draw nothing meaningful. Leaving it
		// blank is honest; drawing boxes would look like content.
		return
	}

	padding := 12 * state.scale
	cursor := Cursor {
		x     = state.bounds.x0 + padding,
		y     = state.bounds.y0 + padding - state.scroll,
		width = render.rect_width(state.bounds) - padding * 2,
		line  = render.line_height(state.atlas),
		limit = state.bounds.y1,
	}

	if state.selection == model.NO_EVENT {
		// docs/01: an empty panel explains why it is empty.
		draw_empty(list, state, &cursor, "No event selected")
		draw_hint(list, state, &cursor, "Click the timeline or press an arrow key.")
		return
	}

	index := int(state.selection) - 1
	if index < 0 || index >= len(trace.events) {
		draw_empty(list, state, &cursor, "The selected event is not in this trace")
		return
	}
	event := trace.events[index]

	draw_event_header(list, state, &cursor, trace, event)
	draw_attributes(list, state, &cursor, trace, event)

	// An outcome gets its evidence stack; anything else does not, and saying
	// so is better than an unexplained absence.
	if outcome, found := analysis.find_outcome(outcomes, event.id); found {
		draw_evidence(list, state, &cursor, trace, outcomes, outcome)
	} else if model.is_outcome(event.kind) {
		draw_section(list, state, &cursor, "Evidence")
		draw_note(list, state, &cursor, "This outcome carries no structured result.")
	}
}

@(private)
advance :: proc(cursor: ^Cursor, amount: f32) {
	cursor.y += amount
}

// visible reports whether a row at the cursor would be on screen.
//
// Rows are skipped rather than clipped so a long evidence stack costs nothing
// for the part scrolled out of view.
@(private)
visible :: proc(cursor: ^Cursor, height: f32) -> bool {
	return cursor.y + height >= 0 && cursor.y <= cursor.limit
}

@(private)
draw_empty :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	message: string,
) {
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		message,
		cursor.x,
		cursor.y,
		cursor.width,
		state.theme.muted,
	)
	advance(cursor, cursor.line * 1.4)
}

@(private)
draw_hint :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	message: string,
) {
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		message,
		cursor.x,
		cursor.y,
		cursor.width,
		state.theme.muted,
	)
	advance(cursor, cursor.line * 1.4)
}

@(private)
draw_section :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	title: string,
) {
	advance(cursor, cursor.line * 0.8)
	if visible(cursor, cursor.line) {
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			title,
			cursor.x,
			cursor.y,
			cursor.width,
			state.theme.label,
		)
	}
	advance(cursor, cursor.line)

	if visible(cursor, 1) {
		render.draw_line(
			list,
			cursor.x,
			cursor.y - cursor.line * 0.25,
			cursor.x + cursor.width,
			cursor.y - cursor.line * 0.25,
			state.theme.border,
		)
	}
	advance(cursor, cursor.line * 0.2)
}

// draw_field emits a label and value on one row.
//
// The label column is a fixed fraction of the width so values line up, which
// is what makes a list of attributes scannable rather than a paragraph.
@(private)
draw_field :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	label: string,
	value: string,
	value_color: render.Color,
) {
	if !visible(cursor, cursor.line) {
		advance(cursor, cursor.line)
		return
	}

	label_width := cursor.width * 0.38
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		label,
		cursor.x,
		cursor.y,
		label_width,
		state.theme.label,
	)
	render.draw_text_clipped(
		list,
		state.fonts,
		state.atlas,
		value,
		cursor.x + label_width,
		cursor.y,
		cursor.width - label_width,
		value_color,
	)
	advance(cursor, cursor.line)
}

@(private)
draw_note :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	text: string,
) {
	if visible(cursor, cursor.line) {
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			text,
			cursor.x,
			cursor.y,
			cursor.width,
			state.theme.muted,
		)
	}
	advance(cursor, cursor.line)
}

@(private)
draw_event_header :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	trace: ^codec.Trace,
	event: model.Event,
) {
	heading := state.heading_atlas if state.heading_atlas != nil else state.atlas

	if visible(cursor, render.line_height(heading)) {
		render.draw_text_clipped(
			list,
			state.fonts,
			heading,
			fmt.tprintf("%v", event.kind),
			cursor.x,
			cursor.y,
			cursor.width,
			state.theme.heading,
		)
	}
	advance(cursor, render.line_height(heading) * 1.1)

	summary := lookup_string(trace, event.summary_string_id)
	if summary != "" {
		if visible(cursor, cursor.line) {
			render.draw_text_clipped(
				list,
				state.fonts,
				state.atlas,
				summary,
				cursor.x,
				cursor.y,
				cursor.width,
				state.theme.value,
			)
		}
		advance(cursor, cursor.line)
	}
}

@(private)
draw_attributes :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	trace: ^codec.Trace,
	event: model.Event,
) {
	draw_section(list, state, cursor, "Attributes")

	draw_field(
		list,
		state,
		cursor,
		"event",
		fmt.tprintf("%d", u64(event.id)),
		state.theme.value,
	)
	draw_field(
		list,
		state,
		cursor,
		"sequence",
		fmt.tprintf("%d", u64(event.sequence)),
		state.theme.value,
	)

	// docs/03 makes time quality part of the record. A repaired timestamp is
	// shown as such rather than presented as recorded fact.
	if model.has_wall_time(event) {
		draw_field(
			list,
			state,
			cursor,
			"time",
			format_timestamp(event.wall_time_ns),
			state.theme.value,
		)
	} else {
		draw_field(list, state, cursor, "time", "not recorded", state.theme.muted)
	}
	if event.time_quality != .Exact {
		draw_field(
			list,
			state,
			cursor,
			"time quality",
			fmt.tprintf("%v", event.time_quality),
			state.theme.muted,
		)
	}

	if model.has_duration(event) {
		draw_field(
			list,
			state,
			cursor,
			"duration",
			format_duration(event.duration_ns),
			state.theme.value,
		)
	}

	if path := entity_name(trace, event.primary_entity_id); path != "" {
		draw_field(list, state, cursor, "subject", path, state.theme.value)
	}
	if actor := entity_name(trace, event.actor_entity_id); actor != "" {
		draw_field(list, state, cursor, "actor", actor, state.theme.value)
	}

	// docs/03 requires provenance to be auditable, so the importer and source
	// record are shown rather than kept for debugging only.
	importer := lookup_string(trace, event.source.importer_id)
	if importer != "" {
		draw_field(
			list,
			state,
			cursor,
			"imported by",
			fmt.tprintf("%s %s", importer, lookup_string(trace, event.source.importer_version)),
			state.theme.muted,
		)
	}
	if event.source.record_number != 0 {
		draw_field(
			list,
			state,
			cursor,
			"source record",
			fmt.tprintf("%d", event.source.record_number),
			state.theme.muted,
		)
	}

	// Transformations applied at import. A redacted or truncated value must
	// say so, or a reader would take an altered record for the original.
	if event.source.transforms != {} {
		draw_field(
			list,
			state,
			cursor,
			"transformed",
			fmt.tprintf("%v", event.source.transforms),
			state.theme.muted,
		)
	}
}

@(private)
draw_evidence :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	trace: ^codec.Trace,
	outcomes: ^analysis.Outcome_Index,
	outcome: analysis.Outcome,
) {
	input := analysis.Scoring_Input{trace = trace, outcomes = outcomes}
	ranking := analysis.score_outcome(input, outcome, context.temp_allocator)
	defer analysis.ranking_destroy(&ranking)

	draw_section(list, state, cursor, "Outcome")
	draw_field(
		list,
		state,
		cursor,
		"result",
		model.outcome_status_name(outcome.status),
		state.theme.failure if analysis.outcome_is_failure(outcome) else state.theme.value,
	)

	// The comparison window's origin, so the ranking's scope is visible rather
	// than implied.
	if ranking.window.has_anchor {
		draw_field(
			list,
			state,
			cursor,
			"compared since",
			fmt.tprintf("event %d", u64(ranking.window.anchor)),
			state.theme.muted,
		)
	} else {
		draw_field(
			list,
			state,
			cursor,
			"compared since",
			"session or phase start",
			state.theme.muted,
		)
	}

	// docs/01 requires the heading to name these as candidates. A reader who
	// only sees the numbers must still not read them as causation.
	draw_section(list, state, cursor, "Candidate contributors")

	if len(ranking.candidates) == 0 {
		draw_note(list, state, cursor, "No change in the window carries linking evidence.")
	} else {
		for candidate in ranking.candidates {
			draw_candidate(list, state, cursor, trace, candidate)
		}
	}

	stack := analysis.build_evidence_stack(input, outcome, &ranking, context.temp_allocator)
	defer analysis.evidence_stack_destroy(&stack)

	if len(stack.uncertainties) > 0 {
		// docs/01 makes uncertainty the last item of the evidence stack rather
		// than something the interface omits.
		draw_section(list, state, cursor, "Uncertainty")
		for note in stack.uncertainties {
			draw_note(list, state, cursor, note)
		}
	}
}

@(private)
draw_candidate :: proc(
	list: ^render.Draw_List,
	state: Inspector_State,
	cursor: ^Cursor,
	trace: ^codec.Trace,
	candidate: analysis.Candidate,
) {
	score := model.confidence_to_f32(candidate.score)

	if visible(cursor, cursor.line) {
		// A bar as well as a number: docs/01's rule that colour is never the
		// sole carrier applies to rank too, and a bar is read faster than a
		// decimal when comparing several candidates.
		bar_width := cursor.width * 0.22
		render.fill_rect(
			list,
			render.Rect {
				x0 = cursor.x,
				y0 = cursor.y + cursor.line * 0.25,
				x1 = cursor.x + bar_width * score,
				y1 = cursor.y + cursor.line * 0.75,
			},
			state.theme.score_bar,
		)

		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			fmt.tprintf("%.2f", f64(score)),
			cursor.x + bar_width + 6 * state.scale,
			cursor.y,
			cursor.width * 0.16,
			state.theme.value,
		)

		path := entity_name(trace, candidate.path)
		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			path if path != "" else fmt.tprintf("event %d", u64(candidate.mutation_event)),
			cursor.x + bar_width + cursor.width * 0.18,
			cursor.y,
			cursor.width - bar_width - cursor.width * 0.18,
			state.theme.value,
		)
	}
	advance(cursor, cursor.line)

	// docs/11 makes it an exit criterion that every score expands into its
	// deterministic rule contributions, so the rules are listed rather than
	// hidden behind a disclosure the user has to find.
	for rule in analysis.Rule {
		if rule not_in candidate.rules {
			continue
		}
		if visible(cursor, cursor.line) {
			render.draw_text_clipped(
				list,
				state.fonts,
				state.atlas,
				fmt.tprintf("  %s", analysis.rule_reason(rule)),
				cursor.x + cursor.width * 0.06,
				cursor.y,
				cursor.width * 0.94,
				state.theme.muted,
			)
		}
		advance(cursor, cursor.line * 0.9)
	}

	if candidate.gap_capped {
		draw_note(list, state, cursor, "  confidence capped: a replay gap affects this content")
	}
	advance(cursor, cursor.line * 0.3)
}

// ---------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------

@(private)
lookup_string :: proc(trace: ^codec.Trace, id: model.String_Id) -> string {
	value, ok := model.string_get(&trace.strings, id)
	if !ok {
		return ""
	}
	return value
}

@(private)
entity_name :: proc(trace: ^codec.Trace, id: model.Entity_Id) -> string {
	if id == model.NO_ENTITY {
		return ""
	}
	index := int(id) - 1
	if index < 0 || index >= len(trace.entities) {
		return ""
	}
	return lookup_string(trace, trace.entities[index].name)
}

// format_duration renders a nanosecond span in the largest sensible unit.
//
// A duration is read to compare magnitudes, not to count nanoseconds, so the
// unit changes with the value rather than forcing the reader to count digits.
format_duration :: proc(nanoseconds: i64) -> string {
	value := nanoseconds
	if value < 0 {
		value = -value
	}

	switch {
	case value < 1_000:
		return fmt.tprintf("%d ns", value)
	case value < 1_000_000:
		return fmt.tprintf("%.1f µs", f64(value) / 1_000)
	case value < 1_000_000_000:
		return fmt.tprintf("%.1f ms", f64(value) / 1_000_000)
	case value < 60 * 1_000_000_000:
		return fmt.tprintf("%.2f s", f64(value) / 1_000_000_000)
	}
	minutes := value / (60 * 1_000_000_000)
	seconds := (value % (60 * 1_000_000_000)) / 1_000_000_000
	return fmt.tprintf("%dm %ds", minutes, seconds)
}

// format_timestamp renders a Unix nanosecond instant as UTC.
//
// UTC rather than local time: docs/05 forbids importers depending on the
// machine timezone, and a viewer that displayed local time would make two
// people reading the same trace describe the same event differently.
format_timestamp :: proc(nanoseconds: i64) -> string {
	seconds := nanoseconds / 1_000_000_000
	fraction := nanoseconds % 1_000_000_000
	if fraction < 0 {
		fraction += 1_000_000_000
		seconds -= 1
	}

	days := seconds / 86_400
	remainder := seconds % 86_400
	if remainder < 0 {
		remainder += 86_400
		days -= 1
	}

	hour := remainder / 3600
	minute := (remainder % 3600) / 60
	second := remainder % 60

	year, month, day := civil_from_days(days)
	return fmt.tprintf(
		"%04d-%02d-%02d %02d:%02d:%02d.%03d UTC",
		year,
		month,
		day,
		hour,
		minute,
		second,
		fraction / 1_000_000,
	)
}

// civil_from_days converts a day count since the Unix epoch to a date.
//
// Howard Hinnant's algorithm, which is exact for the whole representable range
// and avoids pulling in a time library for one conversion.
@(private)
civil_from_days :: proc "contextless" (days: i64) -> (year: i64, month: i64, day: i64) {
	shifted := days + 719_468
	era := (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
	day_of_era := shifted - era * 146_097
	year_of_era :=
		(day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365
	y := year_of_era + era * 400
	day_of_year := day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100)
	shifted_month := (5 * day_of_year + 2) / 153
	d := day_of_year - (153 * shifted_month + 2) / 5 + 1
	m := shifted_month < 10 ? shifted_month + 3 : shifted_month - 9
	return y + (m <= 2 ? 1 : 0), m, d
}
