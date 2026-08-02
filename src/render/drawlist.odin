package render

// Draw lists.
//
// docs/02-architecture.md: "the renderer receives draw data and owns no
// product state." A draw list is that data — a plain description of what to
// paint, with no reference to a trace, a selection, or a GPU resource.
//
// Keeping it inert has two consequences worth the indirection. Panels can be
// tested by inspecting what they would draw, which is what docs/09 means by
// testing interaction "below the GPU boundary". And the GPU backend can change
// without touching a single panel, because nothing here knows a backend exists.

// Color is straight (non-premultiplied) RGBA in the 0..1 range.
//
// Straight rather than premultiplied because draw lists are written by hand in
// panel code and inspected in tests, and premultiplied values are unreadable
// in both. The backend premultiplies when it uploads.
Color :: distinct [4]f32

TRANSPARENT :: Color{0, 0, 0, 0}

// rgba builds a color from 0..255 components, which is how designers and
// theme files express them.
rgba :: proc "contextless" (r, g, b: u8, a: u8 = 255) -> Color {
	return Color{f32(r) / 255, f32(g) / 255, f32(b) / 255, f32(a) / 255}
}

// with_alpha returns a color at a different opacity.
with_alpha :: proc "contextless" (color: Color, alpha: f32) -> Color {
	result := color
	result.a = alpha
	return result
}

// Rect is an axis-aligned rectangle in logical pixels.
//
// Stored as min and max corners rather than position and size: clipping and
// intersection are the operations performed most often here, and both are
// simpler on corners.
Rect :: struct {
	x0, y0: f32,
	x1, y1: f32,
}

rect_from_size :: proc "contextless" (x, y, width, height: f32) -> Rect {
	return Rect{x0 = x, y0 = y, x1 = x + width, y1 = y + height}
}

rect_width :: proc "contextless" (rect: Rect) -> f32 {
	return rect.x1 - rect.x0
}

rect_height :: proc "contextless" (rect: Rect) -> f32 {
	return rect.y1 - rect.y0
}

rect_is_empty :: proc "contextless" (rect: Rect) -> bool {
	return rect.x1 <= rect.x0 || rect.y1 <= rect.y0
}

rect_contains :: proc "contextless" (rect: Rect, x, y: f32) -> bool {
	return x >= rect.x0 && x <= rect.x1 && y >= rect.y0 && y <= rect.y1
}

// rect_intersect returns the overlap of two rectangles.
//
// An empty result means they do not overlap, which callers test with
// rect_is_empty rather than with a separate boolean.
rect_intersect :: proc "contextless" (a: Rect, b: Rect) -> Rect {
	return Rect {
		x0 = max(a.x0, b.x0),
		y0 = max(a.y0, b.y0),
		x1 = min(a.x1, b.x1),
		y1 = min(a.y1, b.y1),
	}
}

// Command_Kind discriminates the entries in a draw list.
//
// The set is deliberately small, per docs/07. Every panel composes from these
// rather than introducing its own primitive, because each new primitive is a
// new pipeline and a new batching case.
Command_Kind :: enum u8 {
	Rect         = 0,
	Rect_Outline = 1,
	Rounded_Rect = 2,
	Line         = 3,
	Glyph        = 4,
	Textured     = 5,
	Circle       = 6,
}

// Glyph_Ref locates a rasterized glyph in an atlas.
//
// The draw list names the atlas by identifier rather than holding a texture
// handle, so it stays free of GPU types and can be built on a worker thread.
Glyph_Ref :: struct {
	atlas: u32,
	// Texture coordinates in the 0..1 range.
	u0, v0: f32,
	u1, v1: f32,
}

// Command is one primitive to paint.
//
// A tagged struct rather than a union: the fields overlap heavily, a union
// large enough for every variant would be no smaller, and a flat layout keeps
// the batching pass a linear scan over uniform records.
Command :: struct {
	kind:  Command_Kind,
	rect:  Rect,
	color: Color,
	// Secondary color: the border of an outlined rectangle, or the second
	// endpoint's color for a gradient line.
	color2: Color,
	// Corner radius for rounded rectangles, line thickness for lines, and
	// radius for circles.
	extent: f32,
	// Border thickness for outlined rectangles.
	border: f32,
	// Glyph or texture source. `atlas` is zero for untextured primitives.
	source: Glyph_Ref,
	// Index into the draw list's clip stack. Zero is the unclipped root.
	clip: u32,
	// Painter's order within a layer, so a panel can emit in whatever order is
	// convenient and still control what covers what.
	layer: u16,
}

// Draw_List accumulates commands for one frame.
//
// Reused across frames rather than reallocated: docs/02 gives the frame a
// resetting arena, and clearing a dynamic array keeps its capacity so a steady
// workload stops allocating after the first few frames.
Draw_List :: struct {
	commands: [dynamic]Command,
	// Clip rectangles referenced by index. Entry zero is the whole surface.
	clips: [dynamic]Rect,
	// The clip currently applied to appended commands.
	current_clip: u32,
	// The layer currently applied to appended commands.
	current_layer: u16,
}

draw_list_init :: proc(list: ^Draw_List, allocator := context.allocator) {
	list.commands = make([dynamic]Command, 0, 4096, allocator)
	list.clips = make([dynamic]Rect, 0, 16, allocator)
	// The root clip is unbounded, so a command that sets no clip is never
	// accidentally culled.
	append(&list.clips, Rect{x0 = min(f32), y0 = min(f32), x1 = max(f32), y1 = max(f32)})
}

