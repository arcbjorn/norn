package render

import "core:os"
import "core:unicode/utf8"

import stbtt "vendor:stb/truetype"

// Glyph atlases and text layout.
//
// docs/07-rendering.md: "the glyph atlas is generated lazily and cached by
// font, size, and scale factor." All three belong in the key. Scale
// especially: a 13-point glyph on a 2x display is rasterized at 26 device
// pixels, and reusing a 1x atlas there is what blurry Retina text is.
//
// The phase-zero text spike measured this approach at 0.022 ms to lay out
// 1,965 glyphs and 0.5-0.9 ms to build an atlas, against budgets of 8 ms and
// 50 ms. See docs/13-spike-results.md.

// ATLAS_SIZE is the backing texture for one cached rasterization.
//
// 1024 square holds printable ASCII several times over at interface sizes,
// which keeps the common case to one texture and therefore one draw call.
ATLAS_SIZE :: 1024

// Glyph coverage lives in one channel, so an atlas is one byte per pixel.
ATLAS_BYTES :: ATLAS_SIZE * ATLAS_SIZE

// Font_Kind selects a typeface.
//
// docs/07: "source text uses a monospace font; interface text may use a
// separate readable font." Two roles, so two kinds.
Font_Kind :: enum u8 {
	Interface = 0,
	Monospace = 1,
}

// Glyph is one rasterized character's placement.
//
// Positions are in device pixels within the atlas; offsets and advance are in
// device pixels relative to the pen.
Glyph :: struct {
	x0, y0, x1, y1:     u16,
	offset_x, offset_y: f32,
	advance:            f32,
	// False when the codepoint has no coverage, such as a space. Recorded so
	// layout can advance the pen without emitting an empty quad.
	has_bitmap: bool,
}

// Atlas is one font rasterized at one size and scale factor.
Atlas :: struct {
	key: Atlas_Key,

	// Vertical metrics in device pixels.
	ascent:   f32,
	descent:  f32,
	line_gap: f32,

	// Coverage bitmap, owned. Uploaded once and then kept so the atlas can be
	// re-uploaded after device loss without re-rasterizing.
	pixels: []u8,

	// Glyphs by codepoint. Sparse because a session may reference a handful of
	// characters outside ASCII and pre-rasterizing all of Unicode is absurd.
	glyphs: map[rune]Glyph,

	// Shelf-packing cursor.
	pen_x, pen_y, row_height: int,

	// Identifier the draw list uses to name this atlas.
	id: u32,

	// True once the pixels have been handed to the GPU. Cleared when a glyph
	// is added, so the backend knows to re-upload.
	uploaded: bool,
}

// Atlas_Key is the cache key docs/07 specifies.
Atlas_Key :: struct {
	font: Font_Kind,
	// Point size in logical pixels.
	size: f32,
	// Display scale. Part of the key because it changes the rasterization,
	// not merely the placement.
	scale: f32,
}

// Font_Set owns the loaded typefaces and every atlas derived from them.
Font_Set :: struct {
	faces:   [Font_Kind]Face,
	atlases: map[u64]^Atlas,
	// Next atlas identifier. Starts at one so zero means "no atlas", which is
	// what an untextured draw command carries.
	next_id: u32,
}

Face :: struct {
	data:   []u8,
	info:   stbtt.fontinfo,
	loaded: bool,
}

font_set_init :: proc(set: ^Font_Set, allocator := context.allocator) {
	set.atlases = make(map[u64]^Atlas, 8, allocator)
	set.next_id = 1
}

font_set_destroy :: proc(set: ^Font_Set) {
	for _, atlas in set.atlases {
		delete(atlas.pixels)
		delete(atlas.glyphs)
		free(atlas)
	}
	delete(set.atlases)

	for kind in Font_Kind {
		if set.faces[kind].loaded {
			delete(set.faces[kind].data)
		}
	}
	set^ = {}
}

// load_face reads a font file for one role.
//
// A `.ttc` collection needs an explicit face offset; passing zero to InitFont
// is only correct for a single-face `.ttf`. GetFontOffsetForIndex handles both,
// which the text spike established the hard way.
load_face :: proc(set: ^Font_Set, kind: Font_Kind, path: string) -> bool {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return false
	}

	face := &set.faces[kind]
	if face.loaded {
		delete(face.data)
	}
	face.data = data

	offset := stbtt.GetFontOffsetForIndex(raw_data(data), 0)
	if offset < 0 {
		delete(data)
		face^ = {}
		return false
	}
	if !stbtt.InitFont(&face.info, raw_data(data), offset) {
		delete(data)
		face^ = {}
		return false
	}

	face.loaded = true
	return true
}

