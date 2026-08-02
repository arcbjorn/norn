package model

// Canonical identifiers.
//
// docs/03-trace-model.md: identifiers are stable within a trace and never
// reused. They are distinct types so that an entity identifier cannot be
// passed where an event identifier is expected; the compiler catches the
// confusion that would otherwise surface as a wrong panel selection.

// Session_Id is a 128-bit random identifier for one imported session.
Session_Id :: distinct [16]u8

// Event_Id is monotonically assigned starting at 1. Zero means absent.
Event_Id :: distinct u64

// Span_Id groups events belonging to one operation. Zero means absent.
Span_Id :: distinct u64

// Entity_Id names a stable subject such as a path, command, or actor.
// Zero means absent.
Entity_Id :: distinct u64

// String_Id indexes the interned string table. Zero is the empty string.
String_Id :: distinct u32

// Blob_Id indexes the blob table. Zero means absent.
//
// docs/03 describes a blob's stable identity as its 256-bit content digest.
// The in-file table index is what records carry, because a 4-byte index in a
// column is far cheaper than a 32-byte digest repeated per reference. The
// digest remains the content-addressed identity and is stored once per blob
// in the blob table; Blob_Digest below is that value.
Blob_Id :: distinct u32

// Blob_Digest is the SHA-256 of a blob's uncompressed content.
Blob_Digest :: distinct [32]u8

// Sequence is the total canonical order assigned during import. It is
// authoritative for replay; wall time is not.
Sequence :: distinct u64

// Sentinel values for absent optional identifiers.
NO_EVENT  :: Event_Id(0)
NO_SPAN   :: Span_Id(0)
NO_ENTITY :: Entity_Id(0)
NO_BLOB   :: Blob_Id(0)

// EMPTY_STRING is the interned identifier for the empty or absent string.
EMPTY_STRING :: String_Id(0)

// FIRST_EVENT is the identifier assigned to the first event in a trace.
FIRST_EVENT :: Event_Id(1)

// FIRST_SEQUENCE is the sequence assigned to the first event in a trace.
FIRST_SEQUENCE :: Sequence(1)
