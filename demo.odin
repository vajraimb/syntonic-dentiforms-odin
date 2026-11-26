//------------------------------------------------------------------------------
//  demo -- the demo itself: its timeline and its rendering, the port of
//  src/demo/Demo.
//
//  The demo alternates between the "outer" scene, a flight around a room of
//  boxes, and six "inner" scenes of gears, seen from up close. Every now and
//  then it pauses on a "cut" to show a line of the credits.
//------------------------------------------------------------------------------
package main

import "core:fmt"
import "core:math"
import sg   "sokol/gfx"
import sapp "sokol/app"
import sdtx "sokol/debugtext"
import stm  "sokol/time"

Play_Mode :: enum int {
	MUSIC,   // play music, timing from that
	CAPTURE, // render at 60FPS, timing as if with music, save screenshots
	DEBUG,   // no playback, manual frame/time control with keyboard
}

g_play_mode: Play_Mode

// The action starts a moment after the music does.
DELAY_ACTION :: 0.25

// The demo time, in seconds.
demo_time :: proc() -> f64 {
	#partial switch g_play_mode {
	case .MUSIC:
		return vorbis_player_get_time(g_music_player) + DELAY_ACTION
	case .CAPTURE:
		return f64(g_captured_frames) / 60.0 + DELAY_ACTION
	case .DEBUG:
		return g_debug_time
	}
	return 0
}

demo_delay :: proc() -> f64 {
	return g_play_mode == .DEBUG ? 0.0 : DELAY_ACTION
}

// --------------------------------------------------------------------------

g_music_player: ^Vorbis_Player

g_debug_time: f64 // DEBUG: the time the keys move
g_captured_frames: int // CAPTURE: frames rendered so far
g_capture_frames: [dynamic]int // CAPTURE: the frames to save, in order
g_capture_next: int // CAPTURE: the next of those to save

Scene_Mode :: enum int {
	OUTER = 0,
	SCENE,
}

OUT_SECTIONS := [SCENES + 1]f32{ 0, 255, 473, 653, 939, 1150, 1350 }

g_scene_out: Scene
g_scenes: [SCENES]Scene

g_scene_mode: Scene_Mode
g_scene_index: int // scene/section
g_scene_start_time: f32 // start time of the current scene/section

// current scene cuts
Scene_Cut :: struct {
	last_done:       f32, // last completed cut time
	done_count:      int, // completed cuts count
	curr:            f32, // current cut time, or -1 if no cut
	start_time:      f64, // current cut start time, or -1 if no cut
	scene_start_time: f64,
	duration:        f32, // current cut duration, or -1 if no cut
}

scene_cut_reset :: proc(c: ^Scene_Cut) {
	c.last_done = -1.0
	c.done_count = 0
	c.curr = -1.0
	c.start_time = -1.0
	c.scene_start_time = -1.0
	c.duration = -1.0
}

scene_cut_is_in_cut :: proc(c: ^Scene_Cut) -> bool {
	return c.start_time >= 0
}

g_cut: Scene_Cut

// --------------------------------------------------------------------------

// camera
g_camera: Camera_Entity
g_camera_view_proj_matrix: Matrix4x4
// light
g_light_view_proj_matrix: Matrix4x4
g_light_camera: Camera_Entity
// reflective walls
g_wall_meshes: [int(Cube_Face.COUNT)]^Mesh_Entity
g_wall_data := [int(Cube_Face.COUNT)]Data_Mesh{ .CUBE_PX, .CUBE_NX, .CUBE_PY, .CUBE_NY, .CUBE_PZ, .CUBE_NZ }
g_wall_camera: Camera_Entity

// post-processing fx
g_overlay_color: Vector4
g_overlay_color2: Vector4

// synch anim
g_anim_synch: Anim

// --------------------------------------------------------------------------

