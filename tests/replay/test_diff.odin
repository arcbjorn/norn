package test_replay

import "core:fmt"
import "core:strings"
import "core:testing"

import "src:replay"

// Line diffing.
//
// A diff viewer that shows the wrong lines is worse than none: it looks like
// evidence. These check the properties a reader depends on — every line
// accounted for, numbering that matches the files, and exact text comparison.

@(private)
run_diff :: proc(before: string, after: string) -> replay.Diff {
	return replay.diff_text(transmute([]byte)before, transmute([]byte)after)
}

// reconstruct rebuilds each side from the diff.
//
// The central property: a diff is a description of two files, so removing the
// additions must yield the original and removing the removals must yield the
// result. Anything else means lines were invented or lost.
@(private)
reconstruct :: proc(diff: ^replay.Diff) -> (before: string, after: string) {
	old_builder := strings.builder_make(context.temp_allocator)
	new_builder := strings.builder_make(context.temp_allocator)

	for line in diff.lines {
		switch line.kind {
		case .Context:
			strings.write_string(&old_builder, line.text)
			strings.write_string(&new_builder, line.text)
		case .Removed:
			strings.write_string(&old_builder, line.text)
		case .Added:
			strings.write_string(&new_builder, line.text)
		}
	}
	return strings.to_string(old_builder), strings.to_string(new_builder)
}

@(test)
identical_files_produce_only_context :: proc(t: ^testing.T) {
	content := "alpha\nbeta\ngamma\n"
	diff := run_diff(content, content)
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 0)
	testing.expect_value(t, diff.removed, 0)
	testing.expect(t, !replay.has_changes(diff))
	testing.expect_value(t, len(diff.lines), 3)
	for line in diff.lines {
		testing.expect_value(t, line.kind, replay.Line_Kind.Context)
	}
}

@(test)
a_replaced_line_shows_removal_then_addition :: proc(t: ^testing.T) {
	// A replacement reads as the old text followed by the new. Interleaving
	// them would make a one-line change hard to follow.
	diff := run_diff("alpha\nbeta\ngamma\n", "alpha\nBETA\ngamma\n")
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 1)
	testing.expect_value(t, diff.removed, 1)
	testing.expect_value(t, len(diff.lines), 4)

	testing.expect_value(t, diff.lines[0].kind, replay.Line_Kind.Context)
	testing.expect_value(t, diff.lines[1].kind, replay.Line_Kind.Removed)
	testing.expect_value(t, diff.lines[2].kind, replay.Line_Kind.Added)
	testing.expect_value(t, diff.lines[3].kind, replay.Line_Kind.Context)
}

@(test)
line_numbers_match_both_files :: proc(t: ^testing.T) {
	// The viewer shows old and new numbering side by side, and a wrong number
	// sends the reader to the wrong line in their editor.
	diff := run_diff("a\nb\nc\n", "a\nx\ny\nc\n")
	defer replay.diff_destroy(&diff)

	for line in diff.lines {
		switch line.kind {
		case .Context:
			testing.expect(t, line.old_number > 0 && line.new_number > 0)
		case .Removed:
			testing.expect(t, line.old_number > 0)
			testing.expect_value(t, line.new_number, 0)
		case .Added:
			testing.expect_value(t, line.old_number, 0)
			testing.expect(t, line.new_number > 0)
		}
	}

	// Numbering on each side must be strictly increasing and gapless.
	expected_old := 1
	expected_new := 1
	for line in diff.lines {
		if line.old_number != 0 {
			testing.expect_value(t, line.old_number, expected_old)
			expected_old += 1
		}
		if line.new_number != 0 {
			testing.expect_value(t, line.new_number, expected_new)
			expected_new += 1
		}
	}
}

@(test)
the_diff_reconstructs_both_files :: proc(t: ^testing.T) {
	Case :: struct {
		before: string,
		after:  string,
	}
	cases := []Case {
		{"", ""},
		{"", "new\n"},
		{"old\n", ""},
		{"a\nb\nc\n", "a\nc\n"},
		{"a\nc\n", "a\nb\nc\n"},
		{"a\nb\nc\nd\ne\n", "a\nx\nc\ny\ne\n"},
		{"one\ntwo\nthree\n", "three\ntwo\none\n"},
		{"same\n", "same"},
		{"trailing\n\n\n", "trailing\n"},
	}

	for c in cases {
		diff := run_diff(c.before, c.after)
		defer replay.diff_destroy(&diff)

		before, after := reconstruct(&diff)
		testing.expectf(
			t,
			before == c.before,
			"reconstructing the original gave %q, expected %q",
			before,
			c.before,
		)
		testing.expectf(
			t,
			after == c.after,
			"reconstructing the result gave %q, expected %q",
			after,
			c.after,
		)
	}
}

@(test)
whitespace_differences_are_real_differences :: proc(t: ^testing.T) {
	// Whitespace is frequently what an edit changed, so it cannot be folded.
	diff := run_diff("if x:\n    return 1\n", "if x:\n\treturn 1\n")
	defer replay.diff_destroy(&diff)

	testing.expect(t, replay.has_changes(diff), "indentation change must be reported")
	testing.expect_value(t, diff.added, 1)
	testing.expect_value(t, diff.removed, 1)
}

