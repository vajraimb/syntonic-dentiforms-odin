//------------------------------------------------------------------------------
//  animation -- sampled animations (.danim files), the port of src/animator.
//
//  file format:
//  - 4 bytes "DANI"
//  - 4 bytes animation type; 0 is "sampled", the only type there is
//  - 4 bytes loop type (not used)
//  - 4 bytes curve count, 4 bytes group count
//  - for each curve: a zero-terminated name, 4 bytes parent (not used)
//  - 4 bytes samples per curve
//  - for each group (a group is a position track or a rotation track for all
//    the curves at once):
//      4 bytes type (3 = vectors, 4 = quaternions), 4 bytes sample size,
//      a zero-terminated name,
//      for each curve: 4 bytes interpolation, 4 bytes first sample index,
//                      the collapsed value (sample size bytes),
//      4 bytes total samples, then the samples themselves
//------------------------------------------------------------------------------
package main

import "core:mem"

Anim_Type :: enum i32 {
	VECTOR3    = 3,
	QUATERNION = 4,
}

Anim_Ipol :: enum i32 {
	NONE   = 0, // the curve is a single value
	LINEAR = 2,
}

// Animation curve information.
// This just has first value index (in array of values shared between several curves),
// interpolation type and a collapsed value (if curve is collapsed into single value).
Anim_Curve :: struct {
	first_sample_index: i32,
	ipol:              i32, // an Anim_Ipol, as stored in the file
	collapsed_value:   [4]f32,
}

// A sampled animation.
// Each curve consists of the same number of samples (but can be collapsed
// into a single value).
Sampled_Animation :: struct {
	sample_type:      Anim_Type,
	name:             string,
	samples_in_curve: int,
	sample_data:      []f32, // samples of all the curves, one after the other
	curves:           []Anim_Curve,
}

Animation_Bunch :: struct {
	anims:       [dynamic]Sampled_Animation,
	curve_names: []string,
}

floats_per_sample :: proc(t: Anim_Type) -> int {
	#partial switch t {
	case .VECTOR3:
		return 3
	case .QUATERNION:
		return 4
	}
	return 0
}

bunch_find_anim :: proc(bunch: ^Animation_Bunch, name: string, type: Anim_Type) -> ^Sampled_Animation {
	for &anim, i in bunch.anims {
		if anim.sample_type == type && anim.name == name {
			return &bunch.anims[i]
		}
	}
	return nil
}

bunch_curve_index_by_name :: proc(bunch: ^Animation_Bunch, name: string) -> int {
	for i in 0..<len(bunch.curve_names) {
		if bunch.curve_names[i] == name {
			return i
		}
	}
	return -1
}

// @param time Relative time (zero is start, one is end).
time_to_index :: proc(a: ^Sampled_Animation, time: f32, index1, index2: ^int, alpha: ^f32) {
	n := a.samples_in_curve
	frame := time * f32(n)
	i1 := int(frame)
	i2 := i1 + 1
	alpha^ = frame - f32(i1)

	if i1 < 0 {
		i1 = 0
	} else if i1 >= n {
		i1 = n - 1
	}
	if i2 < 0 {
		i2 = 0
	} else if i2 >= n {
		i2 = n - 1
	}
	index1^ = i1
	index2^ = i2
}

// Writes num_curves values of the curves starting at first_curve, one after the other.
// @param time Relative time (zero is start, one is end).
animation_sample :: proc(a: ^Sampled_Animation, time: f32, first_curve, num_curves: int, dest: [^]f32) {
	assert(first_curve >= 0 && first_curve < len(a.curves))
	assert(num_curves > 0 && first_curve + num_curves <= len(a.curves))

	// get sample indices and alpha
	idx1, idx2: int
	alpha: f32
	time_to_index(a, time, &idx1, &idx2, &alpha)

	floats := floats_per_sample(a.sample_type)
	d := dest

	for i in 0..<num_curves {
		curve := &a.curves[first_curve + i]
		#partial switch transmute(Anim_Ipol) curve.ipol {
		case .NONE:
			for k in 0..<floats {
				d[k] = curve.collapsed_value[k]
			}
		case .LINEAR:
			s1 := (int(curve.first_sample_index) + idx1) * floats
			s2 := (int(curve.first_sample_index) + idx2) * floats
			#partial switch a.sample_type {
			case .VECTOR3:
				v1 := (^Vector3)(&a.sample_data[s1])^
				v2 := (^Vector3)(&a.sample_data[s2])^
				(^Vector3)(d)^ = v1 + (v2 - v1) * alpha
			case .QUATERNION:
				quat_slerp(
					(^Quaternion)(d),
					(^Quaternion)(&a.sample_data[s1])^,
					(^Quaternion)(&a.sample_data[s2])^,
					alpha,
				)
			}
		}
		d = &d[floats]
	}
}

read_sampled_data :: proc(bunch: ^Animation_Bunch, r: ^Reader, curves, groups: int) {
	// samples per curve
	samples_per_curve := read_i32(r)
	if samples_per_curve <= 0 {
		r.ok = false
		return
	}

	for _ in 0..<groups {
		// group type, sample size, group name
		group_type := read_i32(r)
		sample_size := read_i32(r)
		name := read_zero_string(r)
		if sample_size <= 0 || sample_size > 16 {
			r.ok = false
			return
		}

		zero: Sampled_Animation
		append(&bunch.anims, zero)
		anim := &bunch.anims[len(bunch.anims) - 1]
		anim.sample_type = transmute(Anim_Type) group_type
		anim.name = name
		anim.samples_in_curve = int(samples_per_curve)

		// read curves
		anim.curves = make([]Anim_Curve, int(curves))
		for c in 0..<curves {
			anim.curves[c].ipol = read_i32(r)
			anim.curves[c].first_sample_index = read_i32(r)
			collapsed := read_bytes(r, int(sample_size))
			if r.ok {
				mem.copy(&anim.curves[c].collapsed_value, raw_data(collapsed), len(collapsed))
			}
		}
		// read samples
		total_samples := read_i32(r)
		if total_samples < 0 {
			r.ok = false
			return
		}
		anim.sample_data = make([]f32, int(total_samples) * floats_per_sample(anim.sample_type))
		data := read_bytes(r, int(total_samples) * int(sample_size))
		// by bytes: the sample data is floats, the file gives bytes
		mem.copy(raw_data(anim.sample_data), raw_data(data), len(data))
	}
}

animation_bunch_load :: proc(path: string) -> ^Animation_Bunch {
	r, ok := read_open(path)
	if !ok {
		return nil
	}
	defer read_close(&r)

	// read magic
	magic := read_bytes(&r, 4)
	if len(magic) != 4 || magic[0] != 'D' || magic[1] != 'A' || magic[2] != 'N' || magic[3] != 'I' {
		return nil
	}
	// read anim type
	anim_type := read_i32(&r)
	// loop type (not used)
	read_i32(&r)
	// curve count, group count
	curve_count := read_i32(&r)
	group_count := read_i32(&r)
	if curve_count < 0 || group_count < 0 {
		return nil
	}

	bunch := new(Animation_Bunch)

	// read curve infos
	bunch.curve_names = make([]string, int(curve_count))
	for i in 0..<int(curve_count) {
		bunch.curve_names[i] = read_zero_string(&r)
		read_i32(&r) // parent, unused
	}

	// read rest based on anim type
	if anim_type != 0 {
		return nil // 0 is the only animation type there is: sampled
	}
	read_sampled_data(bunch, &r, int(curve_count), int(group_count))
	if !r.ok {
		return nil
	}
	return bunch
}
