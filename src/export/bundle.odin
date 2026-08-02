package export

import "src:analysis"
import "src:trace/codec"
import "src:trace/model"

// Export bundle assembly.
//
// docs/01-user-experience.md: an export is a new artifact, not a screenshot.
// It contains session and importer metadata, the selected time range, selected
// events and evidence edges, relevant diffs and outcomes, import warnings, a
// redaction manifest, and both an HTML report and canonical JSON.
//
// docs/08 adds the rule that shapes the defaults: exports exclude raw source
// records and unrelated prompt content by default. The bundle therefore starts
// from what the range needs and adds nothing beyond it.

// Options controls what an export includes.
//
// Every field defaults to the safer choice. A user who wants prompt text in a
// report they are about to share must ask for it, because the cost of
// including it accidentally is disclosing a private conversation.
Options :: struct {
	// Include visible conversation text for messages in the range.
	include_messages: bool,
	// Include command output and diagnostic text.
	include_output: bool,
	// Include retained raw provider records. docs/10 keeps these opt-in at
	// import; this keeps them opt-in again at export.
	include_raw_records: bool,
}

// DEFAULT_OPTIONS excludes everything that is not needed to explain an outcome.
DEFAULT_OPTIONS :: Options{}

// Included_Event is one event carried in the export.
Included_Event :: struct {
	id:       model.Event_Id,
	sequence: model.Sequence,
	kind:     model.Event_Kind,
	wall_time_ns: i64,
	has_wall_time: bool,
	duration_ns:   i64,
	has_duration:  bool,
	summary:  string, // Already sanitized; empty when excluded by options.
	path:     string,
	span:     model.Span_Id,
}

// Included_Outcome is a result within the range.
Included_Outcome :: struct {
	event:   model.Event_Id,
	kind:    string,
	status:  string,
	subject: string,
}

// Included_Change is one path's difference across the range.
Included_Change :: struct {
	path:   string,
	kind:   string,
	// Set when a replay gap affects this path, so a diff is never presented as
	// complete when it rests on content replay could not reconstruct.
	affected_by_gap: bool,
}

// Included_Candidate is one ranked contributor with its rules.
Included_Candidate :: struct {
	mutation_event: model.Event_Id,
	path:           string,
	score:          f32,
	gap_capped:     bool,
	rules:          [dynamic]Rule_Detail,
}

Rule_Detail :: struct {
	id:     string,
	reason: string,
}

// Included_Edge is an evidence relationship with its origin.
//
// The origin travels with every edge because docs/06 requires the reader to be
// able to tell a recorded fact from a derived guess, and a report that dropped
// it would be less trustworthy than the transcript it replaces.
Included_Edge :: struct {
	kind:       string,
	origin:     string,
	from_event: model.Event_Id,
	to_event:   model.Event_Id,
	confidence: f32,
	rule:       string,
	reason:     string,
}

// Manifest states what the export contains.
//
// docs/08 requires this to be shown before writing. It is also embedded in the
// artifact so a recipient can see what categories were included without
// reading every record.
Manifest :: struct {
	has_prompt_text:      bool,
	has_file_paths:       bool,
	has_diffs:            bool,
	has_command_lines:    bool,
	has_command_output:   bool,
	has_repository_metadata: bool,
	has_raw_records:      bool,
	has_annotations:      bool,

	event_count:     int,
	outcome_count:   int,
	change_count:    int,
	candidate_count: int,
	edge_count:      int,

	// Counts carried through from the import report, so a reader knows the
	// source was redacted and by which rule classes.
	redactions_by_category: [codec.REDACTION_CATEGORY_COUNT]u32,
	warnings_by_category:   [codec.WARNING_CATEGORY_COUNT]u32,

	// Number of values shortened by the export's own size limit.
	truncated_values: int,
}

