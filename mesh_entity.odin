//------------------------------------------------------------------------------
//  mesh_entity -- a mesh placed in the world, the port of src/demo/MeshEntity.
//------------------------------------------------------------------------------
package main

import sg "sokol/gfx"

Render_Mode :: enum int {
	LIT_SHADOWED,
	LIT_SHADOWED_FLIP,
	SHADOW_CASTER,
	REFLECTIVE,
	LIT,
}

Cube_Face :: enum int {
	PX = 0,
	NX,
	PY,
	NY,
	PZ,
	NZ,
	COUNT,
}

Mesh_Entity :: struct {
	transform: Matrix4x4,

	mesh:              ^Mesh,
	render_modes_mask: i32,
	cube_face:         Cube_Face, // reflection cube face
}

// The bit of a render mode in render_modes_mask.
mode_bit :: proc(m: Render_Mode) -> i32 {
	return 1 << u32(m)
}

mesh_entity_init :: proc(type: Data_Mesh) -> Mesh_Entity {
	e := Mesh_Entity{ cube_face = .PX }
	e.transform = matrix_identity()

	assert(int(type) < int(Data_Mesh.COUNT))
	if type == .BOX {
		e.render_modes_mask = mode_bit(.LIT)
	} else if type >= .CUBE && type <= .CUBE_PZ {
		e.render_modes_mask = mode_bit(.LIT_SHADOWED) | mode_bit(.LIT_SHADOWED_FLIP)
		if type != .CUBE {
			e.render_modes_mask |= mode_bit(.REFLECTIVE)
			#partial switch type {
			case .CUBE_PX: e.cube_face = .PX
			case .CUBE_NX: e.cube_face = .NX
			case .CUBE_PY: e.cube_face = .PY
			case .CUBE_NY: e.cube_face = .NY
			case .CUBE_PZ: e.cube_face = .PZ
			case .CUBE_NZ: e.cube_face = .NZ
			}
		}
	} else {
		e.render_modes_mask = mode_bit(.LIT_SHADOWED) | mode_bit(.LIT_SHADOWED_FLIP) |
			mode_bit(.SHADOW_CASTER)
	}

	e.mesh = data_mesh(type)
	return e
}

mesh_entity_frustum_cull :: proc(e: ^Mesh_Entity, planes: ^[6]Plane) -> bool {
	return aabox_frustum_cull(e.mesh.total_aabb, e.transform, planes)
}

mesh_entity_render :: proc(e: ^Mesh_Entity, render_mode: Render_Mode, binds: ^sg.Bindings, planes: ^[6]Plane) {
	if e.render_modes_mask & mode_bit(render_mode) == 0 {
		return
	}

	if mesh_entity_frustum_cull(e, planes) {
		return
	}

	if render_mode == .REFLECTIVE {
		texs := [int(Cube_Face.COUNT)]sg.View{
			rt_refl_px.view_tex,
			rt_refl_nx.view_tex,
			rt_refl_py.view_tex,
			rt_refl_ny.view_tex,
			rt_refl_pz.view_tex,
			rt_refl_nz.view_tex,
		}
		binds.views[0] = texs[e.cube_face]
	}

	// the entity's world transform, as one uniform block
	sg.apply_uniforms(1, { ptr = &e.transform, size = size_of(Matrix4x4) })

	binds.vertex_buffers[0] = e.mesh.vb
	binds.index_buffer = e.mesh.ib
	sg.apply_bindings(binds^)
	sg.draw(0, e.mesh.index_count, 1)
}
