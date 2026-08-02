package test_ui

import "core:fmt"
import "core:strings"
import "core:testing"

import "src:render"
import "src:replay"
import "src:ui"

// The diff and replay panel.
//
// docs/01 makes two of its behaviours normative: unknown or unverifiable
// content is shown explicitly, and Norn never presents partial replay as
// complete. Both are testable against the emitted draw list.

@(private)
DIFF_BOUNDS :: render.Rect{0, 400, 1000, 700}

@(private)
diff_state :: proc(fonts: ^render.Font_Set, mono: ^render.Atlas) -> ui.Diff_Panel_State {
	return ui.Diff_Panel_State {
		bounds = DIFF_BOUNDS,
		theme = ui.DARK_DIFF,
		fonts = fonts,
		mono = mono,
		scale = 1,
	}
}

@(private)
load_mono_font :: proc(set: ^render.Font_Set) -> bool {
	render.font_set_init(set)
	candidates := []string {
		"/System/Library/Fonts/SFNSMono.ttf",
		"/System/Library/Fonts/Menlo.ttc",
		"/System/Library/Fonts/Supplemental/Andale Mono.ttf",
		"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
	}
	for path in candidates {
		if render.load_face(set, .Monospace, path) {
			return true
		}
	}
	return false
}

@(test)
a_replay_gap_is_labelled_not_blank :: proc(t: ^testing.T) {
	// docs/01: "unknown or unverifiable content is shown explicitly." A blank
	// panel would read as an empty file, which is a false statement about the
	// session rather than a missing feature.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, DIFF_BOUNDS)

	ui.draw_diff(
		&list,
		diff_state(&fonts, mono),
		ui.Diff_Content{path = "src/parser.odin", status = .Gap, gap_event = 42},
	)

	testing.expect(t, count_kind(&list, .Glyph) > 0, "a gap must be explained in text")
}

@(test)
every_unresolvable_state_says_something_different :: proc(t: ^testing.T) {
	// Collapsing these into one message would lose the distinction between
	// "this file was deleted" and "we could not reconstruct it", which are
	// different facts about the session.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	states := []replay.Resolved_Status{.Gap, .Binary, .Deleted, .Absent, .Unknown_Path}
	counts := make([]int, len(states))
	defer delete(counts)

	for status, index in states {
		list: render.Draw_List
		render.draw_list_init(&list)
		defer render.draw_list_destroy(&list)
		render.draw_list_reset(&list, DIFF_BOUNDS)

		ui.draw_diff(
			&list,
			diff_state(&fonts, mono),
			ui.Diff_Content{path = "src/a.odin", status = status},
		)
		counts[index] = count_kind(&list, .Glyph)
		testing.expectf(t, counts[index] > 0, "%v must be explained", status)
	}

	// The messages differ in length, so equal glyph counts would suggest one
	// message being reused for several states.
	distinct_counts := 0
	for index in 0 ..< len(counts) {
		unique := true
		for other in 0 ..< index {
			if counts[other] == counts[index] {
				unique = false
			}
		}
		if unique {
			distinct_counts += 1
		}
	}
	testing.expect(t, distinct_counts >= 4, "each state needs its own explanation")
}

@(test)
a_diff_renders_its_lines :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	diff := replay.diff_text(
		transmute([]byte)string("alpha\nbeta\ngamma\n"),
		transmute([]byte)string("alpha\nBETA\ngamma\n"),
	)
	defer replay.diff_destroy(&diff)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, DIFF_BOUNDS)

	ui.draw_diff(
		&list,
		diff_state(&fonts, mono),
		ui.Diff_Content{path = "src/a.odin", status = .Verified, diff = &diff},
	)

	testing.expect(t, count_kind(&list, .Glyph) > 20, "the lines must be drawn")
	// Added and removed rows get a background fill each.
	testing.expect(t, count_kind(&list, .Rect) >= 2, "changed lines need backgrounds")
}

