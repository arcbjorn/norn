package codec

import "core:crypto/hash"
import "core:os"
import "core:time"

import "src:core"
import "src:trace/model"

// The .norn writer.
//
// docs/04-trace-format.md fixes the write protocol: the writer flushes file
// data, writes the footer, flushes again, then patches the header offsets and
// checksum. Import writes to `<destination>.tmp` and atomically renames only
// after reopening and validating the finished file.
//
// The header is written with zero directory and footer offsets and without the
// Finalized flag, so a process that dies mid-write leaves a file the reader
// refuses to open rather than one that looks complete.

// Trace_Content is the canonical material a writer serializes. It borrows the
// caller's collections and does not take ownership.
Trace_Content :: struct {
	session_id: model.Session_Id,
	metadata:   Session_Metadata,
	strings:    ^model.String_Table,
	blobs:      ^model.Blob_Table,
	entities:   []model.Entity,
	spans:      []model.Span,
	events:     []model.Event,
	edges:      []model.Edge,
	mutations:  []model.Mutation,
	payloads:   ^model.Payload_Tables,
}

// Writer accumulates the file image in memory and tracks chunk locations for
// the directory.
Writer :: struct {
	buffer:      [dynamic]u8,
	directory:   [dynamic]Directory_Entry,
	ordinals:    [Chunk_Kind]u32,
	created_ns:  i64,
	session_id:  model.Session_Id,
	flags:       Header_Flags,
}

// writer_init prepares a writer and reserves the file header, which is patched
// with real offsets once the directory and footer positions are known.
//
// `created_ns` defaults to the current time. Tests and reproducible-build
// tooling pass an explicit value: docs/05 excludes creation time from the
// determinism promise, so it must be injectable rather than sampled here.
writer_init :: proc(
	writer: ^Writer,
	session_id: model.Session_Id,
	created_ns := i64(0),
	allocator := context.allocator,
) {
	writer.buffer = make([dynamic]u8, 0, 64 * 1024, allocator)
	writer.directory = make([dynamic]Directory_Entry, 0, 32, allocator)
	writer.session_id = session_id
	writer.created_ns = created_ns if created_ns != 0 else time.to_unix_nanoseconds(time.now())

	// Reserve the header. Offsets stay zero and Finalized stays clear until
	// writer_finish, so an interrupted write cannot produce an openable file.
	header := File_Header {
		magic           = FILE_MAGIC,
		major           = FORMAT_MAJOR,
		minor           = FORMAT_MINOR,
		session_id      = transmute([16]u8)session_id,
		created_unix_ns = writer.created_ns,
	}
	encode_file_header(&writer.buffer, &header)
}

writer_destroy :: proc(writer: ^Writer) {
	delete(writer.buffer)
	delete(writer.directory)
	writer^ = {}
}

// write_chunk appends one chunk: alignment padding, a header, and the payload
// produced by `encode`.
//
// The payload is encoded into a scratch buffer first because the header holds
// the payload's size and checksum, which are unknown until encoding finishes.
@(private)
write_chunk :: proc(
	writer: ^Writer,
	kind: Chunk_Kind,
	schema_version: u16,
	record_count: u32,
	first_sequence: u64,
	last_sequence: u64,
	payload: []byte,
	optional := false,
) -> core.Error {
	if !pad_to_alignment(&writer.buffer) {
		return core.err_make(.Limit_Exceeded, "chunk alignment padding overflows")
	}

	offset := u64(len(writer.buffer))
	ordinal := writer.ordinals[kind]
	writer.ordinals[kind] += 1

	flags: Chunk_Flags
	if optional {
		flags += {.Optional}
	}

	header := Chunk_Header {
		magic          = CHUNK_MAGIC,
		kind           = kind,
		schema_version = schema_version,
		flags          = flags,
		codec_id       = .None,
		ordinal        = ordinal,
		record_count   = record_count,
		// Version one stores payloads uncompressed; docs/04 requires `none` to
		// always be supported, and the codec spike has not yet selected one.
		encoded_size   = u64(len(payload)),
		decoded_size   = u64(len(payload)),
		first_sequence = first_sequence,
		last_sequence  = last_sequence,
		payload_crc32c = core.crc32c(payload),
	}
	encode_chunk_header(&writer.buffer, &header)
	append(&writer.buffer, ..payload)

	append(
		&writer.directory,
		Directory_Entry {
			kind = kind,
			schema_version = schema_version,
			flags = flags,
			ordinal = ordinal,
			record_count = record_count,
			offset = offset,
			encoded_size = header.encoded_size,
			decoded_size = header.decoded_size,
			first_sequence = first_sequence,
			last_sequence = last_sequence,
		},
	)
	return nil
}

