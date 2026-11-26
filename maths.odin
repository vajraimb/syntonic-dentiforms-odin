//------------------------------------------------------------------------------
//  maths -- the demo's own small math library (src/math), ported as it is.
//
//  The conventions matter, the shaders and the data rely on them:
//  - Matrix4x4 is row-major, m[row][column], with the translation in row 3.
//  - Vectors are row vectors: a point is transformed as v * M, so in a product
//    a * b, a is applied first.
//  - The projection is left-handed, with depth in 0..1.
//------------------------------------------------------------------------------
package main

import "core:math"

Vector3 :: [3]f32
Matrix4x4 :: [4][4]f32

Vector4 :: struct {
	x, y, z, w: f32,
}

Quaternion :: struct {
	x, y, z, w: f32,
}

Plane :: struct {
	a, b, c, d: f32,
}

AABox :: struct {
	min, max: Vector3,
}

clampf :: proc(value: f32, vmin: f32 = 0, vmax: f32 = 1) -> f32 {
	if value < vmin {
		return vmin
	} else if value > vmax {
		return vmax
	}
	return value
}

// --------------------------------------------------------
// Vector3

length :: proc(v: Vector3) -> f32 {
	return math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2])
}

length_sq :: proc(v: Vector3) -> f32 {
	return v[0] * v[0] + v[1] * v[1] + v[2] * v[2]
}

dot :: proc(a, b: Vector3) -> f32 {
	return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

cross :: proc(a, b: Vector3) -> Vector3 {
	return {
		a[1] * b[2] - a[2] * b[1],
		a[2] * b[0] - a[0] * b[2],
		a[0] * b[1] - a[1] * b[0],
	}
}

// Scales v to unit length; a zero vector stays zero.
normalize :: proc(v: ^Vector3) {
	norm := length(v^)
	if norm != 0 {
		v^ = { v[0] / norm, v[1] / norm, v[2] / norm }
	} else {
		v^ = { 0, 0, 0 }
	}
}

get_normalized :: proc(v: Vector3) -> Vector3 {
	out := v
	normalize(&out)
	return out
}

// Transforms a point by a matrix and divides by w.
transform_coord :: proc(v: Vector3, pm: Matrix4x4) -> Vector3 {
	norm := pm[0][3] * v[0] + pm[1][3] * v[1] + pm[2][3] * v[2] + pm[3][3]
	return {
		(pm[0][0] * v[0] + pm[1][0] * v[1] + pm[2][0] * v[2] + pm[3][0]) / norm,
		(pm[0][1] * v[0] + pm[1][1] * v[1] + pm[2][1] * v[2] + pm[3][1]) / norm,
		(pm[0][2] * v[0] + pm[1][2] * v[1] + pm[2][2] * v[2] + pm[3][2]) / norm,
	}
}

// --------------------------------------------------------
// Matrix4x4

// The first three rows are the X, Y and Z axes, the last row the origin.
axis_x :: proc(m: ^Matrix4x4) -> ^Vector3 {
	return (^Vector3)(&m[0][0])
}

axis_y :: proc(m: ^Matrix4x4) -> ^Vector3 {
	return (^Vector3)(&m[1][0])
}

axis_z :: proc(m: ^Matrix4x4) -> ^Vector3 {
	return (^Vector3)(&m[2][0])
}

origin :: proc(m: ^Matrix4x4) -> ^Vector3 {
	return (^Vector3)(&m[3][0])
}

matrix_identify :: proc(m: ^Matrix4x4) {
	m[0][1], m[0][2], m[0][3] = 0, 0, 0
	m[1][0], m[1][2], m[1][3] = 0, 0, 0
	m[2][0], m[2][1], m[2][3] = 0, 0, 0
	m[3][0], m[3][1], m[3][2] = 0, 0, 0
	m[0][0], m[1][1], m[2][2], m[3][3] = 1, 1, 1, 1
}

matrix_identity :: proc() -> Matrix4x4 {
	m: Matrix4x4
	matrix_identify(&m)
	return m
}

matrix_mul :: proc(a, b: Matrix4x4) -> Matrix4x4 {
	out: Matrix4x4
	for i in 0..<4 {
		for j in 0..<4 {
			out[i][j] = a[i][0] * b[0][j] + a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j]
		}
	}
	return out
}

