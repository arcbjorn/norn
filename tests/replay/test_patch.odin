package test_replay

import "core:testing"

import "src:replay"

@(private)
apply :: proc(source: string, patch_text: string) -> (result: string, reason: replay.Patch_Error) {
	patch, parse_reason := replay.parse_patch(transmute([]byte)patch_text)
	if parse_reason != .None {
		return "", parse_reason
	}
	defer replay.patch_destroy(&patch)

	bytes, apply_reason := replay.apply_patch(transmute([]byte)source, &patch)
	if apply_reason != .None {
		return "", apply_reason
	}
	return string(bytes), .None
}

@(test)
applies_a_single_line_replacement :: proc(t: ^testing.T) {
	source := "alpha\nbeta\ngamma\n"
	patch := `@@ -2,1 +2,1 @@
-beta
+BETA
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "alpha\nBETA\ngamma\n")
}

@(test)
applies_with_surrounding_context :: proc(t: ^testing.T) {
	source := "one\ntwo\nthree\nfour\nfive\n"
	patch := `@@ -2,3 +2,3 @@
 two
-three
+THREE
 four
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "one\ntwo\nTHREE\nfour\nfive\n")
}

@(test)
applies_pure_insertion :: proc(t: ^testing.T) {
	source := "first\nlast\n"
	patch := `@@ -1,2 +1,3 @@
 first
+middle
 last
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "first\nmiddle\nlast\n")
}

@(test)
applies_pure_deletion :: proc(t: ^testing.T) {
	source := "keep\ndrop\nkeep2\n"
	patch := `@@ -1,3 +1,2 @@
 keep
-drop
 keep2
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "keep\nkeep2\n")
}

@(test)
applies_multiple_hunks :: proc(t: ^testing.T) {
	source := "a\nb\nc\nd\ne\nf\ng\nh\n"
	patch := `@@ -1,2 +1,2 @@
-a
+A
 b
@@ -7,2 +7,2 @@
 g
-h
+H
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "A\nb\nc\nd\ne\nf\ng\nH\n")
}

@(test)
applies_to_an_empty_source :: proc(t: ^testing.T) {
	patch := `@@ -0,0 +1,2 @@
+hello
+world
`
	result, reason := apply("", patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "hello\nworld\n")
}

@(test)
preserves_a_missing_final_newline :: proc(t: ^testing.T) {
	// The exact bytes are the evidence. A patcher that normalized the file to
	// end with a newline would rewrite content the session never wrote.
	source := "alpha\nbeta"
	patch := `@@ -1,2 +1,2 @@
 alpha
-beta
\ No newline at end of file
+BETA
\ No newline at end of file
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "alpha\nBETA")
}

@(test)
rejects_context_that_does_not_match :: proc(t: ^testing.T) {
	// This is the central strictness rule. A fuzzy patcher would find "beta"
	// one line down and apply anyway, producing content the session never had.
	source := "alpha\nbeta\ngamma\n"
	patch := `@@ -2,1 +2,1 @@
-DIFFERENT
+BETA
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Context_Mismatch)
}

@(test)
rejects_a_hunk_offset_by_one_line :: proc(t: ^testing.T) {
	// The patch is internally valid and its content exists in the source, just
	// not where the hunk says. Strict application must still refuse: guessing
	// the offset is exactly the fuzzy behavior docs/05 forbids.
	source := "prelude\nalpha\nbeta\ngamma\n"
	patch := `@@ -2,1 +2,1 @@
-beta
+BETA
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Context_Mismatch)
}

@(test)
rejects_whitespace_only_differences :: proc(t: ^testing.T) {
	// Whitespace is frequently the thing an edit changed, so it cannot be
	// treated as noise.
	source := "if x:\n    return 1\n"
	patch := `@@ -2,1 +2,1 @@
-  return 1
+  return 2
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Context_Mismatch)
}

@(test)
rejects_a_hunk_past_the_end_of_the_source :: proc(t: ^testing.T) {
	source := "only\n"
	patch := `@@ -50,1 +50,1 @@
-missing
+replacement
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Line_Out_Of_Range)
}

@(test)
rejects_overlapping_or_unordered_hunks :: proc(t: ^testing.T) {
	source := "a\nb\nc\nd\n"
	patch := `@@ -3,1 +3,1 @@
-c
+C
@@ -1,1 +1,1 @@
-a
+A
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Overlapping_Hunks)
}

@(test)
rejects_a_body_disagreeing_with_declared_counts :: proc(t: ^testing.T) {
	source := "a\nb\nc\n"
	// The header promises three source lines but the body supplies one.
	patch := `@@ -1,3 +1,3 @@
-a
+A
`
	_, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.Malformed_Hunk)
}

@(test)
rejects_malformed_headers :: proc(t: ^testing.T) {
	cases := []string {
		"@@ this is not a range @@\n context\n",
		"@@ -x,1 +1,1 @@\n-a\n+b\n",
		"@@ -1,1 1,1 @@\n-a\n+b\n",
		"@@ -1,1 +1,1\n-a\n+b\n",
	}
	for text in cases {
		patch, reason := replay.parse_patch(transmute([]byte)text)
		if reason == .None {
			replay.patch_destroy(&patch)
		}
		testing.expectf(t, reason != .None, "malformed header was accepted: %q", text)
	}
}

@(test)
rejects_an_empty_patch :: proc(t: ^testing.T) {
	patch, reason := replay.parse_patch(transmute([]byte)string(""))
	if reason == .None {
		replay.patch_destroy(&patch)
	}
	testing.expect_value(t, reason, replay.Patch_Error.Empty_Patch)

	patch2, reason2 := replay.parse_patch(transmute([]byte)string("--- a/x\n+++ b/x\n"))
	if reason2 == .None {
		replay.patch_destroy(&patch2)
	}
	testing.expect_value(t, reason2, replay.Patch_Error.Empty_Patch)
}

@(test)
ignores_file_headers_before_the_first_hunk :: proc(t: ^testing.T) {
	// The canonical mutation already names the path; a path read from inside
	// patch text would bypass the normalization that prevents escapes.
	source := "value\n"
	patch := `--- a/../../etc/passwd
+++ b/../../etc/passwd
@@ -1,1 +1,1 @@
-value
+changed
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "changed\n")
}

@(test)
split_and_join_round_trip_exactly :: proc(t: ^testing.T) {
	cases := []string {
		"",
		"one line no newline",
		"trailing newline\n",
		"a\nb\nc\n",
		"a\nb\nc",
		"\n\n\n",
		"windows\r\nline\r\n",
	}
	for text in cases {
		lines := replay.split_lines(transmute([]byte)text)
		defer delete(lines)
		joined := replay.join_lines(lines)
		defer delete(joined)
		testing.expectf(
			t,
			string(joined) == text,
			"round trip changed %q into %q",
			text,
			string(joined),
		)
	}
}

@(test)
applies_a_patch_that_empties_a_file :: proc(t: ^testing.T) {
	source := "gone\n"
	patch := `@@ -1,1 +0,0 @@
-gone
`
	result, reason := apply(source, patch)
	testing.expect_value(t, reason, replay.Patch_Error.None)
	testing.expect_value(t, result, "")
}
