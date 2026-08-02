package test_core

import "core:testing"
import "src:core"

@(test)
crc32c_matches_known_vectors :: proc(t: ^testing.T) {
	// Published CRC32C (Castagnoli) check values. These pin the polynomial and
	// bit reflection so a future hardware-accelerated implementation can be
	// verified against the portable one.
	Case :: struct {
		input:    string,
		expected: u32,
	}
	cases := []Case {
		{"", 0x00000000},
		{"a", 0xC1D04330},
		{"123456789", 0xE3069283},
		{"The quick brown fox jumps over the lazy dog", 0x22620404},
	}

	for c in cases {
		actual := core.crc32c(transmute([]byte)c.input)
		testing.expectf(
			t,
			actual == c.expected,
			"crc32c(%q) = 0x%08X, expected 0x%08X",
			c.input,
			actual,
			c.expected,
		)
	}
}

@(test)
crc32c_update_is_incremental :: proc(t: ^testing.T) {
	// A checksum computed over a buffer written in pieces must equal the
	// checksum of the whole, because the writer emits chunk payloads
	// incrementally.
	whole := "The quick brown fox jumps over the lazy dog"
	full := core.crc32c(transmute([]byte)whole)

	partial := core.crc32c_update(0, transmute([]byte)whole[:10])
	partial = core.crc32c_update(partial, transmute([]byte)whole[10:25])
	partial = core.crc32c_update(partial, transmute([]byte)whole[25:])

	testing.expectf(t, partial == full, "incremental 0x%08X != whole 0x%08X", partial, full)
}

@(test)
crc32c_detects_single_bit_flips :: proc(t: ^testing.T) {
	original := []byte{0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04}
	baseline := core.crc32c(original)

	mutated := make([]byte, len(original))
	defer delete(mutated)

	for index in 0 ..< len(original) {
		for bit in 0 ..< 8 {
			copy(mutated, original)
			mutated[index] ~= byte(1 << uint(bit))
			testing.expectf(
				t,
				core.crc32c(mutated) != baseline,
				"flipping byte %d bit %d did not change the checksum",
				index,
				bit,
			)
		}
	}
}
