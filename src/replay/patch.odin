package replay

import "core:strconv"
import "core:strings"

import "src:core"

// Unified-diff parsing and strict application.
//
// docs/05-importers.md: patch application is strict. A failed hunk produces a
// replay gap and warning; it does not trigger fuzzy patching in version one.
//
// That rule drives every decision here. A fuzzy patcher guesses where a hunk
// was meant to land, and a guess that lands wrong produces file content the
// session never had — which is worse than admitting the content is unknown,
// because the user cannot tell the difference by looking.

// Patch_Error explains why a patch could not be parsed or applied. The import
// report counts these by reason rather than emitting one opaque warning.
Patch_Error :: enum u8 {
	None = 0,
	Malformed_Header,       // A hunk header could not be parsed.
	Malformed_Hunk,         // A hunk's body disagrees with its declared counts.
	Context_Mismatch,       // Context or removed lines did not match the source.
	Line_Out_Of_Range,      // A hunk referenced a line beyond the source.
	Overlapping_Hunks,      // Hunks are unordered or overlap.
	Empty_Patch,            // No hunk was found.
	Too_Many_Hunks,
}

patch_error_name :: proc "contextless" (reason: Patch_Error) -> string {
	switch reason {
	case .None:              return "none"
	case .Malformed_Header:  return "malformed_header"
	case .Malformed_Hunk:    return "malformed_hunk"
	case .Context_Mismatch:  return "context_mismatch"
	case .Line_Out_Of_Range: return "line_out_of_range"
	case .Overlapping_Hunks: return "overlapping_hunks"
	case .Empty_Patch:       return "empty_patch"
	case .Too_Many_Hunks:    return "too_many_hunks"
	}
	return "unknown"
}

// MAX_HUNKS bounds a single patch. Untrusted input declares hunk counts, so
// the ceiling is checked before any allocation.
MAX_HUNKS :: 65536

// Hunk is one `@@ -old_start,old_count +new_start,new_count @@` region.
//
// Line numbers in a unified diff are one-based. They are kept that way here
// and converted at the point of use, so a reader comparing this against a
// diff does not have to track an off-by-one in their head.
Hunk :: struct {
	old_start: int,
	old_count: int,
	new_start: int,
	new_count: int,
	// Body lines, each retaining its leading marker (' ', '-', '+').
	lines: [][]byte,
}

Patch :: struct {
	hunks: [dynamic]Hunk,
	// Backing store for the line slices in every hunk.
	line_storage: [dynamic][]byte,
}

patch_destroy :: proc(patch: ^Patch) {
	delete(patch.hunks)
	delete(patch.line_storage)
	patch^ = {}
}

// split_lines splits `data` on '\n', keeping the terminator with each line.
//
// Keeping terminators means concatenating the result reproduces the input
// byte for byte, including whether the file ended with a newline. A patcher
// that normalized line endings would silently rewrite files whose exact bytes
// are the evidence being examined.
split_lines :: proc(data: []byte, allocator := context.allocator) -> [][]byte {
	lines := make([dynamic][]byte, 0, 64, allocator)
	start := 0
	for index in 0 ..< len(data) {
		if data[index] == '\n' {
			append(&lines, data[start:index + 1])
			start = index + 1
		}
	}
	if start < len(data) {
		append(&lines, data[start:])
	}
	return lines[:]
}

// join_lines concatenates lines back into a buffer.
join_lines :: proc(lines: [][]byte, allocator := context.allocator) -> []byte {
	total := 0
	for line in lines {
		total += len(line)
	}
	result := make([]byte, total, allocator)
	offset := 0
	for line in lines {
		copy(result[offset:], line)
		offset += len(line)
	}
	return result
}

