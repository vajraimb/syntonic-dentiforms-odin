//------------------------------------------------------------------------------
//  rendering -- the port of src/demo/Rendering: full screen passes, lines,
//  billboards, the dynamic vertex buffer, and the render targets.
//------------------------------------------------------------------------------
package main

import "core:c"
import "core:mem"
import sg    "sokol/gfx"
import sapp  "sokol/app"
import sglue "sokol/glue"

RPF_None :: 0
RPF_Load_RenderTarget :: 1 << 0
RPF_DoNot_End_Pass :: 1 << 1

// The size of what the demo is rendered into: the window's framebuffer, or
// the image of the offscreen mode.
screen_width :: proc() -> int {
	return g_offscreen ? OFFSCREEN_WIDTH : int(sapp.width())
}

screen_height :: proc() -> int {
	return g_offscreen ? OFFSCREEN_HEIGHT : int(sapp.height())
}

screen_widthf :: proc() -> f32 {
	return f32(screen_width())
}

screen_heightf :: proc() -> f32 {
	return f32(screen_height())
}

render_fullscreen_pass :: proc(
	pipe: Pipeline,
	debug_label: cstring,
	render_target: sg.View,     // as a render target; an invalid view means the swapchain
	input_textures: []sg.View,
	uniforms: sg.Range,
	flags: i32 = RPF_None,
) {
	pass: sg.Pass
	pass.label = debug_label
	if render_target.id != 0 {
		pass.attachments.colors[0] = render_target
	} else if g_offscreen {
		pass.attachments.colors[0] = rt_screen.view_rt
	} else {
		pass.swapchain = sglue.swapchain()
	}
	pass.action.colors[0].store_action = .STORE
	pass.action.colors[0].load_action = (flags & RPF_Load_RenderTarget) != 0 ? .LOAD : .DONTCARE
	pass.action.depth.load_action = .DONTCARE
	sg.begin_pass(pass)

	binds: sg.Bindings
	for i in 0..<len(input_textures) {
		binds.views[i] = input_textures[i]
	}
	binds.samplers[0] = s_smp_linear_clamp

	pipeline_apply(pipe)

	if uniforms.ptr != nil {
		sg.apply_uniforms(0, uniforms)
	}

	sg.apply_bindings(binds)
	sg.draw(0, 3, 1)

	if flags & RPF_DoNot_End_Pass == 0 {
		sg.end_pass()
	}
}

// --------------------------------------------------------
// lines

Line_Point :: struct {
	pos:   Vector3,
	color: u32,
}

// A vertex of the lines and of the billboards.
Line_Vertex :: struct {
	p:       Vector3,
	diffuse: u32,
	tu, tv:  f32,
}

LINE_MAX_VERTICES :: 1024

Line_Renderer :: struct {
	ib: sg.Buffer,
}

g_line_renderer: Line_Renderer

line_renderer_init :: proc() {
	// enough index data for 1000 segments
	SEGMENTS :: 1000
	ib := make([]u16, SEGMENTS * 6)
	for i in 0..<SEGMENTS {
		base := u16(i * 2)
		ib[i * 6 + 0] = base
		ib[i * 6 + 1] = base + 2
		ib[i * 6 + 2] = base + 1
		ib[i * 6 + 3] = base + 2
		ib[i * 6 + 4] = base + 3
		ib[i * 6 + 5] = base + 1
	}
	g_line_renderer.ib = sg.make_buffer({
		usage = { index_buffer = true },
		data = { ptr = raw_data(ib), size = c.size_t(len(ib) * 2) },
	})
	assert(sg.query_buffer_state(g_line_renderer.ib) == .VALID)
	delete(ib)
}

line_renderer_destroy :: proc() {
	sg.destroy_buffer(g_line_renderer.ib)
	g_line_renderer.ib = {}
}

