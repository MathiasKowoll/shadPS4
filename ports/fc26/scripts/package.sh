#!/usr/bin/env bash

set -euo pipefail

port_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(cd -- "$port_dir/../.." && pwd)
launcher_dir=$port_dir/launcher
build_dir=${FC26_BUILD_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/port-build}
package_dir=${FC26_PACKAGE_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/port-package}
sign_identity=${FC26_SIGN_IDENTITY:--}
allow_build_paths=${FC26_PACKAGE_ALLOW_BUILD_PATHS:-0}
engine_files=(shadps4 libvulkan.dylib libvulkan_kosmickrisp.dylib)
icd_name=kosmickrisp_mesa_icd.json

if [[ $(uname -m) != arm64 ]]; then
    echo "STOP: the FC26 launcher must be packaged on Apple silicon" >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "STOP: swiftc is required; install Xcode or the Command Line Tools" >&2
    exit 1
fi
case "$allow_build_paths" in
    0|1)
        ;;
    *)
        echo "STOP: FC26_PACKAGE_ALLOW_BUILD_PATHS must be 0 or 1, got: $allow_build_paths" >&2
        exit 2
        ;;
esac
for artifact in "${engine_files[@]}" "$icd_name"; do
    if [[ ! -f $build_dir/$artifact ]]; then
        echo "STOP: engine build is missing $build_dir/$artifact" >&2
        echo "Build the engine with: ports/fc26/scripts/build.sh" >&2
        exit 1
    fi
done
if [[ $(lipo -archs "$build_dir/shadps4") != x86_64 ]]; then
    echo "STOP: $build_dir/shadps4 must be an x86-64 executable" >&2
    exit 1
fi
if [[ $(plutil -extract ICD.library_path raw "$build_dir/$icd_name") != ./libvulkan_kosmickrisp.dylib ]]; then
    echo "STOP: $build_dir/$icd_name must load ./libvulkan_kosmickrisp.dylib" >&2
    exit 1
fi

