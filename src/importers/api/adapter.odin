package importer_api

import "core:mem"

import "src:core"
import "src:trace/model"

// The adapter contract.
//
// docs/05-importers.md defines what an importer provides: an identity, a
// version, detection with confidence and reasons, inspection, and the import
// itself. Provider-specific assumptions stop here — docs/02 requires that they
// "never leak into rendering or analysis".

// Confidence is how strongly an adapter claims a source.
//
// docs/05: "auto-detection proceeds only when one adapter has high confidence
// and no adapter has comparable confidence. Otherwise the user chooses
// explicitly." That rule needs a comparable scale, and it needs adapters to be
// honest about uncertainty rather than each claiming everything.
Confidence :: enum u8 {
	// Nothing about the source matches this adapter.
	None = 0,
	// The shape is compatible but so are other formats. A JSONL file is not a
	// Codex trace merely because it is JSONL.
	Possible = 1,
	// Distinguishing markers are present but the variant is unconfirmed.
	Likely = 2,
	// A version marker or equally decisive signal identifies the format.
	Certain = 3,
}

// MAX_DETECTION_REASONS bounds the explanation an adapter returns.
MAX_DETECTION_REASONS :: 4

// Detection is an adapter's claim on a source.
//
// The reasons are shown to the user when detection is ambiguous, so they can
// choose an adapter on evidence rather than on a name.
Detection :: struct {
	confidence: Confidence,
	// Static strings describing what matched. Static because they are written
	// by the adapter, not derived from the untrusted source.
	reasons: [MAX_DETECTION_REASONS]string,
	count:   int,
}

// add_reason records why an adapter matched.
add_reason :: proc(detection: ^Detection, reason: string) {
	if detection.count >= MAX_DETECTION_REASONS {
		return
	}
	detection.reasons[detection.count] = reason
	detection.count += 1
}

// reasons returns the populated reason slice.
reasons :: proc(detection: ^Detection) -> []string {
	return detection.reasons[:detection.count]
}

// Source_Metadata is what inspection reports before any import runs.
//
// docs/01: import "shows the detected session metadata, and reports any
// unsupported record types before writing output." A user should learn a trace
// is half unsupported before waiting for it to be written.
Source_Metadata :: struct {
	// Records the adapter could see without a full parse.
	record_count: u64,
	// Byte size of the source.
	size_bytes: u64,
	// The variant the adapter believes it is reading. Displayed so a user can
	// tell a supported variant from a guess.
	variant: string,
	// Record type names the adapter does not map. docs/05 requires these to be
	// reported rather than silently dropped.
	unsupported_types: [dynamic]string,
	// Capabilities the adapter expects to find, before confirming them.
	expected: Expected_Capabilities,
}

Expected_Capabilities :: struct {
	timestamps:      bool,
	conversation:    bool,
	tool_calls:      bool,
	file_mutations:  bool,
	command_output:  bool,
	structured_tests: bool,
}

source_metadata_destroy :: proc(metadata: ^Source_Metadata) {
	delete(metadata.unsupported_types)
	metadata^ = {}
}

// Options configures one import.
Options :: struct {
	// docs/10 keeps raw provider records opt-in, because they help adapter
	// debugging but substantially increase privacy exposure and trace size.
	retain_raw_records: bool,
	// The repository root, for resolving baseline content.
	repository_root: string,
	// Additional literal redaction rules the user supplied.
	literal_rules: []string,
	// The home directory to replace with a stable placeholder.
	home_prefix: string,
	// The repository to read baseline content from. Nil skips capture, which
	// docs/06 treats as a legitimate state: the trace records that it has no
	// baseline rather than implying one.
	repository: ^Repository,
}