// writer_write_content serializes every canonical collection in the canonical
// chunk order given by docs/04. Physical order is deterministic even though
// readers locate chunks through the directory.
writer_write_content :: proc(writer: ^Writer, content: ^Trace_Content) -> core.Error {
	scratch := make([dynamic]u8, 0, 64 * 1024, context.temp_allocator)
	defer delete(scratch)

	// Metadata.
	clear(&scratch)
	encode_metadata(&scratch, &content.metadata)
	write_chunk(writer, .Metadata, SCHEMA_METADATA, 1, 0, 0, scratch[:]) or_return

	// Strings.
	clear(&scratch)
	encode_strings(&scratch, content.strings)
	write_chunk(
		writer,
		.Strings,
		SCHEMA_STRINGS,
		u32(model.string_table_count(content.strings)),
		0,
		0,
		scratch[:],
	) or_return

	// Entities.
	if len(content.entities) > 0 {
		clear(&scratch)
		encode_entities(&scratch, content.entities)
		write_chunk(
			writer,
			.Entities,
			SCHEMA_ENTITIES,
			u32(len(content.entities)),
			0,
			0,
			scratch[:],
		) or_return
	}

	// Spans.
	if len(content.spans) > 0 {
		clear(&scratch)
		encode_spans(&scratch, content.spans)
		write_chunk(writer, .Spans, SCHEMA_SPANS, u32(len(content.spans)), 0, 0, scratch[:]) or_return
	}

	// Events, split into bounded chunks so a time-range query can skip whole
	// chunks using the sequence range in each header.
	for start := 0; start < len(content.events); start += EVENTS_PER_CHUNK {
		end := min(start + EVENTS_PER_CHUNK, len(content.events))
		batch := content.events[start:end]

		clear(&scratch)
		encode_events(&scratch, batch)
		write_chunk(
			writer,
			.Events,
			SCHEMA_EVENTS,
			u32(len(batch)),
			u64(batch[0].sequence),
			u64(batch[len(batch) - 1].sequence),
			scratch[:],
		) or_return
	}

	// Edges.
	if len(content.edges) > 0 {
		clear(&scratch)
		encode_edges(&scratch, content.edges)
		write_chunk(writer, .Edges, SCHEMA_EDGES, u32(len(content.edges)), 0, 0, scratch[:]) or_return
	}

	// Payloads. Written even when every group is empty so a reader always
	// finds the group counts and need not treat absence as a special case.
	if content.payloads != nil {
		clear(&scratch)
		encode_payloads(&scratch, content.payloads)
		write_chunk(
			writer,
			.Payloads,
			SCHEMA_PAYLOADS,
			u32(len(content.payloads.diagnostics) + len(content.payloads.commands) +
				len(content.payloads.tests) + len(content.payloads.messages) +
				len(content.payloads.tools)),
			0,
			0,
			scratch[:],
		) or_return
	}

	// Mutations. Written before blobs only for readability of the file layout;
	// the directory makes physical order irrelevant to readers.
	if len(content.mutations) > 0 {
		clear(&scratch)
		encode_mutations(&scratch, content.mutations)
		write_chunk(
			writer,
			.Mutations,
			SCHEMA_MUTATIONS,
			u32(len(content.mutations)),
			0,
			0,
			scratch[:],
		) or_return
	}

	// Blob content, then the blob table.
	//
	// This order is required: encode_blob_content rewrites each entry's
	// location to its offset within the content payload, and the table must be
	// serialized after those offsets are final.
	clear(&scratch)
	encode_blob_content(&scratch, content.blobs)
	if len(scratch) > 0 {
		write_chunk(
			writer,
			.Blob_Content,
			SCHEMA_BLOB_CONTENT,
			u32(model.blob_table_count(content.blobs)),
			0,
			0,
			scratch[:],
		) or_return
	}

	// The table is written even when empty so a reader always finds the
	// reserved zero slot accounted for.
	clear(&scratch)
	encode_blobs(&scratch, content.blobs.entries[:])
	write_chunk(
		writer,
		.Blobs,
		SCHEMA_BLOBS,
		u32(model.blob_table_count(content.blobs)),
		0,
		0,
		scratch[:],
	) or_return

	return nil
}

