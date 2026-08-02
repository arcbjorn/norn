package replay

import "src:core"
import "src:trace/model"

// The virtual repository.
//
// docs/00-product.md: the repository is never the replay surface. Replay
// occurs in an in-memory virtual repository, and opening a trace must never
// checkout a commit, overwrite a file, invoke a hook, or run a command. There
// is no filesystem call anywhere in this package.
//
// docs/06 requires path identity and content identity to be modeled
// separately, because a rename moves content between paths and the same
// content can exist at several paths at once.

// Verification records how much confidence a path's content carries.
//
// This mirrors the mutation's Replay_Status but describes the resulting state
// rather than the operation. The distinction matters after a gap: the mutation
// that failed is permanently Unsupported_Patch, while the path it damaged can
// later return to Verified when a full-content event re-establishes it.
Verification :: enum u8 {
	// No content is known for this path at this point.
	Unknown = 0,
	// Content was reconstructed and a recorded hash confirmed it.
	Verified = 1,
	// Content was reconstructed but nothing confirmed it.
	Unverified = 2,
	// Content is unknown because an earlier mutation could not be applied.
	// The event that introduced the gap is recorded alongside.
	Gap = 3,
	// The path holds binary or unsupported content; metadata only.
	Binary = 4,
	// Baseline content was observed rather than read from a commit.
	Observational = 5,
}

verification_name :: proc "contextless" (value: Verification) -> string {
	switch value {
	case .Unknown:       return "unknown"
	case .Verified:      return "verified"
	case .Unverified:    return "unverified"
	case .Gap:           return "gap"
	case .Binary:        return "binary"
	case .Observational: return "observational"
	}
	return "unknown"
}

// Path_State is one path's state at a point in the session, per docs/06.
// Content_Ref names content in one of two disjoint spaces.
//
// Recorded blobs are numbered by the trace; reconstructed blobs are numbered
// by the replay store. Both start at 1, so an identifier alone is ambiguous —
// and resolving one against the wrong table silently yields another file's
// bytes. The origin travels with the identifier so that cannot happen.
Content_Origin :: enum u8 {
	None = 0,
	// A blob recorded in the trace.
	Recorded = 1,
	// Content reconstructed during replay and interned in the store.
	Reconstructed = 2,
}

Content_Ref :: struct {
	origin: Content_Origin,
	id:     model.Blob_Id,
}

NO_CONTENT :: Content_Ref{}

recorded_content :: proc "contextless" (id: model.Blob_Id) -> Content_Ref {
	if id == model.NO_BLOB {
		return NO_CONTENT
	}
	return Content_Ref{origin = .Recorded, id = id}
}

reconstructed_content :: proc "contextless" (id: model.Blob_Id) -> Content_Ref {
	if id == model.NO_BLOB {
		return NO_CONTENT
	}
	return Content_Ref{origin = .Reconstructed, id = id}
}

has_ref :: proc "contextless" (ref: Content_Ref) -> bool {
	return ref.origin != .None && ref.id != model.NO_BLOB
}

Path_State :: struct {
	path:         model.Entity_Id,
	content:      Content_Ref, // NO_CONTENT when absent or unknown.
	exists:       bool,
	encoding:     model.Text_Encoding,
	verification: Verification,
	last_mutation: model.Event_Id,
	// The event that introduced a gap, when verification is Gap. docs/06
	// requires a gap to name the event that caused it.
	gap_event: model.Event_Id,
}

// Repository_State maps path entities to their state.
//
// docs/06 calls for a persistent map sharing unchanged substructure. Version
// one uses a plain map copied at snapshot points: the fixture and reference
// workloads touch a few thousand paths, where copying is measured in
// microseconds, and a persistent tree would add structure whose cost is not
// yet justified by measurement. The interface below hides the choice so the
// representation can change without touching callers.
Repository_State :: struct {
	paths: map[model.Entity_Id]Path_State,
}

state_init :: proc(state: ^Repository_State, allocator := context.allocator) {
	state.paths = make(map[model.Entity_Id]Path_State, 64, allocator)
}

state_destroy :: proc(state: ^Repository_State) {
	delete(state.paths)
	state^ = {}
}

// state_clone copies a state, which is how snapshots are taken.
state_clone :: proc(
	source: ^Repository_State,
	allocator := context.allocator,
) -> Repository_State {
	result: Repository_State
	result.paths = make(map[model.Entity_Id]Path_State, len(source.paths), allocator)
	for key, value in source.paths {
		result.paths[key] = value
	}
	return result
}

