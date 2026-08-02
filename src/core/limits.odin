package core

// Resource ceilings enforced before allocation.
//
// docs/04-trace-format.md requires readers to bound every quantity a file can
// declare. The defaults accommodate the million-event stress fixture while
// preventing a small hostile file from requesting unbounded memory. Limits are
// configurable so tests can drive the rejection paths with tiny values.

Limits :: struct {
	// Container geometry.
	max_file_size:          u64,
	max_chunk_encoded:      u64,
	max_chunk_decoded:      u64,
	max_chunk_count:        u64,
	max_compression_ratio:  u64, // decoded / encoded

	// Strings and blobs.
	max_string_length:      u64,
	max_total_string_bytes: u64,
	max_string_count:       u64,
	max_blob_size:          u64,
	max_blob_count:         u64,
	max_blob_cache_bytes:   u64,

	// Canonical record counts.
	max_event_count:        u64,
	max_entity_count:       u64,
	max_span_count:         u64,
	max_edge_count:         u64,
	max_mutation_count:     u64,

	// Structure.
	max_nesting_depth:      u32,
	max_index_fan_out:      u32,
}

// DEFAULT_LIMITS sizes for the stress fixture (1,000,000 events) with headroom.
DEFAULT_LIMITS :: Limits {
	max_file_size          = 64 << 30, // 64 GiB
	max_chunk_encoded      = 1 << 30, // 1 GiB
	max_chunk_decoded      = 4 << 30, // 4 GiB
	max_chunk_count        = 1 << 20,
	max_compression_ratio  = 1000,
	max_string_length      = 16 << 20, // 16 MiB
	max_total_string_bytes = 8 << 30,
	max_string_count       = 64 << 20,
	max_blob_size          = 2 << 30,
	max_blob_count         = 16 << 20,
	max_blob_cache_bytes   = 1 << 30,
	max_event_count        = 64 << 20,
	max_entity_count       = 16 << 20,
	max_span_count         = 16 << 20,
	max_edge_count         = 128 << 20,
	max_mutation_count     = 64 << 20,
	max_nesting_depth      = 256,
	max_index_fan_out      = 1 << 20,
}

// check_limit validates an untrusted declared count against its ceiling.
// The message identifies which ceiling was exceeded so the CLI can report a
// precise reason rather than a generic rejection.
check_limit :: proc "contextless" (value, limit: u64, message: string) -> Error {
	if value > limit {
		return Failure {
			category = .Limit_Exceeded,
			recoverability = .Fatal,
			message = message,
			subject = Subject{kind = .None, number = value},
		}
	}
	return nil
}

// check_compression_ratio rejects declared decoded sizes that imply an
// implausible expansion factor, which is how a decompression bomb announces
// itself before any bytes are decoded.
check_compression_ratio :: proc "contextless" (
	encoded, decoded: u64,
	limits: Limits,
) -> Error {
	if encoded == 0 {
		if decoded == 0 {
			return nil
		}
		return err_make(.Limit_Exceeded, "chunk declares decoded bytes for an empty payload")
	}
	bound, ok := mul_u64(encoded, limits.max_compression_ratio)
	if !ok {
		// The multiplication overflowing means the encoded size is already
		// beyond any sane bound; max_chunk_encoded rejects it separately.
		return nil
	}
	if decoded > bound {
		return err_make(.Limit_Exceeded, "chunk compression ratio exceeds limit")
	}
	return nil
}