// writer_finish writes the directory and footer, then patches the header.
//
// After this call the buffer holds a complete, self-consistent file image.
writer_finish :: proc(writer: ^Writer) -> core.Error {
	// Directory.
	if !pad_to_alignment(&writer.buffer) {
		return core.err_make(.Limit_Exceeded, "directory alignment padding overflows")
	}
	directory_offset := u64(len(writer.buffer))

	scratch := make([dynamic]u8, 0, 4096, context.temp_allocator)
	defer delete(scratch)
	encode_directory(&scratch, writer.directory[:])

	directory_header := Chunk_Header {
		magic          = CHUNK_MAGIC,
		kind           = .Directory,
		schema_version = SCHEMA_DIRECTORY,
		ordinal        = 0,
		record_count   = u32(len(writer.directory)),
		encoded_size   = u64(len(scratch)),
		decoded_size   = u64(len(scratch)),
		payload_crc32c = core.crc32c(scratch[:]),
	}
	encode_chunk_header(&writer.buffer, &directory_header)
	append(&writer.buffer, ..scratch[:])
	directory_size := u64(len(writer.buffer)) - directory_offset

	// Footer.
	if !pad_to_alignment(&writer.buffer) {
		return core.err_make(.Limit_Exceeded, "footer alignment padding overflows")
	}
	footer_offset := u64(len(writer.buffer))

	// The digest covers every byte after the file header.
	//
	// The header itself is excluded because writer_finish patches its offsets
	// and checksum after this point, and a digest over bytes that later change
	// could never match. The header is not left unprotected: it carries its own
	// CRC32C, and decode_file_header verifies that before trusting any offset
	// it declares. Excluding it also makes the digest independent of the
	// creation time and session identity, which docs/05 excludes from the
	// determinism promise.
	digest: [32]u8
	hash.hash(.SHA256, writer.buffer[FILE_HEADER_SIZE:], digest[:])

	footer := Footer {
		magic            = FOOTER_MAGIC,
		major            = FORMAT_MAJOR,
		minor            = FORMAT_MINOR,
		directory_offset = directory_offset,
		directory_size   = directory_size,
		digest           = digest,
		complete         = FOOTER_COMPLETE,
	}
	footer.total_size = footer_offset + FOOTER_SIZE
	encode_footer(&writer.buffer, &footer)

	// Patch the header last: the file only claims to be finalized once every
	// byte it points at is already on disk.
	writer.flags += {.Finalized}
	header := File_Header {
		magic            = FILE_MAGIC,
		major            = FORMAT_MAJOR,
		minor            = FORMAT_MINOR,
		flags            = writer.flags,
		session_id       = transmute([16]u8)writer.session_id,
		created_unix_ns  = writer.created_ns,
		directory_offset = directory_offset,
		footer_offset    = footer_offset,
	}
	patched := make([dynamic]u8, 0, FILE_HEADER_SIZE, context.temp_allocator)
	defer delete(patched)
	encode_file_header(&patched, &header)
	copy(writer.buffer[:FILE_HEADER_SIZE], patched[:])

	return nil
}

