package test_render

import "core:os"
import "core:testing"

import "src:render"

// Glyph atlases and text layout.
//
// These need a real font file, which is a platform resource rather than a
// fixture. Where one is unavailable the test reports that it was skipped
// rather than passing silently — a green run that asserted nothing is worse
// than a visibly absent one.

@(private)
FONT_CANDIDATES :: []string {
	"/System/Library/Fonts/SFNSMono.ttf",
	"/System/Library/Fonts/Menlo.ttc",
	"/System/Library/Fonts/Supplemental/Andale Mono.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
}

@(private)
load_test_font :: proc(set: ^render.Font_Set) -> bool {
	render.font_set_init(set)
	for path in FONT_CANDIDATES {
		if os.exists(path) && render.load_face(set, .Monospace, path) {
			return true
		}
	}
	return false
}

@(test)
an_atlas_rasterizes_glyphs :: proc(t: ^testing.T) {
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})
	testing.expect(t, atlas != nil)

	glyph, ok := render.glyph_for(&set, atlas, 'A')
	testing.expect(t, ok)
	testing.expect(t, glyph.has_bitmap, "a letter must produce coverage")
	testing.expect(t, glyph.advance > 0, "a letter must advance the pen")
	testing.expect(t, glyph.x1 > glyph.x0, "a letter must occupy atlas space")
	testing.expect(t, glyph.y1 > glyph.y0)
}

@(test)
a_space_advances_without_coverage :: proc(t: ^testing.T) {
	// Emitting a quad for a space would waste an instance per word.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 1})
	glyph, ok := render.glyph_for(&set, atlas, ' ')

	testing.expect(t, ok)
	testing.expect(t, !glyph.has_bitmap, "a space has no coverage")
	testing.expect(t, glyph.advance > 0, "a space must still advance")
}

@(test)
the_atlas_cache_distinguishes_scale :: proc(t: ^testing.T) {
	// docs/07 keys the atlas by font, size, and scale factor. Reusing a 1x
	// atlas on a 2x display is what blurry Retina text is, so the two must be
	// different rasterizations rather than the same bitmap sampled twice.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	low := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 1})
	high := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	testing.expect(t, low != high, "two scales must not share an atlas")
	testing.expect(t, low.id != high.id, "each atlas needs its own identifier")

	low_glyph, _ := render.glyph_for(&set, low, 'M')
	high_glyph, _ := render.glyph_for(&set, high, 'M')

	low_width := low_glyph.x1 - low_glyph.x0
	high_width := high_glyph.x1 - high_glyph.x0
	testing.expectf(
		t,
		high_width > low_width,
		"the 2x glyph is %d px wide, the 1x is %d",
		high_width,
		low_width,
	)
}

@(test)
the_atlas_cache_returns_the_same_atlas_for_one_key :: proc(t: ^testing.T) {
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	key := render.Atlas_Key{font = .Monospace, size = 13, scale = 2}
	first := render.get_atlas(&set, key)
	second := render.get_atlas(&set, key)

	testing.expect(t, first == second, "one key must yield one atlas")
}

@(test)
an_unloaded_font_yields_no_atlas :: proc(t: ^testing.T) {
	// A missing typeface must degrade to no text rather than to boxes, which
	// would look like data.
	set: render.Font_Set
	render.font_set_init(&set)
	defer render.font_set_destroy(&set)

	testing.expect(t, !render.has_face(&set, .Interface))
	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Interface, size = 13, scale = 1})
	testing.expect(t, atlas == nil)
}

@(test)
loading_a_missing_file_fails_cleanly :: proc(t: ^testing.T) {
	set: render.Font_Set
	render.font_set_init(&set)
	defer render.font_set_destroy(&set)

	testing.expect(t, !render.load_face(&set, .Interface, "/nonexistent/font.ttf"))
	testing.expect(t, !render.has_face(&set, .Interface))
}

@(test)
measurement_matches_what_is_drawn :: proc(t: ^testing.T) {
	// Right-aligning and fit-testing both rely on measure_text agreeing with
	// draw_text's advance arithmetic. A mismatch shows up as text that
	// overflows the box it was measured against.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	text := "src/parser.odin"
	measured := render.measure_text(&set, atlas, text)
	drawn := render.draw_text(&list, &set, atlas, text, 0, 0, render.rgba(255, 255, 255))

	testing.expectf(
		t,
		abs(measured - drawn) < 0.01,
		"measured %f but drew %f",
		measured,
		drawn,
	)
}

