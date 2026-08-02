package test_codec

import "core:testing"

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// Mutation and blob-content chunk round trips.
//
// Replay depends entirely on these two chunks: mutations say what changed and
// blob content supplies the bytes. A trace that loses either would replay an
// empty session while still passing structural validation, so both are
// asserted directly rather than only through the replay tests.

@(private)
fixture_with_mutations :: proc(fixture: ^Fixture) -> (content_blob: model.Blob_Id) {
	make_fixture(fixture)

	text := "package parser\n"
	content_blob, _ = model.blob_add(&fixture.blobs, transmute([]byte)text)

	mutations := make([dynamic]model.Mutation, 0, 2)
	append(
		&mutations,
		model.Mutation {
			event_id = 3, // The File_Modify event in the shared fixture.
			path = 2,
			op = .Modify,
			encoding = .Utf8,
			content_blob = content_blob,
			after_hash = model.digest_content(transmute([]byte)text),
			flags = {.Has_Content, .Has_After_Hash},
		},
	)
	fixture.content.mutations = mutations[:]
	return content_blob
}

@(test)
mutations_survive_a_round_trip :: proc(t: ^testing.T) {
	fixture: Fixture
	fixture_with_mutations(&fixture)
	defer fixture_destroy(&fixture)
	defer delete(fixture.content.mutations)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expectf(t, core.ok(err), "open failed: %s", core.error_message(err))
	defer codec.trace_destroy(&trace)

	testing.expect_value(t, len(trace.mutations), len(fixture.content.mutations))

	original := fixture.content.mutations[0]
	decoded := trace.mutations[0]
	testing.expect_value(t, decoded.event_id, original.event_id)
	testing.expect_value(t, decoded.path, original.path)
	testing.expect_value(t, decoded.op, original.op)
	testing.expect_value(t, decoded.encoding, original.encoding)
	testing.expect_value(t, decoded.flags, original.flags)
	testing.expect_value(t, decoded.content_blob, original.content_blob)
	testing.expect(
		t,
		model.digest_equal(decoded.after_hash, original.after_hash),
		"the recorded after-hash must survive the round trip",
	)
}

@(test)
blob_content_survives_a_round_trip_and_verifies :: proc(t: ^testing.T) {
	fixture: Fixture
	blob := fixture_with_mutations(&fixture)
	defer fixture_destroy(&fixture)
	defer delete(fixture.content.mutations)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	defer codec.trace_destroy(&trace)

	content, fetch_err := codec.trace_blob_content(&trace, blob)
	testing.expectf(
		t,
		core.ok(fetch_err),
		"blob fetch failed: %s",
		core.error_message(fetch_err),
	)
	testing.expect_value(t, string(content), "package parser\n")
}

@(test)
blob_content_rejects_tampered_bytes :: proc(t: ^testing.T) {
	// docs/04: the reader verifies the digest before treating content as
	// replay-verified. Repairing the surrounding checksums leaves the digest
	// as the only thing standing between a tampered file and the viewer.
	fixture: Fixture
	blob := fixture_with_mutations(&fixture)
	defer fixture_destroy(&fixture)
	defer delete(fixture.content.mutations)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	// Locate the blob content chunk and alter a byte of its payload.
	probe, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	content_offset := u64(0)
	content_size := 0
	for entry in probe.directory {
		if entry.kind == .Blob_Content {
			content_offset = entry.offset
			content_size = int(entry.encoded_size)
			break
		}
	}
	codec.trace_destroy(&probe)
	testing.expect(t, content_offset != 0, "the fixture must contain a blob content chunk")

	payload := int(content_offset) + codec.CHUNK_HEADER_SIZE
	image[payload] ~= 0xFF
	recompute_chunk_payload_crc(image, int(content_offset), content_size)
	recompute_file_digest(image)

	// The container now validates, because every checksum was repaired.
	testing.expect(
		t,
		core.ok(codec.validate_quick(image)),
		"the repaired container must pass structural validation",
	)

	trace, open_err := codec.open_trace(image)
	testing.expect(t, core.ok(open_err))
	defer codec.trace_destroy(&trace)

	_, fetch_err := codec.trace_blob_content(&trace, blob)
	testing.expect(t, !core.ok(fetch_err), "tampered content must not be returned")
	testing.expect_value(t, core.error_category(fetch_err), core.Category.Checksum_Mismatch)
}

@(test)
validation_rejects_a_mutation_naming_a_missing_event :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	mutations := make([dynamic]model.Mutation, 0, 1)
	defer delete(mutations)
	append(
		&mutations,
		model.Mutation{event_id = 9999, path = 2, op = .Modify, encoding = .Utf8},
	)
	fixture.content.mutations = mutations[:]

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	err := codec.validate_full(image)
	testing.expect(t, !core.ok(err), "a mutation naming a missing event must be rejected")
	testing.expect_value(t, core.error_category(err), core.Category.Invalid_Reference)
}

@(test)
validation_rejects_a_rename_without_a_source_path :: proc(t: ^testing.T) {
	// A rename missing its source would silently become a create, inventing
	// content identity the trace never recorded.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	mutations := make([dynamic]model.Mutation, 0, 1)
	defer delete(mutations)
	append(
		&mutations,
		model.Mutation{event_id = 3, path = 2, op = .Rename, encoding = .Utf8},
	)
	fixture.content.mutations = mutations[:]

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	err := codec.validate_full(image)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invariant_Violation)
}

@(test)
validation_rejects_unordered_mutations :: proc(t: ^testing.T) {
	// docs/03 invariant 6: mutations for one path have a deterministic order.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	mutations := make([dynamic]model.Mutation, 0, 2)
	defer delete(mutations)
	append(&mutations, model.Mutation{event_id = 3, path = 2, op = .Modify, encoding = .Utf8})
	append(&mutations, model.Mutation{event_id = 2, path = 2, op = .Modify, encoding = .Utf8})
	fixture.content.mutations = mutations[:]

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	err := codec.validate_full(image)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Invariant_Violation)
}