// parse_patch reads a unified diff into hunks.
//
// Leading `---` and `+++` file headers are skipped when present: the canonical
// mutation already names the path, and trusting a path from inside patch text
// would reintroduce the path-escape risk that normalization exists to prevent.
parse_patch :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	patch: Patch,
	reason: Patch_Error,
) {
	patch.hunks = make([dynamic]Hunk, 0, 8, allocator)
	patch.line_storage = make([dynamic][]byte, 0, 64, allocator)

	lines := split_lines(data, context.temp_allocator)
	defer delete(lines, context.temp_allocator)

	// Hunk bodies are recorded as index ranges first, because appending to
	// line_storage can reallocate and invalidate any slice taken earlier.
	Range :: struct {
		hunk:  Hunk,
		start: int,
		count: int,
	}
	ranges := make([dynamic]Range, 0, 8, context.temp_allocator)
	defer delete(ranges)

	index := 0
	for index < len(lines) {
		line := trim_eol(lines[index])

		if !strings.has_prefix(string(line), "@@") {
			// Anything before the first hunk is a file header or preamble.
			index += 1
			continue
		}

		hunk: Hunk
		hunk, reason = parse_hunk_header(line)
		if reason != .None {
			patch_destroy(&patch)
			return {}, reason
		}
		index += 1

		if len(ranges) >= MAX_HUNKS {
			patch_destroy(&patch)
			return {}, .Too_Many_Hunks
		}

		// Read exactly as many body lines as the header declares. Counting
		// rather than scanning for the next `@@` means a body line that
		// happens to begin with `@@` cannot truncate the hunk.
		old_seen := 0
		new_seen := 0
		body_start := len(patch.line_storage)
		body_count := 0

		for index < len(lines) && (old_seen < hunk.old_count || new_seen < hunk.new_count) {
			body := lines[index]
			if len(body) == 0 {
				break
			}
			switch body[0] {
			case ' ':
				old_seen += 1
				new_seen += 1
			case '-':
				old_seen += 1
			case '+':
				new_seen += 1
			case '\\':
				// "\ No newline at end of file" annotates the preceding line
				// and consumes no source or result line.
				append(&patch.line_storage, body)
				body_count += 1
				index += 1
				continue
			case '\n', '\r':
				// An empty context line. Some producers emit a bare newline
				// rather than a space followed by a newline.
				old_seen += 1
				new_seen += 1
			case:
				// Any other marker ends the hunk body.
				break
			}

			if old_seen > hunk.old_count || new_seen > hunk.new_count {
				patch_destroy(&patch)
				return {}, .Malformed_Hunk
			}

			append(&patch.line_storage, body)
			body_count += 1
			index += 1
		}

		if old_seen != hunk.old_count || new_seen != hunk.new_count {
			patch_destroy(&patch)
			return {}, .Malformed_Hunk
		}

		// A "\ No newline at end of file" annotation on the final line falls
		// outside the declared counts, because it describes a line rather than
		// being one. The count-driven loop above therefore stops just before
		// it, so absorb any that follow. Dropping it would silently append a
		// newline the source never had.
		for index < len(lines) && len(lines[index]) > 0 && lines[index][0] == '\\' {
			append(&patch.line_storage, lines[index])
			body_count += 1
			index += 1
		}

		append(&ranges, Range{hunk = hunk, start = body_start, count = body_count})
	}

	if len(ranges) == 0 {
		patch_destroy(&patch)
		return {}, .Empty_Patch
	}

	// Bind body slices now that line_storage has stopped growing.
	for range in ranges {
		hunk := range.hunk
		hunk.lines = patch.line_storage[range.start:range.start + range.count]
		append(&patch.hunks, hunk)
	}

	return patch, .None
}

@(private)
trim_eol :: proc "contextless" (line: []byte) -> []byte {
	result := line
	if len(result) > 0 && result[len(result) - 1] == '\n' {
		result = result[:len(result) - 1]
	}
	if len(result) > 0 && result[len(result) - 1] == '\r' {
		result = result[:len(result) - 1]
	}
	return result
}

// parse_hunk_header reads `@@ -old[,count] +new[,count] @@ optional heading`.
@(private)
parse_hunk_header :: proc(line: []byte) -> (hunk: Hunk, reason: Patch_Error) {
	text := string(line)
	if !strings.has_prefix(text, "@@") {
		return {}, .Malformed_Header
	}
	text = text[2:]

	closing := strings.index(text, "@@")
	if closing < 0 {
		return {}, .Malformed_Header
	}
	// Text after the closing marker is a section heading and carries no
	// applicable information.
	ranges := strings.trim_space(text[:closing])

	fields := strings.fields(ranges, context.temp_allocator)
	defer delete(fields, context.temp_allocator)
	if len(fields) != 2 {
		return {}, .Malformed_Header
	}
	if !strings.has_prefix(fields[0], "-") || !strings.has_prefix(fields[1], "+") {
		return {}, .Malformed_Header
	}

	old_start, old_count, ok_old := parse_range(fields[0][1:])
	new_start, new_count, ok_new := parse_range(fields[1][1:])
	if !ok_old || !ok_new {
		return {}, .Malformed_Header
	}

	return Hunk {
			old_start = old_start,
			old_count = old_count,
			new_start = new_start,
			new_count = new_count,
		},
		.None
}

