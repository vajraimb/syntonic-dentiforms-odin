//------------------------------------------------------------------------------
//  scene_teeth -- the last scene: two gears grind against each other, and
//  their teeth fly out; the port of src/demo/SceneTeeth.
//------------------------------------------------------------------------------
package main

import "core:fmt"
import "core:math"
import sg "sokol/gfx"

TOTAL_FRAMES :: 1500
PATH_FRAMES :: 200
BLOB_BLUR_PASSES :: 5

GEARS :: 2
TEETH_PACKS :: 4

// ------------------------------------
// One pack of teeth flying out: the curves of one .danim file, which are
// sampled ahead of time into whole flight paths.

Teeth_Anim :: struct {
	total_frames: int,
	start_frame:  int,
	end_frame:    int,
	anim:         ^Animation_Bunch,
	pos_anim:     ^Sampled_Animation,
	rot_anim:     ^Sampled_Animation,

	vectors:   []Vector3, // one per curve: the latest positions
	quats:     []Quaternion,
	teeth_idx: []int, // curve -> mesh index; -1 if the curve is no tooth
	paths:     [][PATH_FRAMES]Vector3, // curve -> its whole flight path
}

teeth_anim_init :: proc(animation: Data_Anim, start_frame, end_frame: int) -> Teeth_Anim {
	ta := Teeth_Anim{
		anim         = data_anim(animation),
		total_frames = TOTAL_FRAMES,
		start_frame  = start_frame,
		end_frame    = end_frame,
	}
	ta.pos_anim = bunch_find_anim(ta.anim, "pos", .VECTOR3)
	assert(ta.pos_anim != nil)
	ta.rot_anim = bunch_find_anim(ta.anim, "rot", .QUATERNION)
	assert(ta.rot_anim != nil)

	ncurves := len(ta.anim.curve_names)
	ta.teeth_idx = make([]int, ncurves)
	ta.vectors = make([]Vector3, ncurves)
	ta.quats = make([]Quaternion, ncurves)
	ta.paths = make([][PATH_FRAMES]Vector3, ncurves)
	for i in 0..<ncurves {
		ta.teeth_idx[i] = -1
	}

	// sample the whole path of every curve
	for i in 0..<PATH_FRAMES {
		a := f32(i) / f32(PATH_FRAMES)
		animation_sample(ta.pos_anim, a, 0, ncurves, &ta.vectors[0][0])
		for j in 0..<ncurves {
			ta.paths[j][i] = ta.vectors[j]
		}
	}
	return ta
}

teeth_anim_curve_count :: proc(ta: ^Teeth_Anim) -> int {
	return len(ta.anim.curve_names)
}

// Where t is in the pack's own time, 0..1; it can be before the pack starts.
teeth_anim_get_rel_time :: proc(ta: ^Teeth_Anim, t: f32) -> f32 {
	tframe := t * f32(ta.total_frames)
	return (tframe - f32(ta.start_frame)) / f32(ta.end_frame - ta.start_frame)
}

// Samples the pack at t. Returns true if t is before the pack starts.
teeth_anim_evaluate :: proc(ta: ^Teeth_Anim, t: f32) -> bool {
	reltime := teeth_anim_get_rel_time(ta, t)
	before := reltime < 0.0
	reltime = clampf(reltime)
	n := teeth_anim_curve_count(ta)
	animation_sample(ta.pos_anim, reltime, 0, n, &ta.vectors[0][0])
	animation_sample(ta.rot_anim, reltime, 0, n, &ta.quats[0].x)
	return before
}

teeth_anim_possibly_add_tooth :: proc(ta: ^Teeth_Anim, name: string, index: int) -> bool {
	idx := bunch_curve_index_by_name(ta.anim, name)
	if idx < 0 {
		return false
	}
	assert(ta.teeth_idx[idx] == -1)
	ta.teeth_idx[idx] = index
	return true
}

