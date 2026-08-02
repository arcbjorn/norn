package export

import "core:strings"
import "core:unicode/utf8"

// Text encoding for untrusted trace content.
//
// docs/08-security.md: provider records never become format strings, shader
// source, file paths, command arguments, or markup without appropriate
// encoding and validation. Everything an export writes originates in a trace,
// and a trace can be downloaded or produced by a compromised tool, so every
// string passes through one of these procedures.
//
// The encoders are deliberately aggressive. Escaping a character that did not
// strictly need escaping costs a few bytes; missing one that did produces an
// export that executes attacker content in the reader's browser.

// escape_html writes `value` with HTML metacharacters replaced by entities.
//
// All five of `& < > " '` are escaped rather than only the three that matter
// in element content, because the same procedure is used for attribute values
// and getting that distinction wrong once is enough.
//
// Control characters other than tab, newline, and carriage return are dropped:
// they carry no meaning in a report and some terminals and browsers treat them
// as formatting instructions.
escape_html :: proc(builder: ^strings.Builder, value: string) {
	for index := 0; index < len(value); index += 1 {
		c := value[index]
		switch c {
		case '&':  strings.write_string(builder, "&amp;")
		case '<':  strings.write_string(builder, "&lt;")
		case '>':  strings.write_string(builder, "&gt;")
		case '"':  strings.write_string(builder, "&quot;")
		case '\'': strings.write_string(builder, "&#39;")
		case '\t', '\n', '\r':
			strings.write_byte(builder, c)
		case:
			if c < 0x20 || c == 0x7F {
				// Dropped rather than escaped: a control character in a report
				// is never content the user wants to read.
				continue
			}
			strings.write_byte(builder, c)
		}
	}
}

// escape_json writes `value` as the interior of a JSON string.
//
// Escaping follows RFC 8259. The quote characters themselves are not written,
// so callers control whether the result is a key or a value.
//
// `<` and `/` are additionally escaped. Neither is required by JSON, but a
// JSON document embedded in an HTML page can otherwise be terminated early by
// a `</script>` sequence inside a string, and the export writes both formats
// from the same data.
escape_json :: proc(builder: ^strings.Builder, value: string) {
	for index := 0; index < len(value); index += 1 {
		c := value[index]
		switch c {
		case '"':  strings.write_string(builder, `\"`)
		case '\\': strings.write_string(builder, `\\`)
		case '\n': strings.write_string(builder, `\n`)
		case '\r': strings.write_string(builder, `\r`)
		case '\t': strings.write_string(builder, `\t`)
		case '\b': strings.write_string(builder, `\b`)
		case '\f': strings.write_string(builder, `\f`)
		case '<':  strings.write_string(builder, `\u003c`)
		case '>':  strings.write_string(builder, `\u003e`)
		case '/':  strings.write_string(builder, `\/`)
		case:
			if c < 0x20 || c == 0x7F {
				write_unicode_escape(builder, c)
			} else {
				// Bytes at or above 0x20 pass through, including UTF-8
				// continuation bytes: JSON strings are UTF-8 and a multi-byte
				// sequence must not be re-encoded byte by byte.
				strings.write_byte(builder, c)
			}
		}
	}
}

@(private)
HEX :: [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}

@(private)
write_unicode_escape :: proc(builder: ^strings.Builder, c: u8) {
	digits := HEX
	strings.write_string(builder, `\u00`)
	strings.write_byte(builder, digits[c >> 4])
	strings.write_byte(builder, digits[c & 0x0F])
}

// write_json_string writes a complete quoted JSON string.
write_json_string :: proc(builder: ^strings.Builder, value: string) {
	strings.write_byte(builder, '"')
	escape_json(builder, value)
	strings.write_byte(builder, '"')
}

// sanitize_text returns a copy of `value` safe to place in either format.
//
// Invalid UTF-8 is replaced rather than passed through: a trace is untrusted
// input, and an ill-formed sequence can be interpreted differently by the
// exporter and by whatever later reads the file. Replacing it makes both agree.
//
// The caller owns the result.
sanitize_text :: proc(value: string, allocator := context.allocator) -> string {
	if utf8.valid_string(value) {
		return strings.clone(value, allocator)
	}

	builder := strings.builder_make(allocator)
	for index := 0; index < len(value); {
		r, width := utf8.decode_rune_in_string(value[index:])
		if r == utf8.RUNE_ERROR && width <= 1 {
			strings.write_rune(&builder, '�')
			index += 1
			continue
		}
		strings.write_rune(&builder, r)
		index += width
	}
	return strings.to_string(builder)
}

// MAX_EXPORTED_TEXT bounds a single exported string.
//
// An export is a bug report, not an archive. A trace may hold a multi-megabyte
// command output; including it whole would produce a report nobody can open
// and would defeat the purpose of a bounded artifact.
MAX_EXPORTED_TEXT :: 64 * 1024

// truncate_text shortens a string to the export limit.
//
// Truncation is reported rather than silent: the second return value tells the
// caller to mark the value as incomplete, because a diff or command output cut
// short without a label reads as complete evidence.
truncate_text :: proc(value: string) -> (result: string, truncated: bool) {
	if len(value) <= MAX_EXPORTED_TEXT {
		return value, false
	}

	// Cut on a UTF-8 boundary so the result stays well-formed.
	limit := MAX_EXPORTED_TEXT
	for limit > 0 && (value[limit] & 0xC0) == 0x80 {
		limit -= 1
	}
	return value[:limit], true
}