// Bundle is the assembled export, ready to render in either format.
Bundle :: struct {
	// Session and importer identity.
	importer_id:      string,
	importer_version: string,
	repository_name:  string,
	baseline_kind:    string,
	format_major:     u16,
	format_minor:     u16,

	// The selected range.
	range_from: model.Sequence,
	range_to:   model.Sequence,

	// The outcome this export explains, when it was built around one.
	focus_outcome:     model.Event_Id,
	has_focus_outcome: bool,
	window_anchor:     model.Event_Id,
	has_window_anchor: bool,

	events:     [dynamic]Included_Event,
	outcomes:   [dynamic]Included_Outcome,
	changes:    [dynamic]Included_Change,
	candidates: [dynamic]Included_Candidate,
	edges:      [dynamic]Included_Edge,
	uncertainties: [dynamic]string,

	manifest: Manifest,
	options:  Options,

	// Owns every string the bundle references, so rendering never reaches back
	// into the trace and the bundle can outlive it.
	arena: [dynamic]string,
}

bundle_destroy :: proc(bundle: ^Bundle) {
	for candidate in bundle.candidates {
		delete(candidate.rules)
	}
	for text in bundle.arena {
		delete(text)
	}
	delete(bundle.arena)
	delete(bundle.events)
	delete(bundle.outcomes)
	delete(bundle.changes)
	delete(bundle.candidates)
	delete(bundle.edges)
	delete(bundle.uncertainties)
	bundle^ = {}
}

// own copies a string into the bundle's storage and records the truncation.
@(private)
own :: proc(bundle: ^Bundle, value: string) -> string {
	trimmed, truncated := truncate_text(value)
	if truncated {
		bundle.manifest.truncated_values += 1
	}
	copied := sanitize_text(trimmed)
	append(&bundle.arena, copied)
	return copied
}

@(private)
lookup_string :: proc(trace: ^codec.Trace, id: model.String_Id) -> string {
	value, ok := model.string_get(&trace.strings, id)
	if !ok {
		return ""
	}
	return value
}

@(private)
entity_name :: proc(trace: ^codec.Trace, id: model.Entity_Id) -> string {
	if id == model.NO_ENTITY {
		return ""
	}
	index := int(id) - 1
	if index < 0 || index >= len(trace.entities) {
		return ""
	}
	return lookup_string(trace, trace.entities[index].name)
}

// build_bundle assembles an export for a sequence range.
//
// `focus` names the outcome the export explains; passing NO_EVENT produces a
// range export with no candidate ranking. The range is inclusive of both ends.
build_bundle :: proc(
	trace: ^codec.Trace,
	outcomes: ^analysis.Outcome_Index,
	from: model.Sequence,
	to: model.Sequence,
	focus: model.Event_Id = model.NO_EVENT,
	options := DEFAULT_OPTIONS,
    allocator := context.allocator,
) -> Bundle {
	low := from
	high := to
	if low > high {
		low, high = high, low
	}

	bundle := Bundle {
		range_from = low,
		range_to   = high,
		options    = options,
		events     = make([dynamic]Included_Event, 0, 32, allocator),
		outcomes   = make([dynamic]Included_Outcome, 0, 8, allocator),
		changes    = make([dynamic]Included_Change, 0, 8, allocator),
		candidates = make([dynamic]Included_Candidate, 0, 8, allocator),
		edges      = make([dynamic]Included_Edge, 0, 16, allocator),
		uncertainties = make([dynamic]string, 0, 4, allocator),
		arena      = make([dynamic]string, 0, 64, allocator),
	}

	bundle.format_major = trace.header.major
	bundle.format_minor = trace.header.minor
	bundle.importer_id = own(&bundle, lookup_string(trace, trace.metadata.importer_id))
	bundle.importer_version = own(&bundle, lookup_string(trace, trace.metadata.importer_version))
	bundle.repository_name = own(&bundle, lookup_string(trace, trace.metadata.repository_name))
	bundle.baseline_kind = own(&bundle, baseline_name(trace.metadata.baseline_kind))

	// docs/01 requires import warnings and a redaction manifest in the export.
	bundle.manifest.warnings_by_category = trace.metadata.warnings
	bundle.manifest.redactions_by_category = trace.metadata.redactions
	bundle.manifest.has_repository_metadata = true

	collect_events(&bundle, trace, low, high)
	collect_outcomes(&bundle, trace, outcomes, low, high)
	collect_changes(&bundle, trace, low, high)

	if focus != model.NO_EVENT {
		collect_focus(&bundle, trace, outcomes, focus)
	}

	collect_edges(&bundle, trace, low, high)

	bundle.manifest.event_count = len(bundle.events)
	bundle.manifest.outcome_count = len(bundle.outcomes)
	bundle.manifest.change_count = len(bundle.changes)
	bundle.manifest.candidate_count = len(bundle.candidates)
	bundle.manifest.edge_count = len(bundle.edges)

	// Raw records are never included in this build. docs/10 makes retention
	// opt-in at import and docs/08 excludes them from exports by default;
	// honoring the option would require reading blobs the exporter
	// deliberately does not touch.
	bundle.manifest.has_raw_records = false

	return bundle
}

