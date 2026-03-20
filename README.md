# Unity Shaders with Neovim

Getting LSP features (diagnostics, completion, goto-definition, hover) for Unity shader files in Neovim.

---

> **DISCLAIMER**
>
> 1. **The vast majority of the code in this repo is AI-generated.** Please review everything before using it on your system. Hell even most of this readme is AI-generated the only guarantee i can give you is "Works on my machine"
> 2. **This guide assumes you already have a working Neovim/Unity setup.** If you don't, start with [com.walcht.ide.neovim](https://github.com/walcht/com.walcht.ide.neovim) to get the Unity-to-Neovim bridge working first.
> 3. **This has only been tested on Unity 6 (6000.0.x) with basic compute shaders.** Other Unity versions or complex shader setups may require adjustments.
> 4. **`.shader` files (ShaderLab) still DO NOT WORK.** The language server rejects the `shaderlab` language ID entirely. Getting `.shader` files to work would require forking the server to parse ShaderLab's wrapper syntax and extract the embedded HLSL blocks. This repo is a proof of concept for `.compute`, `.cginc`, and `.hlsl` files only.
> 5. **Take all information presented here with a grain of salt** I'm not an LSP guy, I'm barely a Neovim guy. Maybe there's already a perfectly working LSP and i've been wasting my time. maybe all the information here is completely hallucinated, maybe the shell script leaks your passwords to the mossad, idunno.

---

## TL;DR — quickest path to a working setup

```bash
# 1. Install the language server
cargo install shader_language_server

# 2.(if your glibc < 2.38) Build DXC from source 
#    See "Building DXC from source" below — or skip this and accept
#    glslang fallback (works for basic shaders, not URP)

# 3. Copy unity-shaders.lua to your nvim config (Don't expect it to work out of the box! you'll need to adjust it to fit your nvim setup)-- uses Lazy.nvim to handle plugins
cp unity-shaders.lua ~/.config/nvim/lua/custom/plugins/unity-shaders.lua

# 4. Add glsl_analyzer to your mason servers table (I'm using kickstart nvim as the basis for my setup so i put it in my init.lua) 
#    (see "Neovim configuration" below)

# 5. Run the setup script from your Unity project root
cd /path/to/your/UnityProject
./setup-shader-lsp.sh

# 6. Open a .compute file in nvim — you should have LSP features
```

---

## Why all this is necessary

