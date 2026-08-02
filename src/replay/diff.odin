package replay

// Line-level diffing.
//
// Produces the change runs the diff viewer renders. docs/06 already defines
// comparison at the path level; this is the line detail underneath it.
//
// The algorithm is a longest-common-subsequence over lines, computed with the
// standard dynamic-programming table. That is O(n*m) in time and memory, which
// is why MAX_DIFF_LINES exists: a pathological pair of files must degrade to a
// coarse result rather than exhaust memory. docs/09 puts diff latency by file
// size on the benchmark list, so this is the implementation those numbers will
// describe.

// Line_Kind classifies one line in a diff.
Line_Kind :: enum u8 {
	Context = 0,
	Added   = 1,
	Removed = 2,
}

// Diff_Line is one rendered line.
//
// Both line numbers are carried because a diff viewer shows the old and new
// numbering side by side, and recomputing either from position would go wrong
// the moment a run of additions shifts the correspondence.
Diff_Line :: struct {
	kind: Line_Kind,
	// One-based line numbers, or zero where the line does not exist on that
	// side. An added line has no old number; a removed line has no new one.
	old_number: int,
	new_number: int,
	// Borrowed from the caller's content buffers.
	text: string,
}

// Diff is the full comparison of two file states.
Diff :: struct {
	lines: [dynamic]Diff_Line,
	// Totals, for a summary line above the content.
	added:   int,
	removed: int,
	// True when the comparison was too large to compute exactly and fell back
	// to a coarse result. docs/01 forbids presenting partial work as complete,
	// so the viewer must say so.
	truncated: bool,
}

diff_destroy :: proc(diff: ^Diff) {
	delete(diff.lines)
	diff^ = {}
}

// MAX_DIFF_LINES bounds the exact algorithm.
//
// The table is one byte per cell, so 4,000 lines a side is 16 MB — large
// enough for any source file a person reads, small enough that a generated
// file cannot exhaust memory. Beyond it the diff degrades rather than failing:
// a coarse answer about a huge file is more useful than no answer.
MAX_DIFF_LINES :: 4000

// diff_text compares two file states line by line.
//
// The returned lines borrow `before` and `after`, so both must outlive the
// diff. That avoids copying a file's worth of text for a view that is usually
// scrolled through and then discarded.
diff_text :: proc(
	before: []byte,
	after: []byte,
	allocator := context.allocator,
) -> Diff {
	result := Diff {
		lines = make([dynamic]Diff_Line, 0, 256, allocator),
	}

	old_lines := split_lines(before, context.temp_allocator)
	defer delete(old_lines, context.temp_allocator)
	new_lines := split_lines(after, context.temp_allocator)
	defer delete(new_lines, context.temp_allocator)

	// Identical content is the common case when scrubbing a timeline: most
	// files are unchanged between two adjacent moments. Detecting it first
	// avoids building a table to discover nothing happened.
	if slices_equal(old_lines, new_lines) {
		for line, index in old_lines {
			append(
				&result.lines,
				Diff_Line {
					kind = .Context,
					old_number = index + 1,
					new_number = index + 1,
					text = string(line),
				},
			)
		}
		return result
	}

	if len(old_lines) > MAX_DIFF_LINES || len(new_lines) > MAX_DIFF_LINES {
		build_coarse_diff(&result, old_lines, new_lines)
		result.truncated = true
		return result
	}

	// Trimming the common prefix and suffix before building the table is what
	// makes an edit to one line of a large file cheap: the table then covers
	// only the region that actually differs.
	prefix := common_prefix(old_lines, new_lines)
	suffix := common_suffix(old_lines[prefix:], new_lines[prefix:])

	for index in 0 ..< prefix {
		append(
			&result.lines,
			Diff_Line {
				kind = .Context,
				old_number = index + 1,
				new_number = index + 1,
				text = string(old_lines[index]),
			},
		)
	}

	middle_old := old_lines[prefix:len(old_lines) - suffix]
	middle_new := new_lines[prefix:len(new_lines) - suffix]
	build_exact_diff(&result, middle_old, middle_new, prefix)

	for index in 0 ..< suffix {
		old_index := len(old_lines) - suffix + index
		new_index := len(new_lines) - suffix + index
		append(
			&result.lines,
			Diff_Line {
				kind = .Context,
				old_number = old_index + 1,
				new_number = new_index + 1,
				text = string(old_lines[old_index]),
			},
		)
	}

	return result
}

@(private)
slices_equal :: proc(a: [][]byte, b: [][]byte) -> bool {
	if len(a) != len(b) {
		return false
	}
	for index in 0 ..< len(a) {
		if !lines_identical(a[index], b[index]) {
			return false
		}
	}
	return true
}

