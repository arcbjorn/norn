package importer_api

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:time"

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// The import pipeline.
//
// docs/05-importers.md fixes the stage order:
//
//   detect -> inspect -> stream parse -> redact -> normalize -> correlate
//        -> validate batches -> write canonical chunks -> build indexes
//        -> full validation -> atomic publish
//
// Redaction, normalization, and correlation happen inside the sink, so this
// coordinates the stages around them: it drives an adapter, validates what the
// adapter produced, and publishes only after the finished file reads back
// clean.
//
// docs/11 makes one of its exit criteria explicit: "import never writes a
// complete-looking destination after failure." Everything below is arranged so
// that a failure at any stage leaves no destination at all.

// Import_Outcome is what a completed import reports.
Import_Outcome :: struct {
	report: Import_Report,
	// Path the trace was published to, empty when the import failed.
	destination: string,
	// Wall time the import took, for the report docs/05 specifies.
	elapsed_ns: i64,
	// Bytes the source occupied, for context alongside the trace size.
	source_bytes: u64,
	trace_bytes:  u64,
}

// import_source runs the pipeline for one adapter and source.
//
// `destination` is the `.norn` path to publish. The temporary file and atomic
// rename are handled by the codec's write_trace, which reopens and validates
// before publishing.
import_source :: proc(
	importer: Importer,
	source: []byte,
	destination: string,
	identity: Session_Identity,
	options: Options,
    allocator := context.allocator,
) -> (
	outcome: Import_Outcome,
	err: core.Error,
) {
	if importer.import_source == nil {
		return {}, core.err_make(.Invalid_Argument, "the adapter cannot import")
	}

	started := time.tick_now()
	outcome.source_bytes = u64(len(source))

	redactor: Redactor
	redactor_init(&redactor, allocator)
	defer redactor_destroy(&redactor)

	// User rules first: the more specific a rule, the earlier it should match,
	// and a home prefix must be replaced before a pattern rule can match
	// inside the same path.
	add_home_prefix(&redactor, options.home_prefix)
	for rule in options.literal_rules {
		add_literal(&redactor, rule)
	}

	sink: Sink
	sink_init(&sink, &redactor, importer.id, importer.version, source_name(destination), allocator)
	defer sink_destroy(&sink)

	// Stages three through six: the adapter streams, and every record it
	// describes passes through the sink's redaction and normalization.
	if parse_err := importer.import_source(source, &sink, options); !core.ok(parse_err) {
		return {}, parse_err
	}

	// Batch validation. The codec validates the finished file too, but failing
	// here names the adapter rather than reporting a corrupt trace after the
	// writer has run.
	if invariant_err := validate_invariants(&sink); !core.ok(invariant_err) {
		return {}, invariant_err
	}

	metadata := build_metadata(&sink, identity)
	content := finish(&sink, new_session_id(), metadata)

	// Writing, full validation, and atomic publish are the codec's: write_trace
	// writes a temporary file, reopens it, validates, and renames only on
	// success. A failure removes the temporary and leaves no destination.
	if write_err := codec.write_trace(destination, &content); !core.ok(write_err) {
		return {}, write_err
	}

	outcome.report = sink.report
	outcome.destination = destination
	outcome.elapsed_ns = i64(time.duration_nanoseconds(time.tick_since(started)))

	if info, stat_err := os.stat(destination, context.temp_allocator); stat_err == nil {
		outcome.trace_bytes = u64(info.size)
	}

	return outcome, nil
}

// inspect_source runs detection and inspection without writing anything.
//
// docs/01: import "shows the detected session metadata, and reports any
// unsupported record types before writing output." A user should learn a trace
// is half unsupported before waiting for it to be written.
inspect_source :: proc(
	importer: Importer,
	source: []byte,
	allocator := context.allocator,
) -> (
	metadata: Source_Metadata,
	err: core.Error,
) {
	if importer.inspect == nil {
		return {}, core.err_make(.Unsupported_Feature, "the adapter cannot inspect")
	}
	return importer.inspect(source, allocator)
}