matrix_from_pos_rot :: proc(pos: Vector3, rot: Quaternion) -> Matrix4x4 {
	m := matrix_identity()
	m[0][0] = 1.0 - 2.0 * (rot.y * rot.y + rot.z * rot.z)
	m[0][1] = 2.0 * (rot.x * rot.y + rot.z * rot.w)
	m[0][2] = 2.0 * (rot.x * rot.z - rot.y * rot.w)
	m[1][0] = 2.0 * (rot.x * rot.y - rot.z * rot.w)
	m[1][1] = 1.0 - 2.0 * (rot.x * rot.x + rot.z * rot.z)
	m[1][2] = 2.0 * (rot.y * rot.z + rot.x * rot.w)
	m[2][0] = 2.0 * (rot.x * rot.z + rot.y * rot.w)
	m[2][1] = 2.0 * (rot.y * rot.z - rot.x * rot.w)
	m[2][2] = 1.0 - 2.0 * (rot.x * rot.x + rot.y * rot.y)
	origin(&m)^ = pos
	return m
}

matrix_perspective_fov_lh :: proc(m: ^Matrix4x4, fovy, aspect, zn, zf: f32) {
	matrix_identify(m)
	m[0][0] = 1.0 / (aspect * math.tan(fovy / 2.0))
	m[1][1] = 1.0 / math.tan(fovy / 2.0)
	m[2][2] = zf / (zf - zn)
	m[2][3] = 1.0
	m[3][2] = (zf * zn) / (zn - zf)
	m[3][3] = 0.0
}

matrix_ortho_lh :: proc(m: ^Matrix4x4, w, h, zn, zf: f32) {
	matrix_identify(m)
	m[0][0] = 2.0 / w
	m[1][1] = 2.0 / h
	m[2][2] = 1.0 / (zf - zn)
	m[3][2] = zn / (zn - zf)
}

matrix_rotation_x :: proc(m: ^Matrix4x4, angle: f32) {
	matrix_identify(m)
	m[1][1] = math.cos(angle)
	m[2][2] = math.cos(angle)
	m[1][2] = math.sin(angle)
	m[2][1] = -math.sin(angle)
}

matrix_rotation_y :: proc(m: ^Matrix4x4, angle: f32) {
	matrix_identify(m)
	m[0][0] = math.cos(angle)
	m[2][2] = math.cos(angle)
	m[0][2] = -math.sin(angle)
	m[2][0] = math.sin(angle)
}

matrix_rotation_z :: proc(m: ^Matrix4x4, angle: f32) {
	matrix_identify(m)
	m[0][0] = math.cos(angle)
	m[1][1] = math.cos(angle)
	m[0][1] = math.sin(angle)
	m[1][0] = -math.sin(angle)
}

