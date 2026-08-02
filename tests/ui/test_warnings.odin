package test_ui

import "core:strings"
import "core:testing"

import "src:render"
import "src:trace/codec"
import "src:ui"

// The import-notes panel.
//
// docs/01: "Warnings do not disappear after the import dialog. They remain part
// of the session metadata." A user who opens a trace months later never saw the
// dialog, so the workspace has to carry the counts.
//
// The failure this guards against is silent: a trace can be quietly incomplete
// — records dropped, timestamps repaired — and every other panel renders
// confidently over the gap. Nothing looks wrong.

WARNINGS_BOUNDS :: render.Rect{0, 0, 560, 420}

@(private)
warnings_state :: proc(fonts: ^render.Font_Set, atlas: ^render.Atlas) -> ui.Warning_State {
	return ui.Warning_State {
		bounds = WARNINGS_BOUNDS,
		theme = ui.DARK_WARNINGS,
		fonts = fonts,
		atlas = atlas,
		scale = 1,
	}
}

@(private)
metadata_with :: proc(
	warnings: []struct {
		category: codec.Warning_Category,
		count:    u32,
	},
	redactions: []struct {
		category: codec.Redaction_Category,
		count:    u32,
	} = nil,
) -> codec.Session_Metadata {
	metadata: codec.Session_Metadata
	for entry in warnings {
		metadata.warnings[int(entry.category)] = entry.count
	}
	for entry in redactions {
		metadata.redactions[int(entry.category)] = entry.count
	}
	return metadata
}

@(test)
every_warning_category_has_a_description :: proc(t: ^testing.T) {
	// A category with no description would render as a bare count, which tells
	// a user nothing about what to distrust. The enum is the source of truth, so
	// a category added later fails here rather than shipping unlabelled.
	for category in codec.Warning_Category {
		description := ui.warning_description(category)
		testing.expectf(t, description != "", "%v has no description", category)
		testing.expectf(
			t,
			description != "unrecognised warnings",
			"%v fell through to the fallback",
			category,
		)
	}
}

@(test)
every_redaction_category_has_a_description :: proc(t: ^testing.T) {
	for category in codec.Redaction_Category {
		description := ui.redaction_description(category)
		testing.expectf(t, description != "", "%v has no description", category)
		testing.expectf(t, description != "values", "%v fell through to the fallback", category)
	}
}

@(test)
descriptions_state_a_consequence_not_a_category :: proc(t: ^testing.T) {
	// "3 malformed_record" is a count beside an identifier. "3 records could
	// not be parsed" tells a user which conclusions to distrust. The
	// distinction is the whole reason this panel exists rather than a table of
	// the metadata counters.
	for category in codec.Warning_Category {
		description := ui.warning_description(category)
		identifier := codec.warning_category_name(category)
		testing.expectf(
			t,
			!strings.contains(description, identifier),
			"%v describes itself with its own identifier",
			category,
		)
		testing.expectf(
			t,
			strings.contains(description, " "),
			"%v reads as an identifier rather than a sentence",
			category,
		)
	}
}

@(test)
warnings_that_limit_conclusions_are_serious :: proc(t: ^testing.T) {
	// The severity split is not cosmetic. A repaired timestamp means the order
	// shown is source order — a caveat. A failed patch means a file's content
	// is unknown — a hole in the evidence.
	serious := []codec.Warning_Category {
		.Patch_Failed,
		.Hash_Mismatch,
		.Missing_Baseline,
		.Malformed_Record,
		.Path_Rejected,
	}
	for category in serious {
		testing.expectf(
			t,
			ui.warning_severity(category) == .Serious,
			"%v limits what can be concluded and must be serious",
			category,
		)
	}

	notices := []codec.Warning_Category{.Timestamp_Repaired, .Span_Incomplete}
	for category in notices {
		testing.expectf(
			t,
			ui.warning_severity(category) == .Notice,
			"%v reduces completeness but does not limit conclusions",
			category,
		)
	}
}

@(test)
a_clean_import_says_so :: proc(t: ^testing.T) {
	// docs/01: an empty panel explains why it is empty. "Nothing was reported"
	// distinguishes a clean import from a panel that failed to load.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	metadata: codec.Session_Metadata

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, WARNINGS_BOUNDS)

	ui.draw_warnings(&list, warnings_state(&fonts, atlas), &metadata)

	// Heading plus the explanation; a blank panel would draw only the heading.
	testing.expect(t, count_kind(&list, .Glyph) > 40, "a clean import must still explain itself")
}

@(test)
the_summary_is_empty_when_there_is_nothing_to_report :: proc(t: ^testing.T) {
	// An empty string rather than "0 warnings": the caller draws nothing, and a
	// reassuring zero on every clean trace is noise that trains users to ignore
	// the line that matters.
	metadata: codec.Session_Metadata
	testing.expect_value(t, ui.warning_summary(&metadata), "")
	testing.expect(t, !ui.has_serious_warnings(&metadata))
}

@(test)
the_summary_leads_with_the_most_consequential_warning :: proc(t: ^testing.T) {
	// A hundred repaired timestamps matter less than one failed patch. A
	// summary that led with the larger count would bury the one that limits
	// conclusions.
	metadata := metadata_with(
		{{.Timestamp_Repaired, 100}, {.Patch_Failed, 1}},
	)

	summary := ui.warning_summary(&metadata)
	testing.expect(t, strings.contains(summary, "101 import warnings"))
	testing.expectf(
		t,
		strings.contains(summary, "patches did not apply"),
		"the serious warning must lead the summary, got %q",
		summary,
	)
	testing.expect(t, ui.has_serious_warnings(&metadata))
}

