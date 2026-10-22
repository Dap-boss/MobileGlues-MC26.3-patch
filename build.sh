#!/usr/bin/env bash
# 一键复现脚本：拉取上游 MobileGlues、应用本仓库补丁、编译出 libmobileglues.so
#
# 用法:
#   ./build.sh                     # 默认 arm64-v8a, Release
#   ABI=x86_64 ./build.sh          # 其它架构
#   NDK=/path/to/ndk ./build.sh    # 手动指定 NDK（默认走环境变量/Android SDK）
#   SRC_DIR=./MobileGlues ./build.sh
#
# 环境要求: git, cmake >= 3.22, ninja, Android NDK 27（其它版本未测）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ABI="${ABI:-arm64-v8a}"
PLATFORM="${PLATFORM:-android-21}"
BUILD_TYPE="${BUILD_TYPE:-Release}"
SRC_DIR="${SRC_DIR:-$SCRIPT_DIR/MobileGlues}"
BUILD_DIR="${BUILD_DIR:-$SCRIPT_DIR/build-$ABI}"
# 基线 commit：补丁就是基于它生成的
MG_REF="${MG_REF:-97558a69157b033b890958b1e49258c5b51a80c6}"
MG_REPO="${MG_REPO:-https://github.com/MobileGL-Dev/MobileGlues.git}"
PATCH_FILE="${PATCH_FILE:-$SCRIPT_DIR/patches/mobileglues-mc26.3.patch}"

log() { printf '\033[1;32m[build]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

find_ndk() {
    if [[ -n "${NDK:-}" ]]; then echo "$NDK"; return; fi
    if [[ -n "${ANDROID_NDK_HOME:-}" ]]; then echo "$ANDROID_NDK_HOME"; return; fi
    if [[ -n "${ANDROID_NDK_ROOT:-}" ]]; then echo "$ANDROID_NDK_ROOT"; return; fi
    local sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    if [[ -n "$sdk" && -d "$sdk/ndk" ]]; then
        # 取版本号最大的那个
        ls -1 "$sdk/ndk" | sort -V | tail -n 1 | sed "s|^|$sdk/ndk/|"
        return
    fi
    return 1
}

NDK_PATH="$(find_ndk || true)"
[[ -n "$NDK_PATH" && -d "$NDK_PATH" ]] || die "找不到 NDK。请设置 NDK=/path/to/android-ndk-r27"

TOOLCHAIN="$NDK_PATH/build/cmake/android.toolchain.cmake"
[[ -f "$TOOLCHAIN" ]] || die "NDK 路径不对，缺少 $TOOLCHAIN"

for bin in git cmake ninja; do
    command -v "$bin" >/dev/null || die "缺少 $bin"
done

# 1. 准备源码
if [[ ! -d "$SRC_DIR/.git" ]]; then
    log "clone 上游到 $SRC_DIR"
    git clone --recursive "$MG_REPO" "$SRC_DIR"
    git -C "$SRC_DIR" checkout "$MG_REF"
    git -C "$SRC_DIR" submodule update --init --recursive
else
    log "复用已有源码 $SRC_DIR"
fi

# 2. 打补丁（已打过就跳过）
if git -C "$SRC_DIR" apply --check "$PATCH_FILE" 2>/dev/null; then
    log "应用补丁 $(basename "$PATCH_FILE")"
    git -C "$SRC_DIR" apply "$PATCH_FILE"
else
    log "补丁已应用或无法应用，跳过（如需重来：git -C $SRC_DIR checkout -- MobileGlues-cpp）"
fi

# 3. 配置 + 编译
log "配置 ($ABI / $BUILD_TYPE)"
cmake -S "$SRC_DIR/MobileGlues-cpp" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$(command -v ninja)" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
    -DANDROID_ABI="$ABI" \
    -DANDROID_PLATFORM="$PLATFORM" \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DANDROID_STL=c++_static

log "编译"
ninja -C "$BUILD_DIR" mobileglues

SO="$BUILD_DIR/libmobileglues.so"
[[ -f "$SO" ]] || die "编译产物不存在: $SO"

# 4. strip（减小体积，保留符号可选）
STRIP="$NDK_PATH/toolchains/llvm/prebuilt/*/bin/llvm-strip"
for s in $STRIP; do
    if [[ -x "$s" ]]; then
        "$s" --strip-unneeded "$SO"
        break
    fi
done

log "完成: $SO ($(du -h "$SO" | cut -f1))"
echo
echo "安装到设备/启动器时放到: lib/<abi>/libmobileglues.so"
