package codec

import "src:core"
import "src:trace/model"

// Session metadata.
//
// docs/01-user-experience.md: import warnings do not disappear after the
// import dialog — they remain part of the session metadata. This chunk is
// where that promise is kept, so the counts here are written even when zero.

// Capability enumerates what a source trace actually provided, per docs/05.
// The UI derives feature availability from this manifest: missing data is not
// an error and must not be presented as recorded evidence.
Capability :: enum u32 {
	Wall_Clock_Timestamps = 0,
	Monotonic_Timing      = 1,
	Stable_Event_Ids      = 2,
	Nested_Spans          = 3,
	Conversation_Text     = 4,
	Structured_Tool_Calls = 5,
	File_Reads            = 6,
	Patches               = 7,
	Before_After_Content  = 8,
	Command_Boundaries    = 9,
	Command_Output        = 10,
	Structured_Tests      = 11,
	Token_Usage           = 12,
	Sub_Agent_Identity    = 13,
	Raw_Record_Preserved  = 14,
}

Capabilities :: bit_set[Capability; u32]

// Warning_Category groups import warnings so the report can count them without
// storing one string per occurrence.
Warning_Category :: enum u16 {
	Malformed_Record     = 0,
	Unsupported_Record   = 1,
	Timestamp_Repaired   = 2,
	Path_Rejected        = 3,
	Content_Truncated    = 4,
	Patch_Failed         = 5,
	Hash_Mismatch        = 6,
	Missing_Baseline     = 7,
	Ambiguous_Pairing    = 8,
	Span_Incomplete      = 9,
}

WARNING_CATEGORY_COUNT :: 10

// Redaction_Category counts replacements by rule class. docs/08: reports list
// rule identifiers and counts, never matched values.
Redaction_Category :: enum u16 {
	Credential           = 0,
	Authorization_Header = 1,
	Environment_Variable = 2,
	Url_User_Info        = 3,
	Home_Path_Prefix     = 4,
	User_Rule            = 5,
	Provider_Sensitive   = 6,
}

REDACTION_CATEGORY_COUNT :: 7

// Version_Control identifies the repository kind recorded at import.
Version_Control :: enum u8 {
	None    = 0,
	Unknown = 1,
	Git     = 2,
}

// Baseline_Kind records how strongly the replay baseline is grounded.
// docs/06: a working-tree snapshot is acceptable but is labeled observational,
// and the distinction must survive into the viewer.
Baseline_Kind :: enum u8 {
	// No baseline content was captured; replay begins from nothing.
	None = 0,
	// Content read from a recorded starting commit and verified against
	// recorded hashes.
	Commit_Verified = 1,
	// Content observed from the working tree. It reflects one moment that may
	// already differ from what the session started with.
	Working_Tree_Observational = 2,
}

// Session_Metadata is the metadata chunk's contents.
//
// String fields hold interned identifiers rather than text so the metadata
// chunk stays fixed-width and every string lives once in the strings chunk.
Session_Metadata :: struct {
	// Importer identity, required for reproducing the import.
	importer_id:      model.String_Id,
	importer_version: model.String_Id,

	// Repository identity, per docs/05. The original absolute path is retained
	// only in redacted form.
	repository_name:      model.String_Id,
	repository_path:      model.String_Id, // Redacted.
	version_control:      Version_Control,
	baseline_kind:        Baseline_Kind,
	start_commit:         model.String_Id,
	end_commit:           model.String_Id,
	branch:               model.String_Id,
	case_sensitive_paths: bool,
	initially_dirty:      bool,

	// Session timing. Absent values are zero and are meaningful only when the
	// corresponding capability is present.
	session_start_ns: i64,
	session_end_ns:   i64,

	capabilities: Capabilities,

	// Counts from the import report, per docs/05.
	source_record_count:  u64,
	canonical_event_count: u64,
	extension_event_count: u64,
	ignored_record_count:  u64,
	file_content_bytes:    u64, // docs/08: the UI reports how much content the trace holds.

	warnings:   [WARNING_CATEGORY_COUNT]u32,
	redactions: [REDACTION_CATEGORY_COUNT]u32,
}

// warning_category_name returns a stable identifier for reports and tests.
warning_category_name :: proc "contextless" (category: Warning_Category) -> string {
	switch category {
	case .Malformed_Record:   return "malformed_record"
	case .Unsupported_Record: return "unsupported_record"
	case .Timestamp_Repaired: return "timestamp_repaired"
	case .Path_Rejected:      return "path_rejected"
	case .Content_Truncated:  return "content_truncated"
	case .Patch_Failed:       return "patch_failed"
	case .Hash_Mismatch:      return "hash_mismatch"
	case .Missing_Baseline:   return "missing_baseline"
	case .Ambiguous_Pairing:  return "ambiguous_pairing"
	case .Span_Incomplete:    return "span_incomplete"
	}
	return "unknown"
}

// redaction_category_name returns a stable identifier for reports and tests.
redaction_category_name :: proc "contextless" (category: Redaction_Category) -> string {
	switch category {
	case .Credential:           return "credential"
	case .Authorization_Header: return "authorization_header"
	case .Environment_Variable: return "environment_variable"
	case .Url_User_Info:        return "url_user_info"
	case .Home_Path_Prefix:     return "home_path_prefix"
	case .User_Rule:            return "user_rule"
	case .Provider_Sensitive:   return "provider_sensitive"
	}
	return "unknown"
}

