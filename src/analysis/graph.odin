package analysis

import "core:math"

import "src:trace/codec"
import "src:trace/model"

// The repository graph.
//
// docs/01-user-experience.md: nodes represent files or symbols, edges
// represent recorded or inferred relationships, and the map filters by
// touched, read, edited, tested, or failed.
//
// docs/07 adds the property that shapes the layout: "the same trace and
// filters must produce the same initial layout." A layout that moved between
// runs would make two people looking at one trace see different pictures, and
// would make a screenshot in a bug report meaningless. Everything here is
// therefore seeded from stable entity identifiers and iterated a fixed number
// of times — no clock, no random source, no map iteration order.

// Activity records what a session did to one entity.
//
// Counted separately rather than summed because the map filters on each: a
// file that was read forty times and never edited is a different subject than
// one edited once.
Activity :: struct {
	reads:     int,
	edits:     int,
	tests:     int,
	failures:  int,
	// Total duration of events naming this entity, for the size-by-duration
	// option in docs/01.
	duration_ns: i64,
	// Sequence of the last event naming it, for colour-by-recency.
	last_sequence: model.Sequence,
}

// touched reports whether a session interacted with an entity at all.
//
// docs/07 defaults the map to touched entities only, because a repository
// contains far more files than any one session mentions and showing them all
// would bury the ones that matter.
touched :: proc "contextless" (activity: Activity) -> bool {
	return activity.reads > 0 || activity.edits > 0 || activity.tests > 0
}

// Node is one entity positioned on the map.
Node :: struct {
	entity: model.Entity_Id,
	kind:   model.Entity_Kind,
	label:  model.String_Id,

	activity: Activity,

	// Layout position in unit coordinates, roughly within [-1, 1]. The panel
	// maps these to pixels, so the layout is independent of panel size.
	x, y: f32,

	// Set when the user pinned this node. docs/07 requires pinned nodes to
	// stay stable, so the layout leaves them where they are.
	pinned: bool,
}

// Graph_Edge connects two nodes.
//
// Indices into the node slice rather than entity identifiers, because the
// layout walks edges far more often than it looks anything up.
Graph_Edge :: struct {
	from:   int,
	to:     int,
	kind:   model.Edge_Kind,
	origin: model.Edge_Origin,
}

// Graph is the built map.
Graph :: struct {
	nodes: [dynamic]Node,
	edges: [dynamic]Graph_Edge,
	// Entity identifier to node index, for hit testing and focus.
	index: map[model.Entity_Id]int,
}

graph_destroy :: proc(graph: ^Graph) {
	delete(graph.nodes)
	delete(graph.edges)
	delete(graph.index)
	graph^ = {}
}

// MAX_NODES is the visible-node budget docs/07 requires.
//
// Beyond a few hundred nodes a force-directed layout is an unreadable hairball
// regardless of how long it is iterated, so the budget is a legibility limit
// rather than a performance one. Entities are admitted in descending activity,
// so the ones a session actually worked on survive the cut.
MAX_NODES :: 300

// build_graph constructs the map for a trace.
//
// Only path and symbol entities become nodes: docs/01 specifies a file and
// symbol map, and adding commands or actors would make it a different diagram
// than the one it describes.
build_graph :: proc(
	trace: ^codec.Trace,
	touched_only := true,
	allocator := context.allocator,
) -> Graph {
	graph := Graph {
		nodes = make([dynamic]Node, 0, 64, allocator),
		edges = make([dynamic]Graph_Edge, 0, 128, allocator),
		index = make(map[model.Entity_Id]int, 64, allocator),
	}

	activity := make(map[model.Entity_Id]Activity, 64, context.temp_allocator)
	defer delete(activity)

	collect_activity(trace, &activity)

	// Entities are walked in identifier order, not map order, so the node
	// slice is built identically on every run. docs/10 forbids relying on map
	// iteration order and this is exactly why.
	for entity in trace.entities {
		if entity.kind != .Path && entity.kind != .Symbol {
			continue
		}
		record := activity[entity.id]
		if touched_only && !touched(record) {
			continue
		}
		if len(graph.nodes) >= MAX_NODES {
			break
		}

		graph.index[entity.id] = len(graph.nodes)
		append(
			&graph.nodes,
			Node {
				entity = entity.id,
				kind = entity.kind,
				label = entity.name,
				activity = record,
			},
		)
	}

	build_graph_edges(trace, &graph)
	layout_graph(&graph)
	return graph
}