// lines_identical compares two lines byte for byte.
//
// Exactly, including trailing whitespace: docs/07 requires the diff viewer to
// show accurate text, and whitespace is frequently what an edit changed.
@(private)
lines_identical :: proc "contextless" (a: []byte, b: []byte) -> bool {
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

@(private)
common_prefix :: proc(a: [][]byte, b: [][]byte) -> int {
	limit := min(len(a), len(b))
	count := 0
	for count < limit && lines_identical(a[count], b[count]) {
		count += 1
	}
	return count
}

@(private)
common_suffix :: proc(a: [][]byte, b: [][]byte) -> int {
	limit := min(len(a), len(b))
	count := 0
	for count < limit && lines_identical(a[len(a) - 1 - count], b[len(b) - 1 - count]) {
		count += 1
	}
	return count
}

// build_exact_diff emits the change runs for the differing region.
//
// `offset` is how many lines were trimmed as a common prefix, so the line
// numbers stay absolute.
@(private)
build_exact_diff :: proc(result: ^Diff, old_lines: [][]byte, new_lines: [][]byte, offset: int) {
	rows := len(old_lines)
	columns := len(new_lines)

	// Degenerate cases need no table.
	if rows == 0 {
		for index in 0 ..< columns {
			append(
				&result.lines,
				Diff_Line {
					kind = .Added,
					new_number = offset + index + 1,
					text = string(new_lines[index]),
				},
			)
			result.added += 1
		}
		return
	}
	if columns == 0 {
		for index in 0 ..< rows {
			append(
				&result.lines,
				Diff_Line {
					kind = .Removed,
					old_number = offset + index + 1,
					text = string(old_lines[index]),
				},
			)
			result.removed += 1
		}
		return
	}

	// Longest-common-subsequence lengths. u16 rather than int because the
	// dimensions are bounded by MAX_DIFF_LINES, which halves the table.
	table := make([]u16, (rows + 1) * (columns + 1), context.temp_allocator)
	defer delete(table, context.temp_allocator)

	at :: proc(table: []u16, columns: int, row: int, column: int) -> u16 {
		return table[row * (columns + 1) + column]
	}
	set :: proc(table: []u16, columns: int, row: int, column: int, value: u16) {
		table[row * (columns + 1) + column] = value
	}

	for row := rows - 1; row >= 0; row -= 1 {
		for column := columns - 1; column >= 0; column -= 1 {
			if lines_identical(old_lines[row], new_lines[column]) {
				set(table, columns, row, column, at(table, columns, row + 1, column + 1) + 1)
			} else {
				down := at(table, columns, row + 1, column)
				right := at(table, columns, row, column + 1)
				set(table, columns, row, column, max(down, right))
			}
		}
	}

	// Walk the table, emitting lines in file order.
	row := 0
	column := 0
	for row < rows && column < columns {
		if lines_identical(old_lines[row], new_lines[column]) {
			append(
				&result.lines,
				Diff_Line {
					kind = .Context,
					old_number = offset + row + 1,
					new_number = offset + column + 1,
					text = string(old_lines[row]),
				},
			)
			row += 1
			column += 1
			continue
		}

		// Removals before additions at the same position, so a replaced line
		// reads as the old text followed by the new rather than interleaved.
		if at(table, columns, row + 1, column) >= at(table, columns, row, column + 1) {
			append(
				&result.lines,
				Diff_Line {
					kind = .Removed,
					old_number = offset + row + 1,
					text = string(old_lines[row]),
				},
			)
			result.removed += 1
			row += 1
		} else {
			append(
				&result.lines,
				Diff_Line {
					kind = .Added,
					new_number = offset + column + 1,
					text = string(new_lines[column]),
				},
			)
			result.added += 1
			column += 1
		}
	}

	for row < rows {
		append(
			&result.lines,
			Diff_Line {
				kind = .Removed,
				old_number = offset + row + 1,
				text = string(old_lines[row]),
			},
		)
		result.removed += 1
		row += 1
	}
	for column < columns {
		append(
			&result.lines,
			Diff_Line {
				kind = .Added,
				new_number = offset + column + 1,
				text = string(new_lines[column]),
			},
		)
		result.added += 1
		column += 1
	}
}

// build_coarse_diff handles files too large for the exact algorithm.
//
// Common prefix and suffix are still exact, so an edit in the middle of a
// generated file is reported precisely. Only the differing region between them
// is coarsened, into a wholesale removal followed by a wholesale addition. The
// result is correct but not minimal, which is why the caller marks it
// truncated rather than presenting it as a normal diff.
@(private)
build_coarse_diff :: proc(result: ^Diff, old_lines: [][]byte, new_lines: [][]byte) {
	prefix := common_prefix(old_lines, new_lines)
	suffix := common_suffix(old_lines[prefix:], new_lines[prefix:])

	for index in 0 ..< prefix {
		append(
			&result.lines,
			Diff_Line {
				kind = .Context,
				old_number = index + 1,
				new_number = index + 1,
				text = string(old_lines[index]),
			},
		)
	}

	for index in prefix ..< len(old_lines) - suffix {
		append(
			&result.lines,
			Diff_Line{kind = .Removed, old_number = index + 1, text = string(old_lines[index])},
		)
		result.removed += 1
	}
	for index in prefix ..< len(new_lines) - suffix {
		append(
			&result.lines,
			Diff_Line{kind = .Added, new_number = index + 1, text = string(new_lines[index])},
		)
		result.added += 1
	}

	for index in 0 ..< suffix {
		old_index := len(old_lines) - suffix + index
		new_index := len(new_lines) - suffix + index
		append(
			&result.lines,
			Diff_Line {
				kind = .Context,
				old_number = old_index + 1,
				new_number = new_index + 1,
				text = string(old_lines[old_index]),
			},
		)
	}
}

// has_changes reports whether anything differs.
has_changes :: proc "contextless" (diff: Diff) -> bool {
	return diff.added > 0 || diff.removed > 0
}
