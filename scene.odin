//------------------------------------------------------------------------------
//  scene -- gears and other meshes with a light and a camera, animated by
//  curves; the port of src/demo/Scene and src/demo/SceneOut.
//
//  The original has Scene as a base class, with SceneOut and SceneTeeth
//  deriving from it and overriding initialize() and evaluateMeshes(). Here a
//  scene knows its kind, and those two are a switch on it.
//------------------------------------------------------------------------------
package main

import "core:math"
import sg "sokol/gfx"

SCENES :: 6

SCENE_MAX_MESHES :: 64
SCENE_MAX_CUTS :: 16

Scene_Kind :: enum int {
	OUTER,  // the flight around the room, in between the scenes
	NORMAL, // the gears up close
	TEETH,  // the last scene, where the teeth fly out
}

Scene_Mesh :: struct {
	entity:  Mesh_Entity,
	pos:     Vector3,
	rot:     Vector3,
	rot_vel: Vector3, // over the whole animation
	parent:  int,     // index into the scene's meshes; -1 for none
}

Scene :: struct {
	kind:   Scene_Kind,
	number: int,

	meshes:     [SCENE_MAX_MESHES]Scene_Mesh,
	mesh_count: int,
	eval_order: [SCENE_MAX_MESHES]int, // depth-first order for the hierarchy
	eval_count: int,

	anim_light:  Anim,
	anim_camera: Anim,
	length:      int, // in frames

	cut_times: [SCENE_MAX_CUTS]f32, // 0..1
	cut_count: int,

	// only the teeth scene uses these
	anim_teeth: [TEETH_PACKS]Teeth_Anim,
	anim_axes:  [GEARS]Anim,
	axes_idx:   [GEARS]int,
	gears_idx:  [GEARS]int,
}

// @param number 0 for the outer scene, 1..6 for the others.
scene_create :: proc(kind: Scene_Kind, number: int) -> Scene {
	s := Scene{ kind = kind, number = number }
	anim := transmute(Data_Anim)(int(Data_Anim.ANIM0) + number)
	s.anim_light = anim_init(anim, "Light")
	s.anim_camera = anim_init(anim, "Camera")
	return s
}

scene_tables := [7]^Scene_Data{ nil, &scene1, &scene2, &scene3, &scene4, &scene5, &scene6 }

scene_data :: proc(number: int) -> ^Scene_Data {
	return scene_tables[number]
}

scene_initialize :: proc(s: ^Scene) {
	#partial switch s.kind {
	case .OUTER:
		scene_out_initialize(s)
	case .NORMAL:
		scene_initialize_hierarchy(s, scene_data(s.number))
	case .TEETH:
		scene_teeth_initialize(s)
	}
}

// The meshes from the scene's table, and the order to evaluate them in.
scene_initialize_hierarchy :: proc(s: ^Scene, sd: ^Scene_Data) {
	s.length = int(sd.length)

	for i in 0..<sd.count {
		e := &sd.entities[i]
		m := &s.meshes[s.mesh_count]
		m^ = {}
		m.parent = e.parent
		m.pos = e.pos
		m.rot = e.rot0 * (f32(math.PI) / 180.0)
		m.rot_vel = (e.rot1 - e.rot0) * (f32(s.length) * f32(math.PI) / 180.0)
		m.entity = mesh_entity_init(e.mesh)
		s.mesh_count += 1

		scene_to_matrix(m.pos, m.rot, &m.entity.transform)
	}

	// calculate hierarchy traversal order
	for i in 0..<s.mesh_count {
		if s.meshes[i].parent == -1 {
			scene_recurse_add(s, i)
		}
	}
}

scene_recurse_add :: proc(s: ^Scene, idx: int) {
	s.eval_order[s.eval_count] = idx
	s.eval_count += 1
	for i in 0..<s.mesh_count {
		if s.meshes[i].parent == idx {
			scene_recurse_add(s, i)
		}
	}
}

scene_add_static_mesh :: proc(s: ^Scene, data: Data_Mesh) -> ^Mesh_Entity {
	m := &s.meshes[s.mesh_count]
	m^ = {}
	m.entity = mesh_entity_init(data)
	m.parent = -1
	s.eval_order[s.eval_count] = s.mesh_count
	s.eval_count += 1
	s.mesh_count += 1
	return &m.entity
}