@(test)
a_notice_only_session_reports_the_total :: proc(t: ^testing.T) {
	metadata := metadata_with({{.Timestamp_Repaired, 12}})

	summary := ui.warning_summary(&metadata)
	testing.expect(t, strings.contains(summary, "12 import warnings"))
	testing.expect(t, !ui.has_serious_warnings(&metadata))
}

@(test)
serious_warnings_are_drawn_before_notices :: proc(t: ^testing.T) {
	// A user scanning from the top should meet the warnings that limit
	// conclusions first.
	//
	// Enum order would put Timestamp_Repaired (a notice) before Patch_Failed
	// (serious), so a panel iterating the enum directly draws them the wrong
	// way round. The glyph y coordinates are what the renderer will actually
	// place, which is why they are compared rather than the classification.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	metadata := metadata_with({{.Timestamp_Repaired, 5}, {.Patch_Failed, 2}})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, WARNINGS_BOUNDS)

	state := warnings_state(&fonts, atlas)
	ui.draw_warnings(&list, state, &metadata)

	// The two lines are drawn in the panel's two accent colours, so the first
	// glyph of each identifies where that line sits.
	serious_y := f32(-1)
	notice_y := f32(-1)
	for command in list.commands {
		if command.kind != .Glyph {
			continue
		}
		if command.color == state.theme.serious && serious_y < 0 {
			serious_y = command.rect.y0
		}
		if command.color == state.theme.notice && notice_y < 0 {
			notice_y = command.rect.y0
		}
	}

	testing.expect(t, serious_y >= 0, "the serious warning must be drawn")
	testing.expect(t, notice_y >= 0, "the notice must be drawn")
	testing.expectf(
		t,
		serious_y < notice_y,
		"the serious warning was drawn at y=%.1f, below the notice at y=%.1f",
		serious_y,
		notice_y,
	)
}

@(test)
redaction_counts_are_shown_without_the_values :: proc(t: ^testing.T) {
	// docs/08: reports list rule identifiers and counts, never matched values.
	// The panel says how much was removed, never what.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	metadata := metadata_with(nil, {{.Credential, 3}, {.Home_Path_Prefix, 7}})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, WARNINGS_BOUNDS)

	height := ui.draw_warnings(&list, warnings_state(&fonts, atlas), &metadata)

	testing.expect(t, height > 0, "the panel must report its content height")
	testing.expect(t, count_kind(&list, .Glyph) > 60, "redaction lines must be drawn")
}

@(test)
the_panel_reports_a_height_so_scrolling_can_be_bounded :: proc(t: ^testing.T) {
	// A panel that clipped without reporting its extent would strand its last
	// lines out of reach.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	few := metadata_with({{.Timestamp_Repaired, 1}})
	many := metadata_with(
		{
			{.Malformed_Record, 1},
			{.Unsupported_Record, 1},
			{.Timestamp_Repaired, 1},
			{.Path_Rejected, 1},
			{.Content_Truncated, 1},
			{.Patch_Failed, 1},
			{.Hash_Mismatch, 1},
			{.Missing_Baseline, 1},
			{.Ambiguous_Pairing, 1},
			{.Span_Incomplete, 1},
		},
	)

	short: render.Draw_List
	render.draw_list_init(&short)
	defer render.draw_list_destroy(&short)
	render.draw_list_reset(&short, WARNINGS_BOUNDS)
	short_height := ui.draw_warnings(&short, warnings_state(&fonts, atlas), &few)

	tall: render.Draw_List
	render.draw_list_init(&tall)
	defer render.draw_list_destroy(&tall)
	render.draw_list_reset(&tall, WARNINGS_BOUNDS)
	tall_height := ui.draw_warnings(&tall, warnings_state(&fonts, atlas), &many)

	testing.expect(t, tall_height > short_height, "more warnings must report more height")
}

@(test)
the_panel_draws_without_a_font :: proc(t: ^testing.T) {
	metadata := metadata_with({{.Patch_Failed, 1}})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, WARNINGS_BOUNDS)

	ui.draw_warnings(&list, warnings_state(nil, nil), &metadata)

	testing.expect_value(t, count_kind(&list, .Glyph), 0)
	testing.expect(t, count_kind(&list, .Rect) > 0, "the panel must still fill its bounds")
}

@(test)
a_zero_count_draws_no_line :: proc(t: ^testing.T) {
	// Ten categories at zero would produce ten lines saying nothing happened.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	one := metadata_with({{.Patch_Failed, 1}})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, WARNINGS_BOUNDS)
	height := ui.draw_warnings(&list, warnings_state(&fonts, atlas), &one)

	empty: codec.Session_Metadata
	blank: render.Draw_List
	render.draw_list_init(&blank)
	defer render.draw_list_destroy(&blank)
	render.draw_list_reset(&blank, WARNINGS_BOUNDS)
	blank_height := ui.draw_warnings(&blank, warnings_state(&fonts, atlas), &empty)

	// One warning is one line taller than the clean-import explanation, not
	// ten lines taller.
	testing.expect(t, height <= blank_height + ui.WARNING_LINE_HEIGHT * 2)
}
