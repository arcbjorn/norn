package ui

import "core:math"

import "src:analysis"
import "src:render"
import "src:trace/codec"
import "src:trace/model"

// The repository map.
//
// docs/01-user-experience.md: a two-dimensional file and symbol map, filtered
// by activity, sized by count or duration, coloured by outcome or recency,
// with pinned nodes and a focused neighbourhood.
//
// docs/07 adds the constraint that governs labelling: "label only selected,
// hovered, pinned, or sufficiently separated nodes." A map that labels
// everything is unreadable at any useful node count, and the labels overlap
// into illegibility exactly when the graph is dense enough to need them.

// Map_Theme collects the panel's colours.
Map_Theme :: struct {
	background: render.Color,
	border:     render.Color,
	heading:    render.Color,
	label:      render.Color,
	muted:      render.Color,

	// Edge colour by evidence level, so a derived relationship is visibly
	// weaker than a recorded one.
	explicit_edge:      render.Color,
	reconstructed_edge: render.Color,
	inferred_edge:      render.Color,

	// Node colour by outcome, per docs/01's colour-by-outcome option.
	node_read:   render.Color,
	node_edited: render.Color,
	node_tested: render.Color,
	node_failed: render.Color,

	selection: render.Color,
	pin:       render.Color,
}

DARK_MAP :: Map_Theme {
	background         = render.Color{0.10, 0.11, 0.14, 1.0},
	border             = render.Color{0.20, 0.21, 0.25, 1.0},
	heading            = render.Color{0.94, 0.95, 0.97, 1.0},
	label              = render.Color{0.78, 0.80, 0.85, 1.0},
	muted              = render.Color{0.50, 0.53, 0.60, 1.0},
	explicit_edge      = render.Color{0.38, 0.42, 0.50, 1.0},
	reconstructed_edge = render.Color{0.30, 0.33, 0.42, 1.0},
	inferred_edge      = render.Color{0.42, 0.36, 0.28, 1.0},
	node_read          = render.Color{0.42, 0.62, 0.92, 1.0},
	node_edited        = render.Color{0.45, 0.78, 0.55, 1.0},
	node_tested        = render.Color{0.40, 0.80, 0.78, 1.0},
	node_failed        = render.Color{0.95, 0.35, 0.35, 1.0},
	selection          = render.Color{1.00, 1.00, 1.00, 1.0},
	pin                = render.Color{0.92, 0.72, 0.36, 1.0},
}

// Map_Layer ordering. Edges below nodes so a line never crosses a circle it
// connects; labels above everything so they stay legible.
MAP_LAYER_EDGES  :: u16(0)
MAP_LAYER_NODES  :: u16(1)
MAP_LAYER_MARKS  :: u16(2)
MAP_LAYER_LABELS :: u16(3)

// Node radius bounds, in logical pixels before scaling.
//
// A minimum so a single-touch file is still clickable, and a maximum so a
// heavily edited file does not swallow its neighbours.
MIN_NODE_RADIUS :: f32(4)
MAX_NODE_RADIUS :: f32(14)

// LABEL_SEPARATION is how far apart two nodes must be for both to be labelled.
//
// docs/07's "sufficiently separated" made concrete. Below this, one label
// would overlap the other and neither would be readable, so only the more
// active node gets one.
LABEL_SEPARATION :: f32(70)

// Map_State is the panel's layout and view.
Map_State :: struct {
	bounds: render.Rect,
	theme:  Map_Theme,
	fonts:  ^render.Font_Set,
	atlas:  ^render.Atlas,
	scale:  f32,

	// The selected node, drawn with a ring.
	selection: model.Entity_Id,
	// Restrict to the neighbourhood of this entity, when set.
	focus:     model.Entity_Id,
	has_focus: bool,

	filter: analysis.Node_Filter,
	// Size nodes by cumulative duration rather than activity count.
	size_by_duration: bool,
}