// ------------------------------------

scene_teeth_create :: proc(number: int) -> Scene {
	s := scene_create(.TEETH, number)
	s.anim_teeth[0] = teeth_anim_init(.S6_TEETH_A, 350, 480)
	s.anim_teeth[1] = teeth_anim_init(.S6_TEETH_B, 490, 590)
	s.anim_teeth[2] = teeth_anim_init(.S6_TEETH_C, 745, 860)
	s.anim_teeth[3] = teeth_anim_init(.S6_TEETH_D, 860, 965)
	s.anim_axes[0] = anim_init(.S6_AXES, "Axis1")
	s.anim_axes[1] = anim_init(.S6_AXES, "Axis2")
	return s
}

scene_teeth_initialize :: proc(s: ^Scene) {
	sd := &scene6
	s.length = int(sd.length)

	// create axes
	s.axes_idx[0] = s.mesh_count
	scene_add_static_mesh(s, .S6_AXIS1)
	s.axes_idx[1] = s.mesh_count
	scene_add_static_mesh(s, .S6_AXIS2)

	// create meshes
	tooth1_count := 0
	tooth2_count := 0
	for i in 0..<sd.count {
		e := &sd.entities[i]
		m := &s.meshes[s.mesh_count]
		m^ = {}
		m.parent = e.parent
		m.pos = e.pos
		m.rot = e.rot0 * (f32(math.PI) / 180.0)
		m.rot_vel = (e.rot1 - e.rot0) * (f32(s.length) * f32(math.PI) / 180.0)

		// teeth?
		if e.mesh == .S6_TOOTH1 || e.mesh == .S6_TOOTH2 {
			tooth_name: string
			if e.mesh == .S6_TOOTH1 {
				tooth_name = fmt.tprintf("Tooth1_%d", tooth1_count)
				tooth1_count += 1
			} else {
				tooth_name = fmt.tprintf("Tooth2_%d", tooth2_count)
				tooth2_count += 1
			}
			found := false
			for k in 0..<TEETH_PACKS {
				found = teeth_anim_possibly_add_tooth(&s.anim_teeth[k], tooth_name, s.mesh_count)
				if found {
					break
				}
			}
			assert(found)
		}
		// gear?
		if e.mesh == .S6_GEAR1 {
			s.gears_idx[0] = s.mesh_count
		} else if e.mesh == .S6_GEAR2 {
			s.gears_idx[1] = s.mesh_count
		}

		m.entity = mesh_entity_init(e.mesh)
		s.mesh_count += 1
		scene_to_matrix(m.pos, m.rot, &m.entity.transform)
	}
}

scene_teeth_evaluate_meshes :: proc(s: ^Scene, t: f32) {
	AXES_FRAMES :: 1100.0
	axest := t * (f32(TOTAL_FRAMES) / AXES_FRAMES)

	// eval axes & gears...
	for i in 0..<GEARS {
		// axis...
		anim_sample(&s.anim_axes[i], axest, &s.meshes[s.axes_idx[i]].entity.transform)

		// gear...
		mesh := &s.meshes[s.gears_idx[i]]
		// local transform
		rot := mesh.rot + mesh.rot_vel * t
		scene_to_matrix(mesh.pos, rot, &mesh.entity.transform)
		// into world space
		mesh.entity.transform = matrix_mul(mesh.entity.transform, s.meshes[s.axes_idx[i]].entity.transform)
	}

	// eval teeth...
	for i in 0..<TEETH_PACKS {
		ta := &s.anim_teeth[i]
		before := teeth_anim_evaluate(ta, t)
		for j in 0..<teeth_anim_curve_count(ta) {
			if ta.teeth_idx[j] < 0 {
				continue
			}
			mesh := &s.meshes[ta.teeth_idx[j]]
			if before {
				// attach to parent
				scene_to_matrix(mesh.pos, mesh.rot, &mesh.entity.transform)
				mesh.entity.transform = matrix_mul(mesh.entity.transform, s.meshes[s.gears_idx[mesh.parent]].entity.transform)
			} else {
				// animate
				mesh.entity.transform = matrix_from_pos_rot(ta.vectors[j], ta.quats[j])
			}
		}
	}
}