// parse_range reads `start` or `start,count`. An absent count means one line.
@(private)
parse_range :: proc(text: string) -> (start: int, count: int, ok: bool) {
	comma := strings.index_byte(text, ',')
	if comma < 0 {
		start = strconv.parse_int(text) or_return
		return start, 1, start >= 0
	}
	start = strconv.parse_int(text[:comma]) or_return
	count = strconv.parse_int(text[comma + 1:]) or_return
	return start, count, start >= 0 && count >= 0
}

// apply_patch applies a parsed patch to `source`, returning the result.
//
// Application is strict: every context and removed line must match the source
// byte for byte at the position the hunk declares. There is no offset search
// and no whitespace tolerance. The caller owns the returned bytes.
apply_patch :: proc(
	source: []byte,
	patch: ^Patch,
	allocator := context.allocator,
) -> (
	result: []byte,
	reason: Patch_Error,
) {
	source_lines := split_lines(source, context.temp_allocator)
	defer delete(source_lines, context.temp_allocator)

	output := make([dynamic][]byte, 0, len(source_lines) + 16, context.temp_allocator)
	defer delete(output)

	// Zero-based cursor into source_lines. Everything before it has been
	// copied or consumed.
	cursor := 0

	for hunk in patch.hunks {
		// A hunk that only adds lines uses old_start as the line it follows,
		// so a zero count means "insert after old_start" rather than "at".
		target := hunk.old_start - 1
		if hunk.old_count == 0 {
			target = hunk.old_start
		}
		if target < 0 {
			return nil, .Malformed_Header
		}
		if target < cursor {
			return nil, .Overlapping_Hunks
		}
		if target > len(source_lines) {
			return nil, .Line_Out_Of_Range
		}

		// Copy the untouched region preceding this hunk.
		for cursor < target {
			append(&output, source_lines[cursor])
			cursor += 1
		}

		// Marker of the previous body line, so a "no newline" annotation can
		// tell which side of the diff it describes.
		previous_marker := u8(0)

		for body in hunk.lines {
			if len(body) == 0 {
				return nil, .Malformed_Hunk
			}
			marker := body[0]
			payload := body[1:] if marker != '\n' && marker != '\r' else body

			previous := previous_marker
			previous_marker = marker

			switch marker {
			case '\\':
				// "\ No newline at end of file" states that the line it
				// follows has no terminator. Patch text always ends that line
				// with a newline, so when the line reached the output its
				// terminator must be stripped, or the result gains a byte the
				// source never had.
				//
				// Which side it describes depends on the line before it. After
				// a removed line the annotation is about the source, which is
				// being discarded, so there is nothing in the output to fix.
				// Stripping there would truncate an unrelated earlier line.
				if previous != '-' && len(output) > 0 {
					last := &output[len(output) - 1]
					last^ = trim_eol(last^)
				}
				continue

			case ' ', '\n', '\r':
				if cursor >= len(source_lines) {
					return nil, .Line_Out_Of_Range
				}
				if !lines_equal(source_lines[cursor], payload) {
					return nil, .Context_Mismatch
				}
				append(&output, source_lines[cursor])
				cursor += 1

			case '-':
				if cursor >= len(source_lines) {
					return nil, .Line_Out_Of_Range
				}
				if !lines_equal(source_lines[cursor], payload) {
					return nil, .Context_Mismatch
				}
				cursor += 1

			case '+':
				append(&output, payload)

			case:
				return nil, .Malformed_Hunk
			}
		}
	}

	// Copy whatever follows the final hunk.
	for cursor < len(source_lines) {
		append(&output, source_lines[cursor])
		cursor += 1
	}

	return join_lines(output[:], allocator), .None
}

// lines_equal compares a source line with a patch line, ignoring only the
// presence of a trailing newline.
//
// The tolerance is limited to the terminator because a patch's final line may
// legitimately lack one where the source has it. Every other byte, including
// leading and trailing whitespace, must match exactly: whitespace is often
// precisely what an edit changed.
@(private)
lines_equal :: proc "contextless" (source: []byte, patch: []byte) -> bool {
	a := trim_eol(source)
	b := trim_eol(patch)
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< len(a) {
		if a[index] != b[index] {
			return false
		}
	}
	return true
}

// patch_error_to_core maps a patch failure to the shared error model, so a
// caller that only reports errors does not need to know patch specifics.
patch_error_to_core :: proc "contextless" (reason: Patch_Error) -> core.Error {
	if reason == .None {
		return nil
	}
	return core.err_make(.Unsupported_Feature, "patch could not be applied strictly")
}