// Importer is the adapter interface.
//
// Procedure pointers rather than an interface type, because Odin has no
// interfaces and a table of functions makes the contract explicit: an adapter
// is exactly these five things and nothing else.
Importer :: struct {
	id:      string,
	version: string,

	// detect examines a prefix of the source. It must not read the whole file:
	// detection runs against every registered adapter, and a hostile file
	// should not be parsed five times before one adapter claims it.
	detect: proc(prefix: []byte, path_hint: string) -> Detection,

	// inspect reports what the source contains without producing a trace.
	inspect: proc(source: []byte, allocator: mem.Allocator) -> (Source_Metadata, core.Error),

	// import_source converts the source into canonical records in the sink.
	import_source: proc(
		source: []byte,
		sink: ^Sink,
		options: Options,
	) -> core.Error,
}

// DETECTION_PREFIX is how many bytes detection may examine.
//
// Enough to see a header or a first record, small enough that detecting
// against several adapters costs one page read rather than a full parse.
DETECTION_PREFIX :: 8192

// Registry holds the available adapters.
Registry :: struct {
	adapters: [dynamic]Importer,
}

registry_init :: proc(registry: ^Registry, allocator := context.allocator) {
	registry.adapters = make([dynamic]Importer, 0, 4, allocator)
}

registry_destroy :: proc(registry: ^Registry) {
	delete(registry.adapters)
	registry^ = {}
}

register :: proc(registry: ^Registry, importer: Importer) {
	append(&registry.adapters, importer)
}

// find returns the adapter with a given identifier.
find :: proc(registry: ^Registry, id: string) -> (importer: Importer, found: bool) {
	for adapter in registry.adapters {
		if adapter.id == id {
			return adapter, true
		}
	}
	return {}, false
}

// Detection_Result pairs an adapter with its claim.
Detection_Result :: struct {
	importer:  Importer,
	detection: Detection,
}

// detect_all runs every adapter's detection against a source.
//
// Results are in registration order, which is deterministic, so a report
// listing them reads the same on every run.
detect_all :: proc(
	registry: ^Registry,
	source: []byte,
	path_hint: string,
	allocator := context.allocator,
) -> [dynamic]Detection_Result {
	results := make([dynamic]Detection_Result, 0, len(registry.adapters), allocator)

	prefix := source
	if len(prefix) > DETECTION_PREFIX {
		prefix = prefix[:DETECTION_PREFIX]
	}

	for adapter in registry.adapters {
		if adapter.detect == nil {
			continue
		}
		detection := adapter.detect(prefix, path_hint)
		if detection.confidence == .None {
			continue
		}
		append(&results, Detection_Result{importer = adapter, detection = detection})
	}
	return results
}

// choose_adapter applies the auto-detection rule from docs/05.
//
// "Auto-detection proceeds only when one adapter has high confidence and no
// adapter has comparable confidence. Otherwise the user chooses explicitly."
// Ambiguity returns false rather than picking the first match: importing with
// the wrong adapter produces a plausible-looking trace of the wrong session,
// which is worse than asking.
choose_adapter :: proc(
	results: []Detection_Result,
) -> (
	importer: Importer,
	chosen: bool,
) {
	best: Detection_Result
	best_index := -1
	comparable_count := 0

	for result, index in results {
		if best_index < 0 || result.detection.confidence > best.detection.confidence {
			best = result
			best_index = index
		}
	}
	if best_index < 0 || best.detection.confidence < .Likely {
		return {}, false
	}

	for result in results {
		if result.detection.confidence == best.detection.confidence {
			comparable_count += 1
		}
	}
	if comparable_count > 1 {
		return {}, false
	}

	return best.importer, true
}

// Session_Identity is the repository information an import records.
//
// docs/05 lists what the importer records about the repository. The original
// absolute path is retained "only in redacted provenance metadata", which is
// why it passes through the sink's redaction like any other source string.
Session_Identity :: struct {
	repository_name: string,
	repository_path: string,
	version_control: model.Entity_Kind,
	start_commit:    string,
	end_commit:      string,
	branch:          string,
	case_sensitive:  bool,
	initially_dirty: bool,
}