// Draws a polyline as a strip of camera facing quads. The pipeline is up to the caller.
line_render_strip :: proc(npoints: int, points: []Line_Point, half_width: f32) {
	if npoints < 2 {
		return
	}
	cam_pos := origin(&g_render_cam.camera_matrix)^

	nverts := npoints * 2
	ntris := (npoints - 1) * 2
	assert(nverts <= LINE_MAX_VERTICES)

	chunk: [LINE_MAX_VERTICES]Line_Vertex
	vb := 0

	// fill the vertices with line segments
	for i in 1..<npoints {
		pt_a := &points[i - 1]
		pt_b := &points[i]
		seg_dir := pt_b.pos - pt_a.pos
		side := cross(seg_dir, pt_b.pos - cam_pos)
		normalize(&side)
		c1 := side * half_width
		c2 := c1 * -1.0

		// 2 or 4 line corners
		if i == 1 {
			chunk[vb] = { pt_a.pos + c1, pt_a.color, 0.0, 0.0 }
			vb += 1
			chunk[vb] = { pt_a.pos + c2, pt_a.color, 0.0, 1.0 }
			vb += 1
		}
		chunk[vb] = { pt_b.pos + c1, pt_b.color, 1.0, 0.0 }
		vb += 1
		chunk[vb] = { pt_b.pos + c2, pt_b.color, 1.0, 1.0 }
		vb += 1
	}

	offset := dynamic_vb_append(&chunk, nverts * size_of(Line_Vertex))
	dynamic_vb_flush()

	// render
	sg.apply_uniforms(0, { ptr = &g_global_u, size = size_of(Global_Uniforms) })

	binds: sg.Bindings
	binds.vertex_buffers[0] = dynamic_vb_get()
	binds.vertex_buffer_offsets[0] = c.int(offset)
	binds.index_buffer = g_line_renderer.ib
	binds.views[0] = data_tex(.LINE1).view_tex
	binds.samplers[0] = s_smp_linear_repeat
	sg.apply_bindings(binds)
	sg.draw(0, ntris * 3, 1)
}

g_compute_texture_projection :: proc(render_camera_matrix, projector_matrix: Matrix4x4, dest: ^Matrix4x4) {
	// | -0.5     0        0        0 |
	// | 0        0.5      0        0 |
	// | 0        0        1        0 |
	// | 0.5      0.5      0        1 |
	mat_tex_scale := matrix_identity()
	mat_tex_scale[0][0] = 0.5
	mat_tex_scale[1][1] = -0.5
	origin(&mat_tex_scale)^ = { 0.5, 0.5, 0.0 }

	dest^ = matrix_mul(matrix_mul(render_camera_matrix, projector_matrix), mat_tex_scale)
}

// --------------------------------------------------------
// bloom

BLOOM_PASSES :: 4

ping_pong_blur :: proc(passes: int) {
	ping_pong := [2]^Texture{ &rt_4th_2, &rt_4th_1 }

	swidth := screen_width() / 4
	sheight := screen_height() / 4

	for i in 0..<passes {
		pix_dist := f32(i) + 0.5
		offset := Vector4{ pix_dist / f32(swidth), pix_dist / f32(sheight), 0, 0 }
		render_fullscreen_pass(
			.POST_BLUR_STEP, "blur step",
			ping_pong[i & 1].view_rt,
			[]sg.View{ ping_pong[(i + 1) & 1].view_tex },
			{ ptr = &offset, size = size_of(Vector4) },
		)
	}
}

render_bloom :: proc() {
	// downsample main into a smaller RT
	render_fullscreen_pass(.BLIT, "downsample", rt_4th_1.view_rt, []sg.View{ rt_main_resolved.view_tex }, {})

	// blur
	ping_pong_blur(BLOOM_PASSES)

	// add back into resolved
	last := (BLOOM_PASSES & 1) != 0 ? rt_4th_2.view_tex : rt_4th_1.view_tex
	render_fullscreen_pass(
		.POST_COMPOSE_BLOOM, "compose bloom",
		rt_main_resolved.view_rt, []sg.View{ last }, {},
		RPF_Load_RenderTarget,
	)

	// blit into the swapchain backbuffer
	// do not end pass; debug text will continue rendering
	render_fullscreen_pass(.BLIT_TO_SWAP, "blit to swapchain", {}, []sg.View{ rt_main_resolved.view_tex }, {}, RPF_DoNot_End_Pass)
}

