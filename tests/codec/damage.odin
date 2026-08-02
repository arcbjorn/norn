package test_codec

import "core:crypto/hash"

import "src:core"
import "src:trace/codec"

// Byte-level helpers for building corrupt fixtures.
//
// These deliberately reimplement the container's checksum arithmetic instead
// of calling the codec's own routines. A corruption test that repaired
// checksums by calling the code under test would pass even if that code
// computed them over the wrong bytes.

write_u16_at :: proc(image: []byte, offset: int, value: u16) {
	image[offset + 0] = u8(value)
	image[offset + 1] = u8(value >> 8)
}

write_u32_at :: proc(image: []byte, offset: int, value: u32) {
	image[offset + 0] = u8(value)
	image[offset + 1] = u8(value >> 8)
	image[offset + 2] = u8(value >> 16)
	image[offset + 3] = u8(value >> 24)
}

write_u64_at :: proc(image: []byte, offset: int, value: u64) {
	for index in 0 ..< 8 {
		image[offset + index] = u8(value >> uint(index * 8))
	}
}

read_u64_at :: proc(image: []byte, offset: int) -> u64 {
	value := u64(0)
	for index in 0 ..< 8 {
		value |= u64(image[offset + index]) << uint(index * 8)
	}
	return value
}

// crc_over computes CRC32C of a header with its checksum field zeroed, then
// writes the result back into that field.
@(private)
crc_over :: proc(image: []byte, start: int, size: int, crc_offset: int) {
	for index in 0 ..< 4 {
		image[start + crc_offset + index] = 0
	}
	checksum := core.crc32c(image[start:start + size])
	write_u32_at(image, start + crc_offset, checksum)
}

recompute_file_header_crc :: proc(image: []byte) {
	crc_over(image, 0, codec.FILE_HEADER_SIZE, codec.FILE_HEADER_CRC_OFFSET)
	// A changed header does not change the file digest, which covers only the
	// bytes after the header.
}

recompute_chunk_header_crc :: proc(image: []byte, chunk_offset: int) {
	crc_over(image, chunk_offset, codec.CHUNK_HEADER_SIZE, codec.CHUNK_HEADER_CRC_OFFSET)
	recompute_file_digest(image)
}

recompute_footer_crc :: proc(image: []byte, footer_offset: int) {
	crc_over(image, footer_offset, codec.FOOTER_SIZE, codec.FOOTER_CRC_OFFSET)
}

// recompute_chunk_payload_crc repairs a chunk's payload checksum after its
// content was altered, leaving only the whole-file digest able to notice.
recompute_chunk_payload_crc :: proc(image: []byte, chunk_offset: int, payload_size: int) {
	payload := image[chunk_offset + codec.CHUNK_HEADER_SIZE:][:payload_size]
	write_u32_at(image, chunk_offset + 56, core.crc32c(payload))
	crc_over(image, chunk_offset, codec.CHUNK_HEADER_SIZE, codec.CHUNK_HEADER_CRC_OFFSET)
}

// recompute_file_digest repairs the footer digest so that a test can target a
// specific structural check rather than tripping the digest first.
recompute_file_digest :: proc(image: []byte) {
	footer := len(image) - codec.FOOTER_SIZE
	digest: [32]u8
	hash.hash(.SHA256, image[codec.FILE_HEADER_SIZE:footer], digest[:])
	copy(image[footer + 40:][:32], digest[:])
	recompute_footer_crc(image, footer)
}

// recompute_directory repairs the directory chunk's checksums and the file
// digest after a directory entry was edited.
recompute_directory :: proc(image: []byte, directory_offset: int) {
	size := int(read_u64_at(image, directory_offset + 24))
	recompute_chunk_payload_crc(image, directory_offset, size)
	recompute_file_digest(image)
}
