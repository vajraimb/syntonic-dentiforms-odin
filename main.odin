//------------------------------------------------------------------------------
//  main -- the entry point: creates the window and hands over to the demo.
//  The port of src/demo/main.cpp.
//
//  By default the demo plays in full screen, with the music as its clock.
//  Build with -define:DEMO_DEBUG=true to get a window instead, with the demo
//  time under keyboard control:
//      left/right, page up/down   one frame, five frames back or forward
//      1..5                       jump to a scene, five seconds in
//      space                      one second forward
//      F9                         save the frame to shotNN.tga (macOS, Apple Silicon)
//  Always: ESC quits, and / shows the statistics.
//
//  With --capture=a,b,c the demo renders itself at 60 frames per second from
//  the start, in a window, saves the frames with those numbers as
//  captureNNNNN.tga, and quits after the last of them. With --offscreen added
//  there is no window at all: the frames are rendered into an image in memory.
//------------------------------------------------------------------------------
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import sg        "sokol/gfx"
import sapp      "sokol/app"
import sglue     "sokol/glue"
import slog      "sokol/log"
import stm       "sokol/time"
import sdtx      "sokol/debugtext"
import stb_image "vendor:stb/image"

DEMO_DEBUG :: #config(DEMO_DEBUG, false)

// Called by sokol_app once, before the first frame.
//
// A procedure with the "c" calling convention has no context of its own, so
// every callback starts by installing the default one. That has to happen in
// the callback itself: a called procedure cannot do it for its caller.
init :: proc "c" () {
	context = runtime.default_context()
	sg.setup({
		environment = sglue.environment(),
		logger = { func = slog.func },
	})
	sdtx.setup({
		fonts = { 0 = sdtx.font_cpc() },
		logger = { func = slog.func },
	})
	stm.setup()
	render_cam_init()

	if !demo_init() {
		fmt.eprintln("Could not load the data files of the demo. They are looked for next to the program, in a directory named data.")
		sapp.quit()
	}
}

frame :: proc "c" () {
	context = runtime.default_context()
	if !demo_update() {
		sapp.request_quit()
	}
}

cleanup :: proc "c" () {
	context = runtime.default_context()
	demo_shutdown()
	sg.shutdown()
}

on_event :: proc "c" (evt: ^sapp.Event) {
	context = runtime.default_context()
	demo_event(evt)
}

// The data files are looked for next to the program.
change_curdir :: proc(app_path: string) {
	dir := filepath.dir(app_path)
	if dir != "" && dir != "." {
		if os.chdir(dir) != nil {
			fmt.println("could not change to the program's directory:", dir)
		}
	}
}

parse_command_line :: proc(args: []string) {
	CAPTURE_PREFIX :: "--capture="

	for arg in args {
		if arg == "--offscreen" {
			g_offscreen = true
		}
		if !strings.has_prefix(arg, CAPTURE_PREFIX) {
			continue
		}
		g_play_mode = .CAPTURE
		for f in strings.split(arg[len(CAPTURE_PREFIX):], ",") {
			n, ok := strconv.parse_int(strings.trim_space(f))
			if ok && n >= 0 {
				append(&g_capture_frames, n)
			}
		}
	}

	if g_play_mode == .CAPTURE {
		sort_capture_frames()
		if !SCREENSHOTS {
			fmt.println("Screenshots need Metal on Apple Silicon; the frames will not be saved.")
		}
	}
	if g_offscreen {
		// time comes from the frame counter
		g_play_mode = .CAPTURE
		g_screenshot.enabled = SCREENSHOTS
	}
}

main :: proc() {
	context = runtime.default_context()

	args := os.args
	if len(args) >= 1 {
		change_curdir(args[0])
	}

	g_play_mode = DEMO_DEBUG ? .DEBUG : .MUSIC
	parse_command_line(args)
	if !g_offscreen {
		g_screenshot.enabled = SCREENSHOTS && g_play_mode != .MUSIC
	}

	if g_offscreen {
		if !SCREENSHOTS {
			fmt.println("The offscreen mode needs Metal on Apple Silicon.")
			return
		}
		ok := run_offscreen()
		if !ok {
			os.exit(1)
		}
		return
	}

	app_desc: sapp.Desc
	app_desc.init_cb = init
	app_desc.frame_cb = frame
	app_desc.cleanup_cb = cleanup
	app_desc.event_cb = on_event
	app_desc.width = 640
	app_desc.height = 500
	app_desc.high_dpi = false
	app_desc.sample_count = 1
	app_desc.window_title = "Syntonic Dentiforms"
	app_desc.icon.sokol_default = true
	app_desc.logger = { func = slog.func }

	if g_play_mode == .DEBUG {
		app_desc.fullscreen = false
		app_desc.swap_interval = 0
	} else {
		app_desc.fullscreen = true
		app_desc.swap_interval = 1
	}
	// capture runs at its own 60 frames per second, in a window of a known size
	if g_play_mode == .CAPTURE {
		app_desc.fullscreen = false
		app_desc.swap_interval = 0
	}

	// try to load icon
	icon_width, icon_height, icon_comp: c.int
	icon_image := stb_image.load("data/tex/icon.png", &icon_width, &icon_height, &icon_comp, 4)
	if icon_image != nil {
		app_desc.icon.sokol_default = false
		app_desc.icon.images[0].width = icon_width
		app_desc.icon.images[0].height = icon_height
		app_desc.icon.images[0].pixels = {
			ptr = rawptr(icon_image),
			size = c.size_t(icon_width * icon_height * 4),
		}
	}

	sapp.run(app_desc)
}

// Smallest frame number first, so that they can be saved as the demo goes.
sort_capture_frames :: proc() {
	for i in 1..<len(g_capture_frames) {
		f := g_capture_frames[i]
		j := i - 1
		for j >= 0 && g_capture_frames[j] > f {
			g_capture_frames[j + 1] = g_capture_frames[j]
			j -= 1
		}
		g_capture_frames[j + 1] = f
	}
}