demo_init :: proc() -> bool {
	// samplers
	s_smp_linear_repeat = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u = .REPEAT,
		wrap_v = .REPEAT,
	})
	s_smp_linear_clamp = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
	})
	s_smp_shadow = sg.make_sampler({
		min_filter = .LINEAR,
		mag_filter = .LINEAR,
		wrap_u = .CLAMP_TO_EDGE,
		wrap_v = .CLAMP_TO_EDGE,
		compare = .LESS,
	})

	dynamic_vb_init()
	line_renderer_init()

	// RTs
	ensure_render_targets()

	// preload
	if !load_data_files() {
		return false
	}
	pipelines_init()

	// synch
	g_anim_synch = anim_init(.SYNCH, "BeatBox", ANIM_POSITION)

	// scenes
	g_scene_out = scene_create(.OUTER, 0)
	scene_initialize(&g_scene_out)
	for s in 0..<SCENES {
		if s == SCENES - 1 {
			g_scenes[s] = scene_teeth_create(s + 1)
		} else {
			g_scenes[s] = scene_create(.NORMAL, s + 1)
		}
		scene_initialize(&g_scenes[s])
		scene_add_static_mesh(&g_scenes[s], .CUBE)
		for i in 0..<int(Cube_Face.COUNT) {
			g_wall_meshes[i] = scene_add_static_mesh(&g_scenes[s], g_wall_data[i])
		}
	}

	scene_add_cut(&g_scene_out, 110)
	scene_add_cut(&g_scene_out, 160)
	scene_add_cut(&g_scene_out, 220)

	scene_add_cut(&g_scenes[1], 218)
	scene_add_cut(&g_scenes[2], 188)
	scene_add_cut(&g_scenes[2], 311)
	scene_add_cut(&g_scenes[3], 259)
	scene_add_cut(&g_scenes[4], 154)

	scene_add_cut(&g_scenes[5], 351)
	scene_add_cut(&g_scenes[5], 493)
	scene_add_cut(&g_scenes[5], 748)
	scene_add_cut(&g_scenes[5], 865)

	g_scene_mode = .OUTER
	g_scene_index = 0

	#partial switch g_play_mode {
	case .MUSIC:
		g_music_player = vorbis_player_create()
		vorbis_player_play(g_music_player, "data/music.ogg")
		g_scene_start_time = f32(demo_time() - DELAY_ACTION)
	case .DEBUG:
		g_scene_mode = .SCENE
		g_scene_index = 5
		g_scene_start_time = -15.0
	case .CAPTURE:
	}

	scene_cut_reset(&g_cut)

	return true
}

reflect_matrix :: proc(out: ^Matrix4x4, p: Plane) {
	n := plane_normalize(p)

	out^ = matrix_identity()
	out[0][0] = 1.0 - 2.0 * n.a * n.a
	out[0][1] = -2.0 * n.a * n.b
	out[0][2] = -2.0 * n.a * n.c
	out[1][0] = -2.0 * n.a * n.b
	out[1][1] = 1.0 - 2.0 * n.b * n.b
	out[1][2] = -2.0 * n.b * n.c
	out[2][0] = -2.0 * n.c * n.a
	out[2][1] = -2.0 * n.c * n.b
	out[2][2] = 1.0 - 2.0 * n.c * n.c
	out[3][0] = -2.0 * n.d * n.a
	out[3][1] = -2.0 * n.d * n.b
	out[3][2] = -2.0 * n.d * n.c
}