// node_color returns a node's colour by outcome.
//
// Failure wins over everything else: a file involved in a failure is the one a
// user is looking for, and averaging its colour with its other activity would
// hide it.
node_color :: proc "contextless" (theme: Map_Theme, node: analysis.Node) -> render.Color {
	if node.activity.failures > 0 {
		return theme.node_failed
	}
	if node.activity.tests > 0 {
		return theme.node_tested
	}
	if node.activity.edits > 0 {
		return theme.node_edited
	}
	return theme.node_read
}

// edge_color returns an edge's colour by evidence level.
edge_color :: proc "contextless" (theme: Map_Theme, origin: model.Edge_Origin) -> render.Color {
	switch origin {
	case .Explicit:      return theme.explicit_edge
	case .Reconstructed: return theme.reconstructed_edge
	case .Inferred:      return theme.inferred_edge
	}
	return theme.muted
}

// draw_map renders the repository map.
draw_map :: proc(
	list: ^render.Draw_List,
	state: Map_State,
	graph: ^analysis.Graph,
	trace: ^codec.Trace,
) {
	previous_clip := render.push_clip(list, state.bounds)
	defer render.pop_clip(list, previous_clip)

	render.fill_rect(list, state.bounds, state.theme.background)
	render.draw_line(
		list,
		state.bounds.x0,
		state.bounds.y0,
		state.bounds.x0,
		state.bounds.y1,
		state.theme.border,
	)

	if len(graph.nodes) == 0 {
		// docs/01: an empty panel explains why it is empty.
		if state.fonts != nil && state.atlas != nil {
			render.draw_text_clipped(
				list,
				state.fonts,
				state.atlas,
				"No files were touched in this session.",
				state.bounds.x0 + 12 * state.scale,
				state.bounds.y0 + 12 * state.scale,
				render.rect_width(state.bounds) - 24 * state.scale,
				state.theme.muted,
			)
		}
		return
	}

	visible := select_visible(state, graph)
	defer delete(visible)

	draw_map_edges(list, state, graph, visible)
	draw_map_nodes(list, state, graph, visible)
	draw_map_labels(list, state, graph, trace, visible)
}

// select_visible resolves the filter and focus into a set of node indices.
@(private)
select_visible :: proc(state: Map_State, graph: ^analysis.Graph) -> map[int]bool {
	result := make(map[int]bool, len(graph.nodes), context.temp_allocator)

	// A focused neighbourhood narrows first, then the filter applies within
	// it. The other order would show unfiltered neighbours of a focus the
	// filter had already excluded.
	if state.has_focus {
		nearby := analysis.neighbourhood(graph, state.focus, context.temp_allocator)
		defer delete(nearby)

		for index in nearby {
			if analysis.matches(graph.nodes[index], state.filter) {
				result[index] = true
			}
		}
		return result
	}

	for index in 0 ..< len(graph.nodes) {
		if analysis.matches(graph.nodes[index], state.filter) {
			result[index] = true
		}
	}
	return result
}

// map_position converts a layout coordinate to a pixel position.
//
// The same transform is used for drawing and hit testing, for the reason
// docs/07 gives about the timeline: two formulas drift, and the symptom is a
// click selecting a node next to the one under the cursor.
map_position :: proc "contextless" (state: Map_State, x, y: f32) -> (px: f32, py: f32) {
	// A margin keeps a node at the layout's extreme from being half outside
	// the panel, since a node is drawn as a circle around its position.
	margin := MAX_NODE_RADIUS * state.scale + 4
	width := render.rect_width(state.bounds) - margin * 2
	height := render.rect_height(state.bounds) - margin * 2

	centre_x := state.bounds.x0 + margin + width * 0.5
	centre_y := state.bounds.y0 + margin + height * 0.5
	extent := min(width, height) * 0.5

	return centre_x + x * extent, centre_y + y * extent
}