// build_metadata assembles the session metadata from identity and the report.
@(private)
build_metadata :: proc(sink: ^Sink, identity: Session_Identity) -> codec.Session_Metadata {
	metadata := codec.Session_Metadata {
		// The repository path is interned through the sink, so the home
		// prefix is replaced before it reaches the trace. docs/05: absolute
		// source paths are retained only in redacted provenance metadata.
		repository_name = intern_text(sink, identity.repository_name),
		repository_path = intern_text(sink, identity.repository_path),
		start_commit    = intern_text(sink, identity.start_commit),
		end_commit      = intern_text(sink, identity.end_commit),
		branch          = intern_text(sink, identity.branch),
		case_sensitive_paths = identity.case_sensitive,
		initially_dirty      = identity.initially_dirty,
	}

	if identity.version_control == .Repository {
		metadata.version_control = .Git
	} else {
		metadata.version_control = .None
	}

	// Session extent from the events actually recorded, rather than from a
	// clock read during import: the trace should describe the session, not
	// when it happened to be converted.
	for event in sink.events {
		if .Has_Wall_Time not_in event.flags {
			continue
		}
		if metadata.session_start_ns == 0 || event.wall_time_ns < metadata.session_start_ns {
			metadata.session_start_ns = event.wall_time_ns
		}
		if event.wall_time_ns > metadata.session_end_ns {
			metadata.session_end_ns = event.wall_time_ns
		}
	}

	// docs/06: a working-tree snapshot is acceptable but labelled
	// observational. Without a captured baseline there is nothing to label, so
	// the trace says so rather than implying a verified one.
	metadata.baseline_kind = .None

	return metadata
}

// new_session_id produces a random 128-bit identifier.
//
// docs/05 excludes the session identity from the canonical-content digest, so
// randomness here does not break the determinism requirement: two imports of
// one source produce identical chunks with different session identifiers.
@(private)
new_session_id :: proc() -> model.Session_Id {
	id: model.Session_Id
	crypto.rand_bytes(id[:])
	return id
}

// source_name returns the file name portion of a path.
//
// The full path is not stored as the source identity: docs/08 keeps absolute
// paths out of a trace except as redacted provenance, and a bare file name is
// enough to tell two source logs apart.
@(private)
source_name :: proc(path: string) -> string {
	last := -1
	for index in 0 ..< len(path) {
		if path[index] == '/' {
			last = index
		}
	}
	if last < 0 {
		return path
	}
	return path[last + 1:]
}

// format_report renders the import report docs/05 specifies.
//
// Both displayed and stored, so it is assembled in one place rather than
// formatted differently by each caller.
format_report :: proc(
	outcome: ^Import_Outcome,
	allocator := context.allocator,
) -> string {
	report := &outcome.report

	builder := make([dynamic]u8, 0, 1024, allocator)
	write :: proc(builder: ^[dynamic]u8, text: string) {
		append(builder, ..transmute([]byte)text)
	}

	write(&builder, fmt.tprintf("source records:    %d\n", report.source_records))
	write(&builder, fmt.tprintf("canonical events:  %d\n", report.canonical_events))
	if report.extension_events > 0 {
		write(&builder, fmt.tprintf("extension events:  %d\n", report.extension_events))
	}
	if report.ignored_records > 0 {
		write(&builder, fmt.tprintf("ignored records:   %d\n", report.ignored_records))
	}

	write(
		&builder,
		fmt.tprintf(
			"mutations:         %d replayable, %d partial, %d opaque\n",
			report.replayable_mutations,
			report.partial_mutations,
			report.opaque_mutations,
		),
	)

	// docs/05 requires timestamp quality counts, so a trace whose clock was
	// unreliable says so rather than presenting repaired times as recorded.
	write(
		&builder,
		fmt.tprintf(
			"timestamps:        %d exact, %d repaired, %d absent\n",
			report.exact_timestamps,
			report.repaired_timestamps,
			report.absent_timestamps,
		),
	)

	warnings := 0
	for count in report.warnings {
		warnings += int(count)
	}
	if warnings > 0 {
		write(&builder, fmt.tprintf("\nwarnings: %d\n", warnings))
		for category in codec.Warning_Category {
			count := report.warnings[int(category)]
			if count > 0 {
				write(
					&builder,
					fmt.tprintf("  %-20s %d\n", codec.warning_category_name(category), count),
				)
			}
		}
	}

	redactions := 0
	for count in report.redactions {
		redactions += int(count)
	}
	if redactions > 0 {
		// docs/08: reports list rule identifiers and counts, never matched
		// values.
		write(&builder, fmt.tprintf("\nredactions: %d\n", redactions))
		for category in codec.Redaction_Category {
			count := report.redactions[int(category)]
			if count > 0 {
				write(
					&builder,
					fmt.tprintf("  %-20s %d\n", codec.redaction_category_name(category), count),
				)
			}
		}
	}

	if report.peak_parse_bytes > 0 {
		// docs/05 requires the parser to stream. Showing the high-water mark is
		// how a user can see that it did.
		write(
			&builder,
			fmt.tprintf(
				"\npeak parse memory: %d bytes\n",
				report.peak_parse_bytes,
			),
		)
	}

	write(
		&builder,
		fmt.tprintf(
			"\nsource %d bytes -> trace %d bytes in %.2f s\n",
			outcome.source_bytes,
			outcome.trace_bytes,
			f64(outcome.elapsed_ns) / 1e9,
		),
	)

	return string(builder[:])
}
