package codec

import "src:core"

// File header, chunk header, directory, and footer serialization.
//
// docs/08-security.md governs this file: all lengths and counts are checked
// before arithmetic and allocation, checksums are verified before decoding
// structured payloads, and a parse failure returns an error rather than
// partially initializing a trusted object.

// encode_file_header writes the 64-byte header, computing its CRC32C over the
// header with the checksum field zeroed.
encode_file_header :: proc(buffer: ^[dynamic]u8, header: ^File_Header) {
	start := len(buffer)
	cursor := Writer_Cursor{data = buffer}

	write_bytes(&cursor, header.magic[:])
	write_u16(&cursor, header.major)
	write_u16(&cursor, header.minor)
	write_u32(&cursor, transmute(u32)header.flags)
	write_bytes(&cursor, header.session_id[:])
	write_i64(&cursor, header.created_unix_ns)
	write_u64(&cursor, header.directory_offset)
	write_u64(&cursor, header.footer_offset)
	write_u32(&cursor, 0) // Checksum placeholder, patched below.
	write_zeros(&cursor, 4) // Reserved.

	assert(len(buffer) - start == FILE_HEADER_SIZE)
	patch_header_crc(buffer[start:len(buffer)], FILE_HEADER_CRC_OFFSET)
}

// patch_header_crc computes the CRC32C of a fixed-size header whose checksum
// field is at `crc_offset`, with that field treated as zero, then writes the
// result into the field. Both the file header and every chunk header define
// their checksum this way.
@(private)
patch_header_crc :: proc(header: []byte, crc_offset: int) {
	assert(crc_offset + 4 <= len(header))
	for index in crc_offset ..< crc_offset + 4 {
		header[index] = 0
	}
	checksum := core.crc32c(header)
	header[crc_offset + 0] = u8(checksum)
	header[crc_offset + 1] = u8(checksum >> 8)
	header[crc_offset + 2] = u8(checksum >> 16)
	header[crc_offset + 3] = u8(checksum >> 24)
}

// verify_header_crc recomputes the checksum of a header with its checksum
// field zeroed and compares it against the stored value. The header is copied
// into a stack buffer so that verification never mutates the input, which may
// be a read-only memory mapping.
@(private)
verify_header_crc :: proc(header: []byte, crc_offset: int, stored: u32) -> bool {
	// Sized for the largest fixed structure, which is the footer.
	scratch: [FOOTER_SIZE]u8
	if len(header) > len(scratch) || crc_offset + 4 > len(header) {
		return false
	}
	copy(scratch[:], header)
	for index in crc_offset ..< crc_offset + 4 {
		scratch[index] = 0
	}
	return core.crc32c(scratch[:len(header)]) == stored
}

// decode_file_header parses and validates the 64-byte header.
//
// It checks magic, version support, checksum, and the internal consistency of
// the declared offsets. It deliberately does not read any chunk: a caller must
// be able to reject a hostile file after 64 bytes.
decode_file_header :: proc(
	data: []byte,
	limits := core.DEFAULT_LIMITS,
) -> (
	header: File_Header,
	err: core.Error,
) {
	if len(data) < FILE_HEADER_SIZE {
		return {}, core.err_make(.Truncated_Input, "file is smaller than the 64-byte header")
	}

	cursor := Reader_Cursor{data = data[:FILE_HEADER_SIZE]}
	ok: bool

	magic: []byte
	magic, ok = read_bytes(&cursor, 8)
	if !ok {
		return {}, core.err_make(.Truncated_Input, "header magic is truncated")
	}
	copy(header.magic[:], magic)
	if header.magic != FILE_MAGIC {
		return {}, core.err_make(.Malformed_Container, "file is not a Norn trace")
	}

	header.major, _ = read_u16(&cursor)
	header.minor, _ = read_u16(&cursor)

	raw_flags: u32
	raw_flags, _ = read_u32(&cursor)
	header.flags = transmute(Header_Flags)raw_flags

	session: []byte
	session, _ = read_bytes(&cursor, 16)
	copy(header.session_id[:], session)

	header.created_unix_ns, _ = read_i64(&cursor)
	header.directory_offset, _ = read_u64(&cursor)
	header.footer_offset, _ = read_u64(&cursor)
	header.header_crc32c, _ = read_u32(&cursor)

	// The checksum is verified before any declared offset is trusted, so a
	// corrupt header cannot steer the reader toward an attacker-chosen offset.
	if !verify_header_crc(data[:FILE_HEADER_SIZE], FILE_HEADER_CRC_OFFSET, header.header_crc32c) {
		return {}, core.err_make(.Checksum_Mismatch, "file header checksum does not match")
	}

	if header.major < MIN_SUPPORTED_MAJOR || header.major > FORMAT_MAJOR {
		return {}, core.Failure {
			category = .Unsupported_Version,
			recoverability = .Fatal,
			message = "trace major version is not supported by this build",
			subject = core.Subject{kind = .None, number = u64(header.major)},
		}
	}

	// docs/04: a zero directory or footer offset means the file was not
	// finalized and must not be opened as a complete trace.
	if .Finalized not_in header.flags {
		return {}, core.err_make(
			.Malformed_Container,
			"trace is not finalized; import may have been interrupted",
		)
	}
	if header.directory_offset == 0 || header.footer_offset == 0 {
		return {}, core.err_make(
			.Malformed_Container,
			"finalized trace has a zero directory or footer offset",
		)
	}

	total := u64(len(data))
	if err = core.check_limit(total, limits.max_file_size, "file exceeds the size limit");
	   !core.ok(err) {
		return {}, err
	}

	// Both regions must lie inside the file. Checking here means later code
	// can seek to them without repeating the bounds test.
	if !core.range_within(header.directory_offset, CHUNK_HEADER_SIZE, total) {
		return {}, core.err_at(
			.Malformed_Container,
			"directory offset lies outside the file",
			header.directory_offset,
		)
	}
	if !core.range_within(header.footer_offset, FOOTER_SIZE, total) {
		return {}, core.err_at(
			.Malformed_Container,
			"footer offset lies outside the file",
			header.footer_offset,
		)
	}
	if header.footer_offset < header.directory_offset {
		return {}, core.err_make(
			.Malformed_Container,
			"footer precedes the directory",
		)
	}

	return header, nil
}

