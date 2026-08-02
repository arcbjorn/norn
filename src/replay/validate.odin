package replay

import "src:core"
import "src:trace/codec"
import "src:trace/model"

// Replay validation.
//
// docs/04-trace-format.md defines `replay` mode as full validation plus
// reconstruction of every mutation chain. This lives in the replay package
// rather than the codec because the dependency runs this way: replay consumes
// canonical records, and the codec must not know how they are interpreted.

// Replay_Report summarizes a reconstruction pass over a whole trace.
//
// A trace with gaps is not invalid. docs/03 lists the gap statuses as
// legitimate recorded outcomes, so the report distinguishes "this file is
// malformed" from "this session recorded changes that cannot be replayed".
Replay_Report :: struct {
	mutations:  int,
	verified:   int,
	unverified: int,
	gaps:       int,
	binary:     int,
	// Gap counts by cause, so a report can say why rather than only how many.
	missing_baseline:  int,
	unsupported_patch: int,
	hash_mismatch:     int,
}

// validate_replay reconstructs every mutation chain in an opened trace.
//
// The returned error is non-nil only when the trace itself is unusable. Gaps
// are reported through the report, because failing validation for them would
// make a faithfully recorded partial session indistinguishable from a corrupt
// file.
validate_replay :: proc(
	trace: ^codec.Trace,
	allocator := context.allocator,
) -> (
	report: Replay_Report,
	err: core.Error,
) {
	source := Content_Source {
		user_data = trace,
		fetch = proc(user_data: rawptr, id: model.Blob_Id) -> ([]byte, bool) {
			trace := cast(^codec.Trace)user_data
			content, fetch_err := codec.trace_blob_content(trace, id)
			return content, core.ok(fetch_err)
		},
	}

	// The trace records no baseline manifest yet: capturing one is the
	// importer's job, and the importer does not exist. Replay therefore starts
	// from nothing, which makes every patch against an unseen file a
	// missing-baseline gap. That is the honest result for a trace that carries
	// no baseline, and it changes once the importer records one.
	baseline: Baseline
	baseline_init(&baseline, baseline_kind_from_metadata(trace.metadata.baseline_kind), allocator)
	defer baseline_destroy(&baseline)

	engine: Engine
	engine_init(&engine, source, allocator)
	defer engine_destroy(&engine)
	engine_reset(&engine, &baseline)

	for mutation in trace.mutations {
		outcome := apply_mutation(&engine, mutation)
		report.mutations += 1

		switch outcome.status {
		case .Verified:
			report.verified += 1
		case .Reconstructed_Unverified:
			report.unverified += 1
		case .Binary_Opaque:
			report.binary += 1
		case .Missing_Baseline:
			report.gaps += 1
			report.missing_baseline += 1
		case .Unsupported_Patch:
			report.gaps += 1
			report.unsupported_patch += 1
		case .Hash_Mismatch:
			report.gaps += 1
			report.hash_mismatch += 1
		}
	}

	return report, nil
}

// baseline_kind_from_metadata converts the recorded baseline strength into the
// replay engine's own enumeration.
@(private)
baseline_kind_from_metadata :: proc "contextless" (kind: codec.Baseline_Kind) -> Baseline_Kind {
	switch kind {
	case .None:                       return .None
	case .Commit_Verified:            return .Commit_Verified
	case .Working_Tree_Observational: return .Working_Tree_Observational
	}
	return .None
}