// --------------------------------------------------------
// billboards

Billboard :: struct {
	x1, y1, x2, y2:     f32,
	tu1, tv1, tu2, tv2: f32,
	color:              u32,
	texture:            sg.View,
}

BILLBOARD_MAX :: 256

g_bills: [BILLBOARD_MAX]Billboard
g_bill_count: int
g_ib_quads: sg.Buffer

billboards_add :: proc() -> ^Billboard {
	assert(g_bill_count < BILLBOARD_MAX)
	b := &g_bills[g_bill_count]
	b^ = {}
	g_bill_count += 1
	return b
}

billboards_clear :: proc() {
	g_bill_count = 0
}

// Draws the billboards collected since the last billboards_clear(). The pipeline is up to the caller.
billboards_render :: proc() {
	if g_ib_quads.id == 0 {
		quad_ib := [6]u16{ 0, 1, 3, 1, 2, 3 }
		g_ib_quads = sg.make_buffer({
			usage = { index_buffer = true },
			data = { ptr = &quad_ib, size = c.size_t(size_of(quad_ib)) },
		})
		assert(sg.query_buffer_state(g_ib_quads) == .VALID)
	}

	if g_bill_count == 0 {
		return
	}

	// construct vertices
	vertices: [BILLBOARD_MAX * 4]Line_Vertex
	v := 0
	for i in 0..<g_bill_count {
		b := &g_bills[i]
		z := f32(0.1)
		vertices[v] = { { b.x1, b.y1, z }, b.color, b.tu1, b.tv1 }
		vertices[v + 1] = { { b.x2, b.y1, z }, b.color, b.tu2, b.tv1 }
		vertices[v + 2] = { { b.x2, b.y2, z }, b.color, b.tu2, b.tv2 }
		vertices[v + 3] = { { b.x1, b.y2, z }, b.color, b.tu1, b.tv2 }
		v += 4
	}

	// put them into the GPU buffer
	vb_offset := dynamic_vb_append(&vertices, g_bill_count * 4 * size_of(Line_Vertex))
	dynamic_vb_flush()

	// base bindings
	bind: sg.Bindings
	bind.vertex_buffers[0] = dynamic_vb_get()
	bind.vertex_buffer_offsets[0] = c.int(vb_offset)
	bind.index_buffer = g_ib_quads
	bind.samplers[0] = s_smp_linear_clamp

	for i in 0..<g_bill_count {
		b := &g_bills[i]
		bind.views[0] = b.texture
		bind.vertex_buffer_offsets[0] = c.int(vb_offset + i * size_of(Line_Vertex) * 4)
		sg.apply_bindings(bind)
		sg.draw(0, 6, 1)
	}
}

// --------------------------------------------------------
// dynamic vertex buffer
//
// The original appends to one buffer with sg_append_buffer; the sokol version
// the bindings are for has replaced that with explicit writes, and a buffer
// may be written only once per frame, before it is first bound. As a frame
// draws its lines and billboards in several goes, there is a small pool of
// buffers instead, and every go takes the next one. They all start over each
// frame.

DYNAMIC_VB_BUFFERS :: 16
DYNAMIC_VB_CAPACITY :: 64 * 1024

g_dynamic_vb: struct {
	buffers: [DYNAMIC_VB_BUFFERS]sg.Buffer,
	cpu:     [DYNAMIC_VB_BUFFERS][DYNAMIC_VB_CAPACITY]u8, // what goes into them
	current: int, // the buffer being filled
	appended: int, // bytes put into it since it became the current one
	written: int, // bytes of those already handed to the GPU
}

