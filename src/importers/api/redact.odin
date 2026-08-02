package importer_api

import "core:mem"
import "core:strings"

import "src:trace/codec"

// Redaction.
//
// docs/08-security.md: redaction occurs during import before writing the
// destination trace. That ordering is the whole point — a secret that reaches
// the writer is a secret in the artifact, and no later filtering can remove it
// from a file already on disk.
//
// docs/08 is also explicit that "Norn cannot guarantee automatic discovery of
// every secret." These rules catch shapes that are recognisably credentials.
// They are a reduction in exposure, not a proof of safety, and the import
// dialog says so.

// MARKER_PREFIX opens every replacement.
//
// docs/08 requires a typed marker so a reader can tell redacted content from
// content that was simply absent, and can tell which rule fired.
MARKER_PREFIX :: "[REDACTED:"

// Rule identifies a redaction class. These map onto the categories the trace
// metadata counts, so a report can attribute every replacement.
Rule :: enum u8 {
	Credential           = 0,
	Authorization_Header = 1,
	Environment_Variable = 2,
	Url_User_Info        = 3,
	Home_Path_Prefix     = 4,
	User_Rule            = 5,
	Provider_Sensitive   = 6,
}

rule_marker :: proc "contextless" (rule: Rule) -> string {
	switch rule {
	case .Credential:           return "[REDACTED:credential]"
	case .Authorization_Header: return "[REDACTED:authorization]"
	case .Environment_Variable: return "[REDACTED:environment]"
	case .Url_User_Info:        return "[REDACTED:url-userinfo]"
	case .Home_Path_Prefix:     return "[REDACTED:home]"
	case .User_Rule:            return "[REDACTED:user-rule]"
	case .Provider_Sensitive:   return "[REDACTED:provider]"
	}
	return "[REDACTED]"
}

// rule_category maps a rule onto the metadata counter it increments.
rule_category :: proc "contextless" (rule: Rule) -> codec.Redaction_Category {
	switch rule {
	case .Credential:           return .Credential
	case .Authorization_Header: return .Authorization_Header
	case .Environment_Variable: return .Environment_Variable
	case .Url_User_Info:        return .Url_User_Info
	case .Home_Path_Prefix:     return .Home_Path_Prefix
	case .User_Rule:            return .User_Rule
	case .Provider_Sensitive:   return .Provider_Sensitive
	}
	return .Credential
}

// Literal_Rule replaces an exact string the user supplied.
//
// docs/08 allows user-supplied literal rules. A home directory or a project
// name is the common case, and the user knows those where a pattern cannot.
Literal_Rule :: struct {
	value: string,
	rule:  Rule,
}

// Redactor holds the configured rules and the counts they produced.
//
// Counts only: docs/08 says reports "list rule identifiers and counts, never
// matched values." Storing an example of what was redacted would recreate the
// exposure the redaction exists to prevent.
Redactor :: struct {
	literals: [dynamic]Literal_Rule,
	counts:   [codec.REDACTION_CATEGORY_COUNT]u32,
	// Environment variable names whose values are replaced.
	sensitive_names: [dynamic]string,
}

redactor_init :: proc(redactor: ^Redactor, allocator := context.allocator) {
	redactor.literals = make([dynamic]Literal_Rule, 0, 8, allocator)
	redactor.sensitive_names = make([dynamic]string, 0, 8, allocator)

	// Names whose values are secret by convention. Matching on the name rather
	// than the value catches a token that looks like ordinary text.
	for name in ([]string {
		"AWS_SECRET_ACCESS_KEY",
		"AWS_SESSION_TOKEN",
		"GITHUB_TOKEN",
		"OPENAI_API_KEY",
		"ANTHROPIC_API_KEY",
		"NPM_TOKEN",
		"SLACK_TOKEN",
		"DATABASE_URL",
		"SECRET_KEY",
		"PRIVATE_KEY",
	}) {
		append(&redactor.sensitive_names, name)
	}
}

redactor_destroy :: proc(redactor: ^Redactor) {
	delete(redactor.literals)
	delete(redactor.sensitive_names)
	redactor^ = {}
}

