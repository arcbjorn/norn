package ui

import "core:fmt"

import "src:render"
import "src:replay"

// The diff and replay panel.
//
// docs/01-user-experience.md: for a selected file the user chooses between the
// state at the playhead, a diff from session start, from the previous
// mutation, across the selected range, or the recorded final working tree.
//
// Two of its rules are load-bearing rather than cosmetic. "Unknown or
// unverifiable content is shown explicitly" — a replay gap is a labelled state
// here, not an empty panel. And Norn "must never fill a gap with the current
// on-disk version of a file without labeling that substitution", which is why
// this panel renders only what the replay engine produced and says so when
// that is nothing.

// Diff_Mode selects what the panel compares.
Diff_Mode :: enum u8 {
	// The file's content at the playhead, with no comparison.
	At_Playhead = 0,
	From_Session_Start = 1,
	From_Previous_Mutation = 2,
	Across_Range = 3,
}

diff_mode_name :: proc "contextless" (mode: Diff_Mode) -> string {
	switch mode {
	case .At_Playhead:            return "at playhead"
	case .From_Session_Start:     return "since session start"
	case .From_Previous_Mutation: return "since previous change"
	case .Across_Range:           return "across selected range"
	}
	return "unknown"
}

// Diff_Theme collects the panel's colours.
Diff_Theme :: struct {
	background:  render.Color,
	border:      render.Color,
	heading:     render.Color,
	gutter:      render.Color,
	line_number: render.Color,
	text:        render.Color,
	muted:       render.Color,

	added_text:         render.Color,
	added_background:   render.Color,
	removed_text:       render.Color,
	removed_background: render.Color,

	// States that must be visibly distinct from ordinary content, because
	// mistaking a gap for an empty file would be a false conclusion about the
	// session rather than a cosmetic error.
	gap:        render.Color,
	unverified: render.Color,
}

DARK_DIFF :: Diff_Theme {
	background         = render.Color{0.10, 0.11, 0.13, 1.0},
	border             = render.Color{0.20, 0.21, 0.25, 1.0},
	heading            = render.Color{0.94, 0.95, 0.97, 1.0},
	gutter             = render.Color{0.13, 0.14, 0.17, 1.0},
	line_number        = render.Color{0.54, 0.56, 0.60, 1.0},
	text               = render.Color{0.84, 0.86, 0.90, 1.0},
	muted              = render.Color{0.52, 0.55, 0.62, 1.0},
	added_text         = render.Color{0.62, 0.88, 0.68, 1.0},
	added_background   = render.Color{0.14, 0.24, 0.17, 1.0},
	removed_text       = render.Color{0.94, 0.62, 0.62, 1.0},
	removed_background = render.Color{0.26, 0.14, 0.15, 1.0},
	gap                = render.Color{0.92, 0.72, 0.36, 1.0},
	unverified         = render.Color{0.80, 0.70, 0.45, 1.0},
}

// Diff_Content is what the panel renders.
//
// The caller resolves content through the replay engine and hands the result
// here, so the panel performs no reconstruction of its own and cannot
// accidentally show something replay did not produce.
Diff_Content :: struct {
	// The file being shown, for the heading.
	path: string,
	mode: Diff_Mode,

	// How much the replay engine could establish. A status other than
	// Verified is displayed rather than hidden.
	status: replay.Resolved_Status,
	// The event that introduced a gap, when the status is Gap.
	gap_event: u64,

	// Populated for comparison modes; empty when showing state alone.
	diff: ^replay.Diff,
	// Populated when showing state at the playhead rather than a comparison.
	lines: [][]byte,
}