dynamic_vb_init :: proc() {
	for i in 0..<DYNAMIC_VB_BUFFERS {
		g_dynamic_vb.buffers[i] = sg.make_buffer({
			size = DYNAMIC_VB_CAPACITY,
			usage = { vertex_buffer = true, write_transient = true },
		})
		assert(sg.query_buffer_state(g_dynamic_vb.buffers[i]) == .VALID)
	}
}

dynamic_vb_shutdown :: proc() {
	for i in 0..<DYNAMIC_VB_BUFFERS {
		sg.destroy_buffer(g_dynamic_vb.buffers[i])
	}
	g_dynamic_vb.buffers = {}
}

// Copies the data into a buffer for this frame; returns its offset in bytes.
// Call dynamic_vb_flush() before drawing from it.
dynamic_vb_append :: proc(data: rawptr, size: int) -> int {
	if g_dynamic_vb.written != 0 {
		// this one has been handed out already; on to the next
		g_dynamic_vb.current += 1
		assert(g_dynamic_vb.current < DYNAMIC_VB_BUFFERS)
		g_dynamic_vb.appended = 0
		g_dynamic_vb.written = 0
	}
	offset := g_dynamic_vb.appended
	assert(offset + size <= DYNAMIC_VB_CAPACITY)
	mem.copy(&g_dynamic_vb.cpu[g_dynamic_vb.current][offset], data, size)
	g_dynamic_vb.appended += size
	return offset
}

// Hands what was appended since the last flush to the GPU.
dynamic_vb_flush :: proc() {
	if g_dynamic_vb.written < g_dynamic_vb.appended {
		i := g_dynamic_vb.current
		sg.write_buffer_transient({
			src = {
				data = {
					ptr = &g_dynamic_vb.cpu[i][g_dynamic_vb.written],
					size = c.size_t(g_dynamic_vb.appended - g_dynamic_vb.written),
				},
			},
			dst = { buffer = g_dynamic_vb.buffers[i], offset = c.size_t(g_dynamic_vb.written) },
		})
		g_dynamic_vb.written = g_dynamic_vb.appended
	}
}

// The buffer holding what was appended last.
dynamic_vb_get :: proc() -> sg.Buffer {
	return g_dynamic_vb.buffers[g_dynamic_vb.current]
}

// The contents of the buffers are only good for the frame they were written in.
dynamic_vb_new_frame :: proc() {
	g_dynamic_vb.current = 0
	g_dynamic_vb.appended = 0
	g_dynamic_vb.written = 0
}

// --------------------------------------------------------

s_smp_linear_repeat: sg.Sampler
s_smp_linear_clamp: sg.Sampler
s_smp_shadow: sg.Sampler

// --------------------------------------------------------

MAIN_AA :: 4

rt_main_aa: Texture       // the 3D scene, multisampled
rt_main_z: Texture        // its depth buffer
rt_main_resolved: Texture // the 3D scene resolved, then everything 2D drawn onto it
rt_full_toon: Texture     // the scene with the toon lookup applied
rt_4th_1: Texture         // quarter size, for the bloom blur
rt_4th_2: Texture
rt_refl_px: Texture // what each of the six walls reflects, at half size
rt_refl_py: Texture
rt_refl_pz: Texture
rt_refl_nx: Texture
rt_refl_ny: Texture
rt_refl_nz: Texture
rt_refl_rt: Texture // the color surface the reflections are rendered into
rt_refl_z: Texture  // and its depth buffer
rt_shadow_z: Texture

SHADOW_MAP_SIZE :: 1024

// Match global_uniforms in the shaders.
Global_Uniforms :: struct {
	mat_view:          Matrix4x4,
	mat_projection:    Matrix4x4,
	mat_view_proj:     Matrix4x4,
	mat_view_tex_proj: Matrix4x4,
	mat_shadow_proj:   Matrix4x4,
	eye_pos:           Vector4,
	light_pos:         Vector4,
	light_dir:         Vector4,
	_pad0:             Vector4,
}
#assert(size_of(Global_Uniforms) == 384)

g_global_u: Global_Uniforms

// the size the screen size based textures were created for
rt_main_size_w: int = -1
rt_main_size_h: int = -1