// General purpose inverse; leaves the matrix unchanged if it is not invertible.
matrix_invert :: proc(m: ^Matrix4x4) {
	t: [3]f32
	v: [16]f32

	t[0] = m[2][2] * m[3][3] - m[2][3] * m[3][2]
	t[1] = m[1][2] * m[3][3] - m[1][3] * m[3][2]
	t[2] = m[1][2] * m[2][3] - m[1][3] * m[2][2]
	v[0] = m[1][1] * t[0] - m[2][1] * t[1] + m[3][1] * t[2]
	v[4] = -m[1][0] * t[0] + m[2][0] * t[1] - m[3][0] * t[2]

	t[0] = m[1][0] * m[2][1] - m[2][0] * m[1][1]
	t[1] = m[1][0] * m[3][1] - m[3][0] * m[1][1]
	t[2] = m[2][0] * m[3][1] - m[3][0] * m[2][1]
	v[8] = m[3][3] * t[0] - m[2][3] * t[1] + m[1][3] * t[2]
	v[12] = -m[3][2] * t[0] + m[2][2] * t[1] - m[1][2] * t[2]

	det := m[0][0] * v[0] + m[0][1] * v[4] + m[0][2] * v[8] + m[0][3] * v[12]
	if det == 0.0 {
		return
	}

	t[0] = m[2][2] * m[3][3] - m[2][3] * m[3][2]
	t[1] = m[0][2] * m[3][3] - m[0][3] * m[3][2]
	t[2] = m[0][2] * m[2][3] - m[0][3] * m[2][2]
	v[1] = -m[0][1] * t[0] + m[2][1] * t[1] - m[3][1] * t[2]
	v[5] = m[0][0] * t[0] - m[2][0] * t[1] + m[3][0] * t[2]

	t[0] = m[0][0] * m[2][1] - m[2][0] * m[0][1]
	t[1] = m[3][0] * m[0][1] - m[0][0] * m[3][1]
	t[2] = m[2][0] * m[3][1] - m[3][0] * m[2][1]
	v[9] = -m[3][3] * t[0] - m[2][3] * t[1] - m[0][3] * t[2]
	v[13] = m[3][2] * t[0] + m[2][2] * t[1] + m[0][2] * t[2]

	t[0] = m[1][2] * m[3][3] - m[1][3] * m[3][2]
	t[1] = m[0][2] * m[3][3] - m[0][3] * m[3][2]
	t[2] = m[0][2] * m[1][3] - m[0][3] * m[1][2]
	v[2] = m[0][1] * t[0] - m[1][1] * t[1] + m[3][1] * t[2]
	v[6] = -m[0][0] * t[0] + m[1][0] * t[1] - m[3][0] * t[2]

	t[0] = m[0][0] * m[1][1] - m[1][0] * m[0][1]
	t[1] = m[3][0] * m[0][1] - m[0][0] * m[3][1]
	t[2] = m[1][0] * m[3][1] - m[3][0] * m[1][1]
	v[10] = m[3][3] * t[0] + m[1][3] * t[1] + m[0][3] * t[2]
	v[14] = -m[3][2] * t[0] - m[1][2] * t[1] - m[0][2] * t[2]

	t[0] = m[1][2] * m[2][3] - m[1][3] * m[2][2]
	t[1] = m[0][2] * m[2][3] - m[0][3] * m[2][2]
	t[2] = m[0][2] * m[1][3] - m[0][3] * m[1][2]
	v[3] = -m[0][1] * t[0] + m[1][1] * t[1] - m[2][1] * t[2]
	v[7] = m[0][0] * t[0] - m[1][0] * t[1] + m[2][0] * t[2]

	v[11] = -m[0][0] * (m[1][1] * m[2][3] - m[1][3] * m[2][1]) +
		m[1][0] * (m[0][1] * m[2][3] - m[0][3] * m[2][1]) -
		m[2][0] * (m[0][1] * m[1][3] - m[0][3] * m[1][1])

	v[15] = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
		m[1][0] * (m[0][1] * m[2][2] - m[0][2] * m[2][1]) +
		m[2][0] * (m[0][1] * m[1][2] - m[0][2] * m[1][1])

	det = 1.0 / det
	for i in 0..<4 {
		for j in 0..<4 {
			m[i][j] = v[4 * i + j] * det
		}
	}
}

// --------------------------------------------------------
// Plane

plane :: proc(p, n: Vector3) -> Plane {
	return { n[0], n[1], n[2], -dot(p, n) }
}

plane_normalize :: proc(p: Plane) -> Plane {
	norm := math.sqrt(p.a * p.a + p.b * p.b + p.c * p.c)
	if norm != 0 {
		return { p.a / norm, p.b / norm, p.c / norm, p.d / norm }
	}
	return { 0, 0, 0, 0 }
}

// --------------------------------------------------------
// Quaternion

quat_dot :: proc(a, b: Quaternion) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
}

quat_slerp :: proc(out: ^Quaternion, a, b: Quaternion, t_in: f32) {
	temp: f32 = 1.0 - t_in
	t := t_in
	d := quat_dot(a, b)
	if d < 0.0 {
		t = -t
		d = -d
	}

	if 1.0 - d > 0.001 {
		theta := math.acos(d)
		temp = math.sin(theta * temp) / math.sin(theta)
		t = math.sin(theta * t) / math.sin(theta)
	}

	out^ = {
		temp * a.x + t * b.x,
		temp * a.y + t * b.y,
		temp * a.z + t * b.z,
		temp * a.w + t * b.w,
	}
}

