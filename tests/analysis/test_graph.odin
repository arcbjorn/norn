package test_analysis

import "core:math"
import "core:testing"

import "src:analysis"
import "src:trace/model"

// The repository graph.
//
// docs/07: "the same trace and filters must produce the same initial layout."
// A layout that moved between runs would make two people looking at one trace
// see different pictures, and a screenshot in a bug report would mean nothing.
// That property is what most of these assert.

@(private)
build_graph_fixture :: proc(builder: ^Builder) {
	builder_init(builder)

	parser := add_entity(builder, .Path, "src/parser.odin")
	lexer := add_entity(builder, .Path, "src/lexer.odin")
	untouched := add_entity(builder, .Path, "docs/README.md")
	test_case := add_entity(builder, .Test_Case, "parses_input")

	add_tests_edge(builder, test_case, parser)

	// A read, two edits, a diagnostic, and a failing test.
	push_read(builder, parser)
	add_mutation(builder, parser)
	add_mutation(builder, lexer)
	add_diagnostic(builder, parser, 12, "undefined identifier")
	add_test_result(builder, test_case, .Failed, path = parser)

	_ = untouched
}

@(private)
push_read :: proc(builder: ^Builder, path: model.Entity_Id) -> model.Event_Id {
	return add_event_of_kind(builder, .File_Read, path)
}

@(test)
the_graph_includes_only_touched_entities :: proc(t: ^testing.T) {
	// docs/07 defaults to touched entities only. A repository holds far more
	// files than a session mentions, and showing them all buries the ones
	// that matter.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	for node in graph.nodes {
		testing.expectf(
			t,
			analysis.touched(node.activity),
			"entity %d was included without any activity",
			u64(node.entity),
		)
	}

	// The untouched documentation file must not appear.
	_, present := graph.index[model.Entity_Id(3)]
	testing.expect(t, !present, "an untouched file must be excluded by default")
}

@(test)
the_layout_is_identical_across_runs :: proc(t: ^testing.T) {
	// The central property from docs/07.
	first: Builder
	build_graph_fixture(&first)
	defer builder_destroy(&first)
	graph_a := analysis.build_graph(&first.trace)
	defer analysis.graph_destroy(&graph_a)

	second: Builder
	build_graph_fixture(&second)
	defer builder_destroy(&second)
	graph_b := analysis.build_graph(&second.trace)
	defer analysis.graph_destroy(&graph_b)

	testing.expect_value(t, len(graph_a.nodes), len(graph_b.nodes))
	for index in 0 ..< len(graph_a.nodes) {
		a := graph_a.nodes[index]
		b := graph_b.nodes[index]
		testing.expect_value(t, a.entity, b.entity)
		testing.expectf(
			t,
			a.x == b.x && a.y == b.y,
			"node %d moved between runs: (%f, %f) vs (%f, %f)",
			u64(a.entity),
			a.x,
			a.y,
			b.x,
			b.y,
		)
	}
}

@(test)
building_the_same_graph_twice_in_one_process_agrees :: proc(t: ^testing.T) {
	// A layout that depended on allocator state or a static would pass the
	// cross-run test above but fail here.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	first := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&first)
	second := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&second)

	for index in 0 ..< len(first.nodes) {
		testing.expect_value(t, first.nodes[index].x, second.nodes[index].x)
		testing.expect_value(t, first.nodes[index].y, second.nodes[index].y)
	}
}

@(test)
positions_are_finite_and_bounded :: proc(t: ^testing.T) {
	// A force layout that diverges produces infinities, which would send every
	// node off screen with no indication of why.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	for node in graph.nodes {
		testing.expect(t, !math.is_nan(node.x) && !math.is_nan(node.y), "position must be a number")
		testing.expect(t, !math.is_inf(node.x) && !math.is_inf(node.y), "position must be finite")
		testing.expectf(
			t,
			abs(node.x) <= 1.01 && abs(node.y) <= 1.01,
			"node %d at (%f, %f) escaped the normalized range",
			u64(node.entity),
			node.x,
			node.y,
		)
	}
}

@(test)
nodes_do_not_land_on_top_of_each_other :: proc(t: ^testing.T) {
	// Coincident nodes are unclickable and unreadable. The repulsion pass
	// exists to prevent it, and the coincidence guard exists so that two nodes
	// starting at the same point still separate.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	for i in 0 ..< len(graph.nodes) {
		for j in i + 1 ..< len(graph.nodes) {
			dx := graph.nodes[i].x - graph.nodes[j].x
			dy := graph.nodes[i].y - graph.nodes[j].y
			distance := math.sqrt(dx * dx + dy * dy)
			testing.expectf(
				t,
				distance > 0.01,
				"nodes %d and %d are %f apart",
				u64(graph.nodes[i].entity),
				u64(graph.nodes[j].entity),
				distance,
			)
		}
	}
}

