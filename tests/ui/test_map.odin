package test_ui

import "core:testing"

import "src:analysis"
import "src:render"
import "src:trace/model"
import "src:ui"

// The repository map.
//
// docs/07 governs two of these: hit testing uses the same transform as
// drawing, and only selected, pinned, or sufficiently separated nodes are
// labelled. Both are testable against the emitted draw list.

@(private)
MAP_BOUNDS :: render.Rect{0, 0, 600, 600}

@(private)
map_state :: proc(fonts: ^render.Font_Set, atlas: ^render.Atlas) -> ui.Map_State {
	return ui.Map_State {
		bounds = MAP_BOUNDS,
		theme = ui.DARK_MAP,
		fonts = fonts,
		atlas = atlas,
		scale = 1,
		selection = model.NO_ENTITY,
	}
}

// build_map_fixture makes a session touching several files in different ways.
@(private)
build_map_fixture :: proc(builder: ^Builder) {
	builder_init(builder)

	parser := add_entity_named(builder, .Path, "src/parser.odin")
	lexer := add_entity_named(builder, .Path, "src/lexer.odin")
	reader := add_entity_named(builder, .Path, "src/reader.odin")

	add(builder, .File_Modify, SECOND, primary = parser)
	add(builder, .File_Modify, 2 * SECOND, primary = parser)
	add(builder, .File_Modify, 3 * SECOND, primary = lexer)
	add(builder, .File_Read, 4 * SECOND, primary = reader)
}

@(test)
the_map_draws_a_node_per_touched_file :: proc(t: ^testing.T) {
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, MAP_BOUNDS)

	ui.draw_map(&list, map_state(nil, nil), &graph, &builder.trace)

	testing.expect_value(t, count_kind(&list, .Circle), len(graph.nodes))
	testing.expect_value(t, len(graph.nodes), 3)
}

@(test)
clicking_a_node_selects_that_node :: proc(t: ^testing.T) {
	// The property docs/07 protects: hit testing uses the same transform as
	// drawing, so a click lands on what the user sees.
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	state := map_state(nil, nil)

	for node in graph.nodes {
		x, y := ui.map_position(state, node.x, node.y)
		entity, found := ui.hit_test_map(state, &graph, x, y)

		testing.expectf(t, found, "no hit at the centre of node %d", u64(node.entity))
		testing.expectf(
			t,
			entity == node.entity,
			"clicking node %d selected %d",
			u64(node.entity),
			u64(entity),
		)
	}
}

@(test)
clicking_empty_map_space_selects_nothing :: proc(t: ^testing.T) {
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	state := map_state(nil, nil)

	// A corner, well outside any node's radius.
	_, found := ui.hit_test_map(state, &graph, MAP_BOUNDS.x0 + 1, MAP_BOUNDS.y0 + 1)
	testing.expect(t, !found)
}

@(test)
a_filter_hides_nodes_from_drawing_and_hit_testing :: proc(t: ^testing.T) {
	// A node the filter hid must not be selectable either, or a click would
	// land on something invisible.
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	state := map_state(nil, nil)
	state.filter = analysis.Node_Filter{.Read}

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, MAP_BOUNDS)
	ui.draw_map(&list, state, &graph, &builder.trace)

	// Only the read file passes.
	testing.expect_value(t, count_kind(&list, .Circle), 1)

	// An edited-only node is not selectable under this filter.
	for node in graph.nodes {
		if node.activity.reads > 0 {
			continue
		}
		x, y := ui.map_position(state, node.x, node.y)
		_, found := ui.hit_test_map(state, &graph, x, y)
		testing.expectf(
			t,
			!found,
			"filtered-out node %d must not be selectable",
			u64(node.entity),
		)
	}
}

@(test)
an_empty_map_explains_itself :: proc(t: ^testing.T) {
	// docs/01: empty panels explain why they are empty.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, MAP_BOUNDS)

	ui.draw_map(&list, map_state(&fonts, atlas), &graph, &builder.trace)

	testing.expect(t, count_kind(&list, .Glyph) > 0, "an empty map must say why")
	testing.expect_value(t, count_kind(&list, .Circle), 0)
}

@(test)
a_failing_file_is_coloured_as_a_failure :: proc(t: ^testing.T) {
	// A file involved in a failure is what a user is looking for. Averaging
	// its colour with its other activity would hide it.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity_named(&builder, .Path, "src/broken.odin")
	add(&builder, .File_Modify, SECOND, primary = path)
	add_diagnostic_at(&builder, path, 3, "type mismatch")

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	testing.expect(t, len(graph.nodes) > 0)
	color := ui.node_color(ui.DARK_MAP, graph.nodes[0])
	testing.expect_value(t, color, ui.DARK_MAP.node_failed)
}

@(test)
selection_draws_a_ring_above_the_node :: proc(t: ^testing.T) {
	// A ring under its node would be invisible.
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	state := map_state(nil, nil)
	state.selection = graph.nodes[0].entity

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, MAP_BOUNDS)
	ui.draw_map(&list, state, &graph, &builder.trace)

	testing.expect_value(t, count_kind(&list, .Rect_Outline), 1)
	testing.expect(t, ui.MAP_LAYER_MARKS > ui.MAP_LAYER_NODES)
}

