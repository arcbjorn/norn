package test_ui

import "core:strings"
import "core:testing"

import "src:analysis"
import "src:render"
import "src:trace/model"
import "src:ui"

// The search bar.
//
// docs/01: "filters are composable and visible as removable chips. A hidden
// filter must never explain an apparently missing event."
//
// Both halves are testable. Visible means a chip is drawn for every filter;
// removable means a click at the drawn rectangle toggles it. The second is
// where docs/07's anti-drift rule applies — chips are sized by measured text,
// so any reimplementation of their geometry drifts the moment a label or a font
// changes, and the symptom is a click that does nothing.

SEARCH_BOUNDS :: render.Rect{0, 0, 1200, 34}

@(private)
search_state :: proc(fonts: ^render.Font_Set, atlas: ^render.Atlas) -> ui.Search_State {
	return ui.Search_State {
		bounds = SEARCH_BOUNDS,
		theme = ui.DARK_SEARCH,
		fonts = fonts,
		atlas = atlas,
		scale = 1,
		kinds = analysis.ALL_KINDS,
		selected = -1,
		scoped_path = model.NO_ENTITY,
	}
}

@(private)
with_font :: proc(
	t: ^testing.T,
	fonts: ^render.Font_Set,
) -> ^render.Atlas {
	if !load_ui_font(fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	return render.get_atlas(fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})
}

@(private)
draw_into :: proc(
	list: ^render.Draw_List,
	state: ui.Search_State,
) -> ui.Chip_Layout {
	render.draw_list_init(list)
	render.draw_list_reset(list, SEARCH_BOUNDS)
	return ui.draw_search(list, state)
}

@(test)
every_family_gets_a_chip :: proc(t: ^testing.T) {
	// Visible means all of them, not only the active ones: a filter a user
	// cannot see is one they cannot remove.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	list: render.Draw_List
	layout := draw_into(&list, search_state(&fonts, atlas))
	defer render.draw_list_destroy(&list)

	families := 0
	for index in 0 ..< layout.count {
		if layout.chips[index].kind == .Family {
			families += 1
		}
	}
	testing.expect_value(t, families, len(analysis.Kind_Filter))
}

@(test)
an_active_filter_earns_its_own_chip :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.failed_only = true
	state.scoped_path = model.Entity_Id(3)
	state.has_range = true

	list: render.Draw_List
	layout := draw_into(&list, state)
	defer render.draw_list_destroy(&list)

	found: [ui.Chip_Kind]bool
	for index in 0 ..< layout.count {
		found[layout.chips[index].kind] = true
	}

	testing.expect(t, found[.Failed_Only], "the failed-only filter must be visible")
	testing.expect(t, found[.Scoped_Path], "the path scope must be visible")
	testing.expect(t, found[.Range], "the range filter must be visible")
}

@(test)
an_inactive_filter_shows_no_chip :: proc(t: ^testing.T) {
	// The converse: a chip for a filter that is not applied would suggest the
	// view is narrowed when it is not.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	list: render.Draw_List
	layout := draw_into(&list, search_state(&fonts, atlas))
	defer render.draw_list_destroy(&list)

	for index in 0 ..< layout.count {
		chip := layout.chips[index]
		testing.expectf(
			t,
			chip.kind == .Family,
			"an unfiltered bar must show only family chips, got %v",
			chip.kind,
		)
	}
}

@(test)
a_chip_is_hit_where_it_was_actually_drawn :: proc(t: ^testing.T) {
	// docs/07: hit testing and drawing share one geometry.
	//
	// Probing the recorded rectangle's own centre proves nothing — any
	// consistent shift of the recorded bounds still contains its own centre.
	// The rectangles are therefore read back out of the draw list, so this
	// compares what the renderer will put on screen against what a click will
	// resolve to.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.failed_only = true

	list: render.Draw_List
	layout := draw_into(&list, state)
	defer render.draw_list_destroy(&list)

	testing.expect(t, layout.count > 0, "the bar must draw chips to test")

	drawn := chip_rects_from(&list, state)
	defer delete(drawn)

	testing.expectf(
		t,
		len(drawn) == layout.count,
		"drew %d chip rectangles but recorded %d",
		len(drawn),
		layout.count,
	)

	for rect, index in drawn {
		centre_x := (rect.x0 + rect.x1) * 0.5
		centre_y := (rect.y0 + rect.y1) * 0.5

		hit, found := ui.chip_at(&layout, centre_x, centre_y)
		testing.expectf(
			t,
			found,
			"a click at the centre of drawn chip %d hit nothing",
			index,
		)
		if !found {
			continue
		}
		testing.expectf(
			t,
			hit.bounds == rect,
			"chip %d was drawn at %v but recorded at %v",
			index,
			rect,
			hit.bounds,
		)
	}
}

