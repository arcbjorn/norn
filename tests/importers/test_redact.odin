package test_importers

import "core:strings"
import "core:testing"

import api "src:importers/api"
import "src:trace/codec"

// Redaction.
//
// docs/08-security.md governs this. A missed secret is a secret written to an
// artifact the user may share, so these tests are adversarial about what gets
// through — and equally about what does not, because over-redaction destroys
// the information the trace exists to preserve.

@(private)
redact_with :: proc(redactor: ^api.Redactor, text: string) -> string {
	return api.redact(redactor, text)
}

@(test)
a_url_password_is_removed_but_the_host_survives :: proc(t: ^testing.T) {
	// docs/08 names URL user information specifically. The host stays because
	// which host was contacted is diagnostic information the user needs.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	result := redact_with(&redactor, "cloning https://alice:hunter2@github.com/org/repo.git")
	defer delete(result)

	testing.expect(t, !strings.contains(result, "hunter2"), "the password must be gone")
	testing.expect(t, !strings.contains(result, "alice"), "the user must be gone")
	testing.expect(t, strings.contains(result, "github.com"), "the host must survive")
	testing.expect(t, strings.contains(result, "repo.git"), "the path must survive")
	testing.expect(t, strings.contains(result, api.MARKER_PREFIX), "the marker must appear")
}

@(test)
a_url_without_credentials_is_untouched :: proc(t: ^testing.T) {
	// Over-redaction is its own failure. An ordinary URL carries no secret.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	original := "fetched https://github.com/org/repo/blob/main/src/main.odin"
	result := redact_with(&redactor, original)
	defer delete(result)

	testing.expect_value(t, result, original)
	testing.expect_value(t, api.total_redactions(&redactor), 0)
}

@(test)
known_credential_prefixes_are_replaced :: proc(t: ^testing.T) {
	// Provider token prefixes are the one shape that can be matched precisely
	// rather than heuristically.
	cases := []string {
		"sk-NOTAREALTOKENEXAMPLEONLYFAKE1234",
		"ghp_NOTAREALTOKENEXAMPLEONLYFAKE1234",
		"xoxb-NOTAREALTOKEN-EXAMPLEONLY",
		"AKIANOTAREALKEYEXAMP",
	}

	for secret in cases {
		redactor: api.Redactor
		api.redactor_init(&redactor)
		defer api.redactor_destroy(&redactor)

		text := strings.concatenate({"the key is ", secret, " apparently"}, context.temp_allocator)
		result := redact_with(&redactor, text)
		defer delete(result)

		testing.expectf(
			t,
			!strings.contains(result, secret),
			"the credential %q survived as %q",
			secret,
			result,
		)
		testing.expect(t, strings.contains(result, "the key is"), "context must survive")
		testing.expect(t, strings.contains(result, "apparently"), "context must survive")
	}
}

@(test)
a_short_prefix_match_is_left_alone :: proc(t: ^testing.T) {
	// "sk-" appears in ordinary text. Redacting every occurrence would destroy
	// content for no security gain, so a match must be long enough to be a
	// plausible token.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	original := "the sk-1 flag was passed"
	result := redact_with(&redactor, original)
	defer delete(result)

	testing.expect_value(t, result, original)
}

@(test)
sensitive_environment_values_are_replaced :: proc(t: ^testing.T) {
	// docs/08: configured environment-variable names are redacted. Matching on
	// the name catches a token that looks like ordinary text.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	result := redact_with(&redactor, "GITHUB_TOKEN=abc123def\nPATH=/usr/bin\n")
	defer delete(result)

	testing.expect(t, !strings.contains(result, "abc123def"), "the value must be gone")
	testing.expect(t, strings.contains(result, "GITHUB_TOKEN="), "the name must survive")
	testing.expect(t, strings.contains(result, "/usr/bin"), "an unrelated variable must survive")
}

@(test)
redaction_stops_at_the_end_of_a_line :: proc(t: ^testing.T) {
	// A value that swallowed the rest of an environment dump would destroy
	// every variable after it.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	result := redact_with(
		&redactor,
		"SECRET_KEY=topsecret\nHOME=/home/user\nEDITOR=vim\n",
	)
	defer delete(result)

	testing.expect(t, !strings.contains(result, "topsecret"))
	testing.expect(t, strings.contains(result, "EDITOR=vim"), "later variables must survive")
}

@(test)
a_home_prefix_becomes_a_stable_placeholder :: proc(t: ^testing.T) {
	// docs/08: home-directory prefixes are replaced with a stable placeholder.
	// Stable so two traces from one machine produce the same text, which keeps
	// exports diffable.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	first := redact_with(&redactor, "/Users/someone/projects/norn/src/main.odin")
	defer delete(first)
	second := redact_with(&redactor, "/Users/someone/projects/norn/README.md")
	defer delete(second)

	testing.expect(t, !strings.contains(first, "someone"), "the username must be gone")
	testing.expect(t, strings.contains(first, "projects/norn"), "the path tail must survive")
	testing.expect(
		t,
		strings.has_prefix(first, api.rule_marker(.Home_Path_Prefix)),
		"the placeholder must be stable",
	)
	testing.expect(
		t,
		strings.has_prefix(second, api.rule_marker(.Home_Path_Prefix)),
		"the same placeholder must appear for both",
	)
}