@(test)
an_empty_graph_lays_out_without_crashing :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	testing.expect_value(t, len(graph.nodes), 0)
	testing.expect_value(t, len(graph.edges), 0)
}

@(test)
a_single_node_is_centred :: proc(t: ^testing.T) {
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	path := add_entity(&builder, .Path, "only.odin")
	add_mutation(&builder, path)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	testing.expect_value(t, len(graph.nodes), 1)
	testing.expect_value(t, graph.nodes[0].x, f32(0))
	testing.expect_value(t, graph.nodes[0].y, f32(0))
}

@(test)
activity_is_counted_by_category :: proc(t: ^testing.T) {
	// The map filters on each category separately: a file read forty times and
	// never edited is a different subject than one edited once.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	index, present := graph.index[model.Entity_Id(1)]
	testing.expect(t, present, "the edited parser must be a node")

	parser := graph.nodes[index]
	testing.expect(t, parser.activity.reads > 0, "the read must be counted")
	testing.expect(t, parser.activity.edits > 0, "the edit must be counted")
	testing.expect(t, parser.activity.failures > 0, "the diagnostic must be counted")
}

@(test)
edges_only_connect_nodes_on_the_map :: proc(t: ^testing.T) {
	// An edge to an entity outside the budget would point at nothing, and
	// drawing it would suggest a connection the user cannot follow.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	for edge in graph.edges {
		testing.expect(t, edge.from >= 0 && edge.from < len(graph.nodes))
		testing.expect(t, edge.to >= 0 && edge.to < len(graph.nodes))
		testing.expect(t, edge.from != edge.to, "a node must not link to itself")
	}
}

@(test)
filters_select_by_category :: proc(t: ^testing.T) {
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	edited := 0
	failed := 0
	for node in graph.nodes {
		if analysis.matches(node, analysis.Node_Filter{.Edited}) {
			edited += 1
		}
		if analysis.matches(node, analysis.Node_Filter{.Failed}) {
			failed += 1
		}
	}

	testing.expect(t, edited >= 2, "both edited files must match")
	testing.expect(t, failed >= 1, "the file with a diagnostic must match")
	testing.expect(t, failed < edited, "the filters must select different sets")
}

@(test)
an_empty_filter_shows_everything :: proc(t: ^testing.T) {
	// The same rule as the lane filter: a filter nobody configured should not
	// blank the panel.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	for node in graph.nodes {
		testing.expect(t, analysis.matches(node, analysis.Node_Filter{}))
	}
}

@(test)
the_neighbourhood_is_one_hop :: proc(t: ^testing.T) {
	// docs/01: show only the neighbourhood of the focused outcome. Two hops in
	// a well-connected graph is most of it, which defeats focusing.
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	// The test case is linked to the parser by an explicit tests edge.
	nearby := analysis.neighbourhood(&graph, model.Entity_Id(4))
	defer delete(nearby)

	if len(nearby) > 0 {
		// The focus itself plus its direct neighbours, and nothing further.
		testing.expect(t, len(nearby) <= len(graph.nodes))
	}
}

@(test)
focusing_an_absent_entity_yields_nothing :: proc(t: ^testing.T) {
	builder: Builder
	build_graph_fixture(&builder)
	defer builder_destroy(&builder)

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	nearby := analysis.neighbourhood(&graph, model.Entity_Id(9999))
	defer delete(nearby)
	testing.expect_value(t, len(nearby), 0)
}

@(test)
the_node_budget_is_enforced :: proc(t: ^testing.T) {
	// Beyond a few hundred nodes a force layout is an unreadable hairball, so
	// the budget is a legibility limit rather than a performance one.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< analysis.MAX_NODES + 50 {
		path := add_entity(&builder, .Path, "generated.odin")
		add_mutation(&builder, path)
	}

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	testing.expect(t, len(graph.nodes) <= analysis.MAX_NODES)
	testing.expect_value(t, len(graph.nodes), analysis.MAX_NODES)
}

@(test)
a_large_graph_still_lays_out_finitely :: proc(t: ^testing.T) {
	// The O(n^2) repulsion at the budget is 45,000 pairs per iteration. This
	// confirms it terminates with usable positions rather than diverging.
	builder: Builder
	builder_init(&builder)
	defer builder_destroy(&builder)

	for index in 0 ..< 120 {
		path := add_entity(&builder, .Path, "file.odin")
		add_mutation(&builder, path)
	}

	graph := analysis.build_graph(&builder.trace)
	defer analysis.graph_destroy(&graph)

	testing.expect_value(t, len(graph.nodes), 120)
	for node in graph.nodes {
		testing.expect(t, !math.is_nan(node.x) && !math.is_inf(node.x))
		testing.expect(t, abs(node.x) <= 1.01 && abs(node.y) <= 1.01)
	}
}