scene_to_matrix :: proc(pos, rot: Vector3, m: ^Matrix4x4) {
	mrx, mrz, mry: Matrix4x4
	matrix_rotation_x(&mrx, -rot[0])
	matrix_rotation_z(&mrz, -rot[1])
	matrix_rotation_y(&mry, -rot[2])
	m^ = matrix_mul(matrix_mul(mrx, mrz), mry)
	origin(m)^ = pos
}

scene_evaluate :: proc(s: ^Scene, t: f32, light: ^Matrix4x4, camera: ^Matrix4x4) {
	// eval light/camera
	scene_evaluate_light(s, t, light)
	scene_evaluate_camera(s, t, camera)

	// eval mesh transforms
	scene_evaluate_meshes(s, t)
}

scene_evaluate_camera :: proc(s: ^Scene, t: f32, camera: ^Matrix4x4) {
	mr: Matrix4x4
	anim_sample(&s.anim_camera, t, camera)
	matrix_rotation_x(&mr, f32(math.PI) / 2)
	camera^ = matrix_mul(mr, camera^)
}

scene_evaluate_light :: proc(s: ^Scene, t: f32, light: ^Matrix4x4) {
	mr: Matrix4x4
	anim_sample(&s.anim_light, t, light)
	matrix_rotation_x(&mr, f32(math.PI) / 2)
	light^ = matrix_mul(mr, light^)
}

scene_evaluate_meshes :: proc(s: ^Scene, t: f32) {
	#partial switch s.kind {
	case .NORMAL:
		scene_evaluate_hierarchy(s, t)
	case .TEETH:
		scene_teeth_evaluate_meshes(s, t)
	case .OUTER:
		// nothing moves out there
	}
}

scene_evaluate_hierarchy :: proc(s: ^Scene, t: f32) {
	for i in 0..<s.eval_count {
		m := &s.meshes[s.eval_order[i]]
		// local transform
		rot := m.rot + m.rot_vel * t
		scene_to_matrix(m.pos, rot, &m.entity.transform)
		// into world space
		if m.parent >= 0 {
			m.entity.transform = matrix_mul(m.entity.transform, s.meshes[m.parent].entity.transform)
		}
	}
}

scene_render :: proc(s: ^Scene, render_mode: Render_Mode, binds: ^sg.Bindings) {
	if s.mesh_count == 0 {
		return
	}

	#partial switch render_mode {
	case .LIT_SHADOWED:      pipeline_apply(.RENDER_LIT_SHADOWED)
	case .LIT_SHADOWED_FLIP: pipeline_apply(.RENDER_LIT_SHADOWED_FLIP)
	case .SHADOW_CASTER:     pipeline_apply(.SHADOW_CASTER)
	case .REFLECTIVE:        pipeline_apply(.RENDER_REFLECTIVE)
	case .LIT:               pipeline_apply(.RENDER_LIT)
	}

	sg.apply_uniforms(0, { ptr = &g_global_u, size = size_of(Global_Uniforms) })

	planes: [6]Plane
	extract_frustum_planes(g_render_cam.view_proj_matrix, &planes)
	for i in 0..<s.mesh_count {
		mesh_entity_render(&s.meshes[i].entity, render_mode, binds, &planes)
	}
}

scene_add_cut :: proc(s: ^Scene, frame: f32) {
	assert(s.cut_count < SCENE_MAX_CUTS)
	s.cut_times[s.cut_count] = frame / f32(s.length)
	s.cut_count += 1
}

// The time of the latest cut that t has passed, or -1.
scene_get_past_cut :: proc(s: ^Scene, t: f32) -> f32 {
	i := 0
	for i < s.cut_count {
		if s.cut_times[i] > t {
			break
		}
		i += 1
	}
	if i == 0 {
		return -1.0
	}
	return s.cut_times[i - 1]
}

// --------------------------------------------------------
// the outer scene: a room of 27 boxes

scene_out_initialize :: proc(s: ^Scene) {
	s.length = 1350

	// create meshes
	for ix in -1..=1 {
		for iy in -1..=1 {
			for iz in -1..=1 {
				m := scene_add_static_mesh(s, .BOX)
				o := origin(&m.transform)
				o[0] = f32(ix * 25)
				o[1] = f32(iy * 25)
				o[2] = f32(iz * 25)
			}
		}
	}
}
