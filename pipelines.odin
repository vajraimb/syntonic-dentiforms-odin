//------------------------------------------------------------------------------
//  pipelines -- all the render pipelines of the demo, the port of
//  src/demo/Pipelines. The shaders are the original ones, compiled into the
//  packages in fx/ by tools/build_shaders.sh.
//------------------------------------------------------------------------------
package main

import sg                     "sokol/gfx"
import sh_billboards          "fx/billboards"
import sh_blit                "fx/blit"
import sh_lines               "fx/lines"
import sh_overlay             "fx/overlay"
import sh_postBlurStep        "fx/postBlurStep"
import sh_postComposeToon     "fx/postComposeToon"
import sh_postToon            "fx/postToon"
import sh_renderLit           "fx/renderLit"
import sh_renderLitShadowed   "fx/renderLitShadowed"
import sh_renderReflective    "fx/renderReflective"
import sh_renderWhite         "fx/renderWhite"
import sh_shadowCaster         "fx/shadowCaster"

Pipeline :: enum int {
	BLIT,
	BLIT_TO_SWAP,
	OVERLAY1,
	OVERLAY2,

	POST_COMPOSE_BLOOM,
	POST_COMPOSE_TOON,
	POST_TOON,
	POST_BLUR_STEP,

	BILLBOARDS,
	BILLBOARDS_CLEAR_DEST_ALPHA,
	LINES,
	LINES_NO_AA,

	RENDER_WHITE,
	RENDER_LIT,
	RENDER_LIT_SHADOWED,
	RENDER_LIT_SHADOWED_FLIP,
	RENDER_REFLECTIVE,
	SHADOW_CASTER,

	COUNT,
}

g_fx_pipes: [Pipeline.COUNT]sg.Pipeline

pipe_full_tri :: proc(desc: ^sg.Pipeline_Desc) {
	desc.primitive_type = .TRIANGLES
	desc.colors[0].pixel_format = .RGBA8
	desc.depth.pixel_format = .NONE
	desc.depth.compare = .ALWAYS
	desc.depth.write_enabled = false
	desc.cull_mode = .NONE
}

pipe_blend_add :: proc(desc: ^sg.Pipeline_Desc) {
	desc.colors[0].blend.enabled = true
	desc.colors[0].blend.src_factor_rgb = .ONE
	desc.colors[0].blend.src_factor_alpha = .ONE
	desc.colors[0].blend.dst_factor_rgb = .ONE
	desc.colors[0].blend.dst_factor_alpha = .ONE
}

pipe_blend_alpha :: proc(desc: ^sg.Pipeline_Desc) {
	desc.colors[0].blend.enabled = true
	desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA
	desc.colors[0].blend.src_factor_alpha = .SRC_ALPHA
	desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA
	desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA
}

// The lines and the billboards: a position, a color, texture coordinates.
pipe_vertex_colored :: proc(desc: ^sg.Pipeline_Desc) {
	desc.primitive_type = .TRIANGLES
	desc.index_type = .UINT16
	desc.layout.attrs[0].format = .FLOAT3
	desc.layout.attrs[0].offset = 0
	desc.layout.attrs[1].format = .UBYTE4N
	desc.layout.attrs[1].offset = 12
	desc.layout.attrs[2].format = .FLOAT2
	desc.layout.attrs[2].offset = 16
}

// A mesh: a position and the packed normal.
pipe_vertex_mesh :: proc(desc: ^sg.Pipeline_Desc) {
	desc.primitive_type = .TRIANGLES
	desc.index_type = .UINT16
	desc.layout.buffers[0].stride = 16
	desc.layout.attrs[0].format = .FLOAT3
	desc.layout.attrs[0].offset = 0
	desc.layout.attrs[1].format = .SHORT2N
	desc.layout.attrs[1].offset = 12
}

