package test_core

import "core:testing"
import "src:core"

@(test)
normalize_path_accepts_ordinary_relative_paths :: proc(t: ^testing.T) {
	Case :: struct {
		input:    string,
		expected: string,
	}
	cases := []Case {
		{"src/main.odin", "src/main.odin"},
		{"README.md", "README.md"},
		{"./src/core/path.odin", "src/core/path.odin"},
		{"src//core///path.odin", "src/core/path.odin"},
		{"src/core/", "src/core"},
		{`src\core\path.odin`, "src/core/path.odin"},
		{"a/./b/./c", "a/b/c"},
		{"deeply/nested/path/to/file.txt", "deeply/nested/path/to/file.txt"},
	}

	for c in cases {
		normalized, reason := core.normalize_path(c.input)
		defer delete(normalized)
		testing.expectf(t, reason == .None, "%q was rejected as %v", c.input, reason)
		testing.expectf(
			t,
			normalized == c.expected,
			"%q normalized to %q, expected %q",
			c.input,
			normalized,
			c.expected,
		)
	}
}

@(test)
normalize_path_rejects_escaping_and_hostile_paths :: proc(t: ^testing.T) {
	Case :: struct {
		input:  string,
		reason: core.Path_Rejection,
	}
	cases := []Case {
		{"", .Empty},
		{"/etc/passwd", .Absolute},
		{`\windows\system32`, .Absolute},
		{`\\server\share\file`, .Unc_Prefix},
		{`C:\Users\someone`, .Drive_Prefix},
		{"c:/users/someone", .Drive_Prefix},
		{"../outside", .Parent_Component},
		{"src/../../etc/passwd", .Parent_Component},
		{"src/../src/main.odin", .Parent_Component},
		{"a/b/..", .Parent_Component},
		{".", .Empty_After_Normalization},
		{"./", .Empty_After_Normalization},
		{"//", .Absolute},
		{"src/\x00/etc", .Embedded_Nul},
	}

	for c in cases {
		normalized, reason := core.normalize_path(c.input)
		defer delete(normalized)
		testing.expectf(
			t,
			reason == c.reason,
			"%q rejected as %v, expected %v",
			c.input,
			reason,
			c.reason,
		)
		testing.expectf(t, normalized == "", "rejected path %q must return no value", c.input)
	}
}

@(test)
normalize_path_never_resolves_parent_components :: proc(t: ^testing.T) {
	// Resolving ".." against an earlier component would make this path reduce
	// to "safe/file", hiding that the trace described an escape attempt.
	normalized, reason := core.normalize_path("safe/../../../etc/shadow")
	defer delete(normalized)
	testing.expect_value(t, reason, core.Path_Rejection.Parent_Component)
}

@(test)
normalize_path_rejects_overlong_input :: proc(t: ^testing.T) {
	long := make([]byte, core.MAX_PATH_BYTES + 1)
	defer delete(long)
	for i in 0 ..< len(long) {
		long[i] = 'a'
	}

	normalized, reason := core.normalize_path(string(long))
	defer delete(normalized)
	testing.expect_value(t, reason, core.Path_Rejection.Too_Long)
}

@(test)
normalize_path_rejects_invalid_utf8 :: proc(t: ^testing.T) {
	// A lone continuation byte is not valid UTF-8.
	normalized, reason := core.normalize_path("src/\xff\xfe.odin")
	defer delete(normalized)
	testing.expect_value(t, reason, core.Path_Rejection.Invalid_Utf8)
}

@(test)
is_normalized_path_agrees_with_normalize_path :: proc(t: ^testing.T) {
	accepted := []string{"src/main.odin", "a", "a/b/c.txt"}
	for path in accepted {
		testing.expectf(t, core.is_normalized_path(path), "%q should be canonical", path)
	}

	rejected := []string {
		"",
		"/abs",
		"./rel",
		"a//b",
		"a/../b",
		"a/./b",
		"a/",
		`a\b`,
		"C:/x",
	}
	for path in rejected {
		testing.expectf(t, !core.is_normalized_path(path), "%q should not be canonical", path)
	}
}

@(test)
normalize_path_output_is_canonical :: proc(t: ^testing.T) {
	// Whatever normalize_path accepts must satisfy is_normalized_path, or the
	// codec would reject paths the importer just produced.
	inputs := []string {
		"src/main.odin",
		"./a/b",
		"a//b//c",
		`a\b\c`,
		"a/./b/",
		"single",
	}
	for input in inputs {
		normalized, reason := core.normalize_path(input)
		defer delete(normalized)
		if reason != .None {
			continue
		}
		testing.expectf(
			t,
			core.is_normalized_path(normalized),
			"normalize_path(%q) produced non-canonical %q",
			input,
			normalized,
		)
	}
}
