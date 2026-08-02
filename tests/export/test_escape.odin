package test_export

import "core:strings"
import "core:testing"

import "src:export"

// Encoding of untrusted trace text.
//
// docs/08-security.md: opening or replaying a trace must never render
// arbitrary HTML or active document content. A trace is untrusted input, so
// these tests treat its text as hostile and assert it cannot escape either
// encoding.

@(private)
html :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	export.escape_html(&builder, value)
	return strings.to_string(builder)
}

@(private)
json :: proc(value: string) -> string {
	builder := strings.builder_make(context.temp_allocator)
	export.escape_json(&builder, value)
	return strings.to_string(builder)
}

@(test)
html_escapes_every_metacharacter :: proc(t: ^testing.T) {
	testing.expect_value(t, html("&"), "&amp;")
	testing.expect_value(t, html("<"), "&lt;")
	testing.expect_value(t, html(">"), "&gt;")
	testing.expect_value(t, html("\""), "&quot;")
	testing.expect_value(t, html("'"), "&#39;")
}

@(test)
html_neutralizes_script_injection :: proc(t: ^testing.T) {
	// A prompt or command line containing markup must render as text. This is
	// the case that matters most: a session transcript is exactly where an
	// attacker-supplied string would arrive.
	hostile := []string {
		"<script>alert(1)</script>",
		"<img src=x onerror=alert(1)>",
		"</title><script>alert(1)</script>",
		"<svg/onload=alert(1)>",
		"javascript:alert(1)",
		"\"><script>alert(1)</script>",
		"'; DROP TABLE users; --",
		"<iframe src='evil'></iframe>",
	}

	for input in hostile {
		encoded := html(input)
		testing.expectf(
			t,
			!strings.contains(encoded, "<"),
			"encoded output of %q still contains a raw '<': %q",
			input,
			encoded,
		)
		testing.expectf(
			t,
			!strings.contains(encoded, ">"),
			"encoded output of %q still contains a raw '>': %q",
			input,
			encoded,
		)
	}
}

@(test)
html_escaping_is_safe_inside_an_attribute :: proc(t: ^testing.T) {
	// The same procedure encodes element content and attribute values, so a
	// quote must not survive to close an attribute early.
	encoded := html(`" onmouseover="alert(1)`)
	testing.expect(t, !strings.contains(encoded, `"`))
	testing.expect(t, strings.contains(encoded, "&quot;"))
}

@(test)
html_drops_control_characters :: proc(t: ^testing.T) {
	// A control character in a report is never content the user wants, and
	// some renderers treat them as formatting instructions.
	encoded := html("before\x00\x07\x1baftertext")
	testing.expect(t, !strings.contains(encoded, "\x00"))
	testing.expect(t, !strings.contains(encoded, "\x07"))
	testing.expect(t, !strings.contains(encoded, "\x1b"))
	testing.expect(t, strings.contains(encoded, "before"))
	testing.expect(t, strings.contains(encoded, "aftertext"))
}

@(test)
html_preserves_ordinary_whitespace :: proc(t: ^testing.T) {
	// Tabs and newlines are meaningful in command output and diffs.
	encoded := html("line one\n\tindented")
	testing.expect(t, strings.contains(encoded, "\n"))
	testing.expect(t, strings.contains(encoded, "\t"))
}

@(test)
json_escapes_the_required_characters :: proc(t: ^testing.T) {
	testing.expect_value(t, json(`"`), `\"`)
	testing.expect_value(t, json(`\`), `\\`)
	testing.expect_value(t, json("\n"), `\n`)
	testing.expect_value(t, json("\r"), `\r`)
	testing.expect_value(t, json("\t"), `\t`)
}

@(test)
json_escapes_control_characters_as_unicode :: proc(t: ^testing.T) {
	// A raw control byte inside a JSON string is invalid per RFC 8259, so it
	// must become an escape rather than pass through.
	testing.expect_value(t, json("\x00"), "\\u0000")
	testing.expect_value(t, json("\x1f"), "\\u001f")
	testing.expect_value(t, json("\x7f"), "\\u007f")
}

@(test)
json_cannot_break_out_of_an_embedded_script_context :: proc(t: ^testing.T) {
	// JSON does not require escaping '<' or '/', but a JSON document placed
	// inside an HTML page can otherwise be terminated by a "</script>"
	// sequence appearing inside a string value.
	encoded := json("</script><script>alert(1)</script>")
	testing.expect(t, !strings.contains(encoded, "<"))
	testing.expect(t, !strings.contains(encoded, ">"))
	testing.expect(t, !strings.contains(encoded, "</"))
}

@(test)
json_string_helper_wraps_in_quotes :: proc(t: ^testing.T) {
	builder := strings.builder_make(context.temp_allocator)
	export.write_json_string(&builder, `say "hi"`)
	testing.expect_value(t, strings.to_string(builder), `"say \"hi\""`)
}

@(test)
json_preserves_multibyte_utf8 :: proc(t: ^testing.T) {
	// Continuation bytes must pass through unchanged: JSON strings are UTF-8,
	// and re-encoding them byte by byte would corrupt the text.
	input := "café — naïve 日本語"
	testing.expect_value(t, json(input), input)
}

@(test)
sanitize_replaces_invalid_utf8 :: proc(t: ^testing.T) {
	// Ill-formed input can be interpreted differently by the exporter and by
	// whatever later reads the file. Replacing it makes both agree.
	result := export.sanitize_text("valid\xff\xfetail")
	defer delete(result)

	testing.expect(t, strings.contains(result, "valid"))
	testing.expect(t, strings.contains(result, "tail"))
	testing.expect(t, !strings.contains(result, "\xff"))
}

@(test)
sanitize_leaves_valid_text_unchanged :: proc(t: ^testing.T) {
	input := "ordinary text with — punctuation"
	result := export.sanitize_text(input)
	defer delete(result)
	testing.expect_value(t, result, input)
}

@(test)
truncate_reports_when_it_shortens :: proc(t: ^testing.T) {
	short := "brief"
	result, truncated := export.truncate_text(short)
	testing.expect_value(t, result, short)
	testing.expect(t, !truncated)

	long := strings.repeat("x", export.MAX_EXPORTED_TEXT + 100, context.temp_allocator)
	result, truncated = export.truncate_text(long)
	testing.expect(t, truncated, "exceeding the limit must be reported, not silent")
	testing.expect(t, len(result) <= export.MAX_EXPORTED_TEXT)
}

@(test)
truncate_cuts_on_a_utf8_boundary :: proc(t: ^testing.T) {
	// Cutting mid-sequence would produce invalid UTF-8 in the output, which
	// the encoders would then have to repair.
	prefix := strings.repeat("a", export.MAX_EXPORTED_TEXT - 1, context.temp_allocator)
	input := strings.concatenate({prefix, "日本語"}, context.temp_allocator)

	result, truncated := export.truncate_text(input)
	testing.expect(t, truncated)

	// The result must not end inside a multi-byte sequence.
	if len(result) > 0 {
		last := result[len(result) - 1]
		testing.expect(
			t,
			last < 0x80 || last >= 0xC0 || len(result) < len(input),
			"truncation must not leave a dangling continuation byte",
		)
	}
	sanitized := export.sanitize_text(result)
	defer delete(sanitized)
	testing.expect_value(t, len(sanitized), len(result))
}
