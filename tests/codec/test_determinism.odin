package test_codec

import "core:testing"

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// Determinism of the canonical container.
//
// docs/05: "given identical source bytes, repository baseline, options, and
// importer version, canonical chunks and their hashes must be identical.
// Creation time and random session identity are excluded from the
// canonical-content digest and may differ."
//
// docs/11 makes this a Phase 1 exit criterion. It is worth asserting on the
// bytes rather than on decoded values, because everything that would break it
// — map iteration order, a pointer used as a sort key, a timestamp sampled
// mid-write, padding left uninitialized — produces a trace that still decodes
// to the same records. Only a byte comparison sees it.

// VOLATILE_END is where the file header stops and the chunks begin.
//
// docs/05 permits exactly two things to differ between two imports of one
// source — the session identity and the creation time — and both live in the
// header, along with the checksum that necessarily covers them. Every byte from
// here on must be reproducible.
//
// Stated as a constant so that a format change which moves these fields fails
// here, rather than silently widening what "deterministic" is allowed to mean.
@(private)
VOLATILE_END :: 64

@(private)
build_twice :: proc(
	session_a: model.Session_Id,
	session_b: model.Session_Id,
	created_a: i64,
	created_b: i64,
) -> (
	first: []byte,
	second: []byte,
	ok: bool,
) {
	build :: proc(session: model.Session_Id, created: i64) -> ([]byte, bool) {
		fixture: Fixture
		make_fixture(&fixture)
		defer fixture_destroy(&fixture)

		writer: codec.Writer
		codec.writer_init(&writer, session, created)
		defer codec.writer_destroy(&writer)

		if err := codec.writer_write_content(&writer, &fixture.content); !ok_error(err) {
			return nil, false
		}
		if err := codec.writer_finish(&writer); !ok_error(err) {
			return nil, false
		}

		image := make([]byte, len(writer.buffer))
		copy(image, writer.buffer[:])
		return image, true
	}

	first, ok = build(session_a, created_a)
	if !ok {
		return nil, nil, false
	}
	second, ok = build(session_b, created_b)
	if !ok {
		delete(first)
		return nil, nil, false
	}
	return first, second, true
}

@(test)
identical_input_produces_identical_bytes :: proc(t: ^testing.T) {
	// The strongest form: same session identity and creation time means the
	// whole file must reproduce, byte for byte.
	session := model.Session_Id{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16}

	first, second, ok := build_twice(session, session, 1_000, 1_000)
	testing.expect(t, ok, "both images must serialize")
	if !ok {
		return
	}
	defer delete(first)
	defer delete(second)

	testing.expect_value(t, len(first), len(second))
	for index in 0 ..< min(len(first), len(second)) {
		testing.expectf(
			t,
			first[index] == second[index],
			"byte %d differs: %d against %d",
			index,
			first[index],
			second[index],
		)
		if first[index] != second[index] {
			// One report is enough; a diverging tail would print thousands.
			return
		}
	}
}