@(private)
baseline_name :: proc(kind: codec.Baseline_Kind) -> string {
	switch kind {
	case .None:                       return "none"
	case .Commit_Verified:            return "commit_verified"
	case .Working_Tree_Observational: return "working_tree_observational"
	}
	return "unknown"
}

@(private)
collect_events :: proc(
	bundle: ^Bundle,
	trace: ^codec.Trace,
	from: model.Sequence,
	to: model.Sequence,
) {
	for event in trace.events {
		if event.sequence < from || event.sequence > to {
			continue
		}

		included := Included_Event {
			id            = event.id,
			sequence      = event.sequence,
			kind          = event.kind,
			wall_time_ns  = event.wall_time_ns,
			has_wall_time = model.has_wall_time(event),
			duration_ns   = event.duration_ns,
			has_duration  = model.has_duration(event),
			span          = event.parent_span_id,
		}

		// Conversation text is unrelated prompt content unless the user opted
		// in, so the summary is withheld for message events by default.
		summary := lookup_string(trace, event.summary_string_id)
		if model.is_conversation(event.kind) {
			if bundle.options.include_messages && summary != "" {
				included.summary = own(bundle, summary)
				bundle.manifest.has_prompt_text = true
			}
		} else if summary != "" {
			withhold := !bundle.options.include_output &&
				(event.kind == .Command_Output || event.kind == .Diagnostic)
			if !withhold {
				included.summary = own(bundle, summary)
				if event.kind == .Command_Start || event.kind == .Command_End {
					bundle.manifest.has_command_lines = true
				}
				if event.kind == .Command_Output {
					bundle.manifest.has_command_output = true
				}
			}
		}

		path := entity_name(trace, event.primary_entity_id)
		if path != "" {
			included.path = own(bundle, path)
			bundle.manifest.has_file_paths = true
		}

		append(&bundle.events, included)
	}
}

@(private)
collect_outcomes :: proc(
	bundle: ^Bundle,
	trace: ^codec.Trace,
	outcomes: ^analysis.Outcome_Index,
	from: model.Sequence,
	to: model.Sequence,
) {
	for outcome in outcomes.outcomes {
		if outcome.sequence < from || outcome.sequence > to {
			continue
		}
		subject := entity_name(trace, outcome.test_case)
		if subject == "" {
			subject = entity_name(trace, outcome.command)
		}
		append(
			&bundle.outcomes,
			Included_Outcome {
				event   = outcome.event,
				kind    = own(bundle, analysis.outcome_kind_name(outcome.kind)),
				status  = own(bundle, model.outcome_status_name(outcome.status)),
				subject = own(bundle, subject),
			},
		)
	}
}

@(private)
collect_changes :: proc(
	bundle: ^Bundle,
	trace: ^codec.Trace,
	from: model.Sequence,
	to: model.Sequence,
) {
	// One entry per path, describing the net effect across the range rather
	// than every intermediate edit, which the event list already carries.
	seen := make(map[model.Entity_Id]bool, 16, context.temp_allocator)
	defer delete(seen)

	for mutation in trace.mutations {
		index := int(mutation.event_id) - 1
		if index < 0 || index >= len(trace.events) {
			continue
		}
		sequence := trace.events[index].sequence
		if sequence < from || sequence > to {
			continue
		}
		if seen[mutation.path] {
			continue
		}
		seen[mutation.path] = true

		append(
			&bundle.changes,
			Included_Change {
				path = own(bundle, entity_name(trace, mutation.path)),
				kind = own(bundle, mutation_op_name(mutation.op)),
				affected_by_gap = model.is_replay_gap(mutation.status),
			},
		)
		bundle.manifest.has_diffs = true
		bundle.manifest.has_file_paths = true
	}
}