// has_face reports whether a role has a usable typeface.
//
// Text drawing is skipped rather than faked when a font is missing: a box
// glyph for every character would be worse than no labels, because it looks
// like data rather than like an absent font.
has_face :: proc(set: ^Font_Set, kind: Font_Kind) -> bool {
	return set.faces[kind].loaded
}

@(private)
atlas_hash :: proc "contextless" (key: Atlas_Key) -> u64 {
	// Sizes are quantized to hundredths so floating-point noise in a scale
	// factor does not produce a cache miss for a visually identical atlas.
	size := u64(key.size * 100)
	scale := u64(key.scale * 100)
	return u64(key.font) << 56 | size << 24 | scale
}

// get_atlas returns the atlas for a key, creating it on first use.
//
// Returns nil when the font is not loaded, which callers treat as "draw no
// text" rather than as an error.
get_atlas :: proc(set: ^Font_Set, key: Atlas_Key) -> ^Atlas {
	if !set.faces[key.font].loaded {
		return nil
	}

	hash := atlas_hash(key)
	if existing, found := set.atlases[hash]; found {
		return existing
	}

	atlas := new(Atlas)
	atlas.key = key
	atlas.pixels = make([]u8, ATLAS_BYTES)
	atlas.glyphs = make(map[rune]Glyph, 128)
	atlas.pen_x = 1
	atlas.pen_y = 1
	atlas.id = set.next_id
	set.next_id += 1

	// Rasterize at the device pixel size. This is what makes text crisp: the
	// glyph is generated at the resolution it will be sampled at.
	face := &set.faces[key.font]
	scale := stbtt.ScaleForPixelHeight(&face.info, key.size * key.scale)

	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&face.info, &ascent, &descent, &line_gap)
	atlas.ascent = f32(ascent) * scale
	atlas.descent = f32(descent) * scale
	atlas.line_gap = f32(line_gap) * scale

	set.atlases[hash] = atlas
	return atlas
}

// glyph_for returns a codepoint's placement, rasterizing it on first use.
//
// Lazy per codepoint rather than per atlas: a session that only ever shows
// ASCII should not pay to rasterize a Unicode range it will never display.
glyph_for :: proc(set: ^Font_Set, atlas: ^Atlas, codepoint: rune) -> (glyph: Glyph, ok: bool) {
	if existing, found := atlas.glyphs[codepoint]; found {
		return existing, true
	}

	face := &set.faces[atlas.key.font]
	if !face.loaded {
		return {}, false
	}
	scale := stbtt.ScaleForPixelHeight(&face.info, atlas.key.size * atlas.key.scale)

	width, height, offset_x, offset_y: i32
	bitmap := stbtt.GetCodepointBitmap(
		&face.info,
		scale,
		scale,
		codepoint,
		&width,
		&height,
		&offset_x,
		&offset_y,
	)
	defer if bitmap != nil {
		stbtt.FreeBitmap(bitmap, nil)
	}

	advance, bearing: i32
	stbtt.GetCodepointHMetrics(&face.info, codepoint, &advance, &bearing)

	result := Glyph {
		offset_x = f32(offset_x),
		offset_y = f32(offset_y),
		advance  = f32(advance) * scale,
	}

	if bitmap != nil && width > 0 && height > 0 {
		if !pack_glyph(atlas, bitmap, int(width), int(height), &result) {
			// The atlas is full. The glyph is still cached with its advance so
			// layout stays correct; it simply draws nothing. A visibly wrong
			// advance would be worse than a missing character, because it
			// would shift every glyph after it.
			atlas.glyphs[codepoint] = result
			return result, true
		}
		result.has_bitmap = true
		atlas.uploaded = false
	}

	atlas.glyphs[codepoint] = result
	return result, true
}

// pack_glyph places a bitmap in the atlas using shelf packing.
@(private)
pack_glyph :: proc(
	atlas: ^Atlas,
	bitmap: [^]byte,
	width, height: int,
	glyph: ^Glyph,
) -> bool {
	if atlas.pen_x + width + 1 >= ATLAS_SIZE {
		atlas.pen_x = 1
		atlas.pen_y += atlas.row_height + 1
		atlas.row_height = 0
	}
	if atlas.pen_y + height + 1 >= ATLAS_SIZE {
		return false
	}
	if height > atlas.row_height {
		atlas.row_height = height
	}

	for row in 0 ..< height {
		source := bitmap[row * width:]
		destination := atlas.pixels[(atlas.pen_y + row) * ATLAS_SIZE + atlas.pen_x:]
		copy(destination[:width], source[:width])
	}

	glyph.x0 = u16(atlas.pen_x)
	glyph.y0 = u16(atlas.pen_y)
	glyph.x1 = u16(atlas.pen_x + width)
	glyph.y1 = u16(atlas.pen_y + height)

	atlas.pen_x += width + 1
	return true
}