// Draws one tooth of the mask: scaled, and squashed along its Y axis.
draw_tooth_mask :: proc(mesh: ^Scene_Mesh, scale: f32, binds: ^sg.Bindings, mask_mesh: ^Mesh) {
	m := mesh.entity.transform
	axis_x(&m)^ = axis_x(&m)^ * scale
	axis_y(&m)^ = axis_y(&m)^ * (scale * scale * 0.5)
	axis_z(&m)^ = axis_z(&m)^ * scale
	sg.apply_uniforms(1, { ptr = &m, size = size_of(Matrix4x4) })
	sg.apply_bindings(binds^)
	sg.draw(0, mask_mesh.index_count, 1)
}

scene_teeth_render_bills :: proc(pack: int, rel_t: f32, cut_alpha: f32, masks: bool, aspect: f32) {
	BILLS_PER_PACK :: 3
	BSIZE :: 0.5
	BEDGE :: 0.12
	MEDGE :: 0.06

	// each pack flies out together with the greetings to three groups
	texnames := [TEETH_PACKS][BILLS_PER_PACK]Data_Texture{
		{ .DENT_A_TREPASA, .DENT_B_POKERO, .DENT_C_CORENJO },
		{ .DENT_D_SMOGENIAS, .DENT_E_CHAN_CHAN, .DENT_F_PERTO },
		{ .DENT_G_ZETAL, .DENT_H_LA_VINA, .DENT_I_CARINA },
		{ .DENT_A_TREPASA, .DENT_A_TREPASA, .DENT_A_TREPASA },
	}
	ratios := [TEETH_PACKS][BILLS_PER_PACK]f32{
		{ f32(576) / f32(576), f32(544) / f32(431), f32(436) / f32(394) },
		{ f32(524) / f32(514), f32(462) / f32(420), f32(479) / f32(434) },
		{ f32(380) / f32(360), f32(554) / f32(524), f32(396) / f32(372) },
		{ 1, 1, 1 },
	}
	// rectangles of the greetings image
	greet_uvs := [TEETH_PACKS][BILLS_PER_PACK][4]f32{
		{
			{ 0, 326, 640, 502 },   // Condense&Mandarine
			{ 742, 0, 924, 154 },   // FAN
			{ 0, 0, 394, 154 },     // Farbrausch
		},
		{
			{ 470, 154, 795, 320 }, // Haujobb
			{ 394, 0, 742, 154 },   // Kewlers
			{ 0, 154, 226, 320 },   // Kolor
		},
		{
			{ 795, 154, 989, 286 },  // MFX
			{ 226, 154, 470, 320 },  // Moppi
			{ 640, 326, 1017, 502 }, // All others
		},
		{
			{ 0, 0, 0, 0 },
			{ 0, 0, 0, 0 },
			{ 0, 0, 0, 0 },
		},
	}

	if pack != TEETH_PACKS - 1 {
		for i in 0..<BILLS_PER_PACK {
			bill_alpha: f32 = 3.0 - math.abs(cut_alpha - (f32(i) + 0.5) / f32(BILLS_PER_PACK)) * f32(BILLS_PER_PACK) * 6
			if masks {
				bill_alpha += 0.5
			}
			if bill_alpha <= 0.0 {
				continue
			}

			// tooth image
			bill := billboards_add()
			bill.x1 = 1.0 - BEDGE - BSIZE
			bill.y1 = -1.0 + BEDGE * aspect
			bill.x2 = bill.x1 + BSIZE
			bill.y2 = bill.y1 + BSIZE * aspect / ratios[pack][i]
			bill.texture = data_tex(texnames[pack][i]).view_tex
			c := to_rgba({ 1, 1, 1, bill_alpha })
			if masks {
				bill.x1 -= MEDGE
				bill.y1 -= MEDGE * aspect
				bill.x2 += MEDGE
				bill.y2 += MEDGE * aspect
			}
			bill.color = c
			bill.tu1, bill.tv1, bill.tu2, bill.tv2 = 0, 0, 1, 1

			// greets image
			TEXEL_SCALE :: 1.0 / 768.0
			uvs := &greet_uvs[pack][i]
			bill = billboards_add()
			bill.x1 = 1.0 - BEDGE * 0.5 - BSIZE - (uvs[2] - uvs[0]) * TEXEL_SCALE
			bill.y1 = -1.0 + BEDGE * aspect * 0.2
			bill.x2 = 1.0 - BEDGE * 0.5 - BSIZE
			bill.y2 = bill.y1 + (uvs[3] - uvs[1]) * TEXEL_SCALE * aspect
			bill.color = c
			bill.texture = data_tex(.GREETINGS).view_tex
			bill.tu1 = uvs[0] / 1024.0
			bill.tv1 = uvs[1] / 512.0
			bill.tu2 = uvs[2] / 1024.0
			bill.tv2 = uvs[3] / 512.0
			if masks {
				bill.x1 -= MEDGE
				bill.y1 -= MEDGE * aspect
				bill.x2 += MEDGE
				bill.y2 += MEDGE * aspect
			}
		}
	} else {
		// the last pack flies out together with the last picture
		GRP_WIDTH :: 0.8
		grp_height := GRP_WIDTH * aspect * f32(898) / f32(1050)
		bill := billboards_add()
		bill.x1 = -GRP_WIDTH / 2
		bill.y1 = -grp_height / 2
		bill.x2 = GRP_WIDTH / 2
		bill.y2 = grp_height / 2
		c := Vector4{ 1, 1, 1, 0.0 }
		if masks {
			bill.x1 -= MEDGE * 5
			bill.y1 -= MEDGE * 5 * aspect
			bill.x2 += MEDGE * 5
			bill.y2 += MEDGE * 5 * aspect
			scale := clampf((rel_t - 1.6) * 1.5)
			bill.x1 *= scale
			bill.y1 *= scale
			bill.x2 *= scale
			bill.y2 *= scale
			c.w = rel_t * 3
		} else {
			c.w = rel_t - 2
		}
		bill.color = to_rgba(c)
		bill.texture = data_tex(.BONDIGO_DUO).view_tex
		bill.tu1, bill.tv1, bill.tu2, bill.tv2 = 0, 0, 1, 1
	}

	pipeline_apply(masks ? .BILLBOARDS : .BILLBOARDS_CLEAR_DEST_ALPHA)
	billboards_render()
	billboards_clear()
}

