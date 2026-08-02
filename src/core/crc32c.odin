package core

// CRC32C (Castagnoli, polynomial 0x1EDC6F41) used for header and chunk
// integrity in the .norn container.
//
// This is a portable table-driven implementation. Apple Silicon offers a
// hardware CRC32C instruction; substituting it is a later optimization that
// must reproduce these values exactly, so the table version stays as the
// reference used by tests.

@(private)
CRC32C_POLYNOMIAL_REFLECTED :: u32(0x82F63B78)

@(private)
crc32c_table: [256]u32

@(private)
crc32c_table_ready: bool

@(private)
crc32c_build_table :: proc "contextless" () {
	for i in 0 ..< 256 {
		value := u32(i)
		for _ in 0 ..< 8 {
			if value & 1 != 0 {
				value = (value >> 1) ~ CRC32C_POLYNOMIAL_REFLECTED
			} else {
				value >>= 1
			}
		}
		crc32c_table[i] = value
	}
	crc32c_table_ready = true
}

// crc32c computes the CRC32C of `data`.
crc32c :: proc "contextless" (data: []byte) -> u32 {
	return crc32c_update(0, data)
}

// crc32c_update continues a CRC32C over a further span of bytes, allowing a
// checksum to be computed across a buffer written in pieces.
crc32c_update :: proc "contextless" (seed: u32, data: []byte) -> u32 {
	if !crc32c_table_ready {
		crc32c_build_table()
	}
	crc := ~seed
	for b in data {
		crc = (crc >> 8) ~ crc32c_table[byte(crc) ~ b]
	}
	return ~crc
}