// encode_footer writes the 64-byte footer with its checksum.
@(private)
encode_footer :: proc(buffer: ^[dynamic]u8, footer: ^Footer) {
	start := len(buffer)
	cursor := Writer_Cursor{data = buffer}

	// Field offsets within the 96-byte footer:
	//   0 magic, 8 major, 10 minor, 12 complete, 16 directory_offset,
	//   24 directory_size, 32 total_size, 40 digest, 72 footer_crc32c,
	//   76 reserved.
	write_bytes(&cursor, footer.magic[:])
	write_u16(&cursor, footer.major)
	write_u16(&cursor, footer.minor)
	write_u32(&cursor, footer.complete)
	write_u64(&cursor, footer.directory_offset)
	write_u64(&cursor, footer.directory_size)
	write_u64(&cursor, footer.total_size)
	write_bytes(&cursor, footer.digest[:])
	write_u32(&cursor, 0) // Checksum placeholder.
	write_zeros(&cursor, 20) // Reserved.

	assert(len(buffer) - start == FOOTER_SIZE)
	patch_header_crc(buffer[start:len(buffer)], FOOTER_CRC_OFFSET)
}

// decode_footer parses and validates the footer.
decode_footer :: proc(data: []byte, offset: u64) -> (footer: Footer, err: core.Error) {
	if !core.range_within(offset, FOOTER_SIZE, u64(len(data))) {
		return {}, core.err_at(.Truncated_Input, "footer extends past end of file", offset)
	}
	start, ok := core.to_int(offset)
	if !ok {
		return {}, core.err_at(.Malformed_Container, "footer offset is not addressable", offset)
	}
	raw := data[start:start + FOOTER_SIZE]
	cursor := Reader_Cursor{data = raw}

	magic: []byte
	magic, _ = read_bytes(&cursor, 8)
	copy(footer.magic[:], magic)
	if footer.magic != FOOTER_MAGIC {
		return {}, core.err_at(.Malformed_Container, "footer magic is invalid", offset)
	}

	footer.major, _ = read_u16(&cursor)
	footer.minor, _ = read_u16(&cursor)
	footer.complete, _ = read_u32(&cursor)
	footer.directory_offset, _ = read_u64(&cursor)
	footer.directory_size, _ = read_u64(&cursor)
	footer.total_size, _ = read_u64(&cursor)

	digest: []byte
	digest, _ = read_bytes(&cursor, 32)
	copy(footer.digest[:], digest)
	footer.footer_crc32c, _ = read_u32(&cursor)

	if !verify_header_crc(raw, FOOTER_CRC_OFFSET, footer.footer_crc32c) {
		return {}, core.err_at(.Checksum_Mismatch, "footer checksum does not match", offset)
	}
	if footer.complete != FOOTER_COMPLETE {
		return {}, core.err_make(
			.Malformed_Container,
			"footer is missing its completion marker",
		)
	}
	if footer.total_size != offset + FOOTER_SIZE {
		return {}, core.err_make(
			.Malformed_Container,
			"footer total size disagrees with its position",
		)
	}
	return footer, nil
}

// encode_directory writes the chunk directory, sorted by kind then ordinal.
@(private)
encode_directory :: proc(buffer: ^[dynamic]u8, entries: []Directory_Entry) {
	cursor := Writer_Cursor{data = buffer}
	write_u32(&cursor, u32(len(entries)))
	write_u32(&cursor, 0) // Reserved.
	for entry in entries {
		write_u16(&cursor, u16(entry.kind))
		write_u16(&cursor, entry.schema_version)
		write_u32(&cursor, transmute(u32)entry.flags)
		write_u32(&cursor, entry.ordinal)
		write_u32(&cursor, entry.record_count)
		write_u64(&cursor, entry.offset)
		write_u64(&cursor, entry.encoded_size)
		write_u64(&cursor, entry.decoded_size)
		write_u64(&cursor, entry.first_sequence)
		write_u64(&cursor, entry.last_sequence)
		write_zeros(&cursor, 8) // Reserved, keeps the row at 64 bytes.
	}
}

