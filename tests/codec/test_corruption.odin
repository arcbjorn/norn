package test_codec

import "core:testing"

import "src:core"
import "src:trace/codec"

// Corruption tests.
//
// docs/09-quality.md requires, for every container structure: truncated input
// at each boundary, invalid magic and version, offset and size overflow,
// checksum mismatch, decompression-bomb declarations, duplicate identifiers,
// missing references, cyclic spans and edges, invalid UTF-8 and paths, and
// unfinalized files.
//
// Failures must be deterministic and must not panic or allocate beyond limits.
// Every test here asserts that validation *rejects* the input: a corruption
// that slipped through would mean the viewer trusts a tampered trace.

// corrupt builds a valid image and hands it to `damage` for mutation.
@(private)
corrupt :: proc(damage: proc(image: []byte)) -> []byte {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	if !built {
		return nil
	}
	damage(image)
	return image
}

// expect_rejected asserts that both validation modes refuse the image.
@(private)
expect_rejected :: proc(
	t: ^testing.T,
	image: []byte,
	expected: core.Category,
	what: string,
) {
	testing.expectf(t, image != nil, "%s: the fixture must serialize", what)
	if image == nil {
		return
	}

	quick := codec.validate_quick(image)
	testing.expectf(t, !core.ok(quick), "%s: quick validation accepted a corrupt trace", what)
	if !core.ok(quick) && expected != .None {
		testing.expectf(
			t,
			core.error_category(quick) == expected,
			"%s: expected %s, got %s (%s)",
			what,
			core.category_name(expected),
			core.category_name(core.error_category(quick)),
			core.error_message(quick),
		)
	}

	// Full validation must never be more permissive than quick validation.
	full := codec.validate_full(image)
	testing.expectf(t, !core.ok(full), "%s: full validation accepted a corrupt trace", what)
}

@(test)
rejects_empty_and_tiny_input :: proc(t: ^testing.T) {
	empty: []byte
	err := codec.validate_quick(empty)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Truncated_Input)

	tiny := []byte{'N', 'O', 'R', 'N'}
	err = codec.validate_quick(tiny)
	testing.expect(t, !core.ok(err))
	testing.expect_value(t, core.error_category(err), core.Category.Truncated_Input)
}

@(test)
rejects_invalid_file_magic :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		image[0] = 'X'
	})
	defer delete(image)
	expect_rejected(t, image, .Malformed_Container, "invalid file magic")
}

@(test)
rejects_unsupported_major_version :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		// Major version sits at offset 8. A future major version may alter
		// semantics, so this build must refuse rather than guess.
		image[8] = 99
		image[9] = 0
		recompute_file_header_crc(image)
	})
	defer delete(image)
	expect_rejected(t, image, .Unsupported_Version, "unsupported major version")
}

@(test)
rejects_unfinalized_file :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		// Clear the Finalized flag at offset 12. docs/04: a file without it
		// must not be opened as a complete trace.
		image[12] = 0
		image[13] = 0
		image[14] = 0
		image[15] = 0
		recompute_file_header_crc(image)
	})
	defer delete(image)
	expect_rejected(t, image, .Malformed_Container, "unfinalized file")
}

@(test)
rejects_zero_directory_offset :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		for index in 40 ..< 48 {
			image[index] = 0
		}
		recompute_file_header_crc(image)
	})
	defer delete(image)
	expect_rejected(t, image, .Malformed_Container, "zero directory offset")
}

@(test)
rejects_directory_offset_past_end_of_file :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		write_u64_at(image, 40, 1 << 40)
		recompute_file_header_crc(image)
	})
	defer delete(image)
	expect_rejected(t, image, .Malformed_Container, "directory offset past end of file")
}

@(test)
rejects_footer_offset_overflow :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		// A near-maximum offset must be caught by the overflow-checked range
		// test rather than wrapping into an in-bounds value.
		write_u64_at(image, 48, max(u64) - 8)
		recompute_file_header_crc(image)
	})
	defer delete(image)
	expect_rejected(t, image, .Malformed_Container, "footer offset overflow")
}

@(test)
rejects_corrupt_file_header_checksum :: proc(t: ^testing.T) {
	image := corrupt(proc(image: []byte) {
		// Flip a byte without recomputing the checksum.
		image[32] ~= 0xFF
	})
	defer delete(image)
	expect_rejected(t, image, .Checksum_Mismatch, "corrupt file header checksum")
}

@(test)
rejects_truncation_at_every_boundary :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	full, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(full)

	// Truncating anywhere must fail cleanly. Stepping by a prime keeps the
	// test fast while still landing inside headers, payloads, the directory,
	// and the footer.
	for length := 1; length < len(full); length += 7 {
		truncated := full[:length]
		err := codec.validate_quick(truncated)
		testing.expectf(
			t,
			!core.ok(err),
			"validation accepted a trace truncated to %d of %d bytes",
			length,
			len(full),
		)
	}
}

@(test)
rejects_corrupt_chunk_payload :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_payload := trace.directory[0].offset + codec.CHUNK_HEADER_SIZE
	codec.trace_destroy(&trace)

	// Flipping one payload bit must be caught by the chunk checksum.
	image[first_payload] ~= 0x01
	expect_rejected(t, image, .Checksum_Mismatch, "corrupt chunk payload")
}

