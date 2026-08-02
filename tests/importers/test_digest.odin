package test_importers

import "core:testing"

import api "src:importers/api"
import "src:trace/model"

// Mutation hashes over redacted content.
//
// docs/08 puts redaction before the writer, so a stored blob holds redacted
// bytes and its digest is of those bytes. A mutation hash has to describe the
// same bytes replay will verify.
//
// Getting this wrong is not a visible failure at import time: the trace writes,
// validates, and opens. It fails later, as a hash mismatch on content that
// reconstructed correctly — every redacted mutation becoming a false replay
// gap, in exactly the traces where the user most needs to trust the tool.

@(test)
a_digest_covers_the_bytes_that_are_stored :: proc(t: ^testing.T) {
	sink: api.Sink
	redactor: api.Redactor
	api.redactor_init(&redactor)
	api.sink_init(&sink, &redactor, "test", "1.0.0", "session.jsonl")
	defer api.sink_destroy(&sink)
	defer api.redactor_destroy(&redactor)

	content := "key = \"sk-NOTAREALTOKENEXAMPLEONLYFAKE1234\"\n"

	// What the blob table actually holds after redaction.
	blob := api.add_blob_text(&sink, content)
	entry, found := model.blob_get(&sink.blobs, blob)
	testing.expect(t, found, "the blob must be stored")

	// What an adapter would record as the mutation hash.
	digest := api.content_digest(&sink, content)

	testing.expect(
		t,
		model.digest_equal(digest, entry.digest),
		"the mutation hash must match the stored blob's digest",
	)

	// The naive digest — of the source text — must not match, or this test
	// would pass whether or not redaction was accounted for.
	naive := model.digest_content(transmute([]byte)content)
	testing.expect(
		t,
		!model.digest_equal(naive, entry.digest),
		"the source text must hash differently once redacted",
	)
}

@(test)
a_digest_is_unchanged_when_nothing_is_redacted :: proc(t: ^testing.T) {
	// The ordinary case must stay the plain content hash, or every unredacted
	// trace would carry hashes that no other tool could reproduce.
	sink: api.Sink
	redactor: api.Redactor
	api.redactor_init(&redactor)
	api.sink_init(&sink, &redactor, "test", "1.0.0", "session.jsonl")
	defer api.sink_destroy(&sink)
	defer api.redactor_destroy(&redactor)

	content := "package main\n"

	digest := api.content_digest(&sink, content)
	expected := model.digest_content(transmute([]byte)content)

	testing.expect(t, model.digest_equal(digest, expected))
}

@(test)
taking_a_digest_does_not_count_a_redaction :: proc(t: ^testing.T) {
	// docs/08 reports counts per rule, and a count is how a user judges how
	// much was removed. Hashing content must not inflate it: the digest pass
	// redacts a second time, and counting that would double every replacement
	// on a mutation that also stored its content.
	sink: api.Sink
	redactor: api.Redactor
	api.redactor_init(&redactor)
	api.sink_init(&sink, &redactor, "test", "1.0.0", "session.jsonl")
	defer api.sink_destroy(&sink)
	defer api.redactor_destroy(&redactor)
	api.add_home_prefix(&redactor, "/Users/someone")

	content := "path = /Users/someone/projects/norn\n"

	api.add_blob_text(&sink, content)
	after_storing := api.total_redactions(&redactor)

	api.content_digest(&sink, content)
	after_hashing := api.total_redactions(&redactor)

	testing.expect_value(t, after_storing, 1)
	testing.expect_value(t, after_hashing, after_storing)
}

@(test)
an_empty_digest_is_the_unset_digest :: proc(t: ^testing.T) {
	// A mutation with no before-content leaves the slot unset rather than
	// carrying the hash of the empty string, which replay would treat as a
	// real baseline to verify against.
	sink: api.Sink
	redactor: api.Redactor
	api.redactor_init(&redactor)
	api.sink_init(&sink, &redactor, "test", "1.0.0", "session.jsonl")
	defer api.sink_destroy(&sink)
	defer api.redactor_destroy(&redactor)

	testing.expect(t, model.digest_is_zero(api.content_digest(&sink, "")))
}