// Diff_Panel_State is the panel's layout and style.
Diff_Panel_State :: struct {
	bounds: render.Rect,
	theme:  Diff_Theme,
	fonts:  ^render.Font_Set,
	// Monospace for content, per docs/07; the interface face for headings.
	mono:    ^render.Atlas,
	heading: ^render.Atlas,
	scale:   f32,
	// Vertical scroll in lines rather than pixels, so scrolling lands on line
	// boundaries and text never sits half-clipped.
	scroll_lines: int,
	// Horizontal scroll in pixels. docs/07: long lines are clipped or
	// scrolled, never wrapped in a way that changes line-number alignment.
	scroll_x: f32,
}

// GUTTER_DIGITS is how many line-number columns to reserve.
//
// Five digits covers files up to 99,999 lines. Sizing the gutter from the
// actual maximum would make it change width as the user scrolls, which is
// worse than a little wasted space.
GUTTER_DIGITS :: 5

// draw_diff renders the panel.
draw_diff :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	content: Diff_Content,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	render.fill_rect(list, state.bounds, state.theme.background)
	render.draw_line(
		list,
		state.bounds.x0,
		state.bounds.y0,
		state.bounds.x1,
		state.bounds.y0,
		state.theme.border,
	)

	if state.fonts == nil || state.mono == nil {
		return
	}

	padding := 8 * state.scale
	header_height := draw_diff_header(list, state, content, padding)

	body := render.Rect {
		x0 = state.bounds.x0,
		y0 = state.bounds.y0 + header_height,
		x1 = state.bounds.x1,
		y1 = state.bounds.y1,
	}
	if render.rect_height(body) <= 0 {
		return
	}

	// docs/01: an empty panel explains why. Each of these is a different
	// reason, and collapsing them into one message would lose the distinction
	// between "nothing changed" and "we could not tell".
	#partial switch content.status {
	case .Gap:
		draw_diff_message(
			list,
			state,
			body,
			padding,
			fmt.tprintf(
				"Replay gap: content could not be reconstructed from event %d onward.",
				content.gap_event,
			),
			state.theme.gap,
		)
		return
	case .Binary:
		draw_diff_message(
			list,
			state,
			body,
			padding,
			"Binary content. Version one does not reconstruct binary diffs.",
			state.theme.muted,
		)
		return
	case .Deleted:
		draw_diff_message(
			list,
			state,
			body,
			padding,
			"This file was deleted at this point in the session.",
			state.theme.muted,
		)
		return
	case .Absent:
		draw_diff_message(
			list,
			state,
			body,
			padding,
			"This file did not exist at this point in the session.",
			state.theme.muted,
		)
		return
	case .Unknown_Path:
		draw_diff_message(
			list,
			state,
			body,
			padding,
			"Nothing in this trace mentions this file.",
			state.theme.muted,
		)
		return
	}

	if content.diff != nil {
		draw_diff_lines(list, state, body, content, padding)
	} else {
		draw_plain_lines(list, state, body, content, padding)
	}
}

// draw_diff_header shows the path, mode, and verification status.
@(private)
draw_diff_header :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	content: Diff_Content,
	padding: f32,
) -> f32 {
	heading := state.heading if state.heading != nil else state.mono
	line := render.line_height(heading)
	y := state.bounds.y0 + padding

	x := state.bounds.x0 + padding
	advance := render.draw_text_clipped(
		list,
		state.fonts,
		heading,
		content.path if content.path != "" else "no file selected",
		x,
		y,
		render.rect_width(state.bounds) * 0.55,
		state.theme.heading,
	)

	render.draw_text_clipped(
		list,
		state.fonts,
		state.mono,
		diff_mode_name(content.mode),
		x + advance + padding,
		y,
		render.rect_width(state.bounds) * 0.25,
		state.theme.muted,
	)

	// A verification label whenever the content is anything less than
	// verified. docs/01 requires unverifiable content to be shown explicitly,
	// and silence would read as confirmation.
	label := status_label(content.status)
	if label != "" {
		width := render.measure_text(state.fonts, state.mono, label)
		render.draw_text_clipped(
			list,
			state.fonts,
			state.mono,
			label,
			state.bounds.x1 - padding - width,
			y,
			width,
			state.theme.unverified,
		)
	}

	y += line * 1.2

	if content.diff != nil {
		summary := fmt.tprintf("+%d  -%d", content.diff.added, content.diff.removed)
		if content.diff.truncated {
			// A coarse diff is correct but not minimal, so it is labelled
			// rather than presented as an ordinary comparison.
			summary = fmt.tprintf("%s  (approximate: file too large for exact diff)", summary)
		}
		render.draw_text_clipped(
			list,
			state.fonts,
			state.mono,
			summary,
			x,
			y,
			render.rect_width(state.bounds) - padding * 2,
			state.theme.muted,
		)
		y += render.line_height(state.mono) * 1.1
	}

	render.draw_line(
		list,
		state.bounds.x0,
		y,
		state.bounds.x1,
		y,
		state.theme.border,
	)
	return y - state.bounds.y0 + padding * 0.5
}

