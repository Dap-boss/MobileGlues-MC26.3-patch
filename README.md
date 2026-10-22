> **Unofficial.** This is a community patch set, not affiliated with MobileGL-Dev.
> Issues about the patch belong here; issues about MobileGlues itself belong upstream.
> Prebuilt: [libmobileglues-arm64-v8a.so](https://github.com/Dap-boss/MobileGlues-MC26.3-patch/releases/latest)
# MobileGlues 26.3 适配补丁

让 [MobileGlues](https://github.com/MobileGL-Dev/MobileGlues) 能在 Minecraft Java 26.3（Fabric）上正常编译并渲染的补丁集。
基线版本：MobileGlues `V2.0.0` 之后的 main（commit `97558a69157b033b890958b1e49258c5b51a80c6`，2026-09-22）。

## 背景

MC 26.3 换了渲染架构：core shader 由 glslang 编译、管线走 `RenderPipelines` / `renderpearl`，对 GL 4.x 语义依赖更重。
MG 2.0.0 的 shader 链路（GLSL → glslang → SPIR-V → SPIRV-Cross → GLSL ES）本身没问题，问题出在后处理和绘制提交层，表现为：

- `Failed to load required shader programs`：37 个 `minecraft:pipeline/*` 全部编译失败 → 启动动画后黑屏
- 驱动报错 `L0002: Undeclared variable '_uniform'`、`S0015: Outputs declared as arrays may only be indexed by a constant integral expression`
- 能进世界后帧数被 CPU 侧 GL 提交拖死

## 补丁内容（共 5 个文件，157 行新增）

### 1. `gl/glsl/glsl_for_es.cpp` — 修复 `uniform` 标识符被误拆（黑屏主因）

`process_uniform_declarations()` 用 `compare(scan_pos, 7, "uniform")` 扫描，会把标识符里的子串也当成关键字。
SPIRV-Cross 生成的变量名形如 `_uniform_instance_00_03`，被重写后代码直接碎裂：

```glsl
if (_uniform _instance_00_00 ;        // 原始: if (_uniform_instance_00_03.UseRgss == 1)
```

修复：要求前后都是 token 边界（前一个字符不是 `[_A-Za-z0-9]`，后一个字符是空白）。

### 2. `gl/glsl/glsl_for_es.cpp` — 输出数组动态下标合法化

MC 26.3 的 `oit_add_transmittance.glsl`：

```glsl
layout(location = 0) out vec4 coeff[OIT_COEFF_ATTACHMENT_COUNT];
coeff[attachmentIndex][i] = ...;   // attachmentIndex 是运行期变量
```

桌面 GL 驱动容忍，Adreno/Mali 直接 `S0015` 拒绝，导致所有走 OIT 的管线（text / item / entity / clouds / block / particle …）全部失败。

修复 `legalize_output_arrays()`：把 output 数组搬成全局局部数组，并在 `main()` 结尾按常量下标刷回一组标量 output。

### 3. `gl/framebuffer.cpp` — 冗余 FBO 绑定消除

记录实际下发给驱动的 draw/read 绑定，重复绑定直接返回。FSR1 开启时自动禁用该缓存（FSR1 会绕过缓存直接绑后端）。
实测收益接近 0（26.3 每帧切的是不同 target，重复率低），保留是因为无副作用，且对旧版 MC 有收益。

### 4. `config/settings.cpp` — multidraw 后端首选 `compute`

MC 26.3 的地形提交走 `glMultiDrawElementsBaseVertex`。MG 提供 6 种后端，其中最差的是逐段下发循环。
把 `compute`（一次 compute dispatch 融合全部子批次）提到顺序第一位，其余后端作为回退。

实测（OPPO Reno12 / MT6896 / Mali，MC 26.3 + Sodium）：`glMultiDrawElementsBaseVertex` 的绝对耗时降低约 55%，
渲染线程从 CPU 提交瓶颈转为等待 GPU。

### 5. `gl/multidraw.cpp` + `gl/shader.cpp` — 可选诊断

- 首次选择 multidraw 后端时往 `/sdcard/MG/latest.log` 写一行后端名（release 也能看）
- shader 编译失败时把翻译后的源码 dump 到 `/sdcard/MG/fail_<id>.glsl`

## 构建

环境：Android NDK 27（27.0.12077973 实测可用）、CMake ≥ 3.22、Ninja。

```bash
git clone --recursive https://github.com/MobileGL-Dev/MobileGlues.git
cd MobileGlues
git submodule update --init MobileGlues-cpp/3rdparty/glslang \
    MobileGlues-cpp/3rdparty/SPIRV-Cross \
    MobileGlues-cpp/3rdparty/xxhash \
    MobileGlues-cpp/include/ska
git apply /path/to/mobileglues-mc26.3.patch

cmake -S MobileGlues-cpp -B build -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-21 \
  -DCMAKE_BUILD_TYPE=Release -DANDROID_STL=c++_static
ninja -C build mobileglues
llvm-strip --strip-unneeded build/libmobileglues.so
```

产物：`libmobileglues.so`（arm64-v8a，strip 后约 6.4 MB）。

## 已知问题

- `compute` 后端依赖 ES 3.1 + ≥4 个 SSBO；部分 Mali 驱动上可能不出地形。出现时把 `config/settings.cpp` 里默认顺序改回 `"native", "multiindirect", ...` 即可回退。
- 仅验证过单设备（OPPO Reno12 / MT6896 / Android）。Adreno 与其他 Mali 型号未测。
- MC 26.3 的 Sodium 0.9.2 要求 LWJGL 3.4.3，与 FCL 内置的 3.4.1 有版本校验冲突，与本补丁无关。

## 许可

MobileGlues 采用 **LGPL-2.1**。本仓库只包含补丁与 README，不包含上游代码；
分发含本补丁的 `libmobileglues.so` 时必须同时提供对应源码（上游 + 本补丁即可满足）。