// The room is a cube; this renders what each of its six walls reflects.
render_wall_reflections :: proc() {
	assert(g_scene_mode == .SCENE)
	plane_pos := [int(Cube_Face.COUNT)]Vector3{
		{ 10, 0, 0 },
		{ -10, 0, 0 },
		{ 0, 10, 0 },
		{ 0, -10, 0 },
		{ 0, 0, 10 },
		{ 0, 0, -10 },
	}
	plane_nrm := [int(Cube_Face.COUNT)]Vector3{
		{ -1, 0, 0 },
		{ 1, 0, 0 },
		{ 0, -1, 0 },
		{ 0, 1, 0 },
		{ 0, 0, -1 },
		{ 0, 0, 1 },
	}
	// in the order of the cube faces
	resolve_views := [int(Cube_Face.COUNT)]sg.View{
		rt_refl_px.view_resolve,
		rt_refl_nx.view_resolve,
		rt_refl_py.view_resolve,
		rt_refl_ny.view_resolve,
		rt_refl_pz.view_resolve,
		rt_refl_nz.view_resolve,
	}

	frustum_planes: [6]Plane
	extract_frustum_planes(g_camera_view_proj_matrix, &frustum_planes)

	for curr_wall in 0..<int(Cube_Face.COUNT) {
		if mesh_entity_frustum_cull(g_wall_meshes[curr_wall], &frustum_planes) {
			continue
		}

		refl_plane := plane(plane_pos[curr_wall] + plane_nrm[curr_wall] * 0.05, plane_nrm[curr_wall])
		reflect: Matrix4x4
		reflect_matrix(&reflect, refl_plane)

		g_wall_camera.transform = matrix_mul(g_camera.transform, reflect)
		camera_set_proj_from(&g_wall_camera, &g_camera)
		camera_set_onto_render_context(&g_wall_camera)
		g_compute_texture_projection(g_render_cam.camera_matrix, g_light_view_proj_matrix, &g_global_u.mat_shadow_proj)

		pass: sg.Pass
		pass.label = "reflection"
		pass.attachments.depth_stencil = rt_refl_z.view_z
		pass.attachments.colors[0] = rt_refl_rt.view_rt
		pass.attachments.resolves[0] = resolve_views[curr_wall]
		pass.action.colors[0].store_action = .STORE
		pass.action.colors[0].load_action = .CLEAR
		pass.action.colors[0].clear_value = { 0, 0, 0, 1 }
		pass.action.depth.load_action = .CLEAR
		pass.action.depth.clear_value = 1.0
		sg.begin_pass(pass)

		binds: sg.Bindings
		binds.views[0] = rt_shadow_z.view_tex
		binds.views[1] = data_tex(.SPOT_LIGHT).view_tex
		binds.samplers[0] = s_smp_shadow
		binds.samplers[1] = s_smp_linear_clamp
		scene_render(&g_scenes[g_scene_index], .LIT_SHADOWED_FLIP, &binds)

		sg.end_pass()
	}
}

render_shadow_map :: proc() {
	assert(g_scene_mode == .SCENE)

	camera_set_projection_params(&g_light_camera, f32(math.PI) / 3, 1.0, 0.2, 35.0)
	camera_set_onto_render_context(&g_light_camera)
	g_light_view_proj_matrix = g_render_cam.view_proj_matrix

	pass: sg.Pass
	pass.label = "shadow caster"
	pass.attachments.depth_stencil = rt_shadow_z.view_z
	pass.action.colors[0].store_action = .DONTCARE
	pass.action.colors[0].load_action = .DONTCARE
	pass.action.depth.load_action = .CLEAR
	pass.action.depth.store_action = .STORE
	pass.action.depth.clear_value = 1.0

	sg.begin_pass(pass)
	binds: sg.Bindings
	scene_render(&g_scenes[g_scene_index], .SHADOW_CASTER, &binds)
	sg.end_pass()
}

scene_duration :: proc() -> f32 {
	assert(g_scene_index >= 0 && g_scene_index < SCENES)
	if g_scene_mode == .OUTER {
		frames_per_sec: f32 = g_scene_index == 0 ? 48.0 : 56.0
		sec_len := OUT_SECTIONS[g_scene_index + 1] - OUT_SECTIONS[g_scene_index]
		return sec_len / frames_per_sec
	}
	return f32(g_scenes[g_scene_index].length) / 24.0
}

is_last_cut :: proc() -> bool {
	return g_scene_mode == .SCENE &&
		g_scene_index == SCENES - 1 &&
		scene_cut_is_in_cut(&g_cut) &&
		g_cut.done_count == g_scenes[g_scene_index].cut_count - 1
}