@(test)
a_pure_insertion_reports_no_removals :: proc(t: ^testing.T) {
	diff := run_diff("first\nlast\n", "first\nmiddle\nlast\n")
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 1)
	testing.expect_value(t, diff.removed, 0)
}

@(test)
a_pure_deletion_reports_no_additions :: proc(t: ^testing.T) {
	diff := run_diff("keep\ndrop\nkeep2\n", "keep\nkeep2\n")
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 0)
	testing.expect_value(t, diff.removed, 1)
}

@(test)
creating_a_file_is_all_additions :: proc(t: ^testing.T) {
	diff := run_diff("", "line one\nline two\n")
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 2)
	testing.expect_value(t, diff.removed, 0)
	for line in diff.lines {
		testing.expect_value(t, line.kind, replay.Line_Kind.Added)
	}
}

@(test)
deleting_a_file_is_all_removals :: proc(t: ^testing.T) {
	diff := run_diff("line one\nline two\n", "")
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 0)
	testing.expect_value(t, diff.removed, 2)
}

@(test)
an_edit_in_a_large_file_stays_exact :: proc(t: ^testing.T) {
	// The prefix and suffix trim is what makes this cheap. Without it a
	// one-line change in a large file would build the full table.
	builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 3000 {
		fmt.sbprintf(&builder, "line %d\n", index)
	}
	before := strings.to_string(builder)

	modified := strings.builder_make(context.temp_allocator)
	for index in 0 ..< 3000 {
		if index == 1500 {
			strings.write_string(&modified, "CHANGED\n")
		} else {
			fmt.sbprintf(&modified, "line %d\n", index)
		}
	}
	after := strings.to_string(modified)

	diff := run_diff(before, after)
	defer replay.diff_destroy(&diff)

	testing.expect(t, !diff.truncated, "a trimmed diff must stay exact")
	testing.expect_value(t, diff.added, 1)
	testing.expect_value(t, diff.removed, 1)

	reconstructed_before, reconstructed_after := reconstruct(&diff)
	testing.expect(t, reconstructed_before == before)
	testing.expect(t, reconstructed_after == after)
}

@(test)
an_oversized_diff_degrades_and_says_so :: proc(t: ^testing.T) {
	// docs/01 forbids presenting partial work as complete. A coarse diff is
	// still correct — it reconstructs both files — but it is not minimal, so
	// the viewer must be told.
	before_builder := strings.builder_make(context.temp_allocator)
	after_builder := strings.builder_make(context.temp_allocator)
	for index in 0 ..< replay.MAX_DIFF_LINES + 500 {
		fmt.sbprintf(&before_builder, "old %d\n", index)
		fmt.sbprintf(&after_builder, "new %d\n", index)
	}
	before := strings.to_string(before_builder)
	after := strings.to_string(after_builder)

	diff := run_diff(before, after)
	defer replay.diff_destroy(&diff)

	testing.expect(t, diff.truncated, "an oversized comparison must be marked")
	testing.expect(t, replay.has_changes(diff))

	// Correct even when coarse.
	reconstructed_before, reconstructed_after := reconstruct(&diff)
	testing.expect(t, reconstructed_before == before)
	testing.expect(t, reconstructed_after == after)
}

@(test)
diffing_is_deterministic :: proc(t: ^testing.T) {
	// docs/13 makes version-one analysis deterministic, and a diff a user
	// exports must reproduce.
	before := "a\nb\nc\nd\ne\nf\n"
	after := "a\nx\nc\ny\ne\nz\n"

	first := run_diff(before, after)
	defer replay.diff_destroy(&first)
	second := run_diff(before, after)
	defer replay.diff_destroy(&second)

	testing.expect_value(t, len(first.lines), len(second.lines))
	for index in 0 ..< len(first.lines) {
		testing.expect_value(t, first.lines[index].kind, second.lines[index].kind)
		testing.expect_value(t, first.lines[index].text, second.lines[index].text)
		testing.expect_value(t, first.lines[index].old_number, second.lines[index].old_number)
	}
}

@(test)
a_file_without_a_final_newline_round_trips :: proc(t: ^testing.T) {
	// The exact bytes are the evidence; a diff that added a newline would be
	// describing a file the session never had.
	diff := run_diff("no newline", "no newline at all")
	defer replay.diff_destroy(&diff)

	before, after := reconstruct(&diff)
	testing.expect_value(t, before, "no newline")
	testing.expect_value(t, after, "no newline at all")
}

@(test)
the_diff_finds_the_common_subsequence :: proc(t: ^testing.T) {
	// A naive line-by-line comparison would call every line different here.
	// The point of the algorithm is recognising that most lines moved rather
	// than changed.
	before := "one\ntwo\nthree\nfour\nfive\n"
	after := "zero\none\ntwo\nthree\nfour\nfive\n"

	diff := run_diff(before, after)
	defer replay.diff_destroy(&diff)

	testing.expect_value(t, diff.added, 1)
	testing.expect_value(t, diff.removed, 0)
	testing.expect_value(t, diff.lines[0].kind, replay.Line_Kind.Added)
	testing.expect_value(t, diff.lines[0].text, "zero\n")
}