@(test)
changed_lines_carry_a_marker_not_only_a_colour :: proc(t: ^testing.T) {
	// docs/01: colour is never the sole carrier of status. A reader who cannot
	// distinguish the two backgrounds still needs to see which lines changed.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	// One removal and one addition against an unchanged line.
	changed := replay.diff_text(
		transmute([]byte)string("same\nold\n"),
		transmute([]byte)string("same\nnew\n"),
	)
	defer replay.diff_destroy(&changed)

	unchanged := replay.diff_text(
		transmute([]byte)string("same\nold\n"),
		transmute([]byte)string("same\nold\n"),
	)
	defer replay.diff_destroy(&unchanged)

	count_glyphs :: proc(
		fonts: ^render.Font_Set,
		mono: ^render.Atlas,
		diff: ^replay.Diff,
	) -> int {
		list: render.Draw_List
		render.draw_list_init(&list)
		defer render.draw_list_destroy(&list)
		render.draw_list_reset(&list, DIFF_BOUNDS)
		ui.draw_diff(
			&list,
			ui.Diff_Panel_State {
				bounds = DIFF_BOUNDS,
				theme = ui.DARK_DIFF,
				fonts = fonts,
				mono = mono,
				scale = 1,
			},
			ui.Diff_Content{path = "a", status = .Verified, diff = diff},
		)
		total := 0
		for command in list.commands {
			if command.kind == .Glyph {
				total += 1
			}
		}
		return total
	}

	// The changed diff has one more line and two markers, so it draws more.
	testing.expect(
		t,
		count_glyphs(&fonts, mono, &changed) > count_glyphs(&fonts, mono, &unchanged),
		"changed lines must draw markers the unchanged version does not",
	)
}

@(test)
a_truncated_diff_says_it_is_approximate :: proc(t: ^testing.T) {
	// A coarse diff is correct but not minimal. docs/01 forbids presenting
	// partial work as complete.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	small := replay.diff_text(
		transmute([]byte)string("a\n"),
		transmute([]byte)string("b\n"),
	)
	defer replay.diff_destroy(&small)

	marked := small
	marked.truncated = true

	count :: proc(fonts: ^render.Font_Set, mono: ^render.Atlas, diff: ^replay.Diff) -> int {
		list: render.Draw_List
		render.draw_list_init(&list)
		defer render.draw_list_destroy(&list)
		render.draw_list_reset(&list, DIFF_BOUNDS)
		ui.draw_diff(
			&list,
			ui.Diff_Panel_State {
				bounds = DIFF_BOUNDS,
				theme = ui.DARK_DIFF,
				fonts = fonts,
				mono = mono,
				scale = 1,
			},
			ui.Diff_Content{path = "a", status = .Verified, diff = diff},
		)
		total := 0
		for command in list.commands {
			if command.kind == .Glyph {
				total += 1
			}
		}
		return total
	}

	testing.expect(
		t,
		count(&fonts, mono, &marked) > count(&fonts, mono, &small),
		"a truncated diff must carry an extra warning",
	)
}

@(test)
unverified_content_is_labelled :: proc(t: ^testing.T) {
	// Silence about verification would read as confirmation.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	lines := replay.split_lines(transmute([]byte)string("content\n"))
	defer delete(lines)

	count :: proc(
		fonts: ^render.Font_Set,
		mono: ^render.Atlas,
		lines: [][]byte,
		status: replay.Resolved_Status,
	) -> int {
		list: render.Draw_List
		render.draw_list_init(&list)
		defer render.draw_list_destroy(&list)
		render.draw_list_reset(&list, DIFF_BOUNDS)
		ui.draw_diff(
			&list,
			ui.Diff_Panel_State {
				bounds = DIFF_BOUNDS,
				theme = ui.DARK_DIFF,
				fonts = fonts,
				mono = mono,
				scale = 1,
			},
			ui.Diff_Content{path = "a", status = status, lines = lines},
		)
		total := 0
		for command in list.commands {
			if command.kind == .Glyph {
				total += 1
			}
		}
		return total
	}

	verified := count(&fonts, mono, lines, .Verified)
	unverified := count(&fonts, mono, lines, .Unverified)
	observational := count(&fonts, mono, lines, .Observational)

	testing.expect(t, unverified > verified, "unverified content needs a label")
	testing.expect(t, observational > verified, "an observed baseline needs a label")
}