// While the demo is paused on a cut, a line of the credits flies in: a red
// line across the screen, and the text on both sides of it.
render_credits :: proc(cut_alpha: f32) {
	outer := g_scene_mode == .OUTER

	billboards_clear()

	FLY_ALPHA :: 0.3
	CENTER_X: f32 = outer ? -0.02 : -0.2
	TOP_Y: f32 = outer ? 0.6 : 0.7
	HEIGHT: f32 = outer ? 0.09 + f32(g_cut.done_count) * 0.02 : 0.15
	ASPECT := screen_widthf() / screen_heightf()
	UV_HEIGHT: f32 = outer ? 80.0 / 512.0 : 96.0 / 512.0
	WIDTH := HEIGHT / ASPECT * (outer ? f32(850) / f32(64) : f32(512) / f32(96))

	line := 0
	if !outer {
		line = g_scene_index - 1
		if g_cut.done_count > 0 || g_scene_index > 2 {
			line += 1
		}
	} else {
		line = g_cut.done_count
	}

	line_width := g_camera.znear * 0.026 * HEIGHT

	edge_dist_x := f32(0)
	if cut_alpha < FLY_ALPHA {
		edge_dist_x = FLY_ALPHA - cut_alpha
	} else if cut_alpha > 1 - FLY_ALPHA {
		edge_dist_x = ((1 - FLY_ALPHA) - cut_alpha) * 1.5
	}
	edge_dist_x *= 2.0
	edge_dist_x = edge_dist_x * math.abs(edge_dist_x)

	//
	// lines...

	LINE_PTS :: 200
	SLOPEEND_X := CENTER_X - 0.03 / ASPECT
	SLOPE_X: f32 = 0.06 / ASPECT
	RISE_Y := HEIGHT * f32(22) / f32(96)
	LINE_Y := TOP_Y + HEIGHT * (outer ? f32(61) / f32(80) : f32(59) / f32(96))
	LINE_FLY_ALPHA :: f32(0.3) * f32(0.7)

	linepts: [LINE_PTS]Line_Point
	for i in 0..<LINE_PTS {
		pt_x := f32(i) / f32(LINE_PTS - 1) * 2 - 1
		pt_y := LINE_Y
		if pt_x > SLOPEEND_X {
			pt_y -= RISE_Y
		} else if pt_x > SLOPEEND_X - SLOPE_X {
			pt_y -= RISE_Y * (pt_x - SLOPEEND_X + SLOPE_X) / SLOPE_X
		}

		linepts[i].pos = origin(&g_camera.transform)^ + camera_world_ray(&g_camera, pt_x, pt_y) * (g_camera.znear * 1.01)
		pt_a := f32(0)
		if cut_alpha > LINE_FLY_ALPHA && cut_alpha < 1 - LINE_FLY_ALPHA {
			sub_alpha := (cut_alpha - LINE_FLY_ALPHA) / (1 - LINE_FLY_ALPHA * 2)
			sub_center_x := sub_alpha * 2 - 1
			sub_center_x *= math.abs(sub_center_x)
			sub_center_x -= (CENTER_X + SLOPEEND_X) / 2
			pt_a = 1.0
			dist := math.abs(pt_x - sub_center_x)
			if dist > 0.6 {
				pt_a = 1.0 - (dist - 0.6) * 3
			}
		}
		linepts[i].color = to_rgba({ 1, 0, 0, pt_a })
	}
	pipeline_apply(.LINES_NO_AA)
	line_render_strip(LINE_PTS, linepts[:], line_width)

	//
	// bills...

	btex := data_tex(outer ? .CREDITS_B : .CREDITS_A)
	BILLCOUNT :: 16
	BILLCOL :: 0x18ffffff
	SECOND_BILL_LOWER: f32 = outer ? HEIGHT * 0.33 : 0.0

	for i in 0..<BILLCOUNT {
		edge_bill := edge_dist_x * (1.0 + f32(i) / f32(BILLCOUNT) * 0.5)

		// left...
		b := billboards_add()
		b.x1 = CENTER_X - edge_bill - WIDTH
		b.y1 = TOP_Y
		b.x2 = b.x1 + WIDTH
		b.y2 = b.y1 + HEIGHT
		if outer {
			b.tu1 = 0.0
			b.tv1 = f32(line * 2) * UV_HEIGHT
			b.tu2 = 850.0 / 1024.0
			b.tv2 = f32(line * 2 + 1) * UV_HEIGHT
		} else {
			b.tu1 = 0.0
			b.tv1 = f32(line) * UV_HEIGHT
			b.tu2 = 0.5
			b.tv2 = f32(line + 1) * UV_HEIGHT
		}
		b.texture = btex.view_tex
		b.color = BILLCOL

		// right...
		b = billboards_add()
		b.x1 = CENTER_X + edge_bill
		b.y1 = TOP_Y + SECOND_BILL_LOWER
		b.x2 = b.x1 + WIDTH
		b.y2 = b.y1 + HEIGHT
		if outer {
			b.tu1 = 0.0
			b.tv1 = f32(line * 2 + 1) * UV_HEIGHT
			b.tu2 = 850.0 / 1024.0
			b.tv2 = f32(line * 2 + 2) * UV_HEIGHT
		} else {
			b.tu1 = 0.5
			b.tv1 = f32(line) * UV_HEIGHT
			b.tu2 = 1.0
			b.tv2 = f32(line + 1) * UV_HEIGHT
		}
		b.texture = btex.view_tex
		b.color = BILLCOL
	}

	pipeline_apply(.BILLBOARDS_CLEAR_DEST_ALPHA)
	billboards_render()
}