@(test)
rejects_corrupt_chunk_header :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_chunk := trace.directory[0].offset
	codec.trace_destroy(&trace)

	// Damage the chunk magic and repair both the chunk header checksum and the
	// file digest, so the chunk parser's own magic check is what rejects it.
	// Leaving the digest broken would test the digest a second time instead of
	// the structural check this case exists for.
	image[first_chunk] = 'X'
	recompute_chunk_header_crc(image, int(first_chunk))

	expect_rejected(t, image, .Malformed_Container, "corrupt chunk magic")
}

@(test)
rejects_chunk_size_that_escapes_the_file :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_chunk := trace.directory[0].offset
	codec.trace_destroy(&trace)

	// encoded_size sits at offset 24 within the chunk header. A payload that
	// claims more bytes than the file holds must be rejected before any slice
	// is taken.
	header := int(first_chunk)
	write_u64_at(image, header + 24, 1 << 40)
	write_u64_at(image, header + 32, 1 << 40)
	recompute_chunk_header_crc(image, header)

	expect_rejected(t, image, .Limit_Exceeded, "chunk size escapes the file")
}

@(test)
rejects_chunk_size_overflow :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_chunk := trace.directory[0].offset
	codec.trace_destroy(&trace)

	// A size near the integer maximum must be caught by the overflow-checked
	// arithmetic, not wrap into a small in-bounds value.
	header := int(first_chunk)
	write_u64_at(image, header + 24, max(u64))
	write_u64_at(image, header + 32, max(u64))
	recompute_chunk_header_crc(image, header)

	expect_rejected(t, image, .Limit_Exceeded, "chunk size overflow")
}

@(test)
rejects_declared_decompression_bomb :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_chunk := trace.directory[0].offset
	codec.trace_destroy(&trace)

	// Mark the chunk compressed and declare an absurd decoded size. The
	// ceiling must reject it before a single byte is allocated.
	header := int(first_chunk)
	write_u32_at(image, header + 8, 0b10) // Chunk_Flag.Compressed
	write_u16_at(image, header + 12, 1)   // A codec id other than None.
	write_u64_at(image, header + 32, 1 << 40)
	recompute_chunk_header_crc(image, header)

	expect_rejected(t, image, .Limit_Exceeded, "declared decompression bomb")
}

@(test)
rejects_inverted_chunk_sequence_range :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	events_offset := u64(0)
	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	for entry in trace.directory {
		if entry.kind == .Events {
			events_offset = entry.offset
			break
		}
	}
	codec.trace_destroy(&trace)
	testing.expect(t, events_offset != 0, "the fixture must contain an events chunk")

	// first_sequence is at 40 and last_sequence at 48. An inverted range would
	// make a time-range query skip a chunk that actually holds events.
	header := int(events_offset)
	write_u64_at(image, header + 40, 100)
	write_u64_at(image, header + 48, 5)
	recompute_chunk_header_crc(image, header)

	expect_rejected(t, image, .Malformed_Container, "inverted chunk sequence range")
}

@(test)
rejects_corrupt_footer_magic :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	footer := len(image) - codec.FOOTER_SIZE
	image[footer] = 'X'
	expect_rejected(t, image, .Malformed_Container, "corrupt footer magic")
}

@(test)
rejects_missing_completion_marker :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	// The completion marker sits at footer offset 12.
	footer := len(image) - codec.FOOTER_SIZE
	write_u32_at(image, footer + 12, 0)
	recompute_footer_crc(image, footer)

	expect_rejected(t, image, .Malformed_Container, "missing completion marker")
}

@(test)
rejects_tampered_content_via_file_digest :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	trace, err := codec.open_trace(image)
	testing.expect(t, core.ok(err))
	first_chunk := trace.directory[0]
	codec.trace_destroy(&trace)

	// Rewrite a payload byte and repair the chunk checksum, so only the
	// whole-file digest can still detect the tampering. This is the case that
	// matters: an attacker who edits content will also fix the local checksum.
	payload := int(first_chunk.offset) + codec.CHUNK_HEADER_SIZE
	image[payload] ~= 0xFF
	recompute_chunk_payload_crc(image, int(first_chunk.offset), int(first_chunk.encoded_size))

	err = codec.validate_quick(image)
	testing.expect(t, !core.ok(err), "the file digest must detect repaired tampering")
	testing.expect_value(t, core.error_category(err), core.Category.Checksum_Mismatch)
}

@(test)
rejects_directory_entry_pointing_outside_the_file :: proc(t: ^testing.T) {
	fixture: Fixture
	make_fixture(&fixture)
	defer fixture_destroy(&fixture)

	image, built := build_image(&fixture)
	testing.expect(t, built)
	defer delete(image)

	directory_offset := read_u64_at(image, 40)
	// The first entry's offset field sits 8 bytes into the directory payload.
	entry := int(directory_offset) + codec.CHUNK_HEADER_SIZE + 8 + 16
	write_u64_at(image, entry, 1 << 40)
	recompute_directory(image, int(directory_offset))

	expect_rejected(t, image, .Malformed_Container, "directory entry outside the file")
}

@(test)
validation_is_deterministic :: proc(t: ^testing.T) {
	// The same corrupt input must produce the same category every time, or a
	// bug report's "norn validate" output would not be reproducible.
	image := corrupt(proc(image: []byte) {
		image[0] = 'X'
	})
	defer delete(image)

	first := core.error_category(codec.validate_quick(image))
	for _ in 0 ..< 8 {
		again := core.error_category(codec.validate_quick(image))
		testing.expect_value(t, again, first)
	}
}