// chip_rects_from recovers the chip rectangles the panel actually drew.
//
// The bar fills its background, then the query field, then one rectangle per
// chip. Chips are the only rectangles inset from the top and bottom edges, so
// they are identified by that inset rather than by draw order — which would
// break the moment the panel drew anything else.
@(private)
chip_rects_from :: proc(
	list: ^render.Draw_List,
	state: ui.Search_State,
) -> [dynamic]render.Rect {
	rects := make([dynamic]render.Rect, 0, 8)
	inset := 7 * state.scale
	for command in list.commands {
		if command.kind != .Rect {
			continue
		}
		if command.rect.y0 == state.bounds.y0 + inset &&
		   command.rect.y1 == state.bounds.y1 - inset {
			append(&rects, command.rect)
		}
	}
	return rects
}

@(test)
clicking_between_chips_hits_nothing :: proc(t: ^testing.T) {
	// A gap that selected its neighbour would make removing the wrong filter
	// easy, and the user would not notice which one went.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	list: render.Draw_List
	layout := draw_into(&list, search_state(&fonts, atlas))
	defer render.draw_list_destroy(&list)

	if layout.count < 2 {
		return
	}

	// The space between the first two chips.
	gap_x := (layout.chips[0].bounds.x1 + layout.chips[1].bounds.x0) * 0.5
	gap_y := (layout.chips[0].bounds.y0 + layout.chips[0].bounds.y1) * 0.5

	if gap_x <= layout.chips[0].bounds.x1 || gap_x >= layout.chips[1].bounds.x0 {
		// The chips abut; there is no gap to test.
		return
	}

	_, found := ui.chip_at(&layout, gap_x, gap_y)
	testing.expect(t, !found, "the space between chips belongs to neither")
}

@(test)
clicking_above_the_bar_hits_nothing :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	list: render.Draw_List
	layout := draw_into(&list, search_state(&fonts, atlas))
	defer render.draw_list_destroy(&list)

	_, above := ui.chip_at(&layout, 100, -20)
	testing.expect(t, !above)

	_, below := ui.chip_at(&layout, 100, 500)
	testing.expect(t, !below)
}

@(test)
an_active_chip_is_drawn_differently :: proc(t: ^testing.T) {
	// The state has to be visible, not only recorded: a chip that looked the
	// same whether or not its filter applied would satisfy the letter of
	// "visible" and none of its purpose.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	all: render.Draw_List
	all_layout := draw_into(&all, search_state(&fonts, atlas))
	defer render.draw_list_destroy(&all)

	narrowed := search_state(&fonts, atlas)
	narrowed.kinds = {.File}
	some: render.Draw_List
	some_layout := draw_into(&some, narrowed)
	defer render.draw_list_destroy(&some)

	// Same chips, different active states.
	testing.expect_value(t, all_layout.count, some_layout.count)

	active_in_all := 0
	active_in_some := 0
	for index in 0 ..< all_layout.count {
		if all_layout.chips[index].active {
			active_in_all += 1
		}
		if some_layout.chips[index].active {
			active_in_some += 1
		}
	}
	testing.expect_value(t, active_in_all, len(analysis.Kind_Filter))
	testing.expect_value(t, active_in_some, 1)
}