@(test)
the_root_directory_is_not_a_home_prefix :: proc(t: ^testing.T) {
	// Replacing "/" would rewrite every absolute path to the marker, which
	// destroys the information the path carried.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/")

	original := "/usr/local/bin/odin"
	result := redact_with(&redactor, original)
	defer delete(result)

	testing.expect_value(t, result, original)
}

@(test)
user_literals_are_replaced :: proc(t: ^testing.T) {
	// docs/08 allows user-supplied literal rules, for the cases only the user
	// knows: a project name, an internal hostname.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_literal(&redactor, "internal.example.corp")

	result := redact_with(&redactor, "deploying to internal.example.corp now")
	defer delete(result)

	testing.expect(t, !strings.contains(result, "internal.example.corp"))
	testing.expect(t, strings.contains(result, "deploying to"))
}

@(test)
counts_are_recorded_by_category :: proc(t: ^testing.T) {
	// docs/08: "reports list rule identifiers and counts, never matched
	// values." The counts are what the import report shows.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	one := redact_with(&redactor, "/Users/someone/a")
	defer delete(one)
	two := redact_with(&redactor, "/Users/someone/b")
	defer delete(two)
	three := redact_with(&redactor, "GITHUB_TOKEN=abc123def456")
	defer delete(three)

	testing.expect_value(
		t,
		redactor.counts[int(codec.Redaction_Category.Home_Path_Prefix)],
		u32(2),
	)
	testing.expect_value(
		t,
		redactor.counts[int(codec.Redaction_Category.Environment_Variable)],
		u32(1),
	)
	testing.expect_value(t, api.total_redactions(&redactor), 3)
}

@(test)
ordinary_text_passes_through_unchanged :: proc(t: ^testing.T) {
	// The most important non-security property: redaction must not corrupt a
	// session's actual content. A trace full of markers is useless.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	cases := []string {
		"",
		"running odin test tests/core",
		"src/trace/codec/reader.odin:114:2: error: undefined identifier",
		"commit 3c146e0a5f2b1d8e9c4a7f6b2d1e8c9a4f7b6d2e",
		"the quick brown fox jumps over the lazy dog",
		"PATH=/usr/local/bin:/usr/bin",
		"https://example.com/path?query=value#fragment",
		"{\"key\": \"value\", \"count\": 42}",
	}

	for original in cases {
		result := redact_with(&redactor, original)
		defer delete(result)
		testing.expectf(t, result == original, "%q was altered to %q", original, result)
	}
}

@(test)
redaction_is_idempotent :: proc(t: ^testing.T) {
	// Redacting an already-redacted string must not nest markers, or repeated
	// passes over the same content would corrupt it.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	once := redact_with(&redactor, "/Users/someone/projects/norn")
	defer delete(once)
	twice := redact_with(&redactor, once)
	defer delete(twice)

	testing.expect_value(t, twice, once)
}

@(test)
a_marker_is_detectable :: proc(t: ^testing.T) {
	// docs/03 invariant 8: redacted content cannot remain in a preserved raw
	// record, so the writer needs to recognise a redacted string.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_literal(&redactor, "secret")

	result := redact_with(&redactor, "the secret value")
	defer delete(result)

	testing.expect(t, api.contains_marker(result))
	testing.expect(t, !api.contains_marker("ordinary text"))
}

@(test)
multiple_secrets_in_one_string_are_all_replaced :: proc(t: ^testing.T) {
	// A rule that stopped after the first match would leak every later one.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	result := redact_with(
		&redactor,
		"cp /Users/someone/a.txt /Users/someone/b.txt && echo /Users/someone/c",
	)
	defer delete(result)

	testing.expect(t, !strings.contains(result, "someone"), "no occurrence may survive")
	testing.expect_value(
		t,
		redactor.counts[int(codec.Redaction_Category.Home_Path_Prefix)],
		u32(3),
	)
}

@(test)
the_result_is_always_owned_by_the_caller :: proc(t: ^testing.T) {
	// Ownership that depended on whether anything matched is the kind of rule
	// callers get wrong, so the result is always a fresh allocation.
	redactor: api.Redactor
	api.redactor_init(&redactor)
	defer api.redactor_destroy(&redactor)

	unmatched := redact_with(&redactor, "nothing to redact here")
	delete(unmatched)

	api.add_literal(&redactor, "redact")
	matched := redact_with(&redactor, "nothing to redact here")
	delete(matched)

	empty := redact_with(&redactor, "")
	delete(empty)
}
