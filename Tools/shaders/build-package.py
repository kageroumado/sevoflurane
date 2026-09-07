#!/usr/bin/env python3
"""Builds a shader package for the engine's presenter from mpv user shaders.

An mpv user shader is GLSL split into passes by `//!` directives (HOOK,
BIND, SAVE, WIDTH, HEIGHT, WHEN, COMPONENTS, DESC). Each pass body is a
`vec4 hook()` reading its bound textures through the `NAME_tex(pos)`,
`NAME_texOff(off)`, `NAME_pos`, `NAME_size`, `NAME_pt` family, HOOKED
standing for the texture the pass hooks. A `//!COMPUTE bw bh [tw th]` pass
is a compute shader instead, whose hook() writes `out_image` for a bw×bh
block of output pixels per threadgroup of tw×th threads. This tool wraps
every pass in the main() mpv would give it, compiles it through glslang and
SPIRV-Cross into Metal, links one metallib, and writes graph.json, the pass
list the presenter's runner interprets at frame time (dormison
dlls/winemac.drv/swift/MPVHook.swift).

    build-package.py --name anime4k-c --title Anime4K --version 4.0.1 \
        --license MIT --source https://github.com/bloc97/Anime4K \
        --content "For 2D art and anime-style games" \
        --description "Anime4K's mode C: denoises while upscaling." \
        --license-file LICENSE --out build/anime4k-c shader.glsl [more.glsl]

Shaders are concatenated in the order given, which is the order mpv applies
them. Toolchain: glslangValidator and spirv-cross from Homebrew, metal and
metallib from Xcode.

Semantics were read from mpv's video/out/gpu/user_shaders.c and
libplacebo's src/shaders/custom_mpv.c (both LGPL) and reimplemented here:
nothing is copied.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field

DIRECTIVE = re.compile(r"^//!(\w+)\s*(.*)$")
IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
BUILTIN_TEXTURES = {"MAIN", "LUMA", "NATIVE", "OUTPUT", "HOOKED"}
REJECTED_HOOKS = {"CHROMA", "CHROMA_SCALED", "RGB", "XYZ", "PREKERNEL", "POSTKERNEL", "SCALED"}


@dataclass
class Pass:
    desc: str = ""
    hooks: list = field(default_factory=list)
    binds: list = field(default_factory=list)
    save: str | None = None
    width: list | None = None
    height: list | None = None
    when: list | None = None
    components: int = 4
    body: list = field(default_factory=list)
    # `//!COMPUTE bw bh [tw th]`: the block of output pixels one threadgroup
    # writes and the threads in the group; None for a fragment pass.
    compute: list | None = None


def parse(text: str) -> list[Pass]:
    """The passes of one or more concatenated hook files: a pass is its
    directives followed by its body, and a directive after body lines opens
    the next one."""
    passes: list[Pass] = []
    current: Pass | None = None
    for line in text.splitlines():
        match = DIRECTIVE.match(line.strip())
        if match:
            key, value = match.group(1), match.group(2).strip()
            if current is not None and any(l.strip() for l in current.body):
                passes.append(current)
                current = None
            if current is None:
                current = Pass()
            if key == "DESC":
                current.desc = value
            elif key == "HOOK":
                current.hooks.append(value)
            elif key == "BIND":
                current.binds.append(value)
            elif key == "SAVE":
                current.save = value
            elif key == "WIDTH":
                current.width = value.split()
            elif key == "HEIGHT":
                current.height = value.split()
            elif key == "WHEN":
                current.when = value.split()
            elif key == "COMPONENTS":
                current.components = int(value)
            elif key == "COMPUTE":
                sizes = [int(v) for v in value.split()]
                if len(sizes) == 2:
                    sizes += sizes
                if len(sizes) != 4 or min(sizes) < 1:
                    sys.exit(f"//!COMPUTE {value}: expected 'bw bh [tw th]'")
                current.compute = sizes
            elif key == "OFFSET":
                if value not in ("", "0 0", "ALIGN"):
                    sys.exit(f"//!OFFSET {value}: offsets are not supported")
            else:
                sys.exit(f"unknown directive //!{key}")
            continue
        if current is None:
            continue
        current.body.append(line)
    if current is not None and current.hooks:
        passes.append(current)
    return passes


def validate(passes: list[Pass]):
    known = {"MAIN", "LUMA", "NATIVE", "OUTPUT"}
    for index, p in enumerate(passes):
        if not p.hooks:
            sys.exit(f"pass {index} ({p.desc}) hooks nothing")
        for hook in p.hooks:
            if hook in REJECTED_HOOKS:
                sys.exit(f"pass {index} ({p.desc}) hooks {hook}: the presenter's frames are RGB only")
            if hook not in known:
                sys.exit(f"pass {index} ({p.desc}) hooks {hook}, which nothing produced")
        if not any("hook()" in line for line in p.body):
            sys.exit(f"pass {index} ({p.desc}) has no hook()")
        if p.compute and not any("imageStore" in line for line in p.body):
            sys.exit(f"pass {index} ({p.desc}) is a compute pass that never writes out_image")
        for bind in p.binds:
            if bind == "HOOKED":
                continue
            if bind not in known:
                sys.exit(f"pass {index} ({p.desc}) binds {bind}, which nothing produced")
        for expr in (p.width, p.height):
            if expr:
                for token in expr:
                    ref = token.split(".")[0]
                    if "." in token and ref not in known and ref != "HOOKED":
                        sys.exit(f"pass {index} ({p.desc}) sizes itself by {token}, which nothing produced")
        save = p.save or "HOOKED"
        if save == "HOOKED":
            save = p.hooks[0]
        known.add(save)
        p.save = save


def wrap(p: Pass, index: int) -> str:
    """The complete GLSL 450 shader for one pass: a fragment shader whose
    color output is `hook()`'s answer, or, for a `//!COMPUTE` pass, a compute
    shader whose `hook()` writes `out_image` itself. Every `#extension` line
    of the body moves to the top, where GLSL wants it."""
    hooked = p.hooks[0]
    textures = []
    for bind in p.binds:
        name = hooked if bind == "HOOKED" else bind
        if name not in textures:
            textures.append(name)
    if hooked not in textures:
        textures.insert(0, hooked)
    extensions = [line for line in p.body if line.strip().startswith("#extension")]
    body = [line for line in p.body if not line.strip().startswith("#extension")]
    lines = ["#version 450"] + extensions + [""]
    if p.compute:
        lines.append(f"layout(local_size_x = {p.compute[2]}, local_size_y = {p.compute[3]}, local_size_z = 1) in;")
    else:
        lines.append("layout(location = 0) out vec4 sevo_out;")
    lines.append("")
    # One vec2 per member, in the order the runner writes the buffer:
    # output size first, then each texture's size and pixel size.
    lines.append("layout(std140, binding = 0) uniform SevoUniforms {")
    lines.append("    vec2 sevo_out_size;")
    for name in textures:
        lines.append(f"    vec2 {name}_size;")
        lines.append(f"    vec2 {name}_pt;")
    lines.append("};")
    lines.append("")
    for slot, name in enumerate(textures):
        lines.append(f"layout(binding = {slot + 1}) uniform sampler2D {name}_raw;")
    if p.compute:
        lines.append(f"layout(binding = {len(textures) + 1}, rgba16f) uniform writeonly image2D out_image;")
    lines.append("")
    position = ("((vec2(gl_GlobalInvocationID.xy) + vec2(0.5)) / sevo_out_size)" if p.compute
                else "(gl_FragCoord.xy / sevo_out_size)")
    for name in textures:
        lines += [
            f"#define {name}_pos {position}",
            f"#define {name}_mul 1.0",
            f"vec4 {name}_tex(vec2 pos) {{ return texture({name}_raw, pos); }}",
            f"vec4 {name}_texOff(vec2 off) {{ return {name}_tex({name}_pos + {name}_pt * off); }}",
            f"#define {name}_gather(pos, c) textureGather({name}_raw, pos, c)",
        ]
    for suffix in ("raw", "pos", "size", "pt", "mul", "tex", "texOff", "gather"):
        lines.append(f"#define HOOKED_{suffix} {hooked}_{suffix}")
    lines.append("")
    lines += body
    lines += ["", "void main() { hook(); }" if p.compute else "void main() { sevo_out = hook(); }", ""]
    return "\n".join(lines), textures


def run(command: list[str], **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if result.returncode != 0:
        sys.exit(f"{' '.join(command)}\n{result.stdout}{result.stderr}")
    return result.stdout


def build(args):
    text = ""
    sources = []
    for path in args.shaders:
        with open(path, encoding="utf-8") as f:
            text += f.read() + "\n"
        sources.append(path)
    passes = parse(text)
    if not passes:
        sys.exit("no passes found")
    validate(passes)

    out = args.out
    os.makedirs(out, exist_ok=True)
    source_dir = os.path.join(out, "source")
    os.makedirs(source_dir, exist_ok=True)
    for path in sources:
        shutil.copy(path, source_dir)
    if args.license_file:
        shutil.copy(args.license_file, os.path.join(out, "LICENSE"))

    graph_passes = []
    with tempfile.TemporaryDirectory() as tmp:
        airs = []
        for index, p in enumerate(passes):
            glsl, textures = wrap(p, index)
            name = f"sevo_pass{index}"
            stage = "comp" if p.compute else "frag"
            glsl_path = os.path.join(tmp, f"{name}.{stage}")
            spv_path = os.path.join(tmp, f"{name}.spv")
            metal_path = os.path.join(tmp, f"{name}.metal")
            air_path = os.path.join(tmp, f"{name}.air")
            with open(glsl_path, "w") as f:
                f.write(glsl)
            run([args.glslang, "-V", "-S", stage, "-o", spv_path, glsl_path])
            # Metal indices are the GLSL bindings: buffer 0, texture and
            # sampler k+1 for the k-th bound texture, out_image after them.
            # Left to SPIRV-Cross, a texture the body never reads (glslang
            # drops it) would shift every later index.
            run([args.spirv_cross, "--msl", "--msl-version", "20300", "--msl-decoration-binding",
                 "--rename-entry-point", "main", name, stage,
                 "--output", metal_path, spv_path])
            run(["xcrun", "-sdk", "macosx", "metal", "-c", "-O2", "-o", air_path, metal_path])
            airs.append(air_path)
            if args.keep_metal:
                shutil.copy(metal_path, os.path.join(out, f"{name}.metal"))
            graph_passes.append({
                "function": name,
                "desc": p.desc,
                "hook": p.hooks,
                "textures": textures,
                "save": p.save,
                "width": p.width,
                "height": p.height,
                "when": p.when,
                "components": p.components,
                "compute": p.compute,
            })
        run(["xcrun", "-sdk", "macosx", "metallib", "-o", os.path.join(out, "shaders.metallib")] + airs)

    # Format 2: Metal indices are the GLSL bindings, and a pass may be a
    # compute pass.
    with open(os.path.join(out, "graph.json"), "w") as f:
        json.dump({"format": 2, "name": args.name, "passes": graph_passes}, f, indent=2)
    with open(os.path.join(out, "package.json"), "w") as f:
        json.dump({
            "name": args.name,
            "title": args.title,
            "description": args.description,
            "license": args.license,
            "version": args.version,
            "source": args.source,
            "content": args.content,
        }, f, indent=2)
    print(f"{args.name}: {len(passes)} passes -> {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("shaders", nargs="+", help="mpv hook .glsl files, in application order")
    parser.add_argument("--name", required=True, help="package directory name, e.g. anime4k-c")
    parser.add_argument("--title", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--license", required=True, help="SPDX identifier")
    parser.add_argument("--source", required=True, help="upstream project URL")
    parser.add_argument("--content", required=True, help="one line: what it is trained on or good at")
    parser.add_argument("--description", required=True)
    parser.add_argument("--license-file")
    parser.add_argument("--out", required=True, help="package directory to write")
    parser.add_argument("--glslang", default="glslangValidator")
    parser.add_argument("--spirv-cross", default="spirv-cross")
    parser.add_argument("--keep-metal", action="store_true", help="also write the generated .metal files")
    build(parser.parse_args())


if __name__ == "__main__":
    main()