// encode_chunk_header writes a 64-byte chunk header with its checksum.
encode_chunk_header :: proc(buffer: ^[dynamic]u8, header: ^Chunk_Header) {
	start := len(buffer)
	cursor := Writer_Cursor{data = buffer}

	// Field offsets within the 64-byte header:
	//   0 magic, 4 kind, 6 schema_version, 8 flags, 12 codec_id,
	//   14 reserved, 16 ordinal, 20 record_count, 24 encoded_size,
	//   32 decoded_size, 40 first_sequence, 48 last_sequence,
	//   56 payload_crc32c, 60 header_crc32c.
	write_bytes(&cursor, header.magic[:])
	write_u16(&cursor, u16(header.kind))
	write_u16(&cursor, header.schema_version)
	write_u32(&cursor, transmute(u32)header.flags)
	write_u16(&cursor, u16(header.codec_id))
	write_u16(&cursor, 0) // Reserved.
	write_u32(&cursor, header.ordinal)
	write_u32(&cursor, header.record_count)
	write_u64(&cursor, header.encoded_size)
	write_u64(&cursor, header.decoded_size)
	write_u64(&cursor, header.first_sequence)
	write_u64(&cursor, header.last_sequence)
	write_u32(&cursor, header.payload_crc32c)
	write_u32(&cursor, 0) // Checksum placeholder.

	assert(len(buffer) - start == CHUNK_HEADER_SIZE)
	patch_header_crc(buffer[start:len(buffer)], CHUNK_HEADER_CRC_OFFSET)
}