// line_height is the vertical distance between baselines, in device pixels.
line_height :: proc "contextless" (atlas: ^Atlas) -> f32 {
	return atlas.ascent - atlas.descent + atlas.line_gap
}

// measure_text returns the width a string will occupy, in device pixels.
//
// Used for right-aligning and for deciding whether a label fits before it is
// drawn, so it must agree exactly with draw_text's advance arithmetic.
measure_text :: proc(set: ^Font_Set, atlas: ^Atlas, text: string) -> f32 {
	width := f32(0)
	for codepoint in text {
		glyph, ok := glyph_for(set, atlas, codepoint)
		if !ok {
			continue
		}
		width += glyph.advance
	}
	return width
}

// Text_Align selects horizontal placement within a bounding width.
Text_Align :: enum u8 {
	Left   = 0,
	Center = 1,
	Right  = 2,
}

// draw_text appends glyph quads for a string and returns the advance used.
//
// `x` and `y` are the top-left of the text's line box in device pixels. The
// baseline is derived from the atlas rather than passed in, so two callers
// cannot place the same size of text on different baselines.
draw_text :: proc(
	list: ^Draw_List,
	set: ^Font_Set,
	atlas: ^Atlas,
	text: string,
	x, y: f32,
	color: Color,
) -> f32 {
	if atlas == nil {
		return 0
	}

	pen_x := x
	baseline := y + atlas.ascent

	for codepoint in text {
		glyph, ok := glyph_for(set, atlas, codepoint)
		if !ok {
			continue
		}

		if glyph.has_bitmap {
			// Snapping the pen to a whole device pixel keeps stems on the
			// pixel grid. Without it, text at fractional offsets goes soft.
			left := f32(int(pen_x + glyph.offset_x + 0.5))
			top := baseline + glyph.offset_y
			width := f32(glyph.x1 - glyph.x0)
			height := f32(glyph.y1 - glyph.y0)

			draw_glyph(
				list,
				Rect{x0 = left, y0 = top, x1 = left + width, y1 = top + height},
				Glyph_Ref {
					atlas = atlas.id,
					u0 = f32(glyph.x0) / ATLAS_SIZE,
					v0 = f32(glyph.y0) / ATLAS_SIZE,
					u1 = f32(glyph.x1) / ATLAS_SIZE,
					v1 = f32(glyph.y1) / ATLAS_SIZE,
				},
				color,
			)
		}
		pen_x += glyph.advance
	}
	return pen_x - x
}

// draw_text_clipped draws text truncated to fit a width.
//
// docs/07: "long lines are clipped or horizontally scrolled, never silently
// wrapped in a way that changes line-number alignment." A truncated label ends
// in an ellipsis so the reader knows text was removed rather than believing
// the value is short.
draw_text_clipped :: proc(
	list: ^Draw_List,
	set: ^Font_Set,
	atlas: ^Atlas,
	text: string,
	x, y, max_width: f32,
	color: Color,
) -> f32 {
	if atlas == nil || max_width <= 0 {
		return 0
	}

	full := measure_text(set, atlas, text)
	if full <= max_width {
		return draw_text(list, set, atlas, text, x, y, color)
	}

	ellipsis := measure_text(set, atlas, "…")
	if ellipsis >= max_width {
		// Not even the marker fits, so nothing is drawn. Painting a partial
		// ellipsis would be noise.
		return 0
	}

	budget := max_width - ellipsis
	used := f32(0)
	cut := 0

	for codepoint, index in text {
		glyph, ok := glyph_for(set, atlas, codepoint)
		if !ok {
			continue
		}
		if used + glyph.advance > budget {
			break
		}
		used += glyph.advance
		cut = index + utf8.rune_size(codepoint)
	}

	advance := draw_text(list, set, atlas, text[:cut], x, y, color)
	advance += draw_text(list, set, atlas, "…", x + advance, y, color)
	return advance
}

// draw_text_aligned places text within a box.
draw_text_aligned :: proc(
	list: ^Draw_List,
	set: ^Font_Set,
	atlas: ^Atlas,
	text: string,
	box: Rect,
	align: Text_Align,
	color: Color,
) {
	if atlas == nil {
		return
	}

	width := measure_text(set, atlas, text)
	available := rect_width(box)

	x := box.x0
	switch align {
	case .Left:
	// Already correct.
	case .Center:
		x = box.x0 + (available - width) * 0.5
	case .Right:
		x = box.x1 - width
	}

	// Vertically centred within the box, using the font's own metrics so text
	// of different sizes shares a visual centre line.
	height := line_height(atlas)
	y := box.y0 + (rect_height(box) - height) * 0.5

	draw_text_clipped(list, set, atlas, text, x, y, available, color)
}