@(private)
status_label :: proc "contextless" (status: replay.Resolved_Status) -> string {
	#partial switch status {
	case .Unverified:
		return "reconstructed, unverified"
	case .Observational:
		return "baseline observed, not from a commit"
	}
	return ""
}

@(private)
draw_diff_message :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	body: render.Rect,
	padding: f32,
	message: string,
	color: render.Color,
) {
	render.draw_text_clipped(
		list,
		state.fonts,
		state.mono,
		message,
		body.x0 + padding,
		body.y0 + padding,
		render.rect_width(body) - padding * 2,
		color,
	)
}

// draw_diff_lines renders a comparison.
//
// Virtualized: only the rows intersecting the body are emitted. docs/07
// requires the diff viewer to virtualize lines, and a large file scrolled to
// its middle should cost the same as one scrolled to its top.
@(private)
draw_diff_lines :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	body: render.Rect,
	content: Diff_Content,
	padding: f32,
) {
	line_height := render.line_height(state.mono)
	if line_height <= 0 {
		return
	}

	gutter := gutter_width(state)
	render.fill_rect(
		list,
		render.Rect{x0 = body.x0, y0 = body.y0, x1 = body.x0 + gutter, y1 = body.y1},
		state.theme.gutter,
	)

	visible_rows := int(render.rect_height(body) / line_height) + 1
	first := max(state.scroll_lines, 0)
	last := min(first + visible_rows, len(content.diff.lines))

	for index in first ..< last {
		line := content.diff.lines[index]
		y := body.y0 + f32(index - first) * line_height
		draw_diff_row(list, state, body, gutter, y, line_height, line, padding)
	}
}

@(private)
draw_diff_row :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	body: render.Rect,
	gutter: f32,
	y: f32,
	line_height: f32,
	line: replay.Diff_Line,
	padding: f32,
) {
	text_color := state.theme.text
	marker := " "

	// A marker character as well as a colour, per docs/01's rule that colour
	// is never the sole carrier of status. A user who cannot distinguish the
	// two backgrounds still sees which lines changed.
	#partial switch line.kind {
	case .Added:
		render.fill_rect(
			list,
			render.Rect{x0 = body.x0 + gutter, y0 = y, x1 = body.x1, y1 = y + line_height},
			state.theme.added_background,
		)
		text_color = state.theme.added_text
		marker = "+"
	case .Removed:
		render.fill_rect(
			list,
			render.Rect{x0 = body.x0 + gutter, y0 = y, x1 = body.x1, y1 = y + line_height},
			state.theme.removed_background,
		)
		text_color = state.theme.removed_text
		marker = "-"
	}

	digit := render.measure_text(state.fonts, state.mono, "0")
	number_width := digit * GUTTER_DIGITS

	// Old and new numbering side by side. A blank column where a line does not
	// exist on that side is what makes the correspondence readable.
	if line.old_number > 0 {
		draw_right_aligned(
			list,
			state,
			fmt.tprintf("%d", line.old_number),
			body.x0 + padding * 0.5,
			number_width,
			y,
			state.theme.line_number,
		)
	}
	if line.new_number > 0 {
		draw_right_aligned(
			list,
			state,
			fmt.tprintf("%d", line.new_number),
			body.x0 + padding * 0.5 + number_width + digit,
			number_width,
			y,
			state.theme.line_number,
		)
	}

	content_x := body.x0 + gutter + padding * 0.5
	render.draw_text(list, state.fonts, state.mono, marker, content_x, y, text_color)

	// Long lines scroll horizontally rather than wrapping, so line numbers
	// stay aligned with their text.
	text := trim_newline(line.text)
	render.draw_text_clipped(
		list,
		state.fonts,
		state.mono,
		text,
		content_x + digit * 2 - state.scroll_x,
		y,
		body.x1 - content_x - digit * 2 + state.scroll_x,
		text_color,
	)
}