// Renders one frame. Returns false when the demo is over.
demo_update :: proc() -> bool {
	time0 := stm.now()
	screenshot_poll()
	ensure_render_targets()
	dynamic_vb_new_frame()

	t := demo_time()
	music_time := t - demo_delay()
	st := f32(t - f64(g_scene_start_time))
	scene_dur := scene_duration()

	billboards_clear()

	znear, zfar: f32 = 0.1, 50.0
	camfov := f32(math.PI) / 4

	//
	// current scene and scene's alpha

	scene: ^Scene
	scene_alpha: f32 = 0.0
	if g_scene_mode == .OUTER {
		scene = &g_scene_out
		a0 := OUT_SECTIONS[g_scene_index] / f32(g_scene_out.length)
		a1 := OUT_SECTIONS[g_scene_index + 1] / f32(g_scene_out.length)
		scene_alpha = st / scene_dur
		scene_alpha = a0 + (a1 - a0) * scene_alpha
	} else {
		scene = &g_scenes[g_scene_index]
		scene_alpha = st / scene_dur
	}

	//
	// cut-pauses, adjust scene alpha in them

	CUT_DUR :: 3.75
	if scene_cut_is_in_cut(&g_cut) {
		if !is_last_cut() {
			cut_dur := t - g_cut.start_time
			cut_alpha := f32(cut_dur / f64(g_cut.duration))
			scene_alpha = g_cut.curr + cut_alpha * 0.01
			g_scene_start_time = f32(g_cut.scene_start_time + cut_dur)
			if cut_dur >= f64(g_cut.duration) {
				sdur := scene_dur
				if g_scene_mode == .OUTER {
					sdur /= OUT_SECTIONS[1] / f32(g_scene_out.length)
				}
				g_scene_start_time -= (scene_alpha - g_cut.curr) * sdur
				g_cut.done_count += 1
				g_cut.last_done = g_cut.curr
				g_cut.start_time = -1.0
				g_cut.curr = -1.0
			}
		}
	} else {
		past_cut := scene_get_past_cut(scene, scene_alpha)
		if g_scene_mode == .OUTER && g_scene_index != 0 {
			past_cut = -1.0
		}
		if past_cut > g_cut.last_done {
			g_cut.start_time = t
			g_cut.curr = past_cut
			g_cut.duration = CUT_DUR
			if g_scene_index == SCENES - 1 {
				g_cut.duration *= 2.0
			}
			g_cut.scene_start_time = f64(g_scene_start_time)
		}
	}

	//
	// evaluate scene at alpha

	scene_evaluate(scene, scene_alpha, &g_light_camera.transform, &g_camera.transform)
	light_origin := origin(&g_light_camera.transform)^
	g_global_u.light_pos = { light_origin[0], light_origin[1], light_origin[2], 1.0 }
	light_axis_z := Vector3{ g_light_camera.transform[2][0], g_light_camera.transform[2][1], g_light_camera.transform[2][2] }
	g_global_u.light_dir = { light_axis_z[0], light_axis_z[1], light_axis_z[2], 1.0 }

	//
	// adjust z-ranges in outer scene

	if g_scene_mode == .OUTER {
		ext: f32 = 100.0
		camo := origin(&g_camera.transform)^
		cam_dist := length(camo)
		znear = cam_dist < ext + 0.1 ? 0.1 : cam_dist - ext
		zfar = cam_dist + ext
		camfov = f32(math.PI) / 5
	}

	//
	// render

	camera_set_projection_params(&g_camera, camfov, screen_widthf() / screen_heightf(), znear, zfar)

	if g_scene_mode != .OUTER {
		render_shadow_map()
		render_wall_reflections()
	}

	camera_set_onto_render_context(&g_camera)
	g_compute_texture_projection(g_render_cam.camera_matrix, g_render_cam.view_proj_matrix, &g_global_u.mat_view_tex_proj)
	g_compute_texture_projection(g_render_cam.camera_matrix, g_light_view_proj_matrix, &g_global_u.mat_shadow_proj)
	g_camera_view_proj_matrix = g_render_cam.view_proj_matrix


	// Begin main MSAA 3D rendering pass
	{
		pass: sg.Pass
		pass.label = "main"
		pass.attachments.colors[0] = rt_main_aa.view_rt
		pass.attachments.depth_stencil = rt_main_z.view_z
		pass.attachments.resolves[0] = rt_main_resolved.view_resolve
		pass.action.colors[0].load_action = .CLEAR
		pass.action.colors[0].clear_value = { 0, 0, 0, 0 }
		pass.action.depth.load_action = .CLEAR
		pass.action.depth.clear_value = 1.0
		sg.begin_pass(pass)
	}

	binds: sg.Bindings
	if g_scene_mode != .OUTER {
		binds.views[0] = rt_shadow_z.view_tex
		binds.views[1] = data_tex(.SPOT_LIGHT).view_tex
		binds.samplers[0] = s_smp_shadow
		binds.samplers[1] = s_smp_linear_clamp
		scene_render(&g_scenes[g_scene_index], .LIT_SHADOWED, &binds)

		binds.samplers[0] = s_smp_linear_clamp
		scene_render(&g_scenes[g_scene_index], .REFLECTIVE, &binds)

		// last scene teeth lines
		if scene_cut_is_in_cut(&g_cut) && g_scene_index == SCENES - 1 {
			scene_teeth_render_lines(&g_scenes[g_scene_index], g_cut.done_count, scene_alpha)
		}
	} else {
		scene_render(&g_scene_out, .LIT, &binds)
	}

	// End main 3D MSAA rendering; resolves into rt_main_resolved.
	// Start render pass into that, without depth buffer.
	sg.end_pass()
	{
		pass: sg.Pass
		pass.label = "main resolved"
		pass.attachments.colors[0] = rt_main_resolved.view_rt
		pass.action.colors[0].load_action = .LOAD
		pass.action.depth.load_action = .DONTCARE
		pass.action.depth.clear_value = 1.0
		sg.begin_pass(pass)
	}

	//
	// render credits

	if scene_cut_is_in_cut(&g_cut) && g_scene_index != SCENES - 1 {
		cut_alpha := f32((t - g_cut.start_time) / f64(g_cut.duration))
		render_credits(cut_alpha)
	}

	{
		//
		// overlay for beats...

		SYNCH_LEN :: 6361.0
		OVERSAMPLE :: 1.0 / 6361.0
		synt := music_time / (SYNCH_LEN / 30.0)
		beat_pos0, beat_pos1, beat_pos2: Vector3
		anim_sample_pos(&g_anim_synch, f32(synt - OVERSAMPLE), &beat_pos0)
		anim_sample_pos(&g_anim_synch, f32(synt), &beat_pos1)
		anim_sample_pos(&g_anim_synch, f32(synt + OVERSAMPLE), &beat_pos2)
		beat := (beat_pos0[1] + beat_pos1[1] + beat_pos2[1]) * 0.08
		beat = clampf(beat)
		g_overlay_color2 = { beat, beat, beat, beat }
		if beat > 0.001 {
			pipeline_apply(.OVERLAY2)
			sg.apply_uniforms(0, { ptr = &g_overlay_color2, size = size_of(Vector4) })
			sg.draw(0, 3, 1)
		}
	}

	//
	// overlay for scene/cut transitions

	OVERLAY_DUR :: 0.3
	g_overlay_color = { 0, 0, 0, 0 }
	if scene_dur - st < OVERLAY_DUR {
		g_overlay_color.w = 1.0 - (scene_dur - st) / OVERLAY_DUR
	} else if st < OVERLAY_DUR {
		g_overlay_color.w = 1.0 - st / OVERLAY_DUR
	}

	// overlay for cuts...
	OVERLAY_CUT_DUR :: 0.17
	OVERLAY_CUT_HALF :: OVERLAY_CUT_DUR * 0.5
	if scene_cut_is_in_cut(&g_cut) {
		cut_time := f32(t - g_cut.start_time)

		if g_scene_index == SCENES - 1 {
			steeth := &g_scenes[g_scene_index]
			aspect := screen_widthf() / screen_heightf()
			cut_alpha := cut_time / g_cut.duration
			scene_teeth_render_stuff(steeth, g_cut.done_count, scene_alpha, cut_alpha, aspect)
			scene_teeth_render_ui(steeth, g_cut.done_count, scene_alpha, cut_alpha, aspect)
		}

		if cut_time < OVERLAY_CUT_DUR {
			g_overlay_color.w = 1.0 - math.abs((cut_time - OVERLAY_CUT_HALF) / OVERLAY_CUT_HALF)
		} else if g_cut.duration - cut_time < OVERLAY_CUT_DUR && !is_last_cut() {
			g_overlay_color.w = 1.0 - math.abs((g_cut.duration - cut_time - OVERLAY_CUT_HALF) / OVERLAY_CUT_HALF)
		}
		g_overlay_color.w *= 0.5
	}

	g_overlay_color.w = clampf(g_overlay_color.w)
	if g_overlay_color.w > 0.001 {
		pipeline_apply(.OVERLAY1)
		sg.apply_uniforms(0, { ptr = &g_overlay_color, size = size_of(Vector4) })
		sg.draw(0, 3, 1)
	}

	sg.end_pass()

	//
	// bloom

	render_bloom()

	//
	// manage scene transitions
	continue_exec := true

	if st >= scene_dur {
		if g_scene_mode == .OUTER {
			g_scene_mode = .SCENE
		} else {
			g_scene_mode = .OUTER
			g_scene_index += 1
			if g_scene_index >= SCENES {
				// end!
				g_scene_index = SCENES - 1
				continue_exec = false
			}
		}
		g_scene_start_time = f32(t)
		scene_cut_reset(&g_cut)
	}

	// show stats
	if s_display_stats {
		stats := sg.query_stats()

		sdtx.canvas(f32(screen_width()) / 2.0, f32(screen_height()) / 2.0)
		sdtx.font(0)
		sdtx.pos(1, 1)
		sdtx.printf("Perf: %.2fms frame, %.2fms cpu", s_time_frame_avg_ms, s_time_cpu_avg_ms)
		sdtx.pos(1, 2)
		sdtx.printf(
			"Draw: %i passes, %i draws, %.1fKB uniforms, %ix%i",
			stats.prev_frame.num_passes, stats.prev_frame.num_draw,
			f32(stats.prev_frame.size_apply_uniforms) / 1024.0,
			screen_width(), screen_height(),
		)
		sdtx.draw()
	}

	sg.end_pass()
	sg.commit()

	//
	// capture mode: save the frames that were asked for

	if g_play_mode == .CAPTURE {
		if g_capture_next < len(g_capture_frames) && g_capture_frames[g_capture_next] == g_captured_frames {
			screenshot_request(fmt.tprintf("capture%05d.tga", g_captured_frames))
			g_capture_next += 1
		}
		g_captured_frames += 1
		// the demo is over once everything asked for has been saved
		if g_capture_next >= len(g_capture_frames) && !screenshot_busy() {
			continue_exec = false
		}
	}

	// frame timing, for the stats
	time1 := stm.now()
	if s_time_frame_prev != 0 {
		s_time_frame_accum += time0 - s_time_frame_prev
		s_time_cpu_accum += time1 - time0
		s_time_frame_count += 1
		if stm.sec(s_time_frame_accum) > 0.5 {
			s_time_frame_avg_ms = f32(stm.ms(s_time_frame_accum) / f64(s_time_frame_count))
			s_time_cpu_avg_ms = f32(stm.ms(s_time_cpu_accum) / f64(s_time_frame_count))
			s_time_frame_accum, s_time_cpu_accum = 0, 0
			s_time_frame_count = 0
		}
	}
	s_time_frame_prev = time0

	return continue_exec
}

