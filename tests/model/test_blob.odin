package test_model

import "core:testing"
import "src:trace/model"

@(test)
digest_matches_known_sha256_vectors :: proc(t: ^testing.T) {
	// Published SHA-256 check values pin the content-addressing scheme. A
	// change here would silently invalidate every replay verification, so the
	// vectors are asserted rather than assumed from the crypto library.
	Case :: struct {
		input:    string,
		expected: string,
	}
	cases := []Case {
		{
			"",
			"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
		},
		{
			"abc",
			"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
		},
	}

	buffer: [64]u8
	for c in cases {
		digest := model.digest_content(transmute([]byte)c.input)
		actual := model.digest_to_hex(digest, buffer[:])
		testing.expectf(
			t,
			actual == c.expected,
			"sha256(%q) = %s, expected %s",
			c.input,
			actual,
			c.expected,
		)
	}
}

@(test)
identical_content_interns_once :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	content := transmute([]byte)string("package main\n")
	digest := model.digest_content(content)

	first, ok := model.blob_intern(
		&table,
		model.Blob_Entry{digest = digest, size = u64(len(content))},
	)
	testing.expect(t, ok)

	// An agent that reads the same file repeatedly must produce one blob.
	second, ok2 := model.blob_intern(
		&table,
		model.Blob_Entry{digest = digest, size = u64(len(content))},
	)
	testing.expect(t, ok2)
	testing.expect_value(t, first, second)
	testing.expect_value(t, model.blob_table_count(&table), 1)
}

@(test)
distinct_content_gets_distinct_identifiers :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	a := model.digest_content(transmute([]byte)string("alpha"))
	b := model.digest_content(transmute([]byte)string("beta"))

	first, _ := model.blob_intern(&table, model.Blob_Entry{digest = a})
	second, _ := model.blob_intern(&table, model.Blob_Entry{digest = b})

	testing.expect(t, first != second)
	testing.expect_value(t, model.blob_table_count(&table), 2)
}

@(test)
blob_identifier_zero_is_reserved :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	_, ok := model.blob_get(&table, model.NO_BLOB)
	testing.expect(t, !ok, "the reserved zero identifier must not resolve to a blob")

	id, _ := model.blob_intern(
		&table,
		model.Blob_Entry{digest = model.digest_content(transmute([]byte)string("x"))},
	)
	testing.expect(t, id != model.NO_BLOB, "a real blob must never take identifier zero")
}

@(test)
blob_get_rejects_out_of_range :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	id, _ := model.blob_intern(
		&table,
		model.Blob_Entry{digest = model.digest_content(transmute([]byte)string("only"))},
	)

	_, ok := model.blob_get(&table, id + 1)
	testing.expect(t, !ok)
}

@(test)
blob_intern_respects_count_ceiling :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	a := model.digest_content(transmute([]byte)string("first"))
	b := model.digest_content(transmute([]byte)string("second"))

	_, ok := model.blob_intern(&table, model.Blob_Entry{digest = a}, 1)
	testing.expect(t, ok)

	_, ok = model.blob_intern(&table, model.Blob_Entry{digest = b}, 1)
	testing.expect(t, !ok, "exceeding the blob-count ceiling must fail explicitly")
}

@(test)
reindex_reports_duplicate_digests :: proc(t: ^testing.T) {
	table: model.Blob_Table
	model.blob_table_init(&table)
	defer model.blob_table_destroy(&table)

	digest := model.digest_content(transmute([]byte)string("content"))
	model.blob_intern(&table, model.Blob_Entry{digest = digest})

	testing.expect(t, model.blob_table_reindex(&table), "a deduplicated table must reindex")

	// A duplicate digest in decoded chunk data means the writer failed to
	// deduplicate, which the caller must report as an invariant violation.
	append(&table.entries, model.Blob_Entry{digest = digest})
	testing.expect(t, !model.blob_table_reindex(&table), "duplicate digests must be reported")
}

@(test)
digest_helpers_behave :: proc(t: ^testing.T) {
	zero: model.Blob_Digest
	testing.expect(t, model.digest_is_zero(zero))

	real := model.digest_content(transmute([]byte)string("anything"))
	testing.expect(t, !model.digest_is_zero(real))
	testing.expect(t, model.digest_equal(real, real))
	testing.expect(t, !model.digest_equal(real, zero))
}