// draw_plain_lines renders file content with no comparison.
@(private)
draw_plain_lines :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	body: render.Rect,
	content: Diff_Content,
	padding: f32,
) {
	line_height := render.line_height(state.mono)
	if line_height <= 0 {
		return
	}

	if len(content.lines) == 0 {
		draw_diff_message(list, state, body, padding, "This file is empty.", state.theme.muted)
		return
	}

	gutter := gutter_width(state)
	render.fill_rect(
		list,
		render.Rect{x0 = body.x0, y0 = body.y0, x1 = body.x0 + gutter, y1 = body.y1},
		state.theme.gutter,
	)

	digit := render.measure_text(state.fonts, state.mono, "0")
	number_width := digit * GUTTER_DIGITS

	visible_rows := int(render.rect_height(body) / line_height) + 1
	first := max(state.scroll_lines, 0)
	last := min(first + visible_rows, len(content.lines))

	for index in first ..< last {
		y := body.y0 + f32(index - first) * line_height

		draw_right_aligned(
			list,
			state,
			fmt.tprintf("%d", index + 1),
			body.x0 + padding * 0.5,
			number_width,
			y,
			state.theme.line_number,
		)

		content_x := body.x0 + gutter + padding * 0.5
		render.draw_text_clipped(
			list,
			state.fonts,
			state.mono,
			trim_newline(string(content.lines[index])),
			content_x - state.scroll_x,
			y,
			body.x1 - content_x + state.scroll_x,
			state.theme.text,
		)
	}
}

@(private)
gutter_width :: proc(state: Diff_Panel_State) -> f32 {
	digit := render.measure_text(state.fonts, state.mono, "0")
	// Two number columns and a separating space.
	return digit * (GUTTER_DIGITS * 2 + 2)
}

@(private)
draw_right_aligned :: proc(
	list: ^render.Draw_List,
	state: Diff_Panel_State,
	text: string,
	x: f32,
	width: f32,
	y: f32,
	color: render.Color,
) {
	measured := render.measure_text(state.fonts, state.mono, text)
	render.draw_text(list, state.fonts, state.mono, text, x + width - measured, y, color)
}

// trim_newline removes a trailing line terminator for display.
//
// The terminator is part of the stored line so that concatenating lines
// reproduces the file exactly. Drawing it would emit a glyph for a character
// that is not visible in any editor.
@(private)
trim_newline :: proc "contextless" (text: string) -> string {
	result := text
	if len(result) > 0 && result[len(result) - 1] == '\n' {
		result = result[:len(result) - 1]
	}
	if len(result) > 0 && result[len(result) - 1] == '\r' {
		result = result[:len(result) - 1]
	}
	return result
}

// diff_line_count reports how many rows the panel would render, for scrolling.
diff_line_count :: proc "contextless" (content: Diff_Content) -> int {
	if content.diff != nil {
		return len(content.diff.lines)
	}
	return len(content.lines)
}