minimum_macos=$(otool -l "$build_dir/shadps4" | awk '
    $1 == "cmd" && $2 == "LC_BUILD_VERSION" { found = 1 }
    found && $1 == "minos" { print $2; exit }')
if [[ -z $minimum_macos ]]; then
    echo "STOP: cannot read the minimum macOS version of $build_dir/shadps4" >&2
    exit 1
fi

source_dir=
if [[ -f $build_dir/CMakeCache.txt ]]; then
    source_dir=$(sed -n 's/^CMAKE_HOME_DIRECTORY:INTERNAL=//p' "$build_dir/CMakeCache.txt")
fi
build_info=$build_dir/fc26-build-info.json
if [[ -f $build_info && ! $build_dir/shadps4 -nt $build_info ]]; then
    engine_revision=$(plutil -extract engine_revision raw "$build_info")
    kosmickrisp_revision=$(plutil -extract kosmickrisp_revision raw "$build_info")
else
    if [[ -z $source_dir ]] || ! git -C "$source_dir" rev-parse HEAD >/dev/null 2>&1; then
        echo "STOP: cannot identify the engine source of $build_dir" >&2
        echo "Build the engine with: ports/fc26/scripts/build.sh" >&2
        exit 1
    fi
    engine_revision=$(git -C "$source_dir" rev-parse --short=12 HEAD)
    if [[ -n $(git -C "$source_dir" status --porcelain --untracked-files=no) ]]; then
        engine_revision+=-dirty
    fi
    kosmickrisp_revision=$(git -C "$source_dir/externals/mesa-kosmickrisp" rev-parse --short=12 HEAD)
    if [[ -f $build_info ]]; then
        echo "WARNING: shadps4 is newer than $build_info (rebuilt outside build.sh)." >&2
    else
        echo "WARNING: $build_info is missing." >&2
    fi
    echo "The revision is the source checkout's current state, which can differ from the state" >&2
    echo "the engine was built from: $engine_revision" >&2
fi
license_source=$source_dir
if [[ -z $license_source || ! -d $license_source/externals ]]; then
    license_source=$repo_dir
fi

app_name=$(plutil -extract CFBundleName raw "$launcher_dir/Info.plist")
launcher_version=$(plutil -extract CFBundleShortVersionString raw "$launcher_dir/Info.plist")
package_name=FC26Port-$launcher_version-$engine_revision-macos-arm64
destination=$package_dir/$package_name
if [[ -e $destination ]]; then
    echo "STOP: $destination already exists; move it away or set FC26_PACKAGE_DIR" >&2
    exit 1
fi

mkdir -p "$package_dir"
staging=$(mktemp -d "$package_dir/.staging.XXXXXX")
trap 'rm -rf "$staging"' EXIT
app=$staging/$package_name/$app_name.app
contents=$app/Contents
mkdir -p "$contents/MacOS" "$contents/Resources/licenses"

xcrun swiftc -swift-version 5 -parse-as-library -O -whole-module-optimization \
    -target "arm64-apple-macos$minimum_macos" \
    -file-prefix-map "$launcher_dir/Sources=Sources" \
    -o "$contents/MacOS/FC26Port" "$launcher_dir"/Sources/*.swift

for artifact in "${engine_files[@]}"; do
    cp "$build_dir/$artifact" "$contents/MacOS/$artifact"
    strip -S "$contents/MacOS/$artifact" 2> >(grep -v 'invalidate the code signature' >&2)
done
sed 's#"\./libvulkan_kosmickrisp\.dylib"#"../MacOS/libvulkan_kosmickrisp.dylib"#' \
    "$build_dir/$icd_name" >"$contents/Resources/$icd_name"
if [[ $(plutil -extract ICD.library_path raw "$contents/Resources/$icd_name") != \
    ../MacOS/libvulkan_kosmickrisp.dylib ]]; then
    echo "STOP: cannot point $icd_name at the bundled driver" >&2
    exit 1
fi
ln -s "../Resources/$icd_name" "$contents/MacOS/$icd_name"

cp "$port_dir/profile.json" "$contents/Resources/profile.json"
cp "$port_dir/config/managed.json" "$contents/Resources/managed.json"
cat >"$contents/Resources/build-info.json" <<EOF
{
  "engine_revision": "$engine_revision",
  "kosmickrisp_revision": "$kosmickrisp_revision",
  "launcher_version": "$launcher_version",
  "minimum_macos": "$minimum_macos",
  "packaged_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

cp "$launcher_dir/Info.plist" "$contents/Info.plist"
plutil -replace LSMinimumSystemVersion -string "$minimum_macos" "$contents/Info.plist"
plutil -replace NSMicrophoneUsageDescription \
    -string "The PS4 game can use a microphone, for example for voice chat." "$contents/Info.plist"
plutil -lint "$contents/Info.plist" >/dev/null

cp "$repo_dir/LICENSE" "$contents/Resources/licenses/shadPS4-LICENSE.txt"
while IFS= read -r license; do
    relative=${license#"$license_source/externals/"}
    cp "$license" "$contents/Resources/licenses/${relative//\//-}"
done < <(find "$license_source/externals" -maxdepth 4 -type f \
    \( -iname 'LICENSE*' -o -iname 'COPYING*' -o -iname 'NOTICE*' \) -not -path '*/.git/*' |
    sort)
mesa_dir=$license_source/externals/mesa-kosmickrisp/externals/mesa
if [[ -f $mesa_dir/docs/license.rst ]]; then
    cp "$mesa_dir/docs/license.rst" "$contents/Resources/licenses/mesa-license.rst"
fi
for license in "$mesa_dir"/licenses/*; do
    if [[ -f $license ]]; then
        cp "$license" "$contents/Resources/licenses/mesa-licenses-${license##*/}"
    fi