@(test)
labels_are_limited_when_nodes_crowd :: proc(t: ^testing.T) {
	// docs/07: label only selected, pinned, or sufficiently separated nodes.
	// Labelling everything in a dense graph produces overlapping noise.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	// Enough nodes that the layout must crowd them within the panel.
	for index in 0 ..< 80 {
		path := add_entity_named(&builder, .Path, "src/module.odin")
		add(&builder, .File_Modify, i64(index) * SECOND, primary = path)
	}

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)
	testing.expect_value(t, len(graph.nodes), 80)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, MAP_BOUNDS)
	ui.draw_map(&list, map_state(&fonts, atlas), &graph, &builder.trace)

	// "module.odin" is 11 glyphs; labelling all eighty would be 880.
	glyphs := count_kind(&list, .Glyph)
	testing.expectf(
		t,
		glyphs < 80 * 11,
		"a crowded map labelled everything: %d glyphs",
		glyphs,
	)
	testing.expect(t, glyphs > 0, "some labels must still appear")
}

@(test)
a_selected_node_is_labelled_however_crowded :: proc(t: ^testing.T) {
	// The separation rule has exceptions for exactly the nodes a user is
	// attending to, or focusing a node in a dense region would hide its name.
	fonts: render.Font_Set
	if !load_ui_font(&fonts) {
		testing.fail_now(t, "no system font available to test against")
	}
	defer render.font_set_destroy(&fonts)
	atlas := render.get_atlas(&fonts, render.Atlas_Key{font = .Interface, size = 12, scale = 1})

	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 60 {
		path := add_entity_named(&builder, .Path, "src/module.odin")
		add(&builder, .File_Modify, i64(index) * SECOND, primary = path)
	}

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	unselected: render.Draw_List
	render.draw_list_init(&unselected)
	defer render.draw_list_destroy(&unselected)
	render.draw_list_reset(&unselected, MAP_BOUNDS)
	ui.draw_map(&unselected, map_state(&fonts, atlas), &graph, &builder.trace)

	// Select a node the separation rule would otherwise skip: the last one,
	// which is least active and therefore last in label priority.
	state := map_state(&fonts, atlas)
	state.selection = graph.nodes[len(graph.nodes) - 1].entity

	selected: render.Draw_List
	render.draw_list_init(&selected)
	defer render.draw_list_destroy(&selected)
	render.draw_list_reset(&selected, MAP_BOUNDS)
	ui.draw_map(&selected, state, &graph, &builder.trace)

	testing.expect(
		t,
		count_kind(&selected, .Glyph) >= count_kind(&unselected, .Glyph),
		"selecting a node must not lose its label",
	)
}

@(test)
the_map_panel_clips_to_its_bounds :: proc(t: ^testing.T) {
	builder: Builder
	build_map_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	list: render.Draw_List
	render.draw_list_init(&list)
	defer render.draw_list_destroy(&list)
	render.draw_list_reset(&list, render.Rect{0, 0, 1920, 1080})

	ui.draw_map(&list, map_state(nil, nil), &graph, &builder.trace)

	for command in list.commands {
		clip := list.clips[command.clip]
		testing.expect(
			t,
			clip.x1 <= MAP_BOUNDS.x1 && clip.y1 <= MAP_BOUNDS.y1,
			"every command must be clipped to the panel",
		)
	}
}

@(test)
nodes_stay_inside_the_panel :: proc(t: ^testing.T) {
	// A node drawn half outside would be clipped into a shape the user cannot
	// identify or reliably click.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 40 {
		path := add_entity_named(&builder, .Path, "f.odin")
		add(&builder, .File_Modify, i64(index) * SECOND, primary = path)
	}

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	state := map_state(nil, nil)
	for node in graph.nodes {
		x, y := ui.map_position(state, node.x, node.y)
		testing.expectf(
			t,
			x >= MAP_BOUNDS.x0 && x <= MAP_BOUNDS.x1,
			"node %d at x=%f escaped the panel",
			u64(node.entity),
			x,
		)
		testing.expectf(
			t,
			y >= MAP_BOUNDS.y0 && y <= MAP_BOUNDS.y1,
			"node %d at y=%f escaped the panel",
			u64(node.entity),
			y,
		)
	}
}

@(test)
short_names_trim_directories :: proc(t: ^testing.T) {
	// A map is read at a glance; full paths in a dense graph are noise. The
	// inspector shows the whole path when a node is selected.
	testing.expect_value(t, ui.short_name("src/trace/codec/reader.odin"), "reader.odin")
	testing.expect_value(t, ui.short_name("README.md"), "README.md")
	testing.expect_value(t, ui.short_name(""), "")
	// A trailing separator has no final component to take.
	testing.expect_value(t, ui.short_name("src/"), "src/")
}

@(test)
edge_colour_reflects_the_evidence_level :: proc(t: ^testing.T) {
	// docs/06 requires the interface to identify the evidence level, so a
	// derived relationship must look weaker than a recorded one.
	explicit := ui.edge_color(ui.DARK_MAP, .Explicit)
	reconstructed := ui.edge_color(ui.DARK_MAP, .Reconstructed)
	inferred := ui.edge_color(ui.DARK_MAP, .Inferred)

	testing.expect(t, explicit != reconstructed)
	testing.expect(t, reconstructed != inferred)
	testing.expect(t, explicit != inferred)
}