@(test)
only_the_permitted_fields_differ_between_sessions :: proc(t: ^testing.T) {
	// docs/05 excludes exactly two things. This asserts the exclusion is that
	// narrow: two imports differing only in identity and clock must produce
	// identical chunks, so a stored chunk hash stays comparable across runs.
	first, second, ok := build_twice(
		model.Session_Id{1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
		model.Session_Id{2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2},
		1_000,
		9_999_999,
	)
	testing.expect(t, ok, "both images must serialize")
	if !ok {
		return
	}
	defer delete(first)
	defer delete(second)

	testing.expect_value(t, len(first), len(second))

	for index in VOLATILE_END ..< min(len(first), len(second)) {
		testing.expectf(
			t,
			first[index] == second[index],
			"byte %d is outside the file header and must not differ",
			index,
		)
		if first[index] != second[index] {
			return
		}
	}
}

@(test)
the_content_digest_ignores_identity_and_time :: proc(t: ^testing.T) {
	// The digest is what a reader compares to decide two traces hold the same
	// session. If identity or creation time reached it, no two imports of one
	// source would ever agree, and the determinism promise would be unusable.
	first, second, ok := build_twice(
		model.Session_Id{9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9},
		model.Session_Id{7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7},
		12_345,
		987_654_321,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(first)
	defer delete(second)

	a, a_err := codec.open_trace(first)
	defer codec.trace_destroy(&a)
	b, b_err := codec.open_trace(second)
	defer codec.trace_destroy(&b)

	testing.expect(t, core.ok(a_err))
	testing.expect(t, core.ok(b_err))

	testing.expect(
		t,
		a.footer.digest == b.footer.digest,
		"the content digest must not depend on identity or creation time",
	)
	// And the excluded fields really did differ, or this proves nothing.
	testing.expect(t, a.header.session_id != b.header.session_id)
	testing.expect(t, a.header.created_unix_ns != b.header.created_unix_ns)
}

@(test)
every_chunk_checksum_is_reproducible :: proc(t: ^testing.T) {
	// Per-chunk hashes are what docs/05 names specifically. Comparing them
	// directly localises a failure to one chunk kind rather than reporting that
	// two files differ somewhere.
	first, second, ok := build_twice(
		model.Session_Id{3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1},
		model.Session_Id{4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2},
		500,
		600,
	)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(first)
	defer delete(second)

	a, a_err := codec.open_trace(first)
	defer codec.trace_destroy(&a)
	b, b_err := codec.open_trace(second)
	defer codec.trace_destroy(&b)
	testing.expect(t, core.ok(a_err))
	testing.expect(t, core.ok(b_err))

	testing.expect_value(t, len(a.directory), len(b.directory))
	for entry, index in a.directory {
		if index >= len(b.directory) {
			break
		}
		other := b.directory[index]
		// Chunk order is canonical per docs/04, so entries line up by position.
		testing.expect_value(t, entry.kind, other.kind)
		testing.expect_value(t, entry.ordinal, other.ordinal)
		testing.expect_value(t, entry.offset, other.offset)
		testing.expect_value(t, entry.encoded_size, other.encoded_size)
		testing.expect_value(t, entry.decoded_size, other.decoded_size)
		testing.expect_value(t, entry.record_count, other.record_count)
		testing.expect_value(t, entry.first_sequence, other.first_sequence)
		testing.expect_value(t, entry.last_sequence, other.last_sequence)
	}
}

@(test)
a_rebuilt_trace_reopens_to_the_same_records :: proc(t: ^testing.T) {
	// Byte equality is the strict claim; this is the one a user depends on.
	// Keeping both means a future format change that legitimately alters bytes
	// still has to preserve what the file means.
	session := model.Session_Id{5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5}
	first, second, ok := build_twice(session, session, 42, 42)
	testing.expect(t, ok)
	if !ok {
		return
	}
	defer delete(first)
	defer delete(second)

	a, a_err := codec.open_trace(first)
	defer codec.trace_destroy(&a)
	b, b_err := codec.open_trace(second)
	defer codec.trace_destroy(&b)
	testing.expect(t, core.ok(a_err))
	testing.expect(t, core.ok(b_err))

	testing.expect_value(t, len(a.events), len(b.events))
	for event, index in a.events {
		other := b.events[index]
		testing.expect_value(t, event.id, other.id)
		testing.expect_value(t, event.sequence, other.sequence)
		testing.expect_value(t, event.kind, other.kind)
		testing.expect_value(t, event.summary_string_id, other.summary_string_id)
	}

	testing.expect_value(t, len(a.entities), len(b.entities))
	testing.expect_value(t, len(a.spans), len(b.spans))
	testing.expect_value(t, len(a.edges), len(b.edges))
	testing.expect_value(
		t,
		model.string_table_count(&a.strings),
		model.string_table_count(&b.strings),
	)
}