// --------------------------------------------------------
// AABox

BIG_FLOAT :: f32(1.0e30)

aabox_null :: proc() -> AABox {
	return { { BIG_FLOAT, BIG_FLOAT, BIG_FLOAT }, { -BIG_FLOAT, -BIG_FLOAT, -BIG_FLOAT } }
}

aabox_extend :: proc(b: ^AABox, p: Vector3) {
	if p[0] < b.min[0] {
		b.min[0] = p[0]
	}
	if p[1] < b.min[1] {
		b.min[1] = p[1]
	}
	if p[2] < b.min[2] {
		b.min[2] = p[2]
	}
	if p[0] > b.max[0] {
		b.max[0] = p[0]
	}
	if p[1] > b.max[1] {
		b.max[1] = p[1]
	}
	if p[2] > b.max[2] {
		b.max[2] = p[2]
	}
}

// Culls this AABB, transformed by the given world transform, against frustum planes
// (extracted from the view*projection matrix).
aabox_frustum_cull :: proc(b: AABox, world: Matrix4x4, planes: ^[6]Plane) -> bool {
	// OBB center in world space
	center := (b.min + b.max) * 0.5
	cw := Vector3{
		center[0] * world[0][0] + center[1] * world[1][0] + center[2] * world[2][0] + world[3][0],
		center[0] * world[0][1] + center[1] * world[1][1] + center[2] * world[2][1] + world[3][1],
		center[0] * world[0][2] + center[1] * world[1][2] + center[2] * world[2][2] + world[3][2],
	}
	// OBB half extents
	h := (b.max - b.min) * 0.5
	ax_x := Vector3{ world[0][0], world[0][1], world[0][2] }
	ax_y := Vector3{ world[1][0], world[1][1], world[1][2] }
	ax_z := Vector3{ world[2][0], world[2][1], world[2][2] }

	for i in 0..<6 {
		p := &planes[i]
		n := Vector3{ p.a, p.b, p.c }
		dc := dot(n, cw) + p.d
		// OBB support radius along n
		r := h[0] * math.abs(dot(n, ax_x)) + h[1] * math.abs(dot(n, ax_y)) + h[2] * math.abs(dot(n, ax_z))
		if dc < -r {
			return true
		}
	}
	return false
}

extract_frustum_planes :: proc(view_proj: Matrix4x4, planes: ^[6]Plane) {
	vp := view_proj
	planes[0] = { vp[0][0] + vp[0][3], vp[1][0] + vp[1][3], vp[2][0] + vp[2][3], vp[3][0] + vp[3][3] } // left
	planes[1] = { vp[0][3] - vp[0][0], vp[1][3] - vp[1][0], vp[2][3] - vp[2][0], vp[3][3] - vp[3][0] } // right
	planes[2] = { vp[0][1] + vp[0][3], vp[1][1] + vp[1][3], vp[2][1] + vp[2][3], vp[3][1] + vp[3][3] } // bottom
	planes[3] = { vp[0][3] - vp[0][1], vp[1][3] - vp[1][1], vp[2][3] - vp[2][1], vp[3][3] - vp[3][1] } // top
	planes[4] = { vp[0][2], vp[1][2], vp[2][2], vp[3][2] }                                             // near
	planes[5] = { vp[0][3] - vp[0][2], vp[1][3] - vp[1][2], vp[2][3] - vp[2][2], vp[3][3] - vp[3][2] } // far
}

// --------------------------------------------------------
// Vector4

set :: proc(v: ^Vector4, x, y, z, w: f32) {
	v^ = { x, y, z, w }
}

// Packs the color into 0xAARRGGBB.
to_rgba :: proc(v: Vector4) -> u32 {
	chan :: proc(c: f32) -> u32 {
		if c >= 1.0 {
			return 0xff
		} else if c <= 0.0 {
			return 0
		}
		return u32(c * 255.0 + 0.5)
	}
	return (chan(v.w) << 24) | (chan(v.z) << 16) | (chan(v.y) << 8) | chan(v.x)
}
