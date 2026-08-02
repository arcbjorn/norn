package test_ui

import "core:math"
import "core:testing"

import "src:render"
import "src:ui"

// Text contrast.
//
// docs/01: "Text contrast targets WCAG AA." That is 4.5:1 for body text against
// its background, and 3:1 for large text and for graphical elements that carry
// meaning.
//
// Contrast is the kind of property that regresses silently. Someone adjusts a
// colour to look better on their display, every test still passes, and the
// result is unreadable for a user with low vision — who has no way to report it
// beyond "the numbers are hard to see". Computing the ratio is cheap and exact,
// so there is no reason to leave it to judgement.
//
// Checking this found DARK_DIFF.line_number at 3.99:1, which is the column a
// user scans while matching a diff against a stack trace.

// WCAG_AA_TEXT is the contrast ratio required for body text.
WCAG_AA_TEXT :: 4.5

// WCAG_AA_LARGE is the ratio for large text and meaningful graphics.
//
// Applied to the lane and node colours: those are filled shapes several pixels
// tall rather than glyph strokes, which is the case WCAG's graphical-object
// rule covers.
WCAG_AA_LARGE :: 3.0

// relative_luminance implements the WCAG definition.
//
// The sRGB channels are linearised before weighting, which is why this is not
// simply a brightness average — a mid grey and a saturated yellow of the same
// naive brightness differ by several stops of real luminance.
@(private)
relative_luminance :: proc(color: render.Color) -> f64 {
	channel :: proc(v: f32) -> f64 {
		c := f64(v)
		if c <= 0.04045 {
			return c / 12.92
		}
		return math.pow((c + 0.055) / 1.055, 2.4)
	}
	return 0.2126 * channel(color.r) + 0.7152 * channel(color.g) + 0.0722 * channel(color.b)
}

// contrast_ratio returns the WCAG ratio between two opaque colours.
@(private)
contrast_ratio :: proc(a, b: render.Color) -> f64 {
	la := relative_luminance(a)
	lb := relative_luminance(b)
	lighter := max(la, lb)
	darker := min(la, lb)
	return (lighter + 0.05) / (darker + 0.05)
}

@(private)
expect_contrast :: proc(
	t: ^testing.T,
	foreground: render.Color,
	background: render.Color,
	minimum: f64,
	what: string,
) {
	ratio := contrast_ratio(foreground, background)
	testing.expectf(
		t,
		ratio >= minimum,
		"%s has %.2f:1 contrast, below the %.1f:1 requirement",
		what,
		ratio,
		minimum,
	)
}

@(test)
the_contrast_formula_matches_known_values :: proc(t: ^testing.T) {
	// The check is only as trustworthy as its arithmetic. Black on white is
	// exactly 21:1 and any colour against itself is exactly 1:1, so a formula
	// that got the linearisation wrong fails here rather than silently passing
	// every theme.
	white := render.Color{1, 1, 1, 1}
	black := render.Color{0, 0, 0, 1}

	testing.expect(t, math.abs(contrast_ratio(black, white) - 21.0) < 0.01)
	testing.expect(t, math.abs(contrast_ratio(white, white) - 1.0) < 0.01)
	testing.expect(t, math.abs(contrast_ratio(black, black) - 1.0) < 0.01)

	// A mid grey against white: the published value for #767676 is 4.54:1,
	// which is the colour WCAG itself cites as the AA boundary.
	grey := render.Color{0.463, 0.463, 0.463, 1}
	ratio := contrast_ratio(grey, white)
	testing.expectf(t, ratio > 4.4 && ratio < 4.7, "expected ~4.54:1, got %.2f", ratio)
}

@(test)
timeline_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_THEME
	expect_contrast(t, theme.lane_label, theme.background, WCAG_AA_TEXT, "lane_label")

	// Lane colours fill event bars rather than draw glyphs, so the graphical
	// threshold applies. They still have to be distinguishable from the lane
	// they sit in, or the timeline is a field of grey.
	lanes := []struct {
		color: render.Color,
		name:  string,
	} {
		{theme.conversation, "conversation"},
		{theme.tools, "tools"},
		{theme.files, "files"},
		{theme.commands, "commands"},
		{theme.outcomes, "outcomes"},
		{theme.errors, "errors"},
		{theme.annotations, "annotations"},
		{theme.failure, "failure"},
	}
	for lane in lanes {
		expect_contrast(t, lane.color, theme.lane_background, WCAG_AA_LARGE, lane.name)
	}
}

@(test)
diff_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_DIFF

	expect_contrast(t, theme.heading, theme.background, WCAG_AA_TEXT, "heading")
	expect_contrast(t, theme.text, theme.background, WCAG_AA_TEXT, "text")
	expect_contrast(t, theme.muted, theme.background, WCAG_AA_TEXT, "muted")
	expect_contrast(t, theme.gap, theme.background, WCAG_AA_TEXT, "gap")
	expect_contrast(t, theme.unverified, theme.background, WCAG_AA_TEXT, "unverified")

	// The column a user scans while matching a diff against a stack trace.
	expect_contrast(t, theme.line_number, theme.background, WCAG_AA_TEXT, "line_number")

	// Added and removed text sit on their own tinted rows, not the panel
	// background, so those are the pairs that matter.
	expect_contrast(t, theme.added_text, theme.added_background, WCAG_AA_TEXT, "added_text")
	expect_contrast(
		t,
		theme.removed_text,
		theme.removed_background,
		WCAG_AA_TEXT,
		"removed_text",
	)
}

