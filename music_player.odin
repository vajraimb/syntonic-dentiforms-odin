//------------------------------------------------------------------------------
//  music_player -- streams an Ogg Vorbis file into sokol_audio, and tells how
//  far the playback is; the port of src/demo/MusicPlayer.
//
//  The music is the clock of the demo: the audio thread decodes the file and
//  resamples it to what the device wants, and the main thread asks it how
//  many source frames it has got through.
//------------------------------------------------------------------------------
package main

import "core:c"
import "core:strings"
import "core:sync"
import saudio "sokol/audio"
import stb_vorbis "vendor:stb/vorbis"

REQUESTED_SAMPLE_RATE :: 44100
REQUESTED_CHANNELS :: 2
DECODE_BUFFER_FRAMES :: 4096

Vorbis_Player :: struct {
	vorbis:                   ^stb_vorbis.vorbis,
	info:                     stb_vorbis.vorbis_info,
	decoded_source_frames:    u64, // frames decoded before the current buffer, kept by the audio thread
	decode_buffer:            []f32, // interleaved source samples
	decode_buffer_frames:     int,
	eof:                      bool,
	src_frames_per_dst_frame: f64,
	src_cursor:               f64,
	mutex:                    sync.Mutex,
}

vorbis_player_create :: proc() -> ^Vorbis_Player {
	p := new(Vorbis_Player)
	saudio.setup({
		sample_rate = REQUESTED_SAMPLE_RATE,
		num_channels = REQUESTED_CHANNELS,
		stream_userdata_cb = vorbis_audio_callback,
		user_data = p,
	})
	return p
}

vorbis_player_destroy :: proc(p: ^Vorbis_Player) {
	// stop the audio thread first, so that it is done with the decoder
	saudio.shutdown()
	vorbis_player_close_file(p)
	free(p)
}

vorbis_player_play :: proc(p: ^Vorbis_Player, file_name: string) {
	vorbis_player_close_file(p)
	if len(file_name) == 0 {
		return
	}

	error: stb_vorbis.Error
	v := stb_vorbis.open_filename(strings.clone_to_cstring(file_name, context.temp_allocator), &error, nil)
	if v == nil {
		return
	}

	sync.mutex_lock(&p.mutex)
	info := stb_vorbis.get_info(v)
	p.info = info
	p.decoded_source_frames = 0
	p.eof = false
	p.src_cursor = 0.0
	p.decode_buffer_frames = 0
	channels := max(1, int(info.channels))
	if len(p.decode_buffer) < DECODE_BUFFER_FRAMES * channels {
		p.decode_buffer = make([]f32, DECODE_BUFFER_FRAMES * channels)
	}

	out_rate := saudio.sample_rate()
	if out_rate > 0 {
		p.src_frames_per_dst_frame = f64(info.sample_rate) / f64(out_rate)
	} else {
		p.src_frames_per_dst_frame = 1.0
	}
	// the audio thread starts decoding as soon as it sees the decoder
	p.vorbis = v
	sync.mutex_unlock(&p.mutex)
}

// How many seconds of the file have been played.
vorbis_player_get_time :: proc(p: ^Vorbis_Player) -> f64 {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)
	if p.vorbis == nil || p.info.sample_rate == 0 {
		return 0.0
	}
	absolute_source_frames := f64(sync.atomic_load_explicit(&p.decoded_source_frames, .Relaxed)) + p.src_cursor
	return absolute_source_frames / f64(p.info.sample_rate)
}

vorbis_player_close_file :: proc(p: ^Vorbis_Player) {
	sync.mutex_lock(&p.mutex)
	defer sync.mutex_unlock(&p.mutex)

	if p.vorbis != nil {
		stb_vorbis.close(p.vorbis)
		p.vorbis = nil
	}

	p.info = {}
	p.decoded_source_frames = 0
	p.decode_buffer_frames = 0
	p.eof = false
	p.src_frames_per_dst_frame = 1.0
	p.src_cursor = 0.0
}

// --------------------------------------------------------
// the audio thread

vorbis_audio_callback :: proc "c" (buffer: ^f32, num_frames, num_channels: c.int, user_data: rawptr) {
	vorbis_player_render((^Vorbis_Player)(user_data), buffer, int(num_frames), int(num_channels))
}

vorbis_player_render :: proc "contextless" (p: ^Vorbis_Player, buffer: [^]f32, num_frames, num_channels: int) {
	buf := buffer[:num_frames * num_channels]
	#no_bounds_check {
		for i in 0..<len(buf) {
			buf[i] = 0
		}
	}

	if p.vorbis == nil || p.eof {
		return
	}

	for dst_frame in 0..<num_frames {
		l, r: f32
		if !read_resampled_stereo_frame(p, &l, &r) {
			break
		}

		if num_channels == 1 {
			buf[dst_frame] = 0.5 * (l + r)
		} else {
			buf[dst_frame * num_channels + 0] = l
			buf[dst_frame * num_channels + 1] = r
			for c in 2..<num_channels {
				buf[dst_frame * num_channels + c] = 0
			}
		}
	}
}

refill_decode_buffer :: proc "contextless" (p: ^Vorbis_Player) -> bool {
	if p.vorbis == nil || p.eof {
		return false
	}

	src_channels := int(p.info.channels)
	max_floats := DECODE_BUFFER_FRAMES * src_channels

	frames_read := int(stb_vorbis.get_samples_float_interleaved(p.vorbis, p.info.channels, &p.decode_buffer[0], c.int(max_floats)))
	p.decode_buffer_frames = frames_read

	if frames_read <= 0 {
		p.eof = true
		return false
	}
	return true
}

get_decoded_frame_stereo :: proc "contextless" (p: ^Vorbis_Player, frame_index: int, l, r: ^f32) -> bool {
	if frame_index < 0 || frame_index >= p.decode_buffer_frames {
		l^ = 0
		r^ = 0
		return false
	}

	ch := int(p.info.channels)
	base := frame_index * ch

	if ch == 1 {
		l^ = p.decode_buffer[base]
		r^ = l^
	} else {
		l^ = p.decode_buffer[base + 0]
		r^ = p.decode_buffer[base + 1]
	}
	return true
}

read_resampled_stereo_frame :: proc "contextless" (p: ^Vorbis_Player, l, r: ^f32) -> bool {
	if p.vorbis == nil || p.eof {
		l^ = 0
		r^ = 0
		return false
	}

	if p.decode_buffer_frames == 0 {
		if !refill_decode_buffer(p) {
			l^ = 0
			r^ = 0
			return false
		}
	}

	i0 := int(p.src_cursor)
	frac := f32(p.src_cursor - f64(i0))

	for i0 >= p.decode_buffer_frames {
		p.src_cursor -= f64(p.decode_buffer_frames)
		sync.atomic_add_explicit(&p.decoded_source_frames, u64(p.decode_buffer_frames), .Relaxed)
		if !refill_decode_buffer(p) {
			l^ = 0
			r^ = 0
			return false
		}
		i0 = int(p.src_cursor)
		frac = f32(p.src_cursor - f64(i0))
	}

	l0, r0: f32
	l1, r1: f32

	if !get_decoded_frame_stereo(p, i0, &l0, &r0) {
		l^ = 0
		r^ = 0
		return false
	}
	if !get_decoded_frame_stereo(p, i0 + 1, &l1, &r1) {
		l1 = l0
		r1 = r0
	}

	l^ = l0 + (l1 - l0) * frac
	r^ = r0 + (r1 - r0) * frac

	p.src_cursor += p.src_frames_per_dst_frame
	return true
}
