#!/usr/bin/env bash
# ==============================================================================
# 鸿图 (HongTu EDA) HarmonyOS NEXT 官方完整 CPython 3.12 交叉编译与打包脚本
#
# 说明：
# 1. 鸿图默认已在 C++ 层（libhongtu.so）内置零配置开箱即用的 PocketPy 2.2.0 (Python 3.x)
#    + Clipper2 + GDSII/OASIS 原生脚本引擎，无需运行本脚本即可在真机离线执行版图 Python 脚本。
# 2. 若需进一步在鸿蒙 PC / 平板端启用官方 CPython 3.12 动态库（`libpython3.12.so`）及完整标准库，
#    可在安装了 Command Line Tools / DevEco Studio OHOS SDK 的宿主机执行本脚本：
#      export OHOS_SDK_NATIVE="/path/to/Huawei/Sdk/default/openharmony/native"
#      bash scripts/build_ohos_cpython.sh arm64-v8a
#    编译产物将自动放入 `entry/libs/<abi>/libpython3.12.so` 与 `entry/src/main/resources/rawfile/python312.zip`，
#    `EmbeddedPythonRuntime` 启动时会自动通过 dlopen 识别并无缝切换至 `cpython-native` 模式。
# ==============================================================================
set -euo pipefail

ABI="${1:-arm64-v8a}"
PY_VER="${PY_VER:-3.12.7}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${REPO_ROOT}/.ohos_cpython_build/${ABI}"

if [[ -z "${OHOS_SDK_NATIVE:-}" ]]; then
  echo "请先设置环境变量 OHOS_SDK_NATIVE 指向鸿蒙 SDK native 目录，例如：" >&2
  echo "  export OHOS_SDK_NATIVE=\"\$HOME/Library/Huawei/Sdk/default/openharmony/native\"" >&2
  exit 1
fi

LLVM_BIN="${OHOS_SDK_NATIVE}/llvm/bin"
SYSROOT="${OHOS_SDK_NATIVE}/sysroot"
if [[ ! -x "${LLVM_BIN}/clang" || ! -d "${SYSROOT}" ]]; then
  echo "未在 ${OHOS_SDK_NATIVE} 下找到有效的 llvm/bin/clang 或 sysroot" >&2
  exit 1
fi

case "${ABI}" in
  arm64-v8a)
    TARGET_TRIPLE="aarch64-linux-ohos"
    ;;
  x86_64)
    TARGET_TRIPLE="x86_64-linux-ohos"
    ;;
  *)
    echo "不支持的 ABI: ${ABI}（支持 arm64-v8a 或 x86_64）" >&2
    exit 1
    ;;
esac

mkdir -p "${BUILD_ROOT}"
SRC_TAR="${BUILD_ROOT}/Python-${PY_VER}.tar.xz"
if [[ ! -f "${SRC_TAR}" ]]; then
  echo "[1/4] 下载官方 CPython ${PY_VER} 源码..."
  curl -fL "https://www.python.org/ftp/python/${PY_VER}/Python-${PY_VER}.tar.xz" -o "${SRC_TAR}"
fi

SRC_DIR="${BUILD_ROOT}/Python-${PY_VER}"
rm -rf "${SRC_DIR}"
tar -xf "${SRC_TAR}" -C "${BUILD_ROOT}"

HOST_PY="$(command -v python3.12 || command -v python3)"
echo "[2/4] 使用 ${TARGET_TRIPLE} 交叉编译 libpython3.12.so (BUILD_PYTHON=${HOST_PY})..."

pushd "${SRC_DIR}" >/dev/null
cat > config.site <<'SITE'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_func_getentropy=yes
SITE

export CONFIG_SITE="${SRC_DIR}/config.site"
export CC="${LLVM_BIN}/clang --target=${TARGET_TRIPLE} --sysroot=${SYSROOT}"
export CXX="${LLVM_BIN}/clang++ --target=${TARGET_TRIPLE} --sysroot=${SYSROOT}"
export AR="${LLVM_BIN}/llvm-ar"
export RANLIB="${LLVM_BIN}/llvm-ranlib"
export READELF="${LLVM_BIN}/llvm-readelf"
export CFLAGS="-O3 -fPIC"
export LDFLAGS="-Wl,-soname,libpython3.12.so"

./configure \
  --host="${TARGET_TRIPLE}" \
  --build="$(uname -m)-linux-gnu" \
  --with-build-python="${HOST_PY}" \
  --enable-shared \
  --without-ensurepip \
  --disable-test-modules \
  --prefix="${BUILD_ROOT}/install"

make -j"$(nproc 2>/dev/null || sysctl -n hw.ncpu || echo 4)"
make install
popd >/dev/null

echo "[3/4] 复制 libpython3.12.so 至 entry/libs/${ABI}/..."
mkdir -p "${REPO_ROOT}/entry/libs/${ABI}"
cp -f "${BUILD_ROOT}/install/lib/libpython3.12.so"* "${REPO_ROOT}/entry/libs/${ABI}/libpython3.12.so"
"${LLVM_BIN}/llvm-strip" --strip-unneeded "${REPO_ROOT}/entry/libs/${ABI}/libpython3.12.so" || true

echo "[4/4] 打包精简标准库至 entry/src/main/resources/rawfile/python312.zip..."
mkdir -p "${REPO_ROOT}/entry/src/main/resources/rawfile"
pushd "${BUILD_ROOT}/install/lib/python3.12" >/dev/null
zip -rq "${REPO_ROOT}/entry/src/main/resources/rawfile/python312.zip" . \
  -x "test/*" "idlelib/*" "tkinter/*" "turtledemo/*" "lib2to3/*" "__pycache__/*" "*.pyc"
popd >/dev/null

echo "完成！已生成 entry/libs/${ABI}/libpython3.12.so 与 rawfile/python312.zip。"