// node_radius returns a node's drawn radius.
//
// The square root of the weight rather than the weight itself, so a file with
// a hundred edits is not twenty-five times the area of one with four. Area
// tracking magnitude too closely makes the busiest node dominate the map.
node_radius :: proc "contextless" (state: Map_State, node: analysis.Node, peak: int) -> f32 {
	weight := analysis.activity_weight(node)
	if state.size_by_duration {
		// Duration in milliseconds, so a long command is comparable to a
		// handful of edits rather than dwarfing them by a factor of a million.
		weight = int(node.activity.duration_ns / 1_000_000)
	}
	if peak <= 0 || weight <= 0 {
		return MIN_NODE_RADIUS * state.scale
	}

	fraction := math.sqrt(f32(weight) / f32(peak))
	radius := MIN_NODE_RADIUS + (MAX_NODE_RADIUS - MIN_NODE_RADIUS) * fraction
	return radius * state.scale
}

@(private)
peak_weight :: proc(state: Map_State, graph: ^analysis.Graph) -> int {
	peak := 0
	for node in graph.nodes {
		weight := analysis.activity_weight(node)
		if state.size_by_duration {
			weight = int(node.activity.duration_ns / 1_000_000)
		}
		if weight > peak {
			peak = weight
		}
	}
	return peak
}

@(private)
draw_map_edges :: proc(
	list: ^render.Draw_List,
	state: Map_State,
	graph: ^analysis.Graph,
	visible: map[int]bool,
) {
	previous := render.set_layer(list, MAP_LAYER_EDGES)
	defer render.set_layer(list, previous)

	for edge in graph.edges {
		// An edge to a hidden node would point at nothing.
		if !visible[edge.from] || !visible[edge.to] {
			continue
		}

		from_x, from_y := map_position(state, graph.nodes[edge.from].x, graph.nodes[edge.from].y)
		to_x, to_y := map_position(state, graph.nodes[edge.to].x, graph.nodes[edge.to].y)

		render.draw_line(
			list,
			from_x,
			from_y,
			to_x,
			to_y,
			edge_color(state.theme, edge.origin),
		)
	}
}

@(private)
draw_map_nodes :: proc(
	list: ^render.Draw_List,
	state: Map_State,
	graph: ^analysis.Graph,
	visible: map[int]bool,
) {
	peak := peak_weight(state, graph)

	previous := render.set_layer(list, MAP_LAYER_NODES)
	for index in 0 ..< len(graph.nodes) {
		if !visible[index] {
			continue
		}
		node := graph.nodes[index]
		x, y := map_position(state, node.x, node.y)
		render.draw_circle(list, x, y, node_radius(state, node, peak), node_color(state.theme, node))
	}
	render.set_layer(list, previous)

	// Selection and pins above the nodes, so a ring is never hidden by a
	// neighbour drawn afterwards.
	previous = render.set_layer(list, MAP_LAYER_MARKS)
	defer render.set_layer(list, previous)

	for index in 0 ..< len(graph.nodes) {
		if !visible[index] {
			continue
		}
		node := graph.nodes[index]
		x, y := map_position(state, node.x, node.y)
		radius := node_radius(state, node, peak)

		if node.entity == state.selection {
			render.stroke_rect(
				list,
				render.Rect {
					x0 = x - radius - 3,
					y0 = y - radius - 3,
					x1 = x + radius + 3,
					y1 = y + radius + 3,
				},
				state.theme.selection,
				2,
			)
		}
		if node.pinned {
			// A small mark rather than a colour change, so a pinned node still
			// shows its outcome colour.
			render.fill_rect(
				list,
				render.Rect{x0 = x + radius, y0 = y - radius - 2, x1 = x + radius + 4, y1 = y - radius + 2},
				state.theme.pin,
			)
		}
	}
}