// A mesh of which only the position is used.
pipe_vertex_mesh_pos :: proc(desc: ^sg.Pipeline_Desc) {
	desc.primitive_type = .TRIANGLES
	desc.index_type = .UINT16
	desc.layout.buffers[0].stride = 16
	desc.layout.attrs[0].format = .FLOAT3
	desc.layout.attrs[0].offset = 0
}

pipe_depth_buffer :: proc(desc: ^sg.Pipeline_Desc) {
	desc.depth.pixel_format = .DEPTH
	desc.depth.compare = .LESS_EQUAL
	desc.depth.write_enabled = true
}

pipelines_init :: proc() {
	backend := sg.query_backend()

	{
		desc: sg.Pipeline_Desc
		desc.shader = sg.make_shader(sh_blit.prog_shader_desc(backend))
		desc.label = "blit"
		pipe_full_tri(&desc)
		g_fx_pipes[int(Pipeline.BLIT)] = sg.make_pipeline(desc)

		// the swapchain's own formats
		desc.label = "blitToSwap"
		desc.colors[0].pixel_format = .DEFAULT
		desc.depth.pixel_format = .DEFAULT
		g_fx_pipes[int(Pipeline.BLIT_TO_SWAP)] = sg.make_pipeline(desc)

		desc.label = "composeBloom"
		pipe_full_tri(&desc)
		pipe_blend_add(&desc)
		g_fx_pipes[int(Pipeline.POST_COMPOSE_BLOOM)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "postComposeToon"
		desc.shader = sg.make_shader(sh_postComposeToon.prog_shader_desc(backend))
		pipe_full_tri(&desc)
		desc.colors[0].blend.enabled = true
		desc.colors[0].blend.src_factor_rgb = .ONE_MINUS_SRC_ALPHA
		desc.colors[0].blend.src_factor_alpha = .ONE_MINUS_SRC_ALPHA
		desc.colors[0].blend.dst_factor_rgb = .SRC_ALPHA
		desc.colors[0].blend.dst_factor_alpha = .SRC_ALPHA
		g_fx_pipes[int(Pipeline.POST_COMPOSE_TOON)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "postBlurStep"
		desc.shader = sg.make_shader(sh_postBlurStep.prog_shader_desc(backend))
		pipe_full_tri(&desc)
		g_fx_pipes[int(Pipeline.POST_BLUR_STEP)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "postToon"
		desc.shader = sg.make_shader(sh_postToon.prog_shader_desc(backend))
		pipe_full_tri(&desc)
		g_fx_pipes[int(Pipeline.POST_TOON)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "billboards"
		desc.shader = sg.make_shader(sh_billboards.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		desc.depth.pixel_format = .NONE

		pipe_vertex_colored(&desc)
		pipe_blend_alpha(&desc)
		desc.depth.compare = .ALWAYS
		desc.depth.write_enabled = false
		desc.cull_mode = .NONE
		g_fx_pipes[int(Pipeline.BILLBOARDS)] = sg.make_pipeline(desc)

		desc.label = "billboardsClearDestAlpha"
		desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA
		desc.colors[0].blend.src_factor_alpha = .ONE_MINUS_SRC_ALPHA
		desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA
		desc.colors[0].blend.dst_factor_alpha = .SRC_ALPHA
		g_fx_pipes[int(Pipeline.BILLBOARDS_CLEAR_DEST_ALPHA)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "overlay1"
		desc.shader = sg.make_shader(sh_overlay.prog_shader_desc(backend))
		pipe_full_tri(&desc)
		pipe_blend_add(&desc)
		g_fx_pipes[int(Pipeline.OVERLAY1)] = sg.make_pipeline(desc)

		desc.label = "overlay2"
		desc.colors[0].blend.src_factor_rgb = .DST_COLOR
		desc.colors[0].blend.src_factor_alpha = .DST_ALPHA
		desc.colors[0].blend.dst_factor_rgb = .ONE
		desc.colors[0].blend.dst_factor_alpha = .ONE
		g_fx_pipes[int(Pipeline.OVERLAY2)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "renderWhite"
		desc.shader = sg.make_shader(sh_renderWhite.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		pipe_vertex_mesh_pos(&desc)
		desc.cull_mode = .FRONT
		desc.depth.pixel_format = .NONE
		desc.depth.compare = .ALWAYS
		desc.depth.write_enabled = false
		g_fx_pipes[int(Pipeline.RENDER_WHITE)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "shadowCaster"
		desc.shader = sg.make_shader(sh_shadowCaster.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .NONE
		pipe_vertex_mesh_pos(&desc)
		pipe_depth_buffer(&desc)
		desc.cull_mode = .BACK // render backfaces into the shadowmap (reduces acne)
		g_fx_pipes[int(Pipeline.SHADOW_CASTER)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "lines"
		desc.shader = sg.make_shader(sh_lines.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		pipe_depth_buffer(&desc)

		pipe_vertex_colored(&desc)
		desc.sample_count = MAIN_AA
		// blend, no depth write, no cull
		desc.colors[0].blend.enabled = true
		desc.colors[0].blend.src_factor_rgb = .SRC_ALPHA
		desc.colors[0].blend.src_factor_alpha = .SRC_ALPHA
		desc.colors[0].blend.dst_factor_rgb = .ONE_MINUS_SRC_ALPHA
		desc.colors[0].blend.dst_factor_alpha = .ONE_MINUS_SRC_ALPHA
		desc.depth.write_enabled = false
		desc.cull_mode = .NONE
		g_fx_pipes[int(Pipeline.LINES)] = sg.make_pipeline(desc)

		desc.label = "linesNoAA"
		desc.depth.compare = .ALWAYS
		desc.depth.pixel_format = .NONE
		desc.sample_count = 1
		g_fx_pipes[int(Pipeline.LINES_NO_AA)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "renderLitShadowed"
		desc.shader = sg.make_shader(sh_renderLitShadowed.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		pipe_depth_buffer(&desc)
		pipe_vertex_mesh(&desc)
		desc.sample_count = MAIN_AA
		desc.cull_mode = .FRONT
		g_fx_pipes[int(Pipeline.RENDER_LIT_SHADOWED)] = sg.make_pipeline(desc)

		desc.label = "renderLitShadowedFlip"
		desc.cull_mode = .BACK // reflection; inverted culling
		g_fx_pipes[int(Pipeline.RENDER_LIT_SHADOWED_FLIP)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "renderLit"
		desc.shader = sg.make_shader(sh_renderLit.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		pipe_depth_buffer(&desc)
		pipe_vertex_mesh(&desc)
		desc.sample_count = MAIN_AA
		desc.cull_mode = .FRONT
		g_fx_pipes[int(Pipeline.RENDER_LIT)] = sg.make_pipeline(desc)
	}
	{
		desc: sg.Pipeline_Desc
		desc.label = "renderReflective"
		desc.shader = sg.make_shader(sh_renderReflective.prog_shader_desc(backend))
		desc.colors[0].pixel_format = .RGBA8
		pipe_depth_buffer(&desc)
		pipe_vertex_mesh_pos(&desc)
		desc.sample_count = MAIN_AA
		desc.cull_mode = .FRONT
		pipe_blend_alpha(&desc)
		desc.depth.write_enabled = false
		when REFLECTIONS_DEPTH_BIAS {
			desc.depth.bias = -10.0
		}
		g_fx_pipes[int(Pipeline.RENDER_REFLECTIVE)] = sg.make_pipeline(desc)
	}
}

pipeline_apply :: proc(fx: Pipeline) {
	assert(g_fx_pipes[fx].id != 0)
	sg.apply_pipeline(g_fx_pipes[fx])
}

// Multi-pass rendering of reflections causes garbage artifacts on the
// web, but only on Apple systems.
// Both in Chrome / macOS 15.7 and Safari / iOS 18.
// Just bias the reflections for now!
REFLECTIONS_DEPTH_BIAS :: ODIN_ARCH == .wasm32 || ODIN_ARCH == .wasm64p32