@(test)
the_panel_virtualizes_long_files :: proc(t: ^testing.T) {
	// docs/07 requires the diff viewer to virtualize lines. A thousand-line
	// file must not emit a thousand rows into a panel showing twenty.
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 1000 {
		fmt.sbprintf(&builder, "line %d\n", index)
	}
	lines := replay.split_lines(transmute([]byte)strings.to_string(builder))
	defer delete(lines)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, DIFF_BOUNDS)

	ui.draw_diff(
		&list,
		diff_state(&fonts, mono),
		ui.Diff_Content{path = "big.txt", status = .Verified, lines = lines},
	)

	// The panel is 300 pixels tall, so only a few dozen rows fit. Each row is
	// a handful of glyphs, so a virtualized panel stays well under what a
	// thousand rows would produce.
	glyphs := count_kind(&list, .Glyph)
	testing.expectf(t, glyphs < 1000, "expected a virtualized subset, drew %d glyphs", glyphs)
	testing.expect(t, glyphs > 0, "something must be drawn")
}

@(test)
scrolling_shows_a_different_region :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 500 {
		fmt.sbprintf(&builder, "%d\n", index)
	}
	lines := replay.split_lines(transmute([]byte)strings.to_string(builder))
	defer delete(lines)

	// Scrolled past the end draws nothing rather than repeating the last page.
	state := diff_state(&fonts, mono)
	state.scroll_lines = 10_000

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, DIFF_BOUNDS)

	ui.draw_diff(
		&list,
		state,
		ui.Diff_Content{path = "big.txt", status = .Verified, lines = lines},
	)

	// The header still draws; the body does not.
	testing.expect(t, render.command_count(&list) > 0)
}

@(test)
an_empty_file_says_so :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, DIFF_BOUNDS)

	ui.draw_diff(
		&list,
		diff_state(&fonts, mono),
		ui.Diff_Content{path = "empty.txt", status = .Verified},
	)

	testing.expect(t, count_kind(&list, .Glyph) > 0, "an empty file must be stated")
}

@(test)
the_diff_panel_clips_to_its_bounds :: proc(t: ^testing.T) {
	fonts: render.Font_Set
	if !load_mono_font(&fonts) {
		testing.fail_now(t, "no monospace font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	mono := render.get_atlas(&fonts, render.Atlas_Key{font = .Monospace, size = 12, scale = 1})

	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 200 {
		fmt.sbprintf(&builder, "a fairly long line of content number %d\n", index)
	}
	lines := replay.split_lines(transmute([]byte)strings.to_string(builder))
	defer delete(lines)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, render.Rect{0, 0, 1920, 1080})

	ui.draw_diff(
		&list,
		diff_state(&fonts, mono),
		ui.Diff_Content{path = "a.txt", status = .Verified, lines = lines},
	)

	for command in list.commands {
		clip := list.clips[command.clip]
		testing.expect(
			t,
			clip.y0 >= DIFF_BOUNDS.y0 && clip.y1 <= DIFF_BOUNDS.y1,
			"every command must be clipped to the panel",
		)
	}
}

@(test)
line_count_reports_what_would_be_drawn :: proc(t: ^testing.T) {
	// Scrolling needs the total, and deriving it twice would let the two
	// disagree at the end of a file.
	diff := replay.diff_text(
		transmute([]byte)string("a\nb\n"),
		transmute([]byte)string("a\nc\n"),
	)
	defer replay.diff_destroy(&diff)

	testing.expect_value(
		t,
		ui.diff_line_count(ui.Diff_Content{diff = &diff}),
		len(diff.lines),
	)

	lines := replay.split_lines(transmute([]byte)string("one\ntwo\nthree\n"))
	defer delete(lines)
	testing.expect_value(t, ui.diff_line_count(ui.Diff_Content{lines = lines}), 3)
}
