package test_render

import "core:testing"

import "src:render"

// Backend logic that does not require a device.
//
// The pipelines and submission path need a GPU and are covered by
// `scripts/norn.sh spike backend`. What is testable here is the conversion
// from draw commands to GPU instances, which is pure data transformation and
// is where a field mix-up would silently paint the wrong thing.

@(private)
instances_for :: proc(list: ^render.Draw_List) -> []render.Instance {
	frame: render.Batched_Frame
	render.batched_frame_init(&frame)
	defer render.batched_frame_destroy(&frame)
	render.build_batches(list, &frame)

	backend: render.Backend
	backend.instances = make([dynamic]render.Instance, 0, 16)
	render.build_instances(&backend, list, &frame)

	// The caller owns the copy; the backend's own storage is released here.
	result := make([]render.Instance, len(backend.instances))
	copy(result, backend.instances[:])
	delete(backend.instances)
	return result
}

@(test)
instances_carry_the_command_rectangle :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.Rect{10, 20, 110, 70}, render.rgba(255, 0, 0))

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, len(instances), 1)
	testing.expect_value(t, instances[0].rect[0], f32(10))
	testing.expect_value(t, instances[0].rect[1], f32(20))
	testing.expect_value(t, instances[0].rect[2], f32(110))
	testing.expect_value(t, instances[0].rect[3], f32(70))
}

@(test)
an_outline_uses_its_border_colour :: proc(t: ^testing.T) {
	// stroke_rect stores the border colour in color2, because a command
	// carries both a fill and a border. The instance must present whichever
	// one the shader will actually paint, or an outline renders transparent.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.stroke_rect(&list, render.Rect{0, 0, 100, 50}, render.rgba(0, 255, 0), 2)

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, len(instances), 1)
	testing.expect_value(t, instances[0].color[1], f32(1))
	testing.expect_value(t, instances[0].color[0], f32(0))
	testing.expect_value(t, instances[0].border, f32(2))
}

@(test)
a_filled_shape_uses_its_fill_colour :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.Rect{0, 0, 100, 50}, render.rgba(255, 128, 0, 200))

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, instances[0].color[0], f32(1))
	testing.expectf(
		t,
		abs(instances[0].color[3] - 200.0 / 255.0) < 0.001,
		"alpha was %f",
		instances[0].color[3],
	)
}

@(test)
the_kind_reaches_the_shader :: proc(t: ^testing.T) {
	// The shader branches on kind to choose between a plain rectangle, a
	// rounded one, and an outline. A wrong value paints the wrong shape.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.fill_rect(&list, render.Rect{0, 0, 10, 10}, render.rgba(255, 255, 255))
	render.fill_rounded_rect(&list, render.Rect{20, 0, 40, 20}, render.rgba(255, 255, 255), 4)
	render.draw_circle(&list, 60, 10, 8, render.rgba(255, 255, 255))

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, len(instances), 3)
	testing.expect_value(t, instances[0].kind, u32(render.Command_Kind.Rect))
	testing.expect_value(t, instances[1].kind, u32(render.Command_Kind.Rounded_Rect))
	testing.expect_value(t, instances[1].extent, f32(4))
	testing.expect_value(t, instances[2].kind, u32(render.Command_Kind.Circle))
}

@(test)
glyph_uv_coordinates_are_preserved :: proc(t: ^testing.T) {
	// A glyph sampling the wrong atlas region draws a different character,
	// which is subtle enough to survive casual inspection.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.draw_glyph(
		&list,
		render.Rect{0, 0, 8, 12},
		render.Glyph_Ref{atlas = 1, u0 = 0.25, v0 = 0.5, u1 = 0.3, v1 = 0.6},
		render.rgba(255, 255, 255),
	)

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, len(instances), 1)
	testing.expect_value(t, instances[0].uv[0], f32(0.25))
	testing.expect_value(t, instances[0].uv[1], f32(0.5))
	testing.expect_value(t, instances[0].uv[2], f32(0.3))
	testing.expect_value(t, instances[0].uv[3], f32(0.6))
}

@(test)
instances_follow_the_batched_order :: proc(t: ^testing.T) {
	// Instances are indexed by first-instance offset in the draw call, so they
	// must be laid out in submission order rather than append order.
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	render.set_layer(&list, 9)
	render.fill_rect(&list, render.Rect{0, 0, 10, 10}, render.rgba(255, 0, 0))
	render.set_layer(&list, 1)
	render.fill_rect(&list, render.Rect{20, 0, 30, 10}, render.rgba(0, 255, 0))

	instances := instances_for(&list)
	defer delete(instances)

	// The layer-1 command is submitted first, so it is instance zero.
	testing.expect_value(t, instances[0].rect[0], f32(20))
	testing.expect_value(t, instances[1].rect[0], f32(0))
}

@(test)
the_instance_layout_matches_the_shader :: proc(t: ^testing.T) {
	// The vertex attributes declare byte offsets into this struct. A field
	// reordered without updating them would feed the shader garbage, so the
	// offsets the pipeline uses are asserted against the struct itself.
	testing.expect_value(t, offset_of(render.Instance, rect), uintptr(0))
	testing.expect_value(t, offset_of(render.Instance, color), uintptr(16))
	testing.expect_value(t, offset_of(render.Instance, color2), uintptr(32))
	testing.expect_value(t, offset_of(render.Instance, uv), uintptr(48))
	testing.expect_value(t, offset_of(render.Instance, extent), uintptr(64))

	// The final vec4 the shader reads as `params` covers extent, border, kind,
	// and padding, so those four must be contiguous and 16 bytes total.
	testing.expect_value(t, size_of(render.Instance), 80)
}

@(test)
an_empty_frame_produces_no_instances :: proc(t: ^testing.T) {
	list: render.Draw_List
	make_list(&list)
	defer render.draw_list_destroy(&list)

	instances := instances_for(&list)
	defer delete(instances)

	testing.expect_value(t, len(instances), 0)
}