// decode_directory parses the chunk directory and validates that every entry
// lies within the file.
decode_directory :: proc(
	payload: []byte,
	out: ^[dynamic]Directory_Entry,
	file_size: u64,
	limits := core.DEFAULT_LIMITS,
) -> core.Error {
	cursor := Reader_Cursor{data = payload}
	count, ok := read_u32(&cursor)
	if !ok {
		return core.err_make(.Truncated_Input, "directory is missing its count")
	}
	if !skip(&cursor, 4) {
		return core.err_make(.Truncated_Input, "directory header is truncated")
	}
	if err := core.check_limit(
		u64(count),
		limits.max_chunk_count,
		"directory exceeds the chunk-count limit",
	); !core.ok(err) {
		return err
	}
	span, mul_ok := core.mul_u64(u64(count), DIRECTORY_ENTRY_SIZE)
	if !mul_ok {
		return core.err_make(.Limit_Exceeded, "directory size overflows")
	}
	if !core.range_within(u64(cursor.offset), span, u64(len(payload))) {
		return core.err_make(.Truncated_Input, "directory is shorter than it declares")
	}

	for index in 0 ..< int(count) {
		entry: Directory_Entry
		raw16: u16
		raw32: u32

		raw16, _ = read_u16(&cursor); entry.kind = Chunk_Kind(raw16)
		entry.schema_version, _ = read_u16(&cursor)
		raw32, _ = read_u32(&cursor); entry.flags = transmute(Chunk_Flags)raw32
		entry.ordinal, _ = read_u32(&cursor)
		entry.record_count, _ = read_u32(&cursor)
		entry.offset, _ = read_u64(&cursor)
		entry.encoded_size, _ = read_u64(&cursor)
		entry.decoded_size, _ = read_u64(&cursor)
		entry.first_sequence, _ = read_u64(&cursor)
		entry.last_sequence, _ = read_u64(&cursor)
		_ = skip(&cursor, 8)

		// Each entry is checked against the file before it is stored, so a
		// caller can seek to any directory entry without re-validating.
		chunk_span, sum_ok := core.add_u64(CHUNK_HEADER_SIZE, entry.encoded_size)
		if !sum_ok {
			return core.err_make(.Malformed_Container, "directory entry size overflows")
		}
		if !core.range_within(entry.offset, chunk_span, file_size) {
			return core.err_record(
				.Malformed_Container,
				"directory entry points outside the file",
				u64(index),
			)
		}

		append(out, entry)
	}
	return nil
}

// write_trace serializes content and writes it to `path` via a temporary file.
//
// docs/04: import writes to `<destination>.tmp` and atomically renames only
// after reopening and validating the finished file. A failed validation
// removes the temporary file and leaves no destination, so a partial import
// can never be mistaken for a complete trace.
write_trace :: proc(path: string, content: ^Trace_Content) -> core.Error {
	writer: Writer
	writer_init(&writer, content.session_id)
	defer writer_destroy(&writer)

	writer_write_content(&writer, content) or_return
	writer_finish(&writer) or_return

	temporary := make([]byte, len(path) + 4, context.temp_allocator)
	defer delete(temporary, context.temp_allocator)
	copy(temporary, path)
	copy(temporary[len(path):], ".tmp")
	temporary_path := string(temporary)

	if os.write_entire_file(temporary_path, writer.buffer[:]) != nil {
		return core.err_path(.Io_Failure, "could not write the temporary trace", temporary_path)
	}

	// Reopen and validate before publishing. Validating the buffer we just
	// built would only prove the encoder agrees with itself; reading the file
	// back also proves the bytes reached the filesystem intact.
	written, read_err := os.read_entire_file_from_path(temporary_path, context.allocator)
	if read_err != nil {
		os.remove(temporary_path)
		return core.err_path(.Io_Failure, "could not reopen the temporary trace", temporary_path)
	}
	defer delete(written)

	if err := validate_quick(written); !core.ok(err) {
		os.remove(temporary_path)
		return err
	}

	if os.rename(temporary_path, path) != nil {
		os.remove(temporary_path)
		return core.err_path(.Io_Failure, "could not publish the trace", path)
	}
	return nil
}