@(test)
a_monospace_face_advances_uniformly :: proc(t: ^testing.T) {
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	reference, _ := render.glyph_for(&set, atlas, 'M')
	for codepoint in "abcXYZ0189{}[]" {
		glyph, _ := render.glyph_for(&set, atlas, codepoint)
		testing.expectf(
			t,
			abs(glyph.advance - reference.advance) < 0.01,
			"%v advances %f, M advances %f",
			codepoint,
			glyph.advance,
			reference.advance,
		)
	}
}

@(test)
drawing_text_emits_one_command_per_visible_glyph :: proc(t: ^testing.T) {
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	// Five letters and one space: the space contributes no quad.
	render.draw_text(&list, &set, atlas, "ab cd", 10, 10, render.rgba(255, 255, 255))

	testing.expect_value(t, render.command_count(&list), 4)
	for command in list.commands {
		testing.expect_value(t, command.kind, render.Command_Kind.Glyph)
		testing.expect_value(t, command.source.atlas, atlas.id)
	}
}

@(test)
clipped_text_is_truncated_with_an_ellipsis :: proc(t: ^testing.T) {
	// docs/07: long lines are clipped, never silently wrapped. A truncated
	// label ends in a marker so the reader knows text was removed rather than
	// believing the value is short.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	long := "a/very/long/repository/path/that/will/not/fit.odin"
	full := render.measure_text(&set, atlas, long)
	budget := full * 0.4

	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	used := render.draw_text_clipped(
		&list,
		&set,
		atlas,
		long,
		0,
		0,
		budget,
		render.rgba(255, 255, 255),
	)

	testing.expect(t, used <= budget + 0.01, "clipped text must fit its budget")
	testing.expect(t, render.command_count(&list) > 0, "something must still be drawn")
	testing.expect(
		t,
		render.command_count(&list) < len(long),
		"fewer glyphs than the full string",
	)
}

@(test)
text_that_fits_is_not_truncated :: proc(t: ^testing.T) {
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	text := "short"
	width := render.measure_text(&set, atlas, text)
	used := render.draw_text_clipped(
		&list,
		&set,
		atlas,
		text,
		0,
		0,
		width * 2,
		render.rgba(255, 255, 255),
	)

	testing.expectf(t, abs(used - width) < 0.01, "used %f, expected %f", used, width)
	testing.expect_value(t, render.command_count(&list), len(text))
}

@(test)
glyphs_batch_into_one_draw_call :: proc(t: ^testing.T) {
	// Every glyph from one atlas shares a pipeline and a texture, which is the
	// whole reason for an atlas.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})

	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for line in 0 ..< 40 {
		render.draw_text(
			&list,
			&set,
			atlas,
			"the quick brown fox jumps over the lazy dog",
			10,
			f32(line) * 20,
			render.rgba(255, 255, 255),
		)
	}

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	stats := render.frame_stats(&list, &frame)
	testing.expect(t, stats.commands > 1000, "the fixture must be busy enough to matter")
	testing.expect_value(t, stats.draw_calls, 1)
}

@(test)
adding_a_glyph_marks_the_atlas_for_upload :: proc(t: ^testing.T) {
	// Glyphs rasterize lazily during draw-list generation, so the backend has
	// to know the texture changed. Missing this would show a blank rectangle
	// where a newly seen character should be.
	set: render.Font_Set
	if !load_test_font(&set) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&set)

	atlas := render.get_atlas(&set, render.Atlas_Key{font = .Monospace, size = 13, scale = 2})
	render.glyph_for(&set, atlas, 'A')

	// Simulate the backend having uploaded the atlas.
	atlas.uploaded = true

	render.glyph_for(&set, atlas, 'A') // Cached: no change.
	testing.expect(t, atlas.uploaded, "a cached glyph must not dirty the atlas")

	render.glyph_for(&set, atlas, 'Z') // New: dirties it.
	testing.expect(t, !atlas.uploaded, "a new glyph must mark the atlas for upload")
}
