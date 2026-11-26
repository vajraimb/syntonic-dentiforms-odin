#!/bin/sh
# Compiles the shaders in fx/ into Odin packages, the same way the original's
# CMakeLists.txt compiles them into C headers. Needs nothing but tools/sokol-shdc.
#
# Each fx/<name>.glsl becomes fx/<name>/shader.odin (package <name>). The shader
# sources are the original ones, unchanged; sokol-shdc's Odin output has no
# package and import lines, so they are added here.
set -e
cd "$(dirname "$0")/.."

for name in billboards blit lines overlay postBlurStep postComposeToon postToon \
            renderLit renderLitShadowed renderReflective renderWhite shadowCaster; do
    out="fx/$name/shader.odin"
    mkdir -p "fx/$name"
    tools/sokol-shdc --input "fx/$name.glsl" --output "$out.tmp" \
        --slang glsl430:metal_macos:hlsl5 -f sokol_odin
    {
        printf 'package %s\n' "$name"
        printf 'import sg "../../sokol/gfx"\n\n'
        cat "$out.tmp"
    } > "$out"
    rm "$out.tmp"
    echo "$out"
done
