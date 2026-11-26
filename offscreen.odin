//------------------------------------------------------------------------------
//  offscreen -- rendering the demo without a window, to save frames to files.
//
//  With --offscreen the demo is not shown but rendered into an image in
//  memory, and the frames asked for with --capture are saved from there. It
//  needs Metal on Apple Silicon, like the screenshots do.
//
//  Without a window there is nothing that sets the pace, so the demo runs at
//  its own 60 frames per second, as fast as the machine goes.
//------------------------------------------------------------------------------
package main

import "base:runtime"
import "core:fmt"
import sg   "sokol/gfx"
import slog "sokol/log"
import stm  "sokol/time"
import sdtx "sokol/debugtext"

OFFSCREEN_WIDTH :: 640 // the size of the window
OFFSCREEN_HEIGHT :: 500

g_offscreen: bool

// What the window would show.
rt_screen: Texture

run_offscreen :: proc() -> bool {
	when SCREENSHOTS {
		context = runtime.default_context()

		objc_setup()
		device := metal_create_system_default_device()
		if device == nil {
			fmt.println("No Metal device.")
			return false
		}
		sg.setup({
			environment = {
				// what a window would have: an RGBA8 backbuffer without a depth buffer
				defaults = { color_format = .RGBA8, depth_format = .NONE, sample_count = 1 },
				metal = { device },
			},
			logger = { func = slog.func },
		})
		sdtx.setup({
			fonts = { 0 = sdtx.font_cpc() },
			logger = { func = slog.func },
		})
		stm.setup()
		render_cam_init()

		desc: sg.Image_Desc
		desc.usage.color_attachment = true
		desc.width = OFFSCREEN_WIDTH
		desc.height = OFFSCREEN_HEIGHT
		desc.pixel_format = .RGBA8
		texture_create(&rt_screen, desc)

		if !demo_init() {
			fmt.println("Could not load the data files of the demo. They are looked for next to the program, in a directory named data.")
			sg.shutdown()
			return false
		}
		for demo_update() {}
		demo_shutdown()

		texture_destroy(&rt_screen)
		sg.shutdown()
		return true
	}
	fmt.println("The offscreen mode needs Metal on Apple Silicon.")
	return false
}