done
if [[ ! -f $contents/Resources/licenses/vulkan-loader-LICENSE.txt ||
    ! -f $contents/Resources/licenses/mesa-license.rst ]]; then
    echo "STOP: third-party licenses are missing under $license_source/externals" >&2
    echo "Initialize the engine source's submodules: git submodule update --init --recursive" >&2
    exit 1
fi
cat >"$contents/Resources/licenses/README.txt" <<EOF
This application contains shadPS4, the Khronos Vulkan loader and the Mesa KosmicKrisp Vulkan
driver, built from the EA SPORTS FC 26 port of shadPS4 (https://github.com/MathiasKowoll/shadPS4)
at revision $engine_revision, with KosmicKrisp $kosmickrisp_revision. shadPS4 is licensed under
GPL-2.0-or-later. The files in this folder are the licenses found in the engine source tree.

The application contains no game files, firmware, keys or shader caches. Players supply their own
PS4 dump of EA SPORTS FC 26 and their own PS4 system modules.
EOF

forbidden=$(find "$app" \( -iname '*.sprx' -o -iname '*.prx' -o -iname 'eboot.bin' \
    -o -iname 'param.sfo' -o -iname '*.pkg' -o -iname 'CUSA*' -o -iname '*.spv' \) -print)
if [[ -n $forbidden ]]; then
    echo "STOP: the package contains game or cache files:" >&2
    echo "$forbidden" >&2
    exit 1
fi

personal_paths=0
while IFS= read -r -d '' file; do
    count=$({ LC_ALL=C grep -a -o -E '/(Users|Volumes)/[^/[:cntrl:]]+/' "$file" || true; } |
        wc -l | tr -d ' ')
    if ((count > 0)); then
        echo "${file#"$staging/$package_name/"}: $count embedded /Users or /Volumes paths" >&2
        personal_paths=$((personal_paths + count))
    fi
done < <(find "$app" -type f -print0)
if ((personal_paths > 0)); then
    if [[ $allow_build_paths != 1 ]]; then
        echo "STOP: the package embeds $personal_paths build-machine paths (source paths in" >&2
        echo "assertion messages). Rebuild the engine with path remapping before distributing," >&2
        echo "or set FC26_PACKAGE_ALLOW_BUILD_PATHS=1 for a local test package." >&2
        exit 1
    fi
    echo "WARNING: local test package: it embeds $personal_paths build-machine paths" >&2
fi

if [[ $sign_identity == - ]]; then
    for artifact in "${engine_files[@]}"; do
        codesign --force --sign - "$contents/MacOS/$artifact"
    done
    codesign --force --sign - "$app"
    signing="ad-hoc"
else
    echo "WARNING: Developer ID signing with the hardened runtime has not been validated with" >&2
    echo "the engine yet; test the signed app before distributing it." >&2
    for artifact in libvulkan.dylib libvulkan_kosmickrisp.dylib; do
        codesign --force --timestamp --options runtime --sign "$sign_identity" \
            "$contents/MacOS/$artifact"
    done
    codesign --force --timestamp --options runtime --sign "$sign_identity" \
        --entitlements "$launcher_dir/engine.entitlements" "$contents/MacOS/shadps4"
    codesign --force --timestamp --options runtime --sign "$sign_identity" \
        --entitlements "$launcher_dir/launcher.entitlements" "$app"
    signing=$sign_identity
fi
codesign --verify --deep --strict "$app"

archive=$staging/$package_name/$package_name.zip
ditto -c -k --norsrc --noextattr --noacl --keepParent "$app" "$archive"
(cd "$staging/$package_name" && shasum -a 256 "$package_name.zip" >"$package_name.zip.sha256")
mv "$staging/$package_name" "$destination"

echo "FC26 launcher package: $destination/$app_name.app"
echo "Archive: $destination/$package_name.zip ($(du -h "$destination/$package_name.zip" | cut -f1))"
echo "SHA-256: $(cut -d' ' -f1 "$destination/$package_name.zip.sha256")"
echo "Engine: $engine_revision, KosmicKrisp: $kosmickrisp_revision, minimum macOS $minimum_macos"
echo "Signing: $signing"