@(private)
collect_activity :: proc(trace: ^codec.Trace, activity: ^map[model.Entity_Id]Activity) {
	for event in trace.events {
		subject := event.primary_entity_id
		if subject == model.NO_ENTITY {
			continue
		}

		record := activity[subject]
		record.last_sequence = event.sequence
		if model.has_duration(event) && event.duration_ns > 0 {
			record.duration_ns += event.duration_ns
		}

		#partial switch event.kind {
		case .File_Read, .Directory_Observe:
			record.reads += 1
		case .File_Create, .File_Modify, .File_Delete, .File_Rename:
			record.edits += 1
		case .Test_Case_Result, .Test_Run_End:
			record.tests += 1
		}

		activity[subject] = record
	}

	// Diagnostics and failing tests mark the paths they name, which is what
	// the colour-by-outcome option reads.
	for event in trace.events {
		#partial switch event.kind {
		case .Diagnostic:
			payload, ok := model.get_diagnostic(&trace.payloads, event.payload)
			if !ok || payload.path == model.NO_ENTITY || payload.severity < .Error {
				continue
			}
			record := activity[payload.path]
			record.failures += 1
			activity[payload.path] = record

		case .Test_Case_Result:
			payload, ok := model.get_test(&trace.payloads, event.payload)
			if !ok || !model.is_failure(payload.status) {
				continue
			}
			// A failing test marks the file it named, when it named one.
			if payload.path != model.NO_ENTITY {
				record := activity[payload.path]
				record.failures += 1
				activity[payload.path] = record
			}
		}
	}
}

// build_graph_edges converts trace edges into map edges.
//
// Only relationships between two nodes on the map survive. An edge to an
// entity outside the budget would point at nothing, and drawing it would
// suggest a connection the user cannot follow.
@(private)
build_graph_edges :: proc(trace: ^codec.Trace, graph: ^Graph) {
	for edge in trace.edges {
		if edge.from.kind != .Entity || edge.to.kind != .Entity {
			continue
		}
		from, from_present := graph.index[model.Entity_Id(edge.from.id)]
		to, to_present := graph.index[model.Entity_Id(edge.to.id)]
		if !from_present || !to_present || from == to {
			continue
		}
		append(
			&graph.edges,
			Graph_Edge{from = from, to = to, kind = edge.kind, origin = edge.origin},
		)
	}
}

// LAYOUT_ITERATIONS is how many force steps the layout runs.
//
// Fixed rather than convergence-based: a convergence test would make the
// result depend on floating-point details that differ between builds, and
// docs/07 requires the same trace to produce the same layout.
LAYOUT_ITERATIONS :: 240

// layout_graph positions nodes with a deterministic force-directed pass.
//
// Seeded from entity identifiers rather than a random source, so the initial
// arrangement — and therefore the final one — is a function of the trace.
layout_graph :: proc(graph: ^Graph) {
	count := len(graph.nodes)
	if count == 0 {
		return
	}
	if count == 1 {
		graph.nodes[0].x = 0
		graph.nodes[0].y = 0
		return
	}

	seed_positions(graph)

	// Velocities are held across iterations so the layout settles rather than
	// oscillating between two arrangements.
	velocity := make([][2]f32, count, context.temp_allocator)
	defer delete(velocity, context.temp_allocator)

	// A repulsion strength that scales with node count keeps a large graph
	// from collapsing into the middle and a small one from flying apart.
	repulsion := 0.35 / f32(count)
	attraction := f32(0.02)
	damping := f32(0.85)

	for _ in 0 ..< LAYOUT_ITERATIONS {
		// Every pair repels. O(n^2), which the node budget makes acceptable:
		// 300 nodes is 45,000 pairs per iteration, and the layout runs once
		// when a trace opens rather than per frame.
		for i in 0 ..< count {
			for j in i + 1 ..< count {
				dx := graph.nodes[i].x - graph.nodes[j].x
				dy := graph.nodes[i].y - graph.nodes[j].y
				distance_squared := dx * dx + dy * dy

				// Coincident nodes would divide by zero. Nudging them apart
				// deterministically — by index, not randomly — keeps the
				// layout reproducible.
				if distance_squared < 0.0001 {
					dx = f32(i - j) * 0.001
					dy = f32(i + j) * 0.001
					distance_squared = dx * dx + dy * dy
					if distance_squared < 0.0000001 {
						continue
					}
				}

				force := repulsion / distance_squared
				distance := math.sqrt(distance_squared)
				fx := dx / distance * force
				fy := dy / distance * force

				velocity[i] += {fx, fy}
				velocity[j] -= {fx, fy}
			}
		}

		// Connected nodes attract, which is what groups a file with the tests
		// and diagnostics that name it.
		for edge in graph.edges {
			dx := graph.nodes[edge.to].x - graph.nodes[edge.from].x
			dy := graph.nodes[edge.to].y - graph.nodes[edge.from].y

			velocity[edge.from] += {dx * attraction, dy * attraction}
			velocity[edge.to] -= {dx * attraction, dy * attraction}
		}

		for index in 0 ..< count {
			// docs/07: pinned nodes stay stable. A pinned node still exerts
			// force on its neighbours but does not move itself.
			if graph.nodes[index].pinned {
				velocity[index] = {0, 0}
				continue
			}
			graph.nodes[index].x += velocity[index].x
			graph.nodes[index].y += velocity[index].y
			velocity[index] *= damping
		}
	}

	normalize_positions(graph)
}