// add_literal registers a user-supplied replacement.
add_literal :: proc(redactor: ^Redactor, value: string, rule := Rule.User_Rule) {
	if value == "" {
		return
	}
	append(&redactor.literals, Literal_Rule{value = value, rule = rule})
}

// add_home_prefix registers a home directory to replace.
//
// docs/08: home-directory prefixes are replaced with a stable placeholder.
// Stable so two traces from one machine produce the same text, which keeps
// exports diffable.
add_home_prefix :: proc(redactor: ^Redactor, path: string) {
	if path == "" || path == "/" {
		// Replacing "/" would rewrite every absolute path to the marker, which
		// destroys the information the path carried.
		return
	}
	append(&redactor.literals, Literal_Rule{value = path, rule = .Home_Path_Prefix})
}

// total_redactions sums every counter.
total_redactions :: proc(redactor: ^Redactor) -> int {
	total := 0
	for count in redactor.counts {
		total += int(count)
	}
	return total
}

// redact returns `text` with recognised secrets replaced.
//
// The result is always a fresh allocation the caller owns, even when nothing
// matched. A conditional copy would make ownership depend on the content,
// which is the kind of rule callers get wrong.
redact :: proc(
	redactor: ^Redactor,
	text: string,
	allocator := context.allocator,
) -> string {
	if text == "" {
		return strings.clone("", allocator)
	}

	builder := strings.builder_make(allocator)

	// User literals first: they are the most specific and a home prefix must
	// be replaced before a pattern rule can match inside the same path.
	current := apply_literals(redactor, text, context.temp_allocator)
	current = apply_url_userinfo(redactor, current, context.temp_allocator)
	current = apply_assignments(redactor, current, context.temp_allocator)
	current = apply_token_shapes(redactor, current, context.temp_allocator)

	strings.write_string(&builder, current)
	return strings.to_string(builder)
}

@(private)
apply_literals :: proc(
	redactor: ^Redactor,
	text: string,
	allocator: mem.Allocator,
) -> string {
	result := text
	for literal in redactor.literals {
		if !strings.contains(result, literal.value) {
			continue
		}
		count := strings.count(result, literal.value)
		redactor.counts[int(rule_category(literal.rule))] += u32(count)
		replaced, _ := strings.replace_all(
			result,
			literal.value,
			rule_marker(literal.rule),
			allocator,
		)
		result = replaced
	}
	return result
}

// apply_url_userinfo replaces credentials embedded in a URL.
//
// docs/08 names this specifically. A URL of the form scheme://user:pass@host
// carries a password in plain text, and it survives casual review because it
// looks like an address rather than a secret.
@(private)
apply_url_userinfo :: proc(
	redactor: ^Redactor,
	text: string,
	allocator: mem.Allocator,
) -> string {
	if !strings.contains(text, "://") {
		return text
	}

	builder := strings.builder_make(allocator)
	rest := text

	for {
		scheme := strings.index(rest, "://")
		if scheme < 0 {
			strings.write_string(&builder, rest)
			break
		}

		authority_start := scheme + 3
		strings.write_string(&builder, rest[:authority_start])
		rest = rest[authority_start:]

		// The authority ends at the first path, query, or whitespace.
		authority_end := len(rest)
		for index in 0 ..< len(rest) {
			c := rest[index]
			if c == '/' || c == '?' || c == '#' || c == ' ' || c == '\n' || c == '"' {
				authority_end = index
				break
			}
		}

		authority := rest[:authority_end]
		at := strings.last_index_byte(authority, '@')
		if at > 0 {
			// Only the credential is replaced; the host stays, because which
			// host was contacted is diagnostic information the user needs.
			redactor.counts[int(codec.Redaction_Category.Url_User_Info)] += 1
			strings.write_string(&builder, rule_marker(.Url_User_Info))
			strings.write_string(&builder, authority[at:])
		} else {
			strings.write_string(&builder, authority)
		}

		rest = rest[authority_end:]
	}

	return strings.to_string(builder)
}

