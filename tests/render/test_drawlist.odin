package test_render

import "core:testing"

import "src:render"

// Draw lists and batching.
//
// docs/02: the renderer receives draw data and owns no product state. That is
// what makes these tests possible — every assertion below inspects a plain
// data structure, with no window, device, or surface involved.

@(private)
FULL_SURFACE :: render.Rect{0, 0, 1920, 1080}

@(private)
make_list :: proc(list: ^render.Draw_List) {
	render.draw_list_init(list)
	render.draw_list_reset(list, FULL_SURFACE)
}

@(test)
commands_accumulate_in_order :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.rect_from_size(10, 10, 100, 20), render.rgba(255, 0, 0))
	render.fill_rect(&list, render.rect_from_size(20, 40, 100, 20), render.rgba(0, 255, 0))

	testing.expect_value(t, render.command_count(&list), 2)
	testing.expect_value(t, list.commands[0].kind, render.Command_Kind.Rect)
	testing.expect_value(t, list.commands[0].rect.x0, f32(10))
	testing.expect_value(t, list.commands[1].rect.y0, f32(40))
}

@(test)
reset_keeps_capacity_and_clears_content :: proc(t: ^testing.T) {
	// The frame loop reuses a list every frame. Reset must clear it without
	// giving back the allocation, or a steady workload allocates forever.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for index in 0 ..< 100 {
		render.fill_rect(&list, render.rect_from_size(f32(index), 0, 10, 10), render.rgba(255, 255, 255))
	}
	capacity := cap(list.commands)

	render.draw_list_reset(&list, FULL_SURFACE)

	testing.expect_value(t, render.command_count(&list), 0)
	testing.expect_value(t, cap(list.commands), capacity)
	testing.expect_value(t, len(list.clips), 1)
}

@(test)
commands_outside_the_clip_are_dropped :: proc(t: ^testing.T) {
	// A command outside its clip produces no pixels. Dropping it here saves
	// the batching pass and the GPU upload.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	previous := render.push_clip(&list, render.Rect{0, 0, 100, 100})
	render.fill_rect(&list, render.rect_from_size(10, 10, 20, 20), render.rgba(255, 0, 0))
	render.fill_rect(&list, render.rect_from_size(500, 500, 20, 20), render.rgba(0, 255, 0))
	render.pop_clip(&list, previous)

	testing.expect_value(t, render.command_count(&list), 1)
	testing.expect_value(t, list.commands[0].rect.x0, f32(10))
}

@(test)
zero_area_commands_are_dropped :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.Rect{10, 10, 10, 50}, render.rgba(255, 0, 0)) // zero width
	render.fill_rect(&list, render.Rect{10, 10, 50, 10}, render.rgba(255, 0, 0)) // zero height
	render.fill_rect(&list, render.Rect{50, 50, 10, 10}, render.rgba(255, 0, 0)) // inverted

	testing.expect_value(t, render.command_count(&list), 0)
}

@(test)
a_zero_length_line_is_still_emitted :: proc(t: ^testing.T) {
	// A line's rect holds endpoints rather than a bounding box, so a vertical
	// line has zero width and must not be culled as a zero-area rectangle.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.draw_line(&list, 100, 0, 100, 500, render.rgba(255, 255, 255))

	testing.expect_value(t, render.command_count(&list), 1)
	testing.expect_value(t, list.commands[0].kind, render.Command_Kind.Line)
}

@(test)
nested_clips_intersect_rather_than_replace :: proc(t: ^testing.T) {
	// Intersecting is what makes clipping composable: a nested panel can never
	// draw outside its parent, however large a clip it asks for.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	outer := render.push_clip(&list, render.Rect{100, 100, 400, 400})
	inner := render.push_clip(&list, render.Rect{0, 0, 1920, 1080})

	effective := render.current_clip_rect(&list)
	testing.expect_value(t, effective.x0, f32(100))
	testing.expect_value(t, effective.x1, f32(400))

	render.pop_clip(&list, inner)
	render.pop_clip(&list, outer)
}

@(test)
rounded_radius_is_clamped_to_the_shape :: proc(t: ^testing.T) {
	// A radius larger than half the shorter side would invert the corner
	// geometry, so it is clamped rather than left to the shader.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rounded_rect(
		&list,
		render.rect_from_size(0, 0, 20, 10),
		render.rgba(255, 255, 255),
		100,
	)

	testing.expect_value(t, render.command_count(&list), 1)
	testing.expect_value(t, list.commands[0].extent, f32(5))
}

@(test)
rect_helpers_behave :: proc(t: ^testing.T) {
	rect := render.rect_from_size(10, 20, 100, 50)
	testing.expect_value(t, rect.x1, f32(110))
	testing.expect_value(t, rect.y1, f32(70))
	testing.expect_value(t, render.rect_width(rect), f32(100))
	testing.expect_value(t, render.rect_height(rect), f32(50))
	testing.expect(t, render.rect_contains(rect, 50, 30))
	testing.expect(t, !render.rect_contains(rect, 5, 30))

	overlap := render.rect_intersect(rect, render.Rect{50, 0, 200, 200})
	testing.expect_value(t, overlap.x0, f32(50))
	testing.expect_value(t, overlap.x1, f32(110))

	apart := render.rect_intersect(rect, render.Rect{500, 500, 600, 600})
	testing.expect(t, render.rect_is_empty(apart))
}

// ---------------------------------------------------------------------------
// Batching
// ---------------------------------------------------------------------------