// The flight paths of a pack's teeth, drawn as lines into the 3D scene.
scene_teeth_render_lines :: proc(s: ^Scene, pack: int, t: f32) {
	assert(pack >= 0 && pack < TEETH_PACKS)
	ta := &s.anim_teeth[pack]
	nteeth := teeth_anim_curve_count(ta)

	rel_t := teeth_anim_get_rel_time(ta, t)

	path: [PATH_FRAMES]Line_Point
	for i in 0..<nteeth {
		a := f32(0)
		da: f32 = 1.0 / f32(PATH_FRAMES)
		for j in 0..<PATH_FRAMES {
			path[j].pos = ta.paths[i][j]
			delta := a - rel_t
			if delta < 0.0 {
				delta *= 4
			}
			path[j].color = to_rgba({ 1.0, 0.0, 0.0, 0.75 - math.abs(delta) * 4 })
			a += da
		}
		pipeline_apply(.LINES)
		line_render_strip(PATH_FRAMES, path[:], 0.05)
	}
}

// In the middle of a cut: interrupts the pass that is going on, turns the
// scene into a toon drawing, and lets the teeth of the pack fly out.
scene_teeth_render_stuff :: proc(s: ^Scene, pack: int, t, cut_alpha, aspect: f32) {
	assert(pack >= 0 && pack < TEETH_PACKS)
	ta := &s.anim_teeth[pack]
	nteeth := teeth_anim_curve_count(ta)

	rel_t := teeth_anim_get_rel_time(ta, t)

	// end previous pass, apply toon post-processing
	sg.end_pass()
	{
		inputs := [2]sg.View{ rt_main_resolved.view_tex, data_tex(.COLOR_LUTS).view_tex }
		render_fullscreen_pass(.POST_TOON, "toon fx", rt_full_toon.view_rt, inputs[:], {})
	}

	// render teeth masks into 1/4th mask RT, to be blurred
	{
		pass: sg.Pass
		pass.label = "toon masks"
		pass.attachments.colors[0] = rt_4th_1.view_rt
		pass.action.colors[0].load_action = .CLEAR
		pass.action.colors[0].clear_value = { 0, 0, 0, 0 }
		pass.action.depth.load_action = .DONTCARE
		sg.begin_pass(pass)
	}

	tooth_mask_scale: f32 = 6.0
	SCALEUP_ALPHA :: 0.03
	if cut_alpha < SCALEUP_ALPHA {
		tooth_mask_scale *= cut_alpha / SCALEUP_ALPHA
	}
	if pack != TEETH_PACKS - 1 && cut_alpha > 1 - SCALEUP_ALPHA {
		tooth_mask_scale *= (1 - cut_alpha) / SCALEUP_ALPHA
	}

	pipeline_apply(.RENDER_WHITE)
	sg.apply_uniforms(0, { ptr = &g_global_u, size = size_of(Global_Uniforms) })

	binds: sg.Bindings
	tooth_mask_mesh := data_mesh(.S6_TOOTH1)
	binds.vertex_buffers[0] = tooth_mask_mesh.vb
	binds.index_buffer = tooth_mask_mesh.ib

	if tooth_mask_scale > 0.001 {
		if pack != TEETH_PACKS - 1 {
			for i in 0..<nteeth {
				draw_tooth_mask(&s.meshes[ta.teeth_idx[i]], tooth_mask_scale, &binds, tooth_mask_mesh)
			}
		} else {
			for pk in 0..<TEETH_PACKS {
				pack_anim := &s.anim_teeth[pk]
				for i in 0..<teeth_anim_curve_count(pack_anim) {
					draw_tooth_mask(&s.meshes[pack_anim.teeth_idx[i]], tooth_mask_scale, &binds, tooth_mask_mesh)
				}
			}
		}
	}
	scene_teeth_render_bills(pack, rel_t, cut_alpha, true, aspect)

	sg.end_pass()

	ping_pong_blur(BLOB_BLUR_PASSES)

	// composite
	{
		last := (BLOB_BLUR_PASSES & 1) != 0 ? rt_4th_2.view_tex : rt_4th_1.view_tex
		inputs := [3]sg.View{ rt_full_toon.view_tex, last, data_tex(.ALPHA_EDGE).view_tex }
		render_fullscreen_pass(
			.POST_COMPOSE_TOON, "toon compose",
			rt_main_resolved.view_rt, inputs[:], {},
			RPF_Load_RenderTarget | RPF_DoNot_End_Pass,
		)
	}
}

// On top of the toon drawing: the teeth and the greetings, in 2D.
scene_teeth_render_ui :: proc(s: ^Scene, pack: int, t, cut_alpha, aspect: f32) {
	assert(pack >= 0 && pack < TEETH_PACKS)
	ta := &s.anim_teeth[pack]
	scene_teeth_render_bills(pack, teeth_anim_get_rel_time(ta, t), cut_alpha, false, aspect)
}
