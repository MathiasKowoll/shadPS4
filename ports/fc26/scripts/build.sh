#!/usr/bin/env bash

set -euo pipefail

port_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(cd -- "$port_dir/../.." && pwd)
build_dir=${FC26_BUILD_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/port-build}
jobs=${FC26_BUILD_JOBS:-8}
python=${FC26_PYTHON:-$(command -v python3.15 || true)}
python_env=$build_dir/python-venv

if [[ $(uname -m) != arm64 ]]; then
    echo "STOP: the FC26 macOS build must be created on Apple silicon" >&2
    exit 1
fi
if ! command -v cmake >/dev/null; then
    echo "STOP: cmake is required" >&2
    exit 1
fi
if ! command -v ninja >/dev/null; then
    echo "STOP: ninja is required" >&2
    exit 1
fi
if [[ -z $python || ! -x $python ]]; then
    echo "STOP: Python 3.15 is required to build KosmicKrisp" >&2
    exit 1
fi
if git -C "$repo_dir" submodule status --recursive | grep -q '^-'; then
    echo "STOP: submodules are incomplete; run git submodule update --init --recursive" >&2
    exit 1
fi

if [[ ! -x $python_env/bin/python ]]; then
    "$python" -m venv "$python_env"
fi
if ! "$python_env/bin/python" -c 'import mako, packaging, yaml' 2>/dev/null; then
    "$python_env/bin/python" -m pip install \
        'Mako==1.3.10' 'packaging==25.0' 'PyYAML==6.0.3'
fi
export PATH="$python_env/bin:$PATH"

cmake -S "$repo_dir" -B "$build_dir" -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DCMAKE_OSX_ARCHITECTURES=x86_64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=26.0
cmake --build "$build_dir" --parallel "$jobs"

for artifact in shadps4 libvulkan.dylib libvulkan_kosmickrisp.dylib \
    kosmickrisp_mesa_icd.json; do
    if [[ ! -e $build_dir/$artifact ]]; then
        echo "STOP: build completed without $build_dir/$artifact" >&2
        exit 1
    fi
done

engine_revision=$(git -C "$repo_dir" rev-parse --short=12 HEAD)
if [[ -n $(git -C "$repo_dir" status --porcelain --untracked-files=no) ]]; then
    engine_revision+=-dirty
fi
cat >"$build_dir/fc26-build-info.json" <<EOF
{
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "engine_revision": "$engine_revision",
  "kosmickrisp_revision": "$(git -C "$repo_dir/externals/mesa-kosmickrisp" rev-parse --short=12 HEAD)"
}
EOF

file "$build_dir/shadps4"
echo "FC26 port engine built from $(git -C "$repo_dir" rev-parse --short HEAD)"
echo "Build directory: $build_dir"

