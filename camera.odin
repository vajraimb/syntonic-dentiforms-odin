//------------------------------------------------------------------------------
//  camera -- the port of src/demo/Camera.
//------------------------------------------------------------------------------
package main

Camera_Entity :: struct {
	transform:            Matrix4x4,
	projection_matrix: Matrix4x4,
	ortho:             bool,
	fov:               f32,
	znear:             f32,
	zfar:              f32,
	view_half_width:   f32, // at distance 1
	view_half_height:  f32, // at distance 1
}

camera_set_projection_params :: proc(c: ^Camera_Entity, fov, aspect, znear, zfar: f32) {
	c.ortho = false
	matrix_perspective_fov_lh(&c.projection_matrix, fov, aspect, znear, zfar)
	c.fov = fov
	c.znear = znear
	c.zfar = zfar
	c.view_half_width = 1.0 / c.projection_matrix[0][0]
	c.view_half_height = 1.0 / c.projection_matrix[1][1]
}

camera_set_ortho_params :: proc(c: ^Camera_Entity, width, height, znear, zfar: f32) {
	c.ortho = true
	matrix_ortho_lh(&c.projection_matrix, width, height, znear, zfar)
	c.znear = znear
	c.zfar = zfar
	c.view_half_width = width * 0.5
	c.view_half_height = height * 0.5
}

camera_set_proj_from :: proc(c: ^Camera_Entity, o: ^Camera_Entity) {
	c.ortho = o.ortho
	c.fov = o.fov
	c.znear = o.znear
	c.zfar = o.zfar
	c.view_half_width = o.view_half_width
	c.view_half_height = o.view_half_height
	c.projection_matrix = o.projection_matrix
}

// Gets camera space ray from camera's viewing plane coordinates.
// x is -1 at the left and 1 at the right, y is -1 at the top and 1 at the bottom.
// The ray is not of unit length.
camera_ray :: proc(c: ^Camera_Entity, x, y: f32) -> Vector3 {
	return { x * c.view_half_width, -y * c.view_half_height, 1.0 }
}

// Like camera_ray, but in world space.
camera_world_ray :: proc(c: ^Camera_Entity, x, y: f32) -> Vector3 {
	m := c.transform
	origin(&m)^ = { 0, 0, 0 }
	return transform_coord(camera_ray(c, x, y), m)
}

// Sets the current camera parameters onto the render context's camera.
camera_set_onto_render_context :: proc(c: ^Camera_Entity) {
	render_cam_set_camera_matrix(c.transform)
	render_cam_set_projection_matrix(c.projection_matrix)
}

// --------------------------------------------------------

Render_Camera :: struct {
	camera_matrix:     Matrix4x4,
	projection_matrix: Matrix4x4,
	// calculated from the camera transform
	view_matrix:       Matrix4x4,
	view_proj_matrix:  Matrix4x4,
	camera_rot_matrix: Matrix4x4,
}

g_render_cam: Render_Camera

render_cam_init :: proc() {
	g_render_cam.camera_matrix = matrix_identity()
	g_render_cam.projection_matrix = matrix_identity()
	g_render_cam.camera_rot_matrix = matrix_identity()
	g_render_cam.view_matrix = matrix_identity()
}

render_cam_set_camera_matrix :: proc(transform: Matrix4x4) {
	rc := &g_render_cam
	rc.camera_matrix = transform
	rc.camera_rot_matrix = transform
	origin(&rc.camera_rot_matrix)^ = { 0, 0, 0 }

	rc.view_matrix = rc.camera_matrix
	matrix_invert(&rc.view_matrix)
	rc.view_proj_matrix = matrix_mul(rc.view_matrix, rc.projection_matrix)

	g_global_u.mat_projection = rc.projection_matrix
	g_global_u.mat_view = rc.view_matrix
	g_global_u.mat_view_proj = rc.view_proj_matrix
	o := origin(&rc.camera_matrix)^
	g_global_u.eye_pos = { o[0], o[1], o[2], 1.0 }
}

render_cam_set_projection_matrix :: proc(transform: Matrix4x4) {
	rc := &g_render_cam
	rc.projection_matrix = transform
	rc.view_proj_matrix = matrix_mul(rc.view_matrix, rc.projection_matrix)

	g_global_u.mat_projection = rc.projection_matrix
	g_global_u.mat_view_proj = rc.view_proj_matrix
}
