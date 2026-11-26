//------------------------------------------------------------------------------
//  screenshot -- saving the final image of a frame into a .tga file.
//
//  The original reads the image back through sokol_gfx (sg_readback_*); that
//  API is not in the sokol version these bindings are for. Instead, once the
//  frame is on the GPU, a Metal blit command copies the image into memory the
//  CPU can read, and the file is written as soon as that copy is done.
//
//  This goes through the Objective-C runtime to talk to Metal directly. It is
//  written for macOS on Apple Silicon: the two small structs of the copy
//  command are passed the way that platform has it, each as a pointer to a
//  copy.
//------------------------------------------------------------------------------
package main

import "core:fmt"
import "core:os"
import "core:strings"
import posix "core:sys/posix"
import sg "sokol/gfx"

SCREENSHOTS :: ODIN_OS == .Darwin && ODIN_ARCH == .arm64

Screenshot :: struct {
	enabled: bool, // screenshots are possible and wanted
	pending: bool, // a frame was rendered that is still to be saved
	file:    string,

	command_buffer: rawptr, // the Metal command buffer that copies the image; nil if none
	pixels:         rawptr, // CPU readable memory: height rows of bytes_per_row bytes
	width:          int,
	height:         int,
	bytes_per_row:  int,
}

g_screenshot: Screenshot

screenshot_request :: proc(file: string) {
	g_screenshot.pending = true
	g_screenshot.file = strings.clone(file)
}

screenshot_busy :: proc() -> bool {
	return g_screenshot.pending
}

// What ends up on the window: in the offscreen mode the image that stands in
// for it, otherwise the image the window is blitted from.
screenshot_image :: proc() -> sg.Image {
	return g_offscreen ? rt_screen.image : rt_main_resolved.image
}

// Called at the start of every frame: sees to it that the frame that was asked
// for gets saved.
screenshot_poll :: proc() {
	when SCREENSHOTS {
		s := &g_screenshot
		if s.pending {
			// The frame to save is over by now, and whatever this process put on
			// the GPU queue before this moment comes before what is queued now.
			// So the copy sees the finished frame.
			s.pending = false
			screenshot_copy_image(s)
			// Waiting costs less than a millisecond: only the finished frame and
			// the copy are ahead of it in the queue. It also keeps the command
			// buffer alive: in a window, everything created in a frame is
			// released when the frame is over.
			_ = msg_p(s.command_buffer, objc_sel("waitUntilCompleted"))
			if msg_u(s.command_buffer, objc_sel("status")) == MTL_COMMAND_BUFFER_STATUS_COMPLETED {
				screenshot_save(s)
			} else {
				fmt.println("Could not read the frame back from the GPU; not saved:", s.file)
			}
			s.command_buffer = nil
		}
	}
}

// Queues the copy of the final image into CPU readable memory.
screenshot_copy_image :: proc(s: ^Screenshot) {
	objc_setup()
	width := int(sg.query_image_width(screenshot_image()))
	height := int(sg.query_image_height(screenshot_image()))
	bytes_per_row := (width * 4 + 255) & ~int(255) // Metal likes the rows of such buffers to be 256 byte aligned

	if s.pixels == nil || s.width != width || s.height != height {
		s.pixels = msg_p_uu(
			sg.mtl_device(), objc_sel("newBufferWithLength:options:"),
			u64(bytes_per_row * height), u64(MTL_STORAGE_MODE_SHARED),
		)
		s.width = width
		s.height = height
		s.bytes_per_row = bytes_per_row
	}

	info := sg.mtl_query_image_info(screenshot_image())
	origin := MTL_Origin { 0, 0, 0 }
	size := MTL_Size { i64(width), i64(height), 1 }
	s.command_buffer = msg_p(sg.mtl_command_queue(), objc_sel("commandBuffer"))
	encoder := msg_p(s.command_buffer, objc_sel("blitCommandEncoder"))
	msg_blit(
		encoder,
		objc_sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:"),
		info.tex[info.active_slot], u64(0), u64(0), &origin, &size,
		s.pixels, u64(0), u64(bytes_per_row), u64(bytes_per_row * height),
	)
	_ = msg_p(encoder, objc_sel("endEncoding"))
	_ = msg_p(s.command_buffer, objc_sel("commit"))
}

