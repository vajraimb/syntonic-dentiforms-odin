//------------------------------------------------------------------------------
//  anim -- a named curve of an animation file, sampled into a 4x4 transform.
//  The port of src/demo/Anim.
//------------------------------------------------------------------------------
package main

ANIM_POSITION :: 1 << 0
ANIM_ROTATION :: 1 << 1
ANIM_ALL :: ANIM_POSITION | ANIM_ROTATION

Anim :: struct {
	default_pos: Vector3,
	default_rot: Quaternion,
	pos_anim:    ^Sampled_Animation,
	rot_anim:    ^Sampled_Animation,
	curve:       int,
}

anim_init :: proc(animation: Data_Anim, curve: string, anims := ANIM_ALL) -> Anim {
	a := Anim{ default_rot = { 0, 0, 0, 1 } }
	ab := data_anim(animation)
	a.curve = bunch_curve_index_by_name(ab, curve)
	if anims & ANIM_POSITION != 0 {
		a.pos_anim = bunch_find_anim(ab, "pos", .VECTOR3)
	}
	if anims & ANIM_ROTATION != 0 {
		a.rot_anim = bunch_find_anim(ab, "rot", .QUATERNION)
	}
	return a
}

anim_sample :: proc(a: ^Anim, t: f32, dest: ^Matrix4x4) {
	pos: Vector3
	rot := Quaternion{ 0, 0, 0, 1 }

	if a.pos_anim != nil {
		animation_sample(a.pos_anim, t, a.curve, 1, &pos[0])
	} else {
		pos = a.default_pos
	}
	if a.rot_anim != nil {
		animation_sample(a.rot_anim, t, a.curve, 1, &rot.x)
	} else {
		rot = a.default_rot
	}

	dest^ = matrix_from_pos_rot(pos, rot)
}

anim_sample_pos :: proc(a: ^Anim, t: f32, dest: ^Vector3) {
	if a.pos_anim != nil {
		animation_sample(a.pos_anim, t, a.curve, 1, &dest[0])
	} else {
		dest^ = a.default_pos
	}
}