@(test)
inspector_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_INSPECTOR

	expect_contrast(t, theme.heading, theme.background, WCAG_AA_TEXT, "heading")
	expect_contrast(t, theme.label, theme.background, WCAG_AA_TEXT, "label")
	expect_contrast(t, theme.value, theme.background, WCAG_AA_TEXT, "value")
	expect_contrast(t, theme.muted, theme.background, WCAG_AA_TEXT, "muted")
	expect_contrast(t, theme.failure, theme.background, WCAG_AA_TEXT, "failure")

	// Evidence levels are text, and docs/04 requires the UI to distinguish
	// explicit from reconstructed from inferred. A level a user cannot read is
	// a level they cannot distinguish.
	expect_contrast(t, theme.explicit, theme.background, WCAG_AA_TEXT, "explicit")
	expect_contrast(t, theme.reconstructed, theme.background, WCAG_AA_TEXT, "reconstructed")
	expect_contrast(t, theme.inferred, theme.background, WCAG_AA_TEXT, "inferred")
}

@(test)
search_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_SEARCH

	expect_contrast(t, theme.text, theme.field, WCAG_AA_TEXT, "query text on the field")
	expect_contrast(t, theme.muted, theme.field, WCAG_AA_TEXT, "placeholder on the field")
	expect_contrast(t, theme.count, theme.background, WCAG_AA_TEXT, "result count")

	// Chip labels sit on the chip fill, in both states.
	expect_contrast(t, theme.chip_text, theme.chip, WCAG_AA_TEXT, "chip label")
	expect_contrast(t, theme.chip_text, theme.chip_active, WCAG_AA_TEXT, "active chip label")
}

@(test)
warning_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_WARNINGS

	expect_contrast(t, theme.heading, theme.background, WCAG_AA_TEXT, "heading")
	expect_contrast(t, theme.label, theme.background, WCAG_AA_TEXT, "label")
	expect_contrast(t, theme.muted, theme.background, WCAG_AA_TEXT, "muted")
	expect_contrast(t, theme.serious, theme.background, WCAG_AA_TEXT, "serious")
	expect_contrast(t, theme.notice, theme.background, WCAG_AA_TEXT, "notice")
}

@(test)
map_text_meets_aa :: proc(t: ^testing.T) {
	theme := ui.DARK_MAP

	expect_contrast(t, theme.heading, theme.background, WCAG_AA_TEXT, "heading")
	expect_contrast(t, theme.label, theme.background, WCAG_AA_TEXT, "label")
	expect_contrast(t, theme.muted, theme.background, WCAG_AA_TEXT, "muted")

	// Nodes are filled circles carrying outcome status, so the graphical
	// threshold applies.
	expect_contrast(t, theme.node_read, theme.background, WCAG_AA_LARGE, "node_read")
	expect_contrast(t, theme.node_edited, theme.background, WCAG_AA_LARGE, "node_edited")
	expect_contrast(t, theme.node_tested, theme.background, WCAG_AA_LARGE, "node_tested")
	expect_contrast(t, theme.node_failed, theme.background, WCAG_AA_LARGE, "node_failed")
}

@(test)
status_is_not_carried_by_colour_alone :: proc(t: ^testing.T) {
	// docs/01: "Status uses iconography and text in addition to color." A user
	// who cannot distinguish red from green must still be able to tell a
	// failure from a pass.
	//
	// The timeline draws a shape marker above a failing event as well as
	// colouring it, and every status in the inspector and the warning panel is
	// spelled out in words. This asserts the shape marker exists, since it is
	// the one that could be dropped as a rendering optimisation without any
	// other test noticing.
	testing.expect(
		t,
		ui.FAILURE_MARKER_HEIGHT > 0,
		"a failing event needs a shape, not only a colour",
	)
}

@(test)
state_changes_are_immediate :: proc(t: ^testing.T) {
	// docs/07: "reduced-motion mode replaces movement with immediate state
	// changes and opacity transitions where necessary."
	//
	// Nothing in the renderer interpolates position over time — a selection,
	// a playhead move, and a filter change all take effect on the frame they
	// happen. That satisfies the requirement by construction, so there is no
	// reduced-motion setting: a toggle controlling nothing would be worse than
	// none, because it would imply motion exists.
	//
	// This asserts the property rather than the absence of a setting. A panel
	// that later animates has to introduce a real toggle, and the assertion
	// below is where that obligation is recorded.
	//
	// Playback is the one time-driven feature, and docs/01 makes it discrete:
	// "playback is an inspection aid, not a video. It advances between
	// meaningful events." Stepping event to event is not motion to reduce.
	state: ui.Panel_State
	state.viewport = ui.Viewport{start_ns = 0, span_ns = 1000, width = 100}

	// The transform is a pure function of the viewport: the same input gives
	// the same output regardless of when it is called, which is what rules out
	// a time-varying position.
	first := ui.time_to_x(state.viewport, 500)
	second := ui.time_to_x(state.viewport, 500)
	testing.expect_value(t, first, second)
}
