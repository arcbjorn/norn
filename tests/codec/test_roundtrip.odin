package test_codec

import "core:testing"

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// ok_error is a local helper so tests read as assertions about success rather
// than about the error union's shape.
ok_error :: proc(err: core.Error) -> bool {
	return core.ok(err)
}

@(test)
written_trace_passes_quick_validation :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built, "the fixture must serialize")
	defer delete(image)

	err := codec.validate_quick(image)
	testing.expectf(t, core.ok(err), "quick validation failed: %s", core.error_message(err))
}

@(test)
written_trace_passes_full_validation :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	err := codec.validate_full(image)
	testing.expectf(t, core.ok(err), "full validation failed: %s", core.error_message(err))
}

@(test)
roundtrip_preserves_every_canonical_record :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expectf(t, core.ok(err), "open failed: %s", core.error_message(err))
	defer codec.trace_destroy(&trace)

	testing.expect_value(t, len(trace.events), len(fixture.events))
	testing.expect_value(t, len(trace.entities), len(fixture.entities))
	testing.expect_value(t, len(trace.spans), len(fixture.spans))
	testing.expect_value(t, len(trace.edges), len(fixture.edges))

	for original, index in fixture.events {
		decoded := trace.events[index]
		testing.expect_value(t, decoded.id, original.id)
		testing.expect_value(t, decoded.sequence, original.sequence)
		testing.expect_value(t, decoded.kind, original.kind)
		testing.expect_value(t, decoded.flags, original.flags)
		testing.expect_value(t, decoded.time_quality, original.time_quality)
		testing.expect_value(t, decoded.wall_time_ns, original.wall_time_ns)
		testing.expect_value(t, decoded.duration_ns, original.duration_ns)
		testing.expect_value(t, decoded.parent_span_id, original.parent_span_id)
		testing.expect_value(t, decoded.actor_entity_id, original.actor_entity_id)
		testing.expect_value(t, decoded.primary_entity_id, original.primary_entity_id)
		testing.expect_value(t, decoded.summary_string_id, original.summary_string_id)
		testing.expect_value(t, decoded.source.record_number, original.source.record_number)
		testing.expect_value(t, decoded.source.importer_id, original.source.importer_id)
	}

	for original, index in fixture.edges {
		decoded := trace.edges[index]
		testing.expect_value(t, decoded.kind, original.kind)
		testing.expect_value(t, decoded.origin, original.origin)
		testing.expect_value(t, decoded.from.kind, original.from.kind)
		testing.expect_value(t, decoded.from.id, original.from.id)
		testing.expect_value(t, decoded.to.id, original.to.id)
		testing.expect_value(t, decoded.confidence, original.confidence)
		testing.expect_value(t, decoded.rule, original.rule)
	}

	for original, index in fixture.spans {
		decoded := trace.spans[index]
		testing.expect_value(t, decoded.id, original.id)
		testing.expect_value(t, decoded.kind, original.kind)
		testing.expect_value(t, decoded.start_sequence, original.start_sequence)
		testing.expect_value(t, decoded.end_sequence, original.end_sequence)
	}
}

@(test)
roundtrip_preserves_strings_and_identifiers :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	defer codec.trace_destroy(&trace)

	// Identifiers must survive the roundtrip unchanged, or every reference in
	// the file would point at different text than the writer intended.
	testing.expect_value(
		t,
		model.string_table_count(&trace.strings),
		model.string_table_count(&fixture.strings),
	)

	for id in 0 ..= model.string_table_count(&fixture.strings) {
		expected, had := model.string_get(&fixture.strings, model.String_Id(id))
		actual, got := model.string_get(&trace.strings, model.String_Id(id))
		testing.expectf(t, had == got, "identifier %d resolved differently", id)
		testing.expectf(
			t,
			expected == actual,
			"identifier %d was %q, decoded as %q",
			id,
			expected,
			actual,
		)
	}
}

