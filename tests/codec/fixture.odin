package test_codec

import "src:trace/codec"
import "src:trace/model"

// Shared fixture construction.
//
// Tests build a canonical trace in memory, write it, and read it back. The
// fixture is deliberately small but covers every chunk kind the writer emits,
// so a corruption test can damage any structure and expect a clean rejection.

Fixture :: struct {
	strings:  model.String_Table,
	blobs:    model.Blob_Table,
	entities: [dynamic]model.Entity,
	spans:    [dynamic]model.Span,
	events:   [dynamic]model.Event,
	edges:    [dynamic]model.Edge,
	content:  codec.Trace_Content,
}

fixture_destroy :: proc(fixture: ^Fixture) {
	model.string_table_destroy(&fixture.strings)
	model.blob_table_destroy(&fixture.blobs)
	delete(fixture.entities)
	delete(fixture.spans)
	delete(fixture.events)
	delete(fixture.edges)
}

// make_fixture builds a trace resembling a tiny agent session: a prompt, a
// file read, an edit, a command, and a failing test, with one inferred edge
// linking the edit to the failure.
make_fixture :: proc(fixture: ^Fixture) {
	model.string_table_init(&fixture.strings)
	model.blob_table_init(&fixture.blobs)
	fixture.entities = make([dynamic]model.Entity, 0, 8)
	fixture.spans = make([dynamic]model.Span, 0, 4)
	fixture.events = make([dynamic]model.Event, 0, 8)
	fixture.edges = make([dynamic]model.Edge, 0, 4)

	intern :: proc(fixture: ^Fixture, value: string) -> model.String_Id {
		id, _ := model.string_intern(&fixture.strings, value)
		return id
	}

	importer_id := intern(fixture, "codex")
	importer_version := intern(fixture, "0.1.0")
	source_file := intern(fixture, "session.jsonl")

	source :: proc(
		importer, version, file: model.String_Id,
		record: u64,
	) -> model.Source_Ref {
		return model.Source_Ref {
			importer_id = importer,
			importer_version = version,
			source_file = file,
			record_number = record,
		}
	}

	// Entities. Identifiers are one-based and match their slice position.
	append(
		&fixture.entities,
		model.Entity {
			id = 1,
			kind = .Actor_Agent,
			name = intern(fixture, "agent"),
			first_seen = 1,
			last_seen = 5,
		},
	)
	append(
		&fixture.entities,
		model.Entity {
			id = 2,
			kind = .Path,
			name = intern(fixture, "src/parser.odin"),
			first_seen = 2,
			last_seen = 3,
		},
	)
	append(
		&fixture.entities,
		model.Entity {
			id = 3,
			kind = .Test_Case,
			name = intern(fixture, "parses_empty_input"),
			qualifier = intern(fixture, "parser_tests"),
			first_seen = 5,
			last_seen = 5,
		},
	)

	// One agent turn spanning every event.
	append(
		&fixture.spans,
		model.Span {
			id = 1,
			kind = .Agent_Turn,
			name = intern(fixture, "turn 1"),
			start_sequence = 1,
			end_sequence = 5,
			start_event = 1,
			end_event = 5,
		},
	)

	// A blob standing in for the edited file's content.
	content_bytes := transmute([]byte)string("package parser\n")
	digest := model.digest_content(content_bytes)
	content_blob, _ := model.blob_intern(
		&fixture.blobs,
		model.Blob_Entry {
			digest = digest,
			media_type = intern(fixture, "text/plain"),
			encoding = .Utf8,
			size = u64(len(content_bytes)),
		},
	)

	append(
		&fixture.events,
		model.Event {
			id = 1,
			sequence = 1,
			kind = .User_Message,
			flags = {.Has_Wall_Time},
			time_quality = .Exact,
			wall_time_ns = 1_700_000_000_000_000_000,
			parent_span_id = 1,
			summary_string_id = intern(fixture, "fix the parser"),
			source = source(importer_id, importer_version, source_file, 1),
		},
	)
	append(
		&fixture.events,
		model.Event {
			id = 2,
			sequence = 2,
			kind = .File_Read,
			flags = {.Has_Wall_Time},
			time_quality = .Exact,
			wall_time_ns = 1_700_000_001_000_000_000,
			parent_span_id = 1,
			actor_entity_id = 1,
			primary_entity_id = 2,
			source = source(importer_id, importer_version, source_file, 2),
		},
	)
	append(
		&fixture.events,
		model.Event {
			id = 3,
			sequence = 3,
			kind = .File_Modify,
			flags = {.Has_Wall_Time},
			time_quality = .Exact,
			wall_time_ns = 1_700_000_002_000_000_000,
			parent_span_id = 1,
			actor_entity_id = 1,
			primary_entity_id = 2,
			source = source(importer_id, importer_version, source_file, 3),
		},
	)
	append(
		&fixture.events,
		model.Event {
			id = 4,
			sequence = 4,
			kind = .Command_Start,
			flags = {.Has_Wall_Time},
			time_quality = .Exact,
			wall_time_ns = 1_700_000_003_000_000_000,
			parent_span_id = 1,
			actor_entity_id = 1,
			summary_string_id = intern(fixture, "odin test tests/parser"),
			source = source(importer_id, importer_version, source_file, 4),
		},
	)
	append(
		&fixture.events,
		model.Event {
			id = 5,
			sequence = 5,
			kind = .Test_Case_Result,
			flags = {.Has_Wall_Time, .Has_Duration},
			time_quality = .Exact,
			wall_time_ns = 1_700_000_004_000_000_000,
			duration_ns = 250_000_000,
			parent_span_id = 1,
			actor_entity_id = 1,
			primary_entity_id = 3,
			summary_string_id = intern(fixture, "parses_empty_input failed"),
			source = source(importer_id, importer_version, source_file, 5),
		},
	)

	// A reconstructed edge (the mutation wrote the path) and an inferred one
	// (the edit may have contributed to the failure). The inferred edge must
	// carry its rule identifier or validation rejects it.
	append(
		&fixture.edges,
		model.Edge {
			kind = .Writes,
			origin = .Reconstructed,
			from = model.event_endpoint(3),
			to = model.entity_endpoint(2),
			confidence = model.CONFIDENCE_SCALE,
		},
	)
	append(
		&fixture.edges,
		model.Edge {
			kind = .Candidate_Contributor,
			origin = .Inferred,
			from = model.event_endpoint(3),
			to = model.event_endpoint(5),
			confidence = model.confidence_from_f32(0.6),
			rule = intern(fixture, "recent_edit_before_failure@1"),
			reason = intern(fixture, "edited src/parser.odin before the failing test"),
		},
	)

	metadata := codec.Session_Metadata {
		importer_id = importer_id,
		importer_version = importer_version,
		repository_name = intern(fixture, "norn"),
		repository_path = intern(fixture, "[REDACTED:home]/projects/norn"),
		version_control = .Git,
		baseline_kind = .Commit_Verified,
		start_commit = intern(fixture, "3c146e0"),
		branch = intern(fixture, "master"),
		case_sensitive_paths = false,
		session_start_ns = 1_700_000_000_000_000_000,
		session_end_ns = 1_700_000_004_000_000_000,
		capabilities = {
			.Wall_Clock_Timestamps,
			.Conversation_Text,
			.File_Reads,
			.Command_Boundaries,
			.Structured_Tests,
		},
		source_record_count = 5,
		canonical_event_count = 5,
		file_content_bytes = u64(len(content_bytes)),
	}
	metadata.warnings[int(codec.Warning_Category.Timestamp_Repaired)] = 2
	metadata.redactions[int(codec.Redaction_Category.Home_Path_Prefix)] = 1

	_ = content_blob

	fixture.content = codec.Trace_Content {
		session_id = model.Session_Id{
			0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
			0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10,
		},
		metadata   = metadata,
		strings    = &fixture.strings,
		blobs      = &fixture.blobs,
		entities   = fixture.entities[:],
		spans      = fixture.spans[:],
		events     = fixture.events[:],
		edges      = fixture.edges[:],
	}
}

// build_image writes a fixture to an in-memory file image. The caller owns the
// returned bytes.
build_image :: proc(fixture: ^Fixture) -> ([]byte, bool) {
	writer: codec.Writer
	codec.writer_init(&writer, fixture.content.session_id)
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