// state_get returns a path's state. A path never mentioned by the baseline or
// any mutation is absent rather than empty: docs/06 forbids implying that
// unobserved paths did not exist.
state_get :: proc(
	state: ^Repository_State,
	path: model.Entity_Id,
) -> (
	result: Path_State,
	known: bool,
) {
	result, known = state.paths[path]
	return
}

state_put :: proc(state: ^Repository_State, value: Path_State) {
	state.paths[value.path] = value
}

// Baseline_Entry is one path whose content or absence was actually verified at
// session start.
//
// An alias rather than a second definition: the codec reads these off disk and
// the engine consumes them, so two structs that had to agree field for field
// would eventually not.
Baseline_Entry :: model.Baseline_Entry

// Baseline is the manifest of what was observed before the session began.
//
// docs/06: the manifest records every path whose absence or content was
// actually verified, and must not imply that unobserved paths were absent.
// That is why absence is an explicit entry rather than the default.
Baseline :: struct {
	kind:    Baseline_Kind,
	entries: [dynamic]Baseline_Entry,
}

// Baseline_Kind mirrors the metadata's recorded baseline strength.
Baseline_Kind :: enum u8 {
	None = 0,
	Commit_Verified = 1,
	Working_Tree_Observational = 2,
}

baseline_init :: proc(
	baseline: ^Baseline,
	kind: Baseline_Kind,
	allocator := context.allocator,
) {
	baseline.kind = kind
	baseline.entries = make([dynamic]Baseline_Entry, 0, 16, allocator)
}

baseline_destroy :: proc(baseline: ^Baseline) {
	delete(baseline.entries)
	baseline^ = {}
}

// baseline_apply seeds a repository state from the manifest.
//
// A commit-verified baseline yields Verified content; a working-tree baseline
// yields Observational. The difference survives into every later state, so the
// viewer can say which files rest on a snapshot that may already have drifted.
//
// docs/06 reserves the strongest label for content "verified against recorded
// hashes", so `resolve` is required to make that claim: an entry whose digest
// disagrees with the blob it names is a gap, not verified content. Passing a
// nil resolver downgrades every entry to Unverified rather than trusting the
// manifest — a caller that cannot check has not checked.
baseline_apply :: proc(
	baseline: ^Baseline,
	state: ^Repository_State,
	resolve: Content_Resolver = {},
) {
	claimed := Verification.Unknown
	switch baseline.kind {
	case .None:                       claimed = .Unknown
	case .Commit_Verified:            claimed = .Verified
	case .Working_Tree_Observational: claimed = .Observational
	}

	for entry in baseline.entries {
		verification := claimed
		if entry.exists {
			verification = verify_baseline_entry(entry, claimed, resolve)
		} else {
			// An entry recording absence carries no content to verify.
			verification = .Unknown
		}

		state_put(
			state,
			Path_State {
				path = entry.path,
				// Baseline content comes from the trace, not from replay.
				content = recorded_content(entry.content),
				exists = entry.exists,
				encoding = entry.encoding,
				verification = verification,
			},
		)
	}
}

// Content_Resolver fetches a recorded blob so the baseline can be checked.
//
// A callback rather than the engine itself, because the manifest is applied
// before the engine has any reconstruction of its own and must not be able to
// resolve one by accident.
Content_Resolver :: struct {
	user_data: rawptr,
	fetch:     proc(user_data: rawptr, id: model.Blob_Id) -> ([]byte, bool),
}

// verify_baseline_entry checks one entry's content against its recorded digest.
//
// A mismatch is a gap rather than a downgrade. The manifest and the blob table
// disagreeing means one of them is wrong, and Norn cannot tell which — showing
// the bytes under a weaker label would present content that may belong to a
// different file entirely.
@(private)
verify_baseline_entry :: proc(
	entry: Baseline_Entry,
	claimed: Verification,
	resolve: Content_Resolver,
) -> Verification {
	if entry.encoding == .Binary {
		return .Binary
	}
	if model.digest_is_zero(entry.digest) {
		// Nothing recorded to check against. Older traces predate the digest,
		// and a manifest without one cannot support a verified claim.
		return .Unverified if claimed == .Verified else claimed
	}
	if resolve.fetch == nil {
		return .Unverified
	}

	content, got := resolve.fetch(resolve.user_data, entry.content)
	if !got {
		// The manifest names content the trace cannot produce.
		return .Gap
	}
	if !model.digest_equal(model.digest_content(content), entry.digest) {
		return .Gap
	}
	return claimed
}