@(test)
roundtrip_preserves_metadata_and_warnings :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	defer codec.trace_destroy(&trace)

	original := fixture.content.metadata
	decoded := trace.metadata

	testing.expect_value(t, decoded.importer_id, original.importer_id)
	testing.expect_value(t, decoded.repository_name, original.repository_name)
	testing.expect_value(t, decoded.version_control, original.version_control)
	testing.expect_value(t, decoded.baseline_kind, original.baseline_kind)
	testing.expect_value(t, decoded.capabilities, original.capabilities)
	testing.expect_value(t, decoded.session_start_ns, original.session_start_ns)
	testing.expect_value(t, decoded.canonical_event_count, original.canonical_event_count)
	testing.expect_value(t, decoded.case_sensitive_paths, original.case_sensitive_paths)

	// docs/01: import warnings remain part of the session metadata rather than
	// disappearing with the import dialog.
	testing.expect_value(t, codec.total_warnings(&decoded), u64(2))
	testing.expect_value(t, codec.total_redactions(&decoded), u64(1))
	testing.expect_value(
		t,
		decoded.warnings[int(codec.Warning_Category.Timestamp_Repaired)],
		u32(2),
	)
}

@(test)
roundtrip_preserves_blob_digests :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	defer codec.trace_destroy(&trace)

	testing.expect_value(
		t,
		model.blob_table_count(&trace.blobs),
		model.blob_table_count(&fixture.blobs),
	)

	expected := model.digest_content(transmute([]byte)string("package parser\n"))
	id, found := model.blob_find(&trace.blobs, expected)
	testing.expect(t, found, "the content digest must resolve after a roundtrip")

	entry, got := model.blob_get(&trace.blobs, id)
	testing.expect(t, got)
	testing.expect(t, model.digest_equal(entry.digest, expected))
	testing.expect_value(t, entry.encoding, model.Text_Encoding.Utf8)
}

@(test)
writing_the_same_content_twice_is_byte_identical :: proc(t: ^testing.T) {
	// docs/05 determinism: identical input must produce identical canonical
	// output. Creation time and session identity are excluded from that
	// promise, so both runs are given the same values.
	first: Fixture
	make_fixture(&first)
	defer fixture_destroy(&first)

	second: Fixture
	make_fixture(&second)
	defer fixture_destroy(&second)

	FIXED_TIME :: i64(1_700_000_000_000_000_000)

	writer_a: codec.Writer
	codec.writer_init(&writer_a, first.content.session_id, FIXED_TIME)
	defer codec.writer_destroy(&writer_a)

	writer_b: codec.Writer
	codec.writer_init(&writer_b, second.content.session_id, FIXED_TIME)
	defer codec.writer_destroy(&writer_b)

	codec.writer_write_content(&writer_a, &first.content)
	codec.writer_finish(&writer_a)
	codec.writer_write_content(&writer_b, &second.content)
	codec.writer_finish(&writer_b)

	testing.expect_value(t, len(writer_a.buffer), len(writer_b.buffer))
	for index in 0 ..< len(writer_a.buffer) {
		if writer_a.buffer[index] != writer_b.buffer[index] {
			testing.expectf(
				t,
				false,
				"byte %d differs between runs: 0x%02X vs 0x%02X",
				index,
				writer_a.buffer[index],
				writer_b.buffer[index],
			)
			break
		}
	}
}

@(test)
chunks_start_on_aligned_boundaries :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	defer codec.trace_destroy(&trace)

	for entry, index in trace.directory {
		testing.expectf(
			t,
			entry.offset % codec.CHUNK_ALIGNMENT == 0,
			"chunk %d (%s) starts at unaligned offset %d",
			index,
			codec.chunk_kind_name(entry.kind),
			entry.offset,
		)
	}
}

@(test)
replay_validation_reports_that_it_is_unavailable :: proc(t: ^testing.T) {
	// Reporting the gap plainly is required: silently running a weaker check
	// and returning success would tell the user their mutation chains were
	// verified when nothing verified them.
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	err := codec.validate(image, .Replay)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Unsupported_Feature)
}