// total_warnings sums every warning counter.
total_warnings :: proc "contextless" (metadata: ^Session_Metadata) -> u64 {
	total := u64(0)
	for count in metadata.warnings {
		total += u64(count)
	}
	return total
}

// total_redactions sums every redaction counter.
total_redactions :: proc "contextless" (metadata: ^Session_Metadata) -> u64 {
	total := u64(0)
	for count in metadata.redactions {
		total += u64(count)
	}
	return total
}

encode_metadata :: proc(buffer: ^[dynamic]u8, metadata: ^Session_Metadata) {
	cursor := Writer_Cursor{data = buffer}

	write_u32(&cursor, u32(metadata.importer_id))
	write_u32(&cursor, u32(metadata.importer_version))
	write_u32(&cursor, u32(metadata.repository_name))
	write_u32(&cursor, u32(metadata.repository_path))
	write_u32(&cursor, u32(metadata.start_commit))
	write_u32(&cursor, u32(metadata.end_commit))
	write_u32(&cursor, u32(metadata.branch))

	write_u8(&cursor, u8(metadata.version_control))
	write_u8(&cursor, u8(metadata.baseline_kind))
	write_u8(&cursor, metadata.case_sensitive_paths ? 1 : 0)
	write_u8(&cursor, metadata.initially_dirty ? 1 : 0)

	write_i64(&cursor, metadata.session_start_ns)
	write_i64(&cursor, metadata.session_end_ns)
	write_u32(&cursor, transmute(u32)metadata.capabilities)
	write_zeros(&cursor, 4) // Reserved.

	write_u64(&cursor, metadata.source_record_count)
	write_u64(&cursor, metadata.canonical_event_count)
	write_u64(&cursor, metadata.extension_event_count)
	write_u64(&cursor, metadata.ignored_record_count)
	write_u64(&cursor, metadata.file_content_bytes)

	write_u16(&cursor, u16(WARNING_CATEGORY_COUNT))
	write_u16(&cursor, u16(REDACTION_CATEGORY_COUNT))
	for count in metadata.warnings {
		write_u32(&cursor, count)
	}
	for count in metadata.redactions {
		write_u32(&cursor, count)
	}
}

decode_metadata :: proc(payload: []byte) -> (metadata: Session_Metadata, err: core.Error) {
	cursor := Reader_Cursor{data = payload}
	raw32: u32
	raw8: u8
	ok: bool

	raw32, ok = read_u32(&cursor)
	if !ok {
		return {}, core.err_make(.Truncated_Input, "metadata chunk is truncated")
	}
	metadata.importer_id = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.importer_version = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.repository_name = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.repository_path = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.start_commit = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.end_commit = model.String_Id(raw32)
	raw32, _ = read_u32(&cursor); metadata.branch = model.String_Id(raw32)

	raw8, _ = read_u8(&cursor); metadata.version_control = Version_Control(raw8)
	raw8, _ = read_u8(&cursor); metadata.baseline_kind = Baseline_Kind(raw8)
	raw8, _ = read_u8(&cursor); metadata.case_sensitive_paths = raw8 != 0
	raw8, ok = read_u8(&cursor); metadata.initially_dirty = raw8 != 0
	if !ok {
		return {}, core.err_make(.Truncated_Input, "metadata chunk is truncated")
	}

	metadata.session_start_ns, _ = read_i64(&cursor)
	metadata.session_end_ns, _ = read_i64(&cursor)
	raw32, _ = read_u32(&cursor)
	metadata.capabilities = transmute(Capabilities)raw32
	if !skip(&cursor, 4) {
		return {}, core.err_make(.Truncated_Input, "metadata chunk is truncated")
	}

	metadata.source_record_count, _ = read_u64(&cursor)
	metadata.canonical_event_count, _ = read_u64(&cursor)
	metadata.extension_event_count, _ = read_u64(&cursor)
	metadata.ignored_record_count, _ = read_u64(&cursor)
	metadata.file_content_bytes, ok = read_u64(&cursor)
	if !ok {
		return {}, core.err_make(.Truncated_Input, "metadata chunk is truncated")
	}

	// The counter-array lengths are stored so a future minor version can add
	// categories: a reader keeps the ones it knows and skips the rest.
	warning_count, redaction_count: u16
	warning_count, _ = read_u16(&cursor)
	redaction_count, ok = read_u16(&cursor)
	if !ok {
		return {}, core.err_make(.Truncated_Input, "metadata chunk is truncated")
	}

	needed, mul_ok := core.mul_u64(u64(warning_count) + u64(redaction_count), 4)
	if !mul_ok {
		return {}, core.err_make(.Limit_Exceeded, "metadata counter arrays overflow")
	}
	if !core.range_within(u64(cursor.offset), needed, u64(len(payload))) {
		return {}, core.err_make(.Truncated_Input, "metadata counter arrays are truncated")
	}

	for index in 0 ..< int(warning_count) {
		value, _ := read_u32(&cursor)
		if index < WARNING_CATEGORY_COUNT {
			metadata.warnings[index] = value
		}
	}
	for index in 0 ..< int(redaction_count) {
		value, _ := read_u32(&cursor)
		if index < REDACTION_CATEGORY_COUNT {
			metadata.redactions[index] = value
		}
	}

	return metadata, nil
}