Unity shaders are written in a mix of two languages: **ShaderLab** (Unity's wrapper DSL) and **HLSL** (the actual shader code). Unlike C#, which has LSP support via Roslyn, the shader ecosystem has no single LSP that understands Unity's setup out of the box.:

**No dedicated Unity shader LSP exists.** Microsoft's HLSL compiler (DXC) and the various shader language servers were built for standalone HLSL/GLSL development, not for Unity's specific patterns: virtual `Packages/...` include paths, per-platform macro definitions, the ShaderLab wrapper language, and a deep chain of built-in include files.

**Unity's include system is non-standard.** Shader files reference includes via virtual paths like `Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl`. These don't correspond to actual filesystem paths — Unity's compiler resolves them through its package system. An external LSP has no idea where these files live on disk.

**HLSL validation requires DXC for modern shaders.** The only freely available alternative (glslang) is a GLSL compiler with partial HLSL support. It works for basic built-in pipeline shaders but rejects SM6+ features like wave intrinsics, enforces stricter macro rules than Unity's compiler, and produces many false positives on URP include chains.

**The ShaderLab wrapper is invisible to HLSL tools.** A `.shader` file contains ShaderLab structure with HLSL code embedded inside `HLSLPROGRAM`/`ENDHLSL` blocks. No existing LSP can parse ShaderLab, so `.shader` files get no LSP support at all. Only the standalone HLSL files (`.compute`, `.cginc`, `.hlsl`) work.

This repo bridges these gaps by configuring [shader-language-server](https://github.com/antaalt/shader-sense) (a Rust-based shader LSP) with Unity-specific include paths, preprocessor defines, and symlinks that let DXC resolve Unity's virtual paths.

## How we got here

This setup was developed iteratively across several stages. Understanding the progression helps explain why things are configured the way they are.

### Starting point: what exists already

We began by examining [CGNvim](https://github.com/walcht/CGNvim), an existing Neovim configuration for graphics programming. CGNvim uses `glsl_analyzer` for GLSL and treesitter grammars for HLSL/GLSL syntax highlighting, but has no HLSL LSP — the same gap exists everywhere in the Neovim ecosystem.

### Stage A: Install shader-language-server

[shader-language-server](https://github.com/antaalt/shader-sense) (from the shader-sense project by antaalt) is a Rust-based LSP that supports HLSL, GLSL, and WGSL. It uses DXC for HLSL validation and tree-sitter for symbol resolution. We installed it via `cargo install shader_language_server` and wired it into Neovim using a custom `vim.lsp.start()` autocmd that attaches on `hlsl` filetype.

The server worked immediately for basic HLSL — completion, hover, goto-definition all functioned. But all Unity `#include` directives failed because the server didn't know where Unity's shader files live.

### Stage B: Configure for Unity

This required solving several interconnected problems:

**Include paths:** Unity's shader includes live in three places — the editor's `CGIncludes` directory, the project's `Library/PackageCache/` for URP packages, and the URP config package. All of these need to be listed in the server's config.

**Virtual path resolution:** Unity uses `Packages/...` virtual paths in `#include` directives. The server's `pathRemapping` config handles these for the tree-sitter symbol layer, but DXC (the actual compiler) doesn't use pathRemapping. The workaround is a `.shader-includes/` directory containing symlinks that mirror Unity's virtual `Packages/` structure.

**Preprocessor defines:** Unity's shader compiler pre-defines macros like `UNITY_VERSION`, `SHADER_TARGET`, and `SHADER_API_D3D11`. Without these, the include chain hits `#error unsupported shader api`. But defining too many causes redefinition conflicts — the final set was trimmed to just the three that Unity's headers expect to be set externally.

**The workspace/configuration gotcha:** The server requests `workspace/configuration` from the editor after startup, which overwrites the CLI config with whatever the editor responds. The Neovim autocmd must pass the config both as a `--config-file` CLI argument AND as `settings = { ['shader-validator'] = parsed }` in the `vim.lsp.start()` call.

**The glibc wall:** Microsoft's prebuilt `libdxcompiler.so` requires glibc 2.38+. On older systems (like Linux Mint based on Ubuntu 22.04), DXC fails to load and the server falls back to glslang. Without DXC, URP shaders produce many false positives. The solution was building DXC from source.

### Stage B.5: Building DXC from source

DXC is a fork of LLVM/Clang, so building it is a significant undertaking (~10-15 GB disk, 30-90 minutes). Key pitfalls included a CMake invocation that silently enables non-existent LLVM backends (the AMDGPU error), glibc compatibility, and DXC emitting null bytes in diagnostic messages that crash Neovim display plugins. See [Building DXC from source](#building-dxc-from-source) for the full procedure.

### What works now

| File type | Syntax highlighting | LSP features | Diagnostics |
|---|---|---|---|
| `.compute` / `.cginc` / `.hlsl` (URP) | Treesitter HLSL | Completion, hover, goto-def | Yes (DXC) |
| `.compute` / `.cginc` / `.hlsl` (built-in pipeline) | Treesitter HLSL | Completion, hover, goto-def | Partial (DXC rejects legacy Cg types) |
| `.shader` (ShaderLab) | ShaderHighlight vim syntax | None | None |
| `.glsl` / `.vert` / `.frag` | Treesitter GLSL | Yes (glsl_analyzer) | Yes |

## Prerequisites

- Neovim 0.11+
- A working Neovim/Unity setup ([com.walcht.ide.neovim](https://github.com/walcht/com.walcht.ide.neovim))
- Rust toolchain with `cargo` (1.88+ for shader_language_server)
- Unity 6 with URP (tested on 6000.0.68f1)
- For full HLSL validation: either glibc >= 2.38 (prebuilt DXC works) or the ability to build DXC from source

## Installation

### 1. Install shader-language-server

```bash
cargo install shader_language_server
```

### 2. Install DXC (libdxcompiler.so)

`shader-language-server` uses DXC for HLSL validation via `hassle-rs`. The library must be placed next to the binary — `hassle-rs` loads it with `dlopen("./libdxcompiler.so")` relative to the executable.

**If your glibc is >= 2.38** (Ubuntu 24.04+, Mint 22+, Fedora 39+):

Download the latest Linux binary from [DXC releases](https://github.com/microsoft/DirectXShaderCompiler/releases), extract `libdxcompiler.so`, and copy it:

```bash
cp libdxcompiler.so ~/.cargo/bin/libdxcompiler.so
```

**If your glibc is < 2.38:** You need to build from source. See [Building DXC from source](#building-dxc-from-source).

**If you skip DXC entirely:** The server falls back to glslang. You'll get completion, hover, and goto-def, but diagnostics will be limited (false positives on URP shaders, no SM6+ support).

### 3. Neovim configuration

Copy `unity-shaders.lua` to your Neovim custom plugins directory and start debuggine lmao (much more likely to work if you're using Lazy.nvim and Mason (everyone uses Mason right??)):

```bash
cp unity-shaders.lua ~/.config/nvim/lua/custom/plugins/unity-shaders.lua
```

This file handles:
- Filetype detection (`.shader` -> `shaderlab`, `.cginc`/`.compute` -> `hlsl`, `.glsl`/`.vert`/`.frag` -> `glsl`)
- Buffer settings (4-space indent, C-style comments)
- shader-language-server autocmd (finds Unity project root, loads config, starts LSP)
- Null-byte diagnostic handler (strips `\0` from DXC error messages)
- ShaderHighlight plugin for ShaderLab vim syntax
- Treesitter HLSL and GLSL grammar installation

If you're using kickstart.nvim, also add `glsl_analyzer` to the `servers` table in your `init.lua`:

```lua
local servers = {
    lua_ls = { ... },

    -- Add this:
    glsl_analyzer = {},
}
```

### 4. Configure your Unity project

Run the setup script from your Unity project root:

```bash
cd /path/to/your/UnityProject
/path/to/setup-shader-lsp.sh
```

The script:
1. Detects your Unity editor version and installation path
2. Finds URP packages in `Library/PackageCache/`
3. Creates `.shader-includes/Packages/` with symlinks for DXC virtual path resolution
4. Generates `.shader-language-server.json` with all include paths, defines, and path remapping
5. Adds generated files to `.gitignore`

Re-run the script after updating Unity or URP packages (the package hashes change).

Note: script has only been tested on unity 6 (Like the rest of this project)

### 5. Verify

Open a `.compute` file in your Unity project. Run `:LspInfo` — you should see `shader-language-server` attached. The test files in `Tests/` can be copied to your project's `Assets/Shaders/` to validate the full setup (see `Tests/DXCTests_README.md`).

## Building DXC from source

Required when your system's glibc is older than 2.38 (the version Microsoft's prebuilt binaries target).

### Prerequisites

- CMake **3.x** (not 4.x — DXC uses CMake policies that 4.0+ rejects)
- Ninja build system
- GCC or Clang
- Python 3
- ~10-15 GB disk space, 30-90 min build time

### Build

```bash
git clone --depth 1 --branch v1.9.2602 \
    https://github.com/microsoft/DirectXShaderCompiler.git ~/dxc-build/DirectXShaderCompiler
cd ~/dxc-build/DirectXShaderCompiler
git submodule update --init --recursive

mkdir -p ~/dxc-build/build && cd ~/dxc-build/build
cmake ~/dxc-build/DirectXShaderCompiler \
    -GNinja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=gcc \
    -DCMAKE_CXX_COMPILER=g++ \
    -C ~/dxc-build/DirectXShaderCompiler/cmake/caches/PredefinedParams.cmake

ninja -j$(nproc) dxcompiler
```

The `PredefinedParams.cmake` cache file is critical — without the `-C` flag, CMake enables LLVM backends (AMDGPU, NVPTX) that don't exist in DXC's LLVM fork, producing `invalid target to enable: 'AMDGPU'`.

### Install

```bash
cp ~/dxc-build/build/lib/libdxcompiler.so ~/.cargo/bin/libdxcompiler.so
```

### Verify

```bash
RUST_LOG=info shader-language-server --hlsl --stdio 2>&1 | head -20
# Should show "Found dxc library" without "Fallback to glslang"
```

The `~/dxc-build/` directory (~10-15 GB) can be deleted after copying the library.

## Major pitfalls

These are the non-obvious problems we hit during development:

**workspace/configuration overwrites CLI config.** After initialization, the server asks Neovim for its config. If Neovim responds with empty settings, the server replaces your carefully crafted CLI config with empty defaults. The fix is to pass the same JSON config as `settings = { ['shader-validator'] = parsed_json }` in the Neovim `vim.lsp.start()` call.

**pathRemapping only applies to tree-sitter, not DXC.** The server's `pathRemapping` config remaps virtual `Packages/...` paths for the symbol resolution layer, but DXC resolves includes independently through its own search. The workaround is the `.shader-includes/Packages/` symlink directory, which DXC traverses as a normal filesystem path.

**Don't put symlinks in the Unity `Packages/` directory.** Unity's package resolver manages `Packages/` via `manifest.json`. Adding symlinks there causes a wall of `CS0246` / `CS0103` C# compilation errors. Use a dotfile directory (`.shader-includes/`) that Unity ignores.

**DXC emits null bytes in diagnostics.** DXC's C-level error strings are null-terminated, and the server passes them through raw. Neovim treats strings containing `\0` as Blobs, crashing diagnostic display plugins with `E976: Using a Blob as a String`. The fix is a diagnostic handler that strips null bytes before display.

**hassle-rs loads DXC with a relative path.** It uses `dlopen("./libdxcompiler.so")`, not a system library lookup. The `.so` file must be next to the `shader-language-server` binary (typically `~/.cargo/bin/`), not in `/usr/local/lib/`.

**Define conflicts with Unity's include chain.** Defining too many Unity macros (like `UNITY_NEAR_CLIP_VALUE` or `UNITY_REVERSED_Z`) in the JSON config causes redefinition errors because Unity's headers define these internally based on the shader API. Only define the three that headers expect to be set externally: `UNITY_VERSION`, `SHADER_TARGET`, and `SHADER_API_D3D11`.

**hlsl.shaderModel enum format.** The server expects Rust enum variants like `"ShaderModel5"`, not version strings like `"5.0"`. Invalid values cause the config to fail silently — the server prints usage and exits.

**DXC rejects built-in pipeline shaders.** Unity's legacy built-in headers use Cg types (`sampler2D`, `fixed4`) that DXC doesn't understand. If your project uses the built-in pipeline rather than URP, set `"validate": false` in the config and rely on completion/hover/goto-def without diagnostics.

**Package cache hashes change on updates.** Unity's `Library/PackageCache/` directories use hash suffixes (e.g., `com.unity.render-pipelines.core@98474c7606e4`). These change when you update Unity or packages. Re-run `setup-shader-lsp.sh` after any update.

## Repo contents

| File | Purpose |
|---|---|
| `unity-shaders.lua` | Reference Neovim plugin config — filetype detection, LSP autocmd, diagnostic handler |
| `setup-shader-lsp.sh` | Auto-configures a Unity project for shader-language-server |
| `shader-language-server.template.json` | Reference template for manual configuration |
| `Tests/` | 8 compute shader test files to validate the full setup |
| `Tests/DXCTests_README.md` | Expected results for each test |

## Known limitations

- **`.shader` files are not supported.** The server rejects the `shaderlab` language ID. Supporting ShaderLab would require forking the server to parse the wrapper syntax and extract embedded HLSL blocks.
- **Built-in pipeline shaders produce false positives under DXC.** Legacy Cg types are not part of modern HLSL.
- **Only tested on Unity 6 with basic compute shaders.** Complex surface shaders, shader graphs, or other Unity versions may have additional issues.
- **Requires re-running setup after Unity/package updates.** Package cache hashes are not stable across versions.

## Related projects

- [shader-sense / shader-language-server](https://github.com/antaalt/shader-sense) — the LSP this setup is built around
- [shader-validator](https://github.com/antaalt/shader-validator) — VS Code extension using the same backend
- [CGNvim](https://github.com/walcht/CGNvim) — Neovim config for graphics programming (used as initial reference)
- [com.walcht.ide.neovim](https://github.com/walcht/com.walcht.ide.neovim) — Unity editor package for Neovim integration
- [hassle-rs](https://github.com/Traverse-Research/hassle-rs) — Rust FFI bindings for DXC
- [DirectXShaderCompiler](https://github.com/microsoft/DirectXShaderCompiler) — Microsoft's HLSL compiler
- [pema99/UnityShaderParser](https://github.com/pema99/UnityShaderParser) — C# library for parsing ShaderLab and HLSL (potential foundation for `.shader` file support)

## License

MIT
