# DXC Validation Test Suite

Drop these `.compute` files into `Assets/Shaders/Compute/DXCTests/` in your
Unity project (EmptyURPForFuckingAround) and open each one in nvim. Check the
diagnostics from shader-language-server.

## Test Matrix

| # | File                            | Expected Result         | What It Tests                                      |
|---|----------------------------------|-------------------------|----------------------------------------------------|
| 1 | DXCTest_01_BasicCompute          | **CLEAN** — no errors   | Basic HLSL: types, RWBuffer, numthreads, semantics |
| 2 | DXCTest_02_StructsAndBuffers     | **CLEAN** — no errors   | Structs, cbuffer, groupshared, atomics, barriers   |
| 3 | DXCTest_03_URPInclude            | **CLEAN** — no errors   | URP Core.hlsl include via .shader-includes symlink |
| 4 | DXCTest_04_BuiltinPipeline       | **ERRORS** — expected   | UnityCG.cginc legacy Cg types (sampler2D, fixed4)  |
| 5 | DXCTest_05_WaveIntrinsics        | **CLEAN** — no errors   | SM6 wave ops (the whole reason we built DXC)       |
| 6 | DXCTest_06_IntentionalErrors     | **3 ERRORS** — expected | Undeclared id, type mismatch, missing semicolon    |
| 7 | DXCTest_07_TextureSampling       | **CLEAN** — no errors   | Texture2D, SamplerState, RWTexture2D, SampleLevel  |
| 8 | DXCTest_08_Defines               | **CLEAN** — no errors   | JSON defines passed through: SHADER_API_D3D11 etc  |

## How to check

1. Open each file in nvim
2. Wait a moment for shader-language-server to validate
3. Check diagnostics: `:lua vim.print(vim.diagnostic.get(0))`
4. Or just look at diagflow / inline diagnostics

## What a pass looks like

- Tests 1, 2, 3, 5, 7, 8: **Zero diagnostics** (empty table from `vim.diagnostic.get(0)`)
- Test 4: Errors about `sampler2D`, `fixed4`, etc — confirms DXC rejects legacy Cg
- Test 6: Exactly 3 errors at the annotated lines — confirms diagnostics work

## What a failure looks like

- Tests 1, 2, 7: Errors here mean DXC itself isn't loading (check lsp.log for glslang fallback)
- Test 3: "file not found" means .shader-includes symlinks or include path is wrong
- Test 5: Wave intrinsic errors mean you're still on glslang, not DXC
- Test 8: `#error` means defines from .shader-language-server.json aren't reaching DXC