ensure_render_targets :: proc() {
	width := screen_width()
	height := screen_height()

	// screen size based textures
	if rt_main_size_w != width || rt_main_size_h != height {
		texture_destroy(&rt_main_aa)
		texture_destroy(&rt_main_z)
		texture_destroy(&rt_main_resolved)
		texture_destroy(&rt_full_toon)
		texture_destroy(&rt_4th_1)
		texture_destroy(&rt_4th_2)
		texture_destroy(&rt_refl_px)
		texture_destroy(&rt_refl_py)
		texture_destroy(&rt_refl_pz)
		texture_destroy(&rt_refl_nx)
		texture_destroy(&rt_refl_ny)
		texture_destroy(&rt_refl_nz)
		texture_destroy(&rt_refl_rt)
		texture_destroy(&rt_refl_z)
		rt_main_size_w = width
		rt_main_size_h = height
	}

	if !texture_valid(&rt_main_aa) {
		desc: sg.Image_Desc
		desc.usage.color_attachment = true

		// full size
		desc.width = c.int(width)
		desc.height = c.int(height)
		desc.sample_count = MAIN_AA
		desc.pixel_format = .RGBA8
		texture_create(&rt_main_aa, desc)

		desc.pixel_format = .DEPTH
		desc.usage.depth_stencil_attachment = true
		desc.usage.color_attachment = false
		texture_create(&rt_main_z, desc)

		desc.pixel_format = .RGBA8
		desc.usage.depth_stencil_attachment = false
		desc.usage.color_attachment = true
		desc.sample_count = 1
		desc.usage.resolve_attachment = true
		texture_create(&rt_main_resolved, desc)
		desc.usage.resolve_attachment = false

		texture_create(&rt_full_toon, desc)

		// 1/4th size
		desc.width = c.int(width / 4)
		desc.height = c.int(height / 4)
		texture_create(&rt_4th_1, desc)
		texture_create(&rt_4th_2, desc)

		// reflection textures
		desc.usage.color_attachment = false
		desc.usage.resolve_attachment = true
		desc.width = c.int(width / 2)
		desc.height = c.int(height / 2)
		texture_create(&rt_refl_px, desc)
		texture_create(&rt_refl_py, desc)
		texture_create(&rt_refl_pz, desc)
		texture_create(&rt_refl_nx, desc)
		texture_create(&rt_refl_ny, desc)
		texture_create(&rt_refl_nz, desc)
		// reflections color/depth MSAA surfaces
		desc.sample_count = MAIN_AA
		desc.usage.color_attachment = true
		desc.usage.resolve_attachment = false
		texture_create(&rt_refl_rt, desc)
		desc.usage.color_attachment = false
		desc.usage.depth_stencil_attachment = true
		desc.pixel_format = .DEPTH
		texture_create(&rt_refl_z, desc)
	}

	// fixed size textures
	if !texture_valid(&rt_shadow_z) {
		desc: sg.Image_Desc
		desc.sample_count = 1
		desc.width = SHADOW_MAP_SIZE
		desc.height = SHADOW_MAP_SIZE
		desc.usage.depth_stencil_attachment = true
		desc.pixel_format = .DEPTH
		texture_create(&rt_shadow_z, desc)
	}
}

destroy_render_targets :: proc() {
	texture_destroy(&rt_main_aa)
	texture_destroy(&rt_main_z)
	texture_destroy(&rt_main_resolved)
	texture_destroy(&rt_full_toon)
	texture_destroy(&rt_4th_1)
	texture_destroy(&rt_4th_2)
	texture_destroy(&rt_refl_px)
	texture_destroy(&rt_refl_py)
	texture_destroy(&rt_refl_pz)
	texture_destroy(&rt_refl_nx)
	texture_destroy(&rt_refl_ny)
	texture_destroy(&rt_refl_nz)
	texture_destroy(&rt_refl_rt)
	texture_destroy(&rt_refl_z)
	texture_destroy(&rt_shadow_z)
}