draw_list_destroy :: proc(list: ^Draw_List) {
	delete(list.commands)
	delete(list.clips)
	list^ = {}
}

// draw_list_reset clears a list for a new frame, keeping its capacity.
draw_list_reset :: proc(list: ^Draw_List, surface: Rect) {
	clear(&list.commands)
	clear(&list.clips)
	append(&list.clips, surface)
	list.current_clip = 0
	list.current_layer = 0
}

// push_clip intersects a rectangle with the current clip and makes it active.
//
// Intersecting rather than replacing means a nested panel can never draw
// outside its parent, which is the property that makes clipping composable.
// Returns the previous clip so the caller can restore it.
push_clip :: proc(list: ^Draw_List, rect: Rect) -> (previous: u32) {
	previous = list.current_clip
	combined := rect_intersect(list.clips[previous], rect)

	append(&list.clips, combined)
	list.current_clip = u32(len(list.clips) - 1)
	return previous
}

// pop_clip restores a clip returned by push_clip.
pop_clip :: proc(list: ^Draw_List, previous: u32) {
	list.current_clip = previous
}

// set_layer selects the painter's-order layer for subsequent commands.
set_layer :: proc(list: ^Draw_List, layer: u16) -> (previous: u16) {
	previous = list.current_layer
	list.current_layer = layer
	return previous
}

// current_clip_rect returns the rectangle currently in force.
current_clip_rect :: proc(list: ^Draw_List) -> Rect {
	return list.clips[list.current_clip]
}

@(private)
append_command :: proc(list: ^Draw_List, command: Command) {
	entry := command
	entry.clip = list.current_clip
	entry.layer = list.current_layer

	// Culled here rather than in the backend: a command outside its clip
	// produces no pixels, and dropping it now saves the batching pass and the
	// GPU upload.
	//
	// A line is excluded from both tests because its rect holds two endpoints
	// rather than a bounding box. An axis-aligned line — the common case for
	// separators and the playhead — has zero width or height, so treating it
	// as a rectangle would cull every one of them.
	if entry.kind == .Line {
		if !line_intersects_clip(list.clips[entry.clip], entry.rect) {
			return
		}
		append(&list.commands, entry)
		return
	}

	if rect_is_empty(entry.rect) {
		return
	}
	if rect_is_empty(rect_intersect(list.clips[entry.clip], entry.rect)) {
		return
	}

	append(&list.commands, entry)
}

// line_intersects_clip reports whether a segment could paint inside a clip.
//
// A conservative test against the segment's bounding box: it keeps a few lines
// that turn out to be fully outside after the shader expands them to their
// thickness, which costs a wasted instance rather than a missing separator.
@(private)
line_intersects_clip :: proc "contextless" (clip: Rect, endpoints: Rect) -> bool {
	bounds := Rect {
		x0 = min(endpoints.x0, endpoints.x1),
		y0 = min(endpoints.y0, endpoints.y1),
		x1 = max(endpoints.x0, endpoints.x1),
		y1 = max(endpoints.y0, endpoints.y1),
	}
	return bounds.x1 >= clip.x0 &&
		bounds.x0 <= clip.x1 &&
		bounds.y1 >= clip.y0 &&
		bounds.y0 <= clip.y1
}

// fill_rect paints a solid rectangle.
fill_rect :: proc(list: ^Draw_List, rect: Rect, color: Color) {
	append_command(list, Command{kind = .Rect, rect = rect, color = color})
}

// stroke_rect paints a rectangle border inside the given bounds.
stroke_rect :: proc(list: ^Draw_List, rect: Rect, color: Color, thickness: f32 = 1) {
	append_command(
		list,
		Command{kind = .Rect_Outline, rect = rect, color2 = color, border = thickness},
	)
}

// fill_rounded_rect paints a rectangle with rounded corners.
fill_rounded_rect :: proc(list: ^Draw_List, rect: Rect, color: Color, radius: f32) {
	// A radius larger than half the shorter side would invert the corner
	// geometry, so it is clamped rather than left to the shader.
	limit := min(rect_width(rect), rect_height(rect)) * 0.5
	append_command(
		list,
		Command {
			kind = .Rounded_Rect,
			rect = rect,
			color = color,
			extent = min(radius, limit),
		},
	)
}

// draw_line paints a straight line between two points.
//
// The rect carries the endpoints rather than a bounding box, because a line's
// direction matters and a bounding box discards it.
draw_line :: proc(list: ^Draw_List, x0, y0, x1, y1: f32, color: Color, thickness: f32 = 1) {
	append_command(
		list,
		Command {
			kind = .Line,
			rect = Rect{x0 = x0, y0 = y0, x1 = x1, y1 = y1},
			color = color,
			extent = thickness,
		},
	)
}

// draw_glyph paints one glyph quad from an atlas.
draw_glyph :: proc(list: ^Draw_List, rect: Rect, source: Glyph_Ref, color: Color) {
	append_command(list, Command{kind = .Glyph, rect = rect, color = color, source = source})
}

// draw_circle paints a filled circle centred in the given rectangle.
draw_circle :: proc(list: ^Draw_List, centre_x, centre_y, radius: f32, color: Color) {
	append_command(
		list,
		Command {
			kind = .Circle,
			rect = Rect {
				x0 = centre_x - radius,
				y0 = centre_y - radius,
				x1 = centre_x + radius,
				y1 = centre_y + radius,
			},
			color = color,
			extent = radius,
		},
	)
}

// command_count reports how many commands survived culling, for diagnostics.
command_count :: proc(list: ^Draw_List) -> int {
	return len(list.commands)
}