@(test)
the_bar_draws_without_a_font :: proc(t: ^testing.T) {
	// docs/13 records font discovery as an open packaging question, so a
	// missing face degrades the interface rather than crashing it.
	list: render.Draw_List
	layout := draw_into(&list, search_state(nil, nil))
	defer render.draw_list_destroy(&list)

	testing.expect_value(t, layout.count, 0)
	testing.expect(t, count_kind(&list, .Rect) > 0, "the bar must still fill its band")
}

@(test)
the_bar_stays_inside_its_bounds :: proc(t: ^testing.T) {
	// docs/07 requires a panel to clip to its own rectangle. A chip row that
	// overflowed would draw over the timeline below it.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.failed_only = true
	state.scoped_path = model.Entity_Id(1)
	state.has_range = true

	list: render.Draw_List
	layout := draw_into(&list, state)
	defer render.draw_list_destroy(&list)

	for index in 0 ..< layout.count {
		bounds := layout.chips[index].bounds
		testing.expect(t, bounds.x1 <= SEARCH_BOUNDS.x1, "a chip must not overflow the bar")
		testing.expect(t, bounds.y0 >= SEARCH_BOUNDS.y0)
		testing.expect(t, bounds.y1 <= SEARCH_BOUNDS.y1)
	}
}

@(test)
a_narrow_bar_drops_chips_rather_than_overflowing :: proc(t: ^testing.T) {
	// Running out of room is a real case on a small window. Drawing past the
	// edge would be worse than drawing fewer chips.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.bounds = render.Rect{0, 0, 300, 34}

	list: render.Draw_List
	render.draw_list_init(&list)
	render.draw_list_reset(&list, state.bounds)
	layout := ui.draw_search(&list, state)
	defer render.draw_list_destroy(&list)

	testing.expect(t, layout.count < len(analysis.Kind_Filter), "a narrow bar cannot fit them all")
	for index in 0 ..< layout.count {
		testing.expect(t, layout.chips[index].bounds.x1 <= state.bounds.x1)
	}
}

@(test)
an_empty_result_says_whether_a_filter_caused_it :: proc(t: ^testing.T) {
	// The whole point of the accounting. "No matches" and "a filter removed
	// everything" send a user to different places, and only one of them is
	// about the trace.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	// Nothing matched, nothing filtered.
	plain := search_state(&fonts, atlas)
	plain.text = "absent"
	plain.examined = 40

	testing.expect(
		t,
		strings.contains(ui.result_summary(plain), "no matches in 40 events"),
		"an unfiltered miss must say so",
	)

	// Nothing matched because a filter removed everything.
	filtered := search_state(&fonts, atlas)
	filtered.text = "present"
	filtered.kinds = {.File}
	filtered.examined = 40
	filtered.excluded_by_kind = 40

	testing.expect(
		t,
		strings.contains(ui.result_summary(filtered), "kind filters"),
		"a filtered miss must name the filter",
	)
}

@(test)
a_truncated_result_says_how_many_more :: proc(t: ^testing.T) {
	// A capped list that looked complete would let a user conclude the rest do
	// not exist.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.text = "common"
	state.match_count = 500
	state.truncated = 1200
	state.examined = 1700

	testing.expect(t, strings.contains(ui.result_summary(state), "1200 more"))
}

@(test)
the_selected_position_is_shown :: proc(t: ^testing.T) {
	// Stepping matches is only navigable if the user can see where they are.
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	state := search_state(&fonts, atlas)
	state.text = "alpha"
	state.match_count = 7
	state.selected = 2
	state.examined = 20

	// One-based for display: the third match is "3 of 7", not "2 of 7".
	testing.expect(t, strings.contains(ui.result_summary(state), "3 of 7"))
}

@(test)
an_unfiltered_empty_query_reports_nothing :: proc(t: ^testing.T) {
	// Before the user types, the bar has nothing to say about results, and a
	// count of zero would read as "no matches".
	fonts: render.Font_Set
	atlas := with_font(t, &fonts)
	defer render.font_set_destroy(&fonts)

	// Empty rather than a zero count: before the user types, the bar has
	// nothing to report, and "0 matches" would read as a failed search.
	testing.expect_value(t, ui.result_summary(search_state(&fonts, atlas)), "")
}