// Content_Source resolves blob identifiers to bytes.
//
// Replay takes this as an interface so it can run against an in-memory table
// during import and against a mapped trace when viewing, without either path
// knowing about the other.
Content_Source :: struct {
	user_data: rawptr,
	fetch:     proc(user_data: rawptr, id: model.Blob_Id) -> (content: []byte, ok: bool),
}

content_fetch :: proc(source: Content_Source, id: model.Blob_Id) -> (content: []byte, ok: bool) {
	if id == model.NO_BLOB || source.fetch == nil {
		return nil, false
	}
	return source.fetch(source.user_data, id)
}

// Content_Store accumulates content produced during replay.
//
// Reconstructed content is not in the trace: applying a patch yields bytes
// nobody stored. Those bytes are interned here so that a Path_State can name
// them by identifier like any other content, keeping one representation for
// recorded and reconstructed content alike.
Content_Store :: struct {
	table: model.Blob_Table,
}

store_init :: proc(store: ^Content_Store, allocator := context.allocator) {
	model.blob_table_init(&store.table, allocator)
}

store_destroy :: proc(store: ^Content_Store) {
	model.blob_table_destroy(&store.table)
}

// store_add interns reconstructed content and returns its identifier.
store_add :: proc(
	store: ^Content_Store,
	content: []byte,
	encoding: model.Text_Encoding,
) -> (
	id: model.Blob_Id,
	ok: bool,
) {
	return model.blob_add(
		&store.table,
		content,
		model.EMPTY_STRING,
		encoding,
		{.Derived},
	)
}

store_get :: proc(store: ^Content_Store, id: model.Blob_Id) -> (content: []byte, ok: bool) {
	return model.blob_content(&store.table, id)
}

// store_source exposes the store as a Content_Source.
store_source :: proc(store: ^Content_Store) -> Content_Source {
	return Content_Source {
		user_data = store,
		fetch = proc(user_data: rawptr, id: model.Blob_Id) -> ([]byte, bool) {
			store := cast(^Content_Store)user_data
			return model.blob_content(&store.table, id)
		},
	}
}

// Resolved_Content is what replay returns for a path at a point in time.
//
// docs/06's replay contract lists six possible answers, and every one of them
// is representable here. `Status` is the discriminant; the other fields are
// meaningful according to it. There is deliberately no way to return content
// without also returning how much it can be trusted.
Resolved_Status :: enum u8 {
	// The path did not exist at this point.
	Absent = 0,
	// Content is known and confirmed by a recorded hash.
	Verified = 1,
	// Content is known but nothing confirmed it.
	Unverified = 2,
	// Content was observed from the working tree rather than a commit.
	Observational = 3,
	// The path was deleted at or before this point.
	Deleted = 4,
	// Content is unknown because of an earlier unreplayable mutation.
	Gap = 5,
	// Binary or unsupported content; metadata only.
	Binary = 6,
	// The path is not mentioned anywhere in the trace, so nothing is known
	// about it. This is distinct from Absent, which is a positive claim.
	Unknown_Path = 7,
}

resolved_status_name :: proc "contextless" (status: Resolved_Status) -> string {
	switch status {
	case .Absent:        return "absent"
	case .Verified:      return "verified"
	case .Unverified:    return "unverified"
	case .Observational: return "observational"
	case .Deleted:       return "deleted"
	case .Gap:           return "gap"
	case .Binary:        return "binary"
	case .Unknown_Path:  return "unknown_path"
	}
	return "unknown"
}

Resolved_Content :: struct {
	status:  Resolved_Status,
	content: []byte, // Borrowed; empty unless the status carries content.
	digest:  model.Blob_Digest,
	encoding: model.Text_Encoding,
	// The mutation that last changed this path, for navigation.
	last_mutation: model.Event_Id,
	// The event that introduced a gap, when status is Gap.
	gap_event: model.Event_Id,
}

// has_content reports whether the caller may display bytes for this result.
has_content :: proc "contextless" (resolved: Resolved_Content) -> bool {
	#partial switch resolved.status {
	case .Verified, .Unverified, .Observational:
		return true
	}
	return false
}
