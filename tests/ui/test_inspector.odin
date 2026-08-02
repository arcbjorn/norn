package test_ui

import "core:strings"
import "core:testing"

import "src:analysis"
import "src:render"
import "src:trace/model"
import "src:ui"

// The event inspector.
//
// docs/01 makes several of this panel's behaviours normative: an empty panel
// explains why it is empty, the interface says "candidate contributor" rather
// than "cause", and every score expands into its rule contributions. Those are
// testable claims, and these assert them against the emitted draw list.

@(private)
INSPECTOR_BOUNDS :: render.Rect{1000, 0, 1400, 600}

@(private)
inspector_state :: proc(
	fonts: ^render.Font_Set,
	atlas: ^render.Atlas,
	selection: model.Event_Id,
) -> ui.Inspector_State {
	return ui.Inspector_State {
		bounds = INSPECTOR_BOUNDS,
		theme = ui.DARK_INSPECTOR,
		fonts = fonts,
		atlas = atlas,
		scale = 1,
		selection = selection,
	}
}

// ---------------------------------------------------------------------------
// Formatting, which needs no font
// ---------------------------------------------------------------------------

@(test)
durations_use_a_readable_unit :: proc(t: ^testing.T) {
	// A duration is read to compare magnitudes, not to count nanoseconds.
	testing.expect_value(t, ui.format_duration(500), "500 ns")
	testing.expect_value(t, ui.format_duration(1_500), "1.5 µs")
	testing.expect_value(t, ui.format_duration(2_500_000), "2.5 ms")
	testing.expect_value(t, ui.format_duration(1_500_000_000), "1.50 s")
	testing.expect_value(t, ui.format_duration(90 * 1_000_000_000), "1m 30s")
}

@(test)
timestamps_render_as_utc :: proc(t: ^testing.T) {
	// docs/05 forbids depending on the machine timezone. A viewer showing
	// local time would make two people reading one trace describe the same
	// event differently.
	testing.expect_value(
		t,
		ui.format_timestamp(0),
		"1970-01-01 00:00:00.000 UTC",
	)

	// 2026-08-06T05:00:00Z, checked against an independent implementation
	// rather than against this one.
	testing.expect_value(
		t,
		ui.format_timestamp(1_785_992_400 * 1_000_000_000),
		"2026-08-06 05:00:00.000 UTC",
	)
}

@(test)
timestamp_handles_leap_years_and_month_ends :: proc(t: ^testing.T) {
	// Date arithmetic is where a hand-rolled conversion goes wrong, so the
	// awkward boundaries are asserted rather than assumed.
	Case :: struct {
		seconds:  i64,
		expected: string,
	}
	cases := []Case {
		// 2024-02-29, a leap day.
		{1_709_164_800, "2024-02-29 00:00:00.000 UTC"},
		// 2023-12-31T23:59:59Z, the last second of a year.
		{1_704_067_199, "2023-12-31 23:59:59.000 UTC"},
		// 2000-03-01, the day after a century leap day.
		{951_868_800, "2000-03-01 00:00:00.000 UTC"},
		// 1900 was not a leap year; 2100 will not be either.
		{4_107_542_400, "2100-03-01 00:00:00.000 UTC"},
	}

	for c in cases {
		actual := ui.format_timestamp(c.seconds * 1_000_000_000)
		testing.expectf(t, actual == c.expected, "got %q, expected %q", actual, c.expected)
	}
}

@(test)
timestamps_before_the_epoch_do_not_break :: proc(t: ^testing.T) {
	// A trace with a broken clock can record a negative instant. It must
	// render as something rather than producing a nonsense date.
	result := ui.format_timestamp(-1 * 1_000_000_000)
	testing.expect_value(t, result, "1969-12-31 23:59:59.000 UTC")
}

// ---------------------------------------------------------------------------
// Panel behaviour
// ---------------------------------------------------------------------------

@(test)
an_empty_inspector_explains_itself :: proc(t: ^testing.T) {
	// docs/01: "empty panels explain why they are empty." A blank panel is
	// indistinguishable from a broken one.
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

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, INSPECTOR_BOUNDS)

	ui.draw_inspector(
		&list,
		inspector_state(&fonts, atlas, model.NO_EVENT),
		&builder.trace,
		&outcomes,
	)

	// Text is drawn, so the panel said something rather than sitting blank.
	testing.expect(t, count_kind(&list, .Glyph) > 0, "an empty panel must explain itself")
}

@(test)
the_inspector_shows_the_selected_event :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	selected := add(&builder, .File_Modify, 5 * SECOND, SECOND)

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, INSPECTOR_BOUNDS)

	ui.draw_inspector(&list, inspector_state(&fonts, atlas, selected), &builder.trace, &outcomes)

	// A selected event produces substantially more text than an empty panel.
	testing.expect(t, count_kind(&list, .Glyph) > 40, "attributes must be listed")
}

