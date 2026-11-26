#!/bin/sh
# Builds the demo. The first time, this also compiles the C libraries of the
# sokol bindings: they are build outputs and not part of the repository.
#
#   ./build.sh              release build:                         syntonic-odin
#   ./build.sh debug        debug build, with bounds checking:     syntonic-odin-d
#   ./build.sh debug-keys   a window, with the demo time on keys:  syntonic-odin-debug
#
# Only macOS on Apple Silicon was tried.
set -e
cd "$(dirname "$0")"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "$0: only macOS was tried. Elsewhere, start with the scripts in sokol/." >&2
    exit 1
fi

if [ ! -f sokol/gfx/sokol_gfx_macos_arm64_metal_release.a ]; then
    echo "compiling the C libraries of the sokol bindings, this takes a moment"
    # With a current SDK the C compiler warns about the sokol headers. Those
    # warnings are kept in build-clibs.log instead of scrolling by.
    if ! (cd sokol && sh build_clibs_macos.sh > /dev/null 2> ../build-clibs.log); then
        cat build-clibs.log >&2
        exit 1
    fi
    if [ -s build-clibs.log ]; then
        echo "warnings from the C compiler are in build-clibs.log"
    else
        rm build-clibs.log
    fi
fi

case "${1:-release}" in
release)
    odin build . -o:speed -no-bounds-check -strict-style -out:syntonic-odin
    ;;
debug)
    odin build . -debug -strict-style -out:syntonic-odin-d
    ;;
debug-keys)
    odin build . -define:DEMO_DEBUG=true -out:syntonic-odin-debug
    ;;
*)
    echo "usage: $0 [release|debug|debug-keys]" >&2
    exit 1
    ;;
esac