@(private)
mutation_op_name :: proc(op: model.Mutation_Op) -> string {
	switch op {
	case .Unknown: return "unknown"
	case .Create:  return "created"
	case .Modify:  return "modified"
	case .Delete:  return "deleted"
	case .Rename:  return "renamed"
	}
	return "unknown"
}

@(private)
collect_focus :: proc(
	bundle: ^Bundle,
	trace: ^codec.Trace,
	outcomes: ^analysis.Outcome_Index,
	focus: model.Event_Id,
) {
	target, found := analysis.find_outcome(outcomes, focus)
	if !found {
		return
	}
	bundle.focus_outcome = focus
	bundle.has_focus_outcome = true

	input := analysis.Scoring_Input{trace = trace, outcomes = outcomes}
	ranking := analysis.score_outcome(input, target, context.temp_allocator)
	defer analysis.ranking_destroy(&ranking)

	if ranking.window.has_anchor {
		bundle.window_anchor = ranking.window.anchor
		bundle.has_window_anchor = true
	}

	for candidate in ranking.candidates {
		included := Included_Candidate {
			mutation_event = candidate.mutation_event,
			path           = own(bundle, entity_name(trace, candidate.path)),
			score          = model.confidence_to_f32(candidate.score),
			gap_capped     = candidate.gap_capped,
			rules          = make([dynamic]Rule_Detail, 0, 4),
		}
		for rule in analysis.Rule {
			if rule not_in candidate.rules {
				continue
			}
			append(
				&included.rules,
				Rule_Detail {
					id     = own(bundle, analysis.rule_id(rule)),
					reason = own(bundle, analysis.rule_reason(rule)),
				},
			)
		}
		append(&bundle.candidates, included)
	}

	stack := analysis.build_evidence_stack(input, target, &ranking, context.temp_allocator)
	defer analysis.evidence_stack_destroy(&stack)
	for note in stack.uncertainties {
		append(&bundle.uncertainties, own(bundle, note))
	}
}

@(private)
collect_edges :: proc(
	bundle: ^Bundle,
	trace: ^codec.Trace,
	from: model.Sequence,
	to: model.Sequence,
) {
	for edge in trace.edges {
		if edge.from.kind != .Event {
			continue
		}
		if !event_in_range(trace, model.Event_Id(edge.from.id), from, to) {
			continue
		}

		append(
			&bundle.edges,
			Included_Edge {
				kind       = own(bundle, edge_kind_name(edge.kind)),
				origin     = own(bundle, model.origin_name(edge.origin)),
				from_event = model.Event_Id(edge.from.id),
				to_event   = model.Event_Id(edge.to.id) if edge.to.kind == .Event else model.NO_EVENT,
				confidence = model.confidence_to_f32(edge.confidence),
				rule       = own(bundle, lookup_string(trace, edge.rule)),
				reason     = own(bundle, lookup_string(trace, edge.reason)),
			},
		)
	}
}

@(private)
event_in_range :: proc(
	trace: ^codec.Trace,
	id: model.Event_Id,
	from: model.Sequence,
	to: model.Sequence,
) -> bool {
	index := int(id) - 1
	if index < 0 || index >= len(trace.events) {
		return false
	}
	sequence := trace.events[index].sequence
	return sequence >= from && sequence <= to
}

@(private)
edge_kind_name :: proc(kind: model.Edge_Kind) -> string {
	switch kind {
	case .Unknown:               return "unknown"
	case .Parent:                return "parent"
	case .Result_Of:             return "result_of"
	case .Reads:                 return "reads"
	case .Writes:                return "writes"
	case .Renames:               return "renames"
	case .Diagnoses:             return "diagnoses"
	case .Tests:                 return "tests"
	case .Precedes:              return "precedes"
	case .Candidate_Contributor: return "candidate_contributor"
	case .Supersedes:            return "supersedes"
	}
	return "unknown"
}