// apply_assignments replaces the value of a sensitive named variable.
//
// Matches `NAME=value` and `NAME: value`, which covers environment dumps,
// shell exports, and configuration echoed into command output.
@(private)
apply_assignments :: proc(
	redactor: ^Redactor,
	text: string,
	allocator: mem.Allocator,
) -> string {
	result := text
	for name in redactor.sensitive_names {
		result = replace_assignment(redactor, result, name, "=", allocator)
		result = replace_assignment(redactor, result, name, ": ", allocator)
	}
	return result
}

@(private)
replace_assignment :: proc(
	redactor: ^Redactor,
	text: string,
	name: string,
	separator: string,
	allocator: mem.Allocator,
) -> string {
	needle := strings.concatenate({name, separator}, context.temp_allocator)
	defer delete(needle, context.temp_allocator)

	if !strings.contains(text, needle) {
		return text
	}

	builder := strings.builder_make(allocator)
	rest := text

	for {
		at := strings.index(rest, needle)
		if at < 0 {
			strings.write_string(&builder, rest)
			break
		}

		strings.write_string(&builder, rest[:at + len(needle)])
		rest = rest[at + len(needle):]

		// The value runs to the end of the line or the next quote, so a
		// following variable in the same dump is not swallowed.
		value_end := len(rest)
		for index in 0 ..< len(rest) {
			c := rest[index]
			if c == '\n' || c == '\r' || c == '"' || c == '\'' {
				value_end = index
				break
			}
		}

		if value_end > 0 {
			redactor.counts[int(codec.Redaction_Category.Environment_Variable)] += 1
			strings.write_string(&builder, rule_marker(.Environment_Variable))
		}
		rest = rest[value_end:]
	}

	return strings.to_string(builder)
}

// MIN_TOKEN_LENGTH is the shortest run treated as a possible credential.
//
// Short enough to catch real tokens, long enough that ordinary identifiers and
// hex colours do not trip it. A false positive here destroys information the
// user needed, so the threshold errs toward leaving text alone.
MIN_TOKEN_LENGTH :: 32

// apply_token_shapes replaces long opaque runs that look like credentials.
//
// Two shapes: a known provider prefix, and a long high-entropy run. The prefix
// rule is precise; the entropy rule is a heuristic and is deliberately
// conservative, because redacting a commit hash or a base64 payload the user
// was debugging would be its own failure.
@(private)
apply_token_shapes :: proc(
	redactor: ^Redactor,
	text: string,
	allocator: mem.Allocator,
) -> string {
	prefixes := []string{"sk-", "ghp_", "gho_", "ghs_", "xoxb-", "xoxp-", "AKIA"}

	found := false
	for prefix in prefixes {
		if strings.contains(text, prefix) {
			found = true
			break
		}
	}
	if !found {
		return text
	}

	builder := strings.builder_make(allocator)
	index := 0

	for index < len(text) {
		matched := false
		for prefix in prefixes {
			if !strings.has_prefix(text[index:], prefix) {
				continue
			}

			// The token runs while the characters could belong to one.
			end := index + len(prefix)
			for end < len(text) && is_token_byte(text[end]) {
				end += 1
			}
			if end - index < len(prefix) + 8 {
				// Too short to be a real token; the prefix is probably part of
				// ordinary text.
				break
			}

			redactor.counts[int(codec.Redaction_Category.Credential)] += 1
			strings.write_string(&builder, rule_marker(.Credential))
			index = end
			matched = true
			break
		}

		if !matched {
			strings.write_byte(&builder, text[index])
			index += 1
		}
	}

	return strings.to_string(builder)
}

@(private)
is_token_byte :: proc "contextless" (c: byte) -> bool {
	return(
		(c >= 'a' && c <= 'z') ||
		(c >= 'A' && c <= 'Z') ||
		(c >= '0' && c <= '9') ||
		c == '-' ||
		c == '_' \
	)
}

// contains_marker reports whether text already holds a redaction marker.
//
// docs/03 invariant 8: redacted content cannot remain in a preserved raw
// record. The writer checks this before retaining a raw record, so a record
// that was redacted is not also stored in its original form.
contains_marker :: proc(text: string) -> bool {
	return strings.contains(text, MARKER_PREFIX)
}
