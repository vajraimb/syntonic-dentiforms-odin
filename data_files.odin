//------------------------------------------------------------------------------
//  data_files -- loading everything in data/ that the demo needs, the port of
//  the loading part of src/demo/DataFiles.cpp. The names and paths are in
//  data_tables.odin.
//------------------------------------------------------------------------------
package main

g_data_tex: [int(Data_Texture.COUNT)]Texture
g_data_mesh: [int(Data_Mesh.COUNT)]^Mesh
g_data_anim: [int(Data_Anim.COUNT)]^Animation_Bunch

load_data_files :: proc() -> bool {
	for i in 0..<int(Data_Texture.COUNT) {
		if !load_texture(&g_data_tex[i], data_texture_paths[i]) {
			return false
		}
	}
	for i in 0..<int(Data_Mesh.COUNT) {
		g_data_mesh[i] = mesh_load(data_mesh_paths[i])
		if g_data_mesh[i] == nil {
			return false
		}
	}
	for i in 0..<int(Data_Anim.COUNT) {
		g_data_anim[i] = animation_bunch_load(data_anim_paths[i])
		if g_data_anim[i] == nil {
			return false
		}
	}
	return true
}

data_tex :: proc(t: Data_Texture) -> ^Texture {
	return &g_data_tex[int(t)]
}

data_mesh :: proc(t: Data_Mesh) -> ^Mesh {
	return g_data_mesh[int(t)]
}

data_anim :: proc(t: Data_Anim) -> ^Animation_Bunch {
	return g_data_anim[int(t)]
}