screenshot_save :: proc(s: ^Screenshot) {
	pixels := ([^]u8)(msg_p(s.pixels, objc_sel("contents")))
	if !write_tga(s.file, pixels[: s.bytes_per_row * s.height], s.bytes_per_row, s.width, s.height) {
		fmt.println("Could not write", s.file)
	}
}

// --------------------------------------------------------
// the file

// 24 bit uncompressed TGA, the same files the original writes.
// The pixels are BGRA rows of bytes_per_row bytes, the first row being the top of the image.
write_tga :: proc(filename: string, pixels: []u8, bytes_per_row, width, height: int) -> bool {
	header := [18]u8{}
	header[2] = 2 // uncompressed, true color
	header[12] = u8(width & 0xFF)
	header[13] = u8((width >> 8) & 0xFF)
	header[14] = u8(height & 0xFF)
	header[15] = u8((height >> 8) & 0xFF)
	header[16] = 24 // 24 bpp
	header[17] = 0 // no alpha, origin bottom left

	data := make([]u8, size_of(header) + width * height * 3)
	copy(data, header[:])
	pos := size_of(header)
	for row in 0..<height {
		// bottom row first
		y := height - 1 - row
		for x in 0..<width {
			p := y * bytes_per_row + x * 4
			data[pos], data[pos + 1], data[pos + 2] = pixels[p + 2], pixels[p + 1], pixels[p] // BGR
			pos += 3
		}
	}
	err := os.write_entire_file(filename, data)
	delete(data)
	return err == nil
}

// --------------------------------------------------------
// talking to Metal through the Objective-C runtime.
//
// base:runtime declares objc_msgSend without a return value and does not
// allow declaring it again, so it is looked up with dlsym and given the exact
// signature of each kind of call.

when SCREENSHOTS {
	MTL_STORAGE_MODE_SHARED :: 0

	MTL_COMMAND_BUFFER_STATUS_COMPLETED :: 4

	MTL_Origin :: struct {
		x, y, z: i64,
	}

	MTL_Size :: struct {
		width, height, depth: i64,
	}

	// Arguments are pointers, 64-bit integers, or the two structs, which are
	// passed each as a pointer to a copy, as the C calling convention has it on
	// this platform.
	Msg_P :: proc "c" (self, sel: rawptr) -> rawptr
	Msg_U :: proc "c" (self, sel: rawptr) -> u64
	Msg_P_UU :: proc "c" (self, sel: rawptr, a, b: u64) -> rawptr
	Msg_Blit :: proc "c" (
		self, sel: rawptr,
		source_texture: rawptr,
		source_slice, source_level: u64,
		source_origin: ^MTL_Origin,
		source_size: ^MTL_Size,
		destination_buffer: rawptr,
		destination_offset, destination_bytes_per_row, destination_bytes_per_image: u64,
	)

	objc_lib: posix.Symbol_Table
	msg_p: Msg_P
	msg_u: Msg_U
	msg_p_uu: Msg_P_UU
	msg_blit: Msg_Blit
	objc_sel: proc "c" (name: cstring) -> rawptr

	objc_setup :: proc() {
		if objc_lib != nil {
			return
		}
		objc_lib = posix.dlopen("/usr/lib/libobjc.A.dylib", { .LAZY })
		assert(objc_lib != nil)
		sym := posix.dlsym(objc_lib, "objc_msgSend")
		msg_p = Msg_P(sym)
		msg_u = Msg_U(sym)
		msg_p_uu = Msg_P_UU(sym)
		msg_blit = Msg_Blit(sym)
		objc_sel = (proc "c" (name: cstring) -> rawptr)(posix.dlsym(objc_lib, "sel_registerName"))
		assert(sym != nil && objc_sel != nil)
	}

	// The default Metal device of the machine.
	metal_create_system_default_device :: proc() -> rawptr {
		metal := posix.dlopen("/System/Library/Frameworks/Metal.framework/Metal", { .LAZY })
		assert(metal != nil)
		create := (proc "c" () -> rawptr)(posix.dlsym(metal, "MTLCreateSystemDefaultDevice"))
		return create()
	}
}