// decode_chunk_header parses and validates a chunk header found at `offset`
// within a file of `file_size` bytes.
//
// Validation rejects, per docs/04: bad magic, arithmetic overflow, a payload
// outside file bounds, unreasonable decoded sizes, invalid sequence ranges,
// and checksum mismatches.
decode_chunk_header :: proc(
	data: []byte,
	offset: u64,
	limits := core.DEFAULT_LIMITS,
) -> (
	header: Chunk_Header,
	err: core.Error,
) {
	file_size := u64(len(data))
	if !core.range_within(offset, CHUNK_HEADER_SIZE, file_size) {
		return {}, core.err_at(.Truncated_Input, "chunk header extends past end of file", offset)
	}

	start, in_range := core.to_int(offset)
	if !in_range {
		return {}, core.err_at(.Malformed_Container, "chunk offset is not addressable", offset)
	}
	raw := data[start:start + CHUNK_HEADER_SIZE]
	cursor := Reader_Cursor{data = raw}

	magic: []byte
	magic, _ = read_bytes(&cursor, 4)
	copy(header.magic[:], magic)
	if header.magic != CHUNK_MAGIC {
		return {}, core.err_at(.Malformed_Container, "chunk magic is invalid", offset)
	}

	kind_value: u16
	kind_value, _ = read_u16(&cursor)
	header.kind = Chunk_Kind(kind_value)
	header.schema_version, _ = read_u16(&cursor)

	raw_flags: u32
	raw_flags, _ = read_u32(&cursor)
	header.flags = transmute(Chunk_Flags)raw_flags

	codec_value: u16
	codec_value, _ = read_u16(&cursor)
	header.codec_id = Compression_Codec(codec_value)
	if !skip(&cursor, 2) {
		return {}, core.err_at(.Truncated_Input, "chunk header is truncated", offset)
	}

	header.ordinal, _ = read_u32(&cursor)
	header.record_count, _ = read_u32(&cursor)
	header.encoded_size, _ = read_u64(&cursor)
	header.decoded_size, _ = read_u64(&cursor)
	header.first_sequence, _ = read_u64(&cursor)
	header.last_sequence, _ = read_u64(&cursor)
	header.payload_crc32c, _ = read_u32(&cursor)
	header.header_crc32c, _ = read_u32(&cursor)

	if !verify_header_crc(raw, CHUNK_HEADER_CRC_OFFSET, header.header_crc32c) {
		return {}, core.err_at(.Checksum_Mismatch, "chunk header checksum does not match", offset)
	}

	// Sizes are bounded before they are used to compute a payload range, so an
	// enormous declared size cannot overflow the range computation itself.
	if err = core.check_limit(
		header.encoded_size,
		limits.max_chunk_encoded,
		"chunk encoded size exceeds the limit",
	); !core.ok(err) {
		return {}, err
	}
	if err = core.check_limit(
		header.decoded_size,
		limits.max_chunk_decoded,
		"chunk decoded size exceeds the limit",
	); !core.ok(err) {
		return {}, err
	}

	payload_offset, sum_ok := core.add_u64(offset, CHUNK_HEADER_SIZE)
	if !sum_ok {
		return {}, core.err_at(.Malformed_Container, "chunk payload offset overflows", offset)
	}
	if !core.range_within(payload_offset, header.encoded_size, file_size) {
		return {}, core.err_at(.Truncated_Input, "chunk payload extends past end of file", offset)
	}

	// An uncompressed chunk must declare equal sizes; anything else means the
	// header disagrees with itself.
	if .Compressed not_in header.flags {
		if header.codec_id != .None {
			return {}, core.err_at(
				.Malformed_Container,
				"chunk names a codec but is not marked compressed",
				offset,
			)
		}
		if header.decoded_size != header.encoded_size {
			return {}, core.err_at(
				.Malformed_Container,
				"uncompressed chunk declares mismatched sizes",
				offset,
			)
		}
	} else {
		if header.codec_id == .None {
			return {}, core.err_at(
				.Unsupported_Feature,
				"chunk is marked compressed with no codec",
				offset,
			)
		}
		if err = core.check_compression_ratio(header.encoded_size, header.decoded_size, limits);
		   !core.ok(err) {
			return {}, err
		}
	}

	// A chunk that carries events must declare an ordered sequence range, so a
	// range query can skip it without decoding.
	if header.first_sequence != 0 && header.last_sequence < header.first_sequence {
		return {}, core.err_at(.Malformed_Container, "chunk sequence range is inverted", offset)
	}
	if header.first_sequence == 0 && header.last_sequence != 0 {
		return {}, core.err_at(.Malformed_Container, "chunk declares an end sequence with no start", offset)
	}

	if is_required_kind(header.kind) && header.kind == .Invalid {
		return {}, core.err_at(.Malformed_Container, "chunk declares the invalid kind", offset)
	}

	return header, nil
}

// chunk_payload returns the payload bytes for a validated chunk header.
//
// The result borrows `data` and is valid for as long as the mapping is. The
// caller has already had every bound checked by decode_chunk_header, so this
// re-derives the same range rather than trusting a separately passed length.
chunk_payload :: proc(
	data: []byte,
	offset: u64,
	header: Chunk_Header,
) -> (
	payload: []byte,
	err: core.Error,
) {
	payload_offset, sum_ok := core.add_u64(offset, CHUNK_HEADER_SIZE)
	if !sum_ok {
		return nil, core.err_at(.Malformed_Container, "chunk payload offset overflows", offset)
	}
	if !core.range_within(payload_offset, header.encoded_size, u64(len(data))) {
		return nil, core.err_at(.Truncated_Input, "chunk payload extends past end of file", offset)
	}
	start, start_ok := core.to_int(payload_offset)
	length, length_ok := core.to_int(header.encoded_size)
	if !start_ok || !length_ok {
		return nil, core.err_at(.Malformed_Container, "chunk payload is not addressable", offset)
	}

	payload = data[start:start + length]

	// docs/08: checksums are verified before decoding structured payloads.
	if core.crc32c(payload) != header.payload_crc32c {
		return nil, core.err_at(.Checksum_Mismatch, "chunk payload checksum does not match", offset)
	}
	return payload, nil
}