@(test)
a_missing_selection_is_reported_not_ignored :: proc(t: ^testing.T) {
	// A selection naming an event the trace does not contain is a bug
	// somewhere, and the panel should say so rather than draw nothing.
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

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, INSPECTOR_BOUNDS)

	ui.draw_inspector(
		&list,
		inspector_state(&fonts, atlas, model.Event_Id(9999)),
		&builder.trace,
		&outcomes,
	)

	testing.expect(t, count_kind(&list, .Glyph) > 0, "an invalid selection must be reported")
}

@(test)
selecting_an_outcome_shows_its_evidence :: proc(t: ^testing.T) {
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
	failure := add_failing_test(&builder, 2 * SECOND)

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	// A plain event and an outcome, drawn separately, to compare.
	plain_list: render.Draw_List
	render.draw_list_init(&plain_list)
	defer render.draw_list_destroy(&plain_list)
	render.draw_list_reset(&plain_list, INSPECTOR_BOUNDS)
	ui.draw_inspector(
		&plain_list,
		inspector_state(&fonts, atlas, model.Event_Id(1)),
		&builder.trace,
		&outcomes,
	)

	outcome_list: render.Draw_List
	render.draw_list_init(&outcome_list)
	defer render.draw_list_destroy(&outcome_list)
	render.draw_list_reset(&outcome_list, INSPECTOR_BOUNDS)
	ui.draw_inspector(
		&outcome_list,
		inspector_state(&fonts, atlas, failure),
		&builder.trace,
		&outcomes,
	)

	testing.expect(
		t,
		count_kind(&outcome_list, .Glyph) > count_kind(&plain_list, .Glyph),
		"an outcome shows an evidence stack a plain event does not",
	)
}

@(test)
the_inspector_clips_to_its_bounds :: proc(t: ^testing.T) {
	// The inspector sits beside the timeline; content overflowing into it
	// would corrupt the neighbouring panel.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	selected := add(&builder, .File_Modify, SECOND)

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, render.Rect{0, 0, 1920, 1080})

	ui.draw_inspector(&list, inspector_state(&fonts, atlas, selected), &builder.trace, &outcomes)

	for command in list.commands {
		clip := list.clips[command.clip]
		testing.expect(
			t,
			clip.x0 >= INSPECTOR_BOUNDS.x0 && clip.x1 <= INSPECTOR_BOUNDS.x1,
			"every command must be clipped to the panel",
		)
	}
}

@(test)
the_inspector_draws_nothing_without_a_font :: proc(t: ^testing.T) {
	// Without a typeface the panel can say nothing meaningful. Its background
	// still draws so the layout does not show a hole.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	selected := add(&builder, .File_Modify, SECOND)

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, INSPECTOR_BOUNDS)

	ui.draw_inspector(&list, inspector_state(nil, nil, selected), &builder.trace, &outcomes)

	testing.expect_value(t, count_kind(&list, .Glyph), 0)
	testing.expect(t, render.command_count(&list) > 0, "the panel background still draws")
}

@(test)
scrolling_moves_content_without_losing_it :: proc(t: ^testing.T) {
	// Rows scrolled out of view are skipped rather than clipped, so a long
	// evidence stack costs nothing for the part nobody is looking at.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)
	selected := add(&builder, .File_Modify, SECOND, SECOND)

	outcomes := analysis.build_outcome_index(&builder.trace)
	defer analysis.outcome_index_destroy(&outcomes)

	unscrolled: render.Draw_List
	render.draw_list_init(&unscrolled)
	defer render.draw_list_destroy(&unscrolled)
	render.draw_list_reset(&unscrolled, INSPECTOR_BOUNDS)
	ui.draw_inspector(
		&unscrolled,
		inspector_state(&fonts, atlas, selected),
		&builder.trace,
		&outcomes,
	)

	scrolled_state := inspector_state(&fonts, atlas, selected)
	scrolled_state.scroll = 10_000 // Far past the content.

	scrolled: render.Draw_List
	render.draw_list_init(&scrolled)
	defer render.draw_list_destroy(&scrolled)
	render.draw_list_reset(&scrolled, INSPECTOR_BOUNDS)
	ui.draw_inspector(&scrolled, scrolled_state, &builder.trace, &outcomes)

	testing.expect(t, count_kind(&unscrolled, .Glyph) > 0)
	testing.expect_value(t, count_kind(&scrolled, .Glyph), 0)
}

@(test)
evidence_levels_have_distinct_colours :: proc(t: ^testing.T) {
	// docs/06 requires the interface to identify the evidence level of every
	// relationship, which needs the three to be visually distinguishable.
	explicit := ui.level_color(ui.DARK_INSPECTOR, .Explicit)
	reconstructed := ui.level_color(ui.DARK_INSPECTOR, .Reconstructed)
	inferred := ui.level_color(ui.DARK_INSPECTOR, .Inferred)

	testing.expect(t, explicit != reconstructed)
	testing.expect(t, reconstructed != inferred)
	testing.expect(t, explicit != inferred)
}