// seed_positions places nodes on a spiral derived from their identifiers.
//
// A spiral rather than a circle so that nodes do not start equidistant, which
// leaves the repulsion step with no gradient to work from. The angle comes
// from the entity identifier, so the same entity starts in the same place in
// every run and in every session that contains it.
@(private)
seed_positions :: proc(graph: ^Graph) {
	// The golden angle spreads successive indices as evenly as possible,
	// which gives the force pass a well-distributed starting point.
	GOLDEN_ANGLE :: f32(2.39996323)

	for index in 0 ..< len(graph.nodes) {
		// Mixing in the entity identifier means a node's start depends on
		// which entity it is, not merely on its position in the slice, so
		// adding an unrelated file does not reshuffle everything.
		entity := u64(graph.nodes[index].entity)
		offset := f32(entity % 97) / 97.0

		angle := GOLDEN_ANGLE * (f32(index) + offset)
		radius := math.sqrt(f32(index) + 0.5) / math.sqrt(f32(len(graph.nodes)))

		graph.nodes[index].x = math.cos(angle) * radius
		graph.nodes[index].y = math.sin(angle) * radius
	}
}

// normalize_positions rescales the layout into roughly [-1, 1].
//
// The force pass has no absolute scale, so without this a graph of five nodes
// and one of two hundred would need different camera settings to view.
@(private)
normalize_positions :: proc(graph: ^Graph) {
	if len(graph.nodes) == 0 {
		return
	}

	min_x := graph.nodes[0].x
	max_x := min_x
	min_y := graph.nodes[0].y
	max_y := min_y

	for node in graph.nodes {
		min_x = min(min_x, node.x)
		max_x = max(max_x, node.x)
		min_y = min(min_y, node.y)
		max_y = max(max_y, node.y)
	}

	width := max_x - min_x
	height := max_y - min_y
	extent := max(width, height)
	if extent < 0.0001 {
		// Every node landed in the same place, which happens only for a graph
		// with no edges and one node. Leave them centred.
		for index in 0 ..< len(graph.nodes) {
			graph.nodes[index].x = 0
			graph.nodes[index].y = 0
		}
		return
	}

	centre_x := (min_x + max_x) * 0.5
	centre_y := (min_y + max_y) * 0.5
	scale := 1.8 / extent

	for index in 0 ..< len(graph.nodes) {
		graph.nodes[index].x = (graph.nodes[index].x - centre_x) * scale
		graph.nodes[index].y = (graph.nodes[index].y - centre_y) * scale
	}
}

// Node_Filter selects which nodes the map shows.
//
// docs/01 lists exactly these categories. An empty set means everything, for
// the same reason the lane filter does: a filter nobody configured should not
// blank the panel.
Node_Filter :: bit_set[Node_Category; u8]

Node_Category :: enum u8 {
	Read   = 0,
	Edited = 1,
	Tested = 2,
	Failed = 3,
}

ALL_CATEGORIES :: Node_Filter{.Read, .Edited, .Tested, .Failed}

// matches reports whether a node passes a filter.
matches :: proc "contextless" (node: Node, filter: Node_Filter) -> bool {
	if filter == {} || filter == ALL_CATEGORIES {
		return true
	}
	if .Read in filter && node.activity.reads > 0 {
		return true
	}
	if .Edited in filter && node.activity.edits > 0 {
		return true
	}
	if .Tested in filter && node.activity.tests > 0 {
		return true
	}
	if .Failed in filter && node.activity.failures > 0 {
		return true
	}
	return false
}

// neighbourhood returns the nodes within one edge of a focus.
//
// docs/01: "show only the neighborhood of the focused outcome." One hop
// because a two-hop neighbourhood in a well-connected graph is most of it,
// which defeats the purpose of focusing.
neighbourhood :: proc(
	graph: ^Graph,
	focus: model.Entity_Id,
	allocator := context.allocator,
) -> map[int]bool {
	result := make(map[int]bool, 16, allocator)

	centre, present := graph.index[focus]
	if !present {
		return result
	}
	result[centre] = true

	for edge in graph.edges {
		if edge.from == centre {
			result[edge.to] = true
		}
		if edge.to == centre {
			result[edge.from] = true
		}
	}
	return result
}

// activity_weight is the size input docs/01 calls "activity count".
activity_weight :: proc "contextless" (node: Node) -> int {
	return node.activity.reads + node.activity.edits + node.activity.tests
}