s_display_stats: bool
s_time_frame_accum, s_time_cpu_accum, s_time_frame_prev: u64
s_time_frame_count: int
s_time_frame_avg_ms, s_time_cpu_avg_ms: f32

demo_shutdown :: proc() {
	if g_music_player != nil {
		vorbis_player_destroy(g_music_player)
		g_music_player = nil
	}

	destroy_render_targets()

	dynamic_vb_shutdown()
	line_renderer_destroy()
}

demo_event :: proc(evt: ^sapp.Event) {
	if evt.type == .KEY_DOWN {
		if g_play_mode == .DEBUG {
			dt: f32 = 1.0 / 60.0 // one frame
			#partial switch evt.key_code {
			case .LEFT:
				g_debug_time -= f64(dt)
			case .RIGHT:
				g_debug_time += f64(dt)
			case .PAGE_UP:
				g_debug_time -= f64(dt * 5.0)
			case .PAGE_DOWN:
				g_debug_time += f64(dt * 5.0)
			case ._1:
				debug_jump_to_scene(1)
			case ._2:
				debug_jump_to_scene(2)
			case ._3:
				debug_jump_to_scene(3)
			case ._4:
				debug_jump_to_scene(4)
			case ._5:
				debug_jump_to_scene(5)
			case .SPACE:
				if !s_space_down {
					g_debug_time += 1.0
					s_space_down = true
				}
			case .F9:
				when SCREENSHOTS {
					s_shot_counter += 1
					screenshot_request(fmt.tprintf("shot%02d.tga", s_shot_counter))
				}
			}
		}
		if evt.key_code == .ESCAPE {
			sapp.quit()
		}
		if evt.key_code == .SLASH {
			s_display_stats = !s_display_stats
			if s_display_stats {
				sg.enable_stats()
			} else {
				sg.disable_stats()
			}
		}
	}
	if evt.type == .KEY_UP {
		if g_play_mode == .DEBUG && evt.key_code == .SPACE {
			s_space_down = false
		}
	}
}

s_space_down: bool
s_shot_counter: int

debug_jump_to_scene :: proc(n: int) {
	g_scene_index = n
	g_scene_mode = .SCENE
	g_scene_start_time = f32(g_debug_time) - 5.0
}