// draw_map_labels labels the nodes docs/07 permits.
//
// Selected and pinned nodes always, plus any node far enough from every
// already-labelled node that its text will not overlap. Walking in descending
// activity means the busiest nodes claim their labels first, which is the
// useful priority when a region is too dense for all of them.
@(private)
draw_map_labels :: proc(
	list: ^render.Draw_List,
	state: Map_State,
	graph: ^analysis.Graph,
	trace: ^codec.Trace,
	visible: map[int]bool,
) {
	if state.fonts == nil || state.atlas == nil {
		return
	}

	previous := render.set_layer(list, MAP_LAYER_LABELS)
	defer render.set_layer(list, previous)

	peak := peak_weight(state, graph)
	separation := LABEL_SEPARATION * state.scale

	// Positions already labelled, so overlap can be tested without a second
	// pass over the draw list.
	claimed := make([dynamic][2]f32, 0, 32, context.temp_allocator)
	defer delete(claimed)

	// Ordered by descending activity, with the entity identifier breaking
	// ties so the choice of which label survives is deterministic.
	order := make([dynamic]int, 0, len(graph.nodes), context.temp_allocator)
	defer delete(order)
	for index in 0 ..< len(graph.nodes) {
		if visible[index] {
			insert_by_activity(&order, index, graph)
		}
	}

	for index in order {
		node := graph.nodes[index]
		x, y := map_position(state, node.x, node.y)
		radius := node_radius(state, node, peak)

		always := node.entity == state.selection || node.pinned
		if !always {
			too_close := false
			for position in claimed {
				dx := position.x - x
				dy := position.y - y
				if dx * dx + dy * dy < separation * separation {
					too_close = true
					break
				}
			}
			if too_close {
				continue
			}
		}

		label, ok := model.string_get(&trace.strings, node.label)
		if !ok || label == "" {
			continue
		}

		render.draw_text_clipped(
			list,
			state.fonts,
			state.atlas,
			short_name(label),
			x + radius + 4,
			y - render.line_height(state.atlas) * 0.5,
			separation,
			state.theme.label if !always else state.theme.heading,
		)
		append(&claimed, [2]f32{x, y})
	}
}

// insert_by_activity inserts an index keeping the list ordered by activity.
//
// Insertion into a small list rather than a sort call, because the node budget
// bounds this at a few hundred and the ordering must be stable and
// deterministic rather than merely fast. The entity identifier breaks ties, so
// which of two equally active nodes keeps its label does not depend on
// iteration order.
@(private)
insert_by_activity :: proc(order: ^[dynamic]int, index: int, graph: ^analysis.Graph) {
	weight := analysis.activity_weight(graph.nodes[index])

	append(order, index)
	position := len(order) - 1
	for position > 0 {
		previous := order[position - 1]
		previous_weight := analysis.activity_weight(graph.nodes[previous])
		if previous_weight > weight {
			break
		}
		if previous_weight == weight && graph.nodes[previous].entity < graph.nodes[index].entity {
			break
		}
		order[position] = previous
		position -= 1
	}
	order[position] = index
}

// short_name trims a path to its final component for display.
//
// A map is read at a glance, and full paths in a dense graph become
// overlapping noise. The inspector shows the whole path when a node is
// selected, so nothing is lost.
short_name :: proc "contextless" (path: string) -> string {
	last := -1
	for index in 0 ..< len(path) {
		if path[index] == '/' {
			last = index
		}
	}
	if last < 0 || last == len(path) - 1 {
		return path
	}
	return path[last + 1:]
}

// hit_test_map returns the node under a pixel position.
//
// Uses the same transform and radius as drawing. The nearest node within its
// own radius wins, so overlapping circles select the one whose centre is
// closest rather than whichever happened to be drawn last.
hit_test_map :: proc(
	state: Map_State,
	graph: ^analysis.Graph,
	x, y: f32,
) -> (
	entity: model.Entity_Id,
	found: bool,
) {
	peak := peak_weight(state, graph)
	best := max(f32)
	result := model.NO_ENTITY

	for node in graph.nodes {
		if !analysis.matches(node, state.filter) {
			continue
		}
		node_x, node_y := map_position(state, node.x, node.y)
		radius := node_radius(state, node, peak)

		dx := node_x - x
		dy := node_y - y
		distance_squared := dx * dx + dy * dy
		if distance_squared > radius * radius {
			continue
		}
		if distance_squared < best {
			best = distance_squared
			result = node.entity
		}
	}
	return result, result != model.NO_ENTITY
}