@(test)
similar_primitives_batch_together :: proc(t: ^testing.T) {
	// docs/07: similar primitives are batched by pipeline, texture atlas, and
	// clip rectangle. A thousand rectangles sharing all three are one call.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for index in 0 ..< 1000 {
		render.fill_rect(
			&list,
			render.rect_from_size(f32(index), 0, 1, 10),
			render.rgba(255, 255, 255),
		)
	}

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	stats := render.frame_stats(&list, &frame)
	testing.expect_value(t, stats.commands, 1000)
	testing.expect_value(t, stats.draw_calls, 1)
	testing.expect_value(t, stats.largest_batch, 1000)
}

@(test)
a_different_pipeline_starts_a_new_batch :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.rect_from_size(0, 0, 10, 10), render.rgba(255, 0, 0))
	render.draw_line(&list, 0, 0, 100, 100, render.rgba(0, 255, 0))
	render.draw_glyph(
		&list,
		render.rect_from_size(0, 0, 8, 12),
		render.Glyph_Ref{atlas = 1, u1 = 1, v1 = 1},
		render.rgba(255, 255, 255),
	)

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	testing.expect_value(t, len(frame.batches), 3)
}

@(test)
a_different_atlas_starts_a_new_batch :: proc(t: ^testing.T) {
	// Two atlases cannot be sampled by one draw call, so a change must break
	// the batch even though the pipeline is identical.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for atlas in ([]u32{1, 1, 2, 2, 1}) {
		render.draw_glyph(
			&list,
			render.rect_from_size(0, 0, 8, 12),
			render.Glyph_Ref{atlas = atlas, u1 = 1, v1 = 1},
			render.rgba(255, 255, 255),
		)
	}

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	// Sorting groups the two atlas-1 runs together, so three commands with
	// atlas 1 and two with atlas 2 become two batches, not three.
	testing.expect_value(t, len(frame.batches), 2)
}

@(test)
a_different_clip_starts_a_new_batch :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	first := render.push_clip(&list, render.Rect{0, 0, 500, 500})
	render.fill_rect(&list, render.rect_from_size(10, 10, 10, 10), render.rgba(255, 0, 0))
	render.pop_clip(&list, first)

	second := render.push_clip(&list, render.Rect{0, 0, 600, 600})
	render.fill_rect(&list, render.rect_from_size(20, 20, 10, 10), render.rgba(0, 255, 0))
	render.pop_clip(&list, second)

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	testing.expect_value(t, len(frame.batches), 2)
}

@(test)
layers_are_submitted_in_painters_order :: proc(t: ^testing.T) {
	// Painter's order is a correctness property, not a hint: a panel that
	// emits a background after its content must still see it behind.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.set_layer(&list, 5)
	render.fill_rect(&list, render.rect_from_size(0, 0, 10, 10), render.rgba(255, 0, 0))

	render.set_layer(&list, 1)
	render.fill_rect(&list, render.rect_from_size(20, 0, 10, 10), render.rgba(0, 255, 0))

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	// The lower layer must come first regardless of emission order.
	first := list.commands[frame.order[0]]
	second := list.commands[frame.order[1]]
	testing.expect_value(t, first.layer, u16(1))
	testing.expect_value(t, second.layer, u16(5))
}

@(test)
batching_is_stable_within_a_layer :: proc(t: ^testing.T) {
	// Two commands with identical keys must keep the order the panel emitted
	// them in, which is what a panel relies on for overlapping shapes.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for index in 0 ..< 50 {
		render.fill_rect(
			&list,
			render.rect_from_size(f32(index), 0, 100, 10),
			render.rgba(u8(index), 0, 0),
		)
	}

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	for position in 0 ..< len(frame.order) {
		testing.expectf(
			t,
			frame.order[position] == position,
			"command %d moved to position %d",
			frame.order[position],
			position,
		)
	}
}

@(test)
an_empty_list_produces_no_batches :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	testing.expect_value(t, len(frame.batches), 0)
	testing.expect_value(t, len(frame.order), 0)
}

@(test)
every_command_appears_exactly_once :: proc(t: ^testing.T) {
	// A sort that dropped or duplicated a command would lose or double-paint
	// part of the frame.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	for index in 0 ..< 200 {
		render.set_layer(&list, u16(index % 4))
		render.fill_rect(
			&list,
			render.rect_from_size(f32(index), 0, 10, 10),
			render.rgba(255, 255, 255),
		)
	}

	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(&list, &frame)

	seen := make([]bool, len(list.commands))
	defer delete(seen)

	for index in frame.order {
		testing.expectf(t, !seen[index], "command %d appeared twice", index)
		seen[index] = true
	}
	for present, index in seen {
		testing.expectf(t, present, "command %d was dropped", index)
	}

	// Batch runs must cover the whole order exactly.
	covered := 0
	for batch in frame.batches {
		covered += batch.count
	}
	testing.expect_value(t, covered, len(frame.order))
}

@(test)
pipeline_assignment_groups_shape_kinds :: proc(t: ^testing.T) {
	// A solid rectangle, an outline, a rounded rectangle, and a circle are one
	// shader with different parameters. Grouping them avoids a state change
	// that buys nothing.
	testing.expect_value(t, render.pipeline_for(.Rect), render.Pipeline.Shape)
	testing.expect_value(t, render.pipeline_for(.Rect_Outline), render.Pipeline.Shape)
	testing.expect_value(t, render.pipeline_for(.Rounded_Rect), render.Pipeline.Shape)
	testing.expect_value(t, render.pipeline_for(.Circle), render.Pipeline.Shape)
	testing.expect_value(t, render.pipeline_for(.Line), render.Pipeline.Line)
	testing.expect_value(t, render.pipeline_for(.Glyph), render.Pipeline.Glyph)
	testing.expect_value(t, render.pipeline_for(.Textured), render.Pipeline.Texture)
}
