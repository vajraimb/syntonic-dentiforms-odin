//------------------------------------------------------------------------------
//  reader -- a cursor over the bytes of a file, for the little-endian binary
//  formats of the meshes and the animations.
//------------------------------------------------------------------------------
package main

import "core:os"
import "core:strings"

Reader :: struct {
	data: []u8,
	pos:  int,
	ok:   bool, // false once a read went past the end of the file
}

read_open :: proc(path: string) -> (Reader, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		return {}, false
	}
	return { data = data, ok = true }, true
}

read_close :: proc(r: ^Reader) {
	delete(r.data)
	r^ = {}
}

// A view into the file; it stays valid until read_close.
read_bytes :: proc(r: ^Reader, size: int) -> []u8 {
	if size < 0 || r.pos + size > len(r.data) {
		r.ok = false
		return nil
	}
	out := r.data[r.pos: r.pos + size]
	r.pos += size
	return out
}

read_u32 :: proc(r: ^Reader) -> u32 {
	b := read_bytes(r, 4)
	if !r.ok {
		return 0
	}
	return u32(b[0]) | u32(b[1]) << 8 | u32(b[2]) << 16 | u32(b[3]) << 24
}

read_i32 :: proc(r: ^Reader) -> i32 {
	return i32(read_u32(r))
}

// Reads bytes up to the next zero byte, which is consumed too. The string is a copy
// that stays valid after read_close.
read_zero_string :: proc(r: ^Reader) -> string {
	start := r.pos
	for r.pos < len(r.data) && r.data[r.pos] != 0 {
		r.pos += 1
	}
	if r.pos >= len(r.data) {
		r.ok = false
		return ""
	}
	s := strings.clone(string(r.data[start:r.pos]))
	r.pos += 1 // the zero byte
	return s
}
