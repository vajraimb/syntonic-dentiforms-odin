//------------------------------------------------------------------------------
//  gfx -- the things the GPU draws from, the ports of src/gfx/Mesh and
//  src/gfx/Texture.
//------------------------------------------------------------------------------
package main

import "core:c"
import "core:strings"
import sg "sokol/gfx"
import stb_image "vendor:stb/image"

Mesh_Vertex :: struct #packed {
	x, y, z: f32, // position
	n:      u32, // normal, 2xSNorm16 octahedral
}
#assert(size_of(Mesh_Vertex) == 16)

Mesh :: struct {
	vertex_count: int,
	index_count:  int,
	vb:           sg.Buffer,
	ib:           sg.Buffer,
	total_aabb:   AABox,
}

mesh_new :: proc(vertex_count, index_count: int, vb_data, ib_data: []u8) -> ^Mesh {
	assert(vertex_count > 0 && index_count > 0)
	m := new(Mesh)
	m.vertex_count = vertex_count
	m.index_count = index_count

	// vertex buffer
	m.vb = sg.make_buffer({
		usage = { vertex_buffer = true },
		data = { ptr = raw_data(vb_data), size = c.size_t(vertex_count * size_of(Mesh_Vertex)) },
	})
	assert(sg.query_buffer_state(m.vb) == .VALID)

	// index buffer
	m.ib = sg.make_buffer({
		usage = { index_buffer = true },
		data = { ptr = raw_data(ib_data), size = c.size_t(index_count * 2) },
	})
	assert(sg.query_buffer_state(m.ib) == .VALID)

	// AABB
	m.total_aabb = aabox_null()
	vertices := ([^]Mesh_Vertex)(raw_data(vb_data))
	for v in 0..<vertex_count {
		aabox_extend(&m.total_aabb, { vertices[v].x, vertices[v].y, vertices[v].z })
	}
	return m
}

// file format:
// - 4 bytes "dmsh"
// - 4 bytes nverts
// - 4 bytes ntris
// - 16*nverts vertex data (3x float position, 2xSNorm16 octahedral normal)
// - 2*3*ntris index data (16 bit)
mesh_load :: proc(path: string) -> ^Mesh {
	r, ok := read_open(path)
	if !ok {
		return nil
	}
	defer read_close(&r)

	magic := read_bytes(&r, 4)
	if len(magic) != 4 || magic[0] != 'd' || magic[1] != 'm' || magic[2] != 's' || magic[3] != 'h' {
		return nil
	}
	nverts := read_u32(&r)
	ntris := read_u32(&r)
	if nverts == 0 || ntris == 0 {
		return nil
	}
	vb_data := read_bytes(&r, int(nverts) * size_of(Mesh_Vertex))
	ib_data := read_bytes(&r, int(ntris) * 3 * 2)
	if !r.ok {
		return nil
	}
	return mesh_new(int(nverts), int(ntris) * 3, vb_data, ib_data)
}

// --------------------------------------------------------

Texture :: struct {
	image:        sg.Image,
	view_rt:      sg.View, // as a render target
	view_z:       sg.View, // as a depth buffer
	view_resolve: sg.View, // as a resolve target
	view_tex:     sg.View, // for sampling
}

texture_create :: proc(t: ^Texture, desc: sg.Image_Desc) {
	assert(t.image.id == 0)

	t.image = sg.make_image(desc)
	assert(sg.query_image_state(t.image) == .VALID)

	if desc.usage.color_attachment {
		t.view_rt = sg.make_view({ color_attachment = { image = t.image } })
		assert(sg.query_view_state(t.view_rt) == .VALID)
	}
	if desc.usage.depth_stencil_attachment {
		t.view_z = sg.make_view({ depth_stencil_attachment = { image = t.image } })
		assert(sg.query_view_state(t.view_z) == .VALID)
	}
	if desc.usage.resolve_attachment {
		t.view_resolve = sg.make_view({ resolve_attachment = { image = t.image } })
		assert(sg.query_view_state(t.view_resolve) == .VALID)
	}
	// only allow sampling it if not MSAA'd (mostly a WebGL2 limitation)
	if desc.sample_count <= 1 {
		t.view_tex = sg.make_view({ texture = { image = t.image } })
		assert(sg.query_view_state(t.view_tex) == .VALID)
	}
}

texture_destroy :: proc(t: ^Texture) {
	if t.image.id != 0 {
		sg.destroy_image(t.image)
	}
	t.image = {}
	if t.view_rt.id != 0 {
		sg.destroy_view(t.view_rt)
	}
	t.view_rt = {}
	if t.view_z.id != 0 {
		sg.destroy_view(t.view_z)
	}
	t.view_z = {}
	if t.view_resolve.id != 0 {
		sg.destroy_view(t.view_resolve)
	}
	t.view_resolve = {}
	if t.view_tex.id != 0 {
		sg.destroy_view(t.view_tex)
	}
	t.view_tex = {}
}

texture_valid :: proc(t: ^Texture) -> bool {
	return t.image.id != 0
}

load_texture :: proc(t: ^Texture, path: string) -> bool {
	width, height, channels: c.int
	data := stb_image.load(strings.clone_to_cstring(path, context.temp_allocator), &width, &height, &channels, 4)
	if data == nil {
		return false
	}
	texture_create(t, {
		width = width,
		height = height,
		data = { ptr = rawptr(data), size = c.size_t(width * height * 4) },
	})
	stb_image.image_free(rawptr(data))
	return true
}
