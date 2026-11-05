#!/usr/bin/env bash

set -euo pipefail

port_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
repo_dir=$(cd -- "$port_dir/../.." && pwd)
game_dir=${FC26_GAME_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/CUSA52342}
data_dir=${FC26_DATA_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/port-data}
build_dir=${FC26_BUILD_DIR:-/Volumes/CrucialX8/Emulation/Ps4/FC26/port-build}
binary=${FC26_BINARY:-$build_dir/shadps4}
fullscreen=${FC26_FULLSCREEN:-false}
config_mode=${FC26_CONFIG_MODE:-preserve}
run_profile=${FC26_RUN_PROFILE:-performance}
log_filter=${FC26_LOG_FILTER:-*:warning Render.Vulkan:info}
metrics_enabled=${FC26_METRICS:-1}
metal_hud_enabled=${FC26_METAL_HUD:-0}
vblank_frequency=${FC26_VBLANK_FREQUENCY:-60}
flip_rate_override=${FC26_FLIP_RATE_OVERRIDE:-0}
trace_imports=${FC26_TRACE_IMPORTS:-}
patch_file=${FC26_PATCH_FILE:-}
network_mode=${FC26_NETWORK:-preserve}
direct_memory_access=${FC26_DIRECT_MEMORY_ACCESS:-preserve}
mode=run
verify_hashes=0

report_system_module_readiness() {
    local sys_modules_dir=$data_dir/user/sys_modules
    local required_modules=(
        libSceJson.sprx
        libSceJson2.sprx
        libSceAudiodec.sprx
    )
    local missing_modules=()

    for module in "${required_modules[@]}"; do
        if [[ ! -f $sys_modules_dir/$module ]]; then
            missing_modules+=("$module")
        fi
    done

    if ((${#missing_modules[@]} == 0)); then
        echo "FC26 menu-media system modules: ready ($sys_modules_dir)"
        return
    fi

    echo "WARNING: FC26 menu-media system modules are missing: ${missing_modules[*]}" >&2
    echo "Place modules dumped from your legally owned PS4 in: $sys_modules_dir" >&2
}

for argument in "$@"; do
    case "$argument" in
        --check)
            mode=check
            ;;
        --verify)
            mode=check
            verify_hashes=1
            ;;
        --dry-run)
            mode=dry-run
            ;;
        *)
            echo "STOP: unknown argument: $argument" >&2
            exit 2
            ;;
    esac
done

survey_args=("$game_dir")
if [[ $verify_hashes == 1 || ${FC26_VERIFY:-0} == 1 ]]; then
    survey_args+=(--verify-hashes)
fi
mkdir -p "$data_dir/reports"
python3 "$port_dir/scripts/survey.py" "${survey_args[@]}" \
    --output "$data_dir/reports/latest-survey.json" >/dev/null

if [[ $mode == check ]]; then
    echo "FC26 PS4 profile is valid: CUSA52342 01.25"
    echo "Report: $data_dir/reports/latest-survey.json"
    report_system_module_readiness
    exit 0
fi

if [[ ! -x $binary ]]; then
    echo "STOP: shadPS4 binary is missing: $binary" >&2
    echo "Build this worktree with: ports/fc26/scripts/build.sh" >&2
    exit 1
fi

build_dir=$(cd -- "$(dirname -- "$binary")" && pwd)
icd=$build_dir/kosmickrisp_mesa_icd.json
driver=$build_dir/libvulkan_kosmickrisp.dylib
loader=$build_dir/libvulkan.dylib
for required in "$icd" "$driver" "$loader"; do
    if [[ ! -f $required ]]; then
        echo "STOP: required graphics runtime is missing: $required" >&2
        exit 1
    fi
done

mkdir -p "$data_dir/user" "$data_dir/logs"
report_system_module_readiness
managed_config=$port_dir/config/managed.json
runtime_config=$data_dir/user/config.json
case "$config_mode" in
    managed)
        cp "$managed_config" "$runtime_config"
        ;;
    preserve)
        if [[ ! -f $runtime_config ]]; then
            cp "$managed_config" "$runtime_config"
        fi
        ;;
    *)
        echo "STOP: FC26_CONFIG_MODE must be managed or preserve, got: $config_mode" >&2
        exit 2
        ;;
esac

case "$run_profile" in
    performance)
        python3 - "$runtime_config" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["Log"].update(
    enable=False,
    sync=False,
)
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
        ;;
    diagnostic)
        if [[ -z $log_filter ]]; then
            echo "STOP: FC26_LOG_FILTER must not be empty in diagnostic mode" >&2
            exit 2
        fi
        python3 - "$runtime_config" "$log_filter" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["Log"].update(
    enable=True,
    filter=sys.argv[2],
    sync=False,
)
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
        ;;
    *)
        echo "STOP: FC26_RUN_PROFILE must be performance or diagnostic, got: $run_profile" >&2
        exit 2
        ;;
esac

case "$network_mode" in
    online|offline)
        python3 - "$runtime_config" "$network_mode" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["Network"]["connected_to_network"] = sys.argv[2] == "online"
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
        ;;
    preserve)
        ;;
    *)
        echo "STOP: FC26_NETWORK must be online, offline, or preserve, got: $network_mode" >&2
        exit 2
        ;;
esac

case "$direct_memory_access" in
    0|1)
        python3 - "$runtime_config" "$direct_memory_access" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["GPU"]["direct_memory_access_enabled"] = sys.argv[2] == "1"
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
        ;;
    preserve)
        ;;
    *)
        echo "STOP: FC26_DIRECT_MEMORY_ACCESS must be 0, 1, or preserve, got: $direct_memory_access" >&2
        exit 2
        ;;
esac

if [[ ! $vblank_frequency =~ ^[0-9]+$ ]] || ((vblank_frequency < 30 || vblank_frequency > 240)); then
    echo "STOP: FC26_VBLANK_FREQUENCY must be an integer from 30 to 240" >&2
    exit 2
fi
python3 - "$runtime_config" "$vblank_frequency" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text(encoding="utf-8"))
config["GPU"]["vblank_frequency"] = int(sys.argv[2])
path.write_text(json.dumps(config, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

case "$flip_rate_override" in
    auto)
        ;;
    0|1|2|3)
        ;;
    *)
        echo "STOP: FC26_FLIP_RATE_OVERRIDE must be auto or an integer from 0 to 3" >&2
        exit 2
        ;;
esac

command=("$binary" --show-fps --fullscreen "$fullscreen")
if [[ -n $patch_file ]]; then
    if [[ ! -f $patch_file ]]; then
        echo "STOP: FC26_PATCH_FILE does not exist: $patch_file" >&2
        exit 1
    fi
    command+=(--patch "$patch_file")
fi
command+=("$game_dir")
metrics_dir=$data_dir/metrics
metrics_file=$metrics_dir/last-run.csv
case "$metrics_enabled" in
    0|1)
        ;;
    *)
        echo "STOP: FC26_METRICS must be 0 or 1, got: $metrics_enabled" >&2
        exit 2
        ;;
esac
case "$metal_hud_enabled" in
    0|1)
        ;;
    *)
        echo "STOP: FC26_METAL_HUD must be 0 or 1, got: $metal_hud_enabled" >&2
        exit 2
        ;;
esac
if [[ $mode == dry-run ]]; then
    printf 'cd %q\n' "$data_dir"
    printf 'VK_DRIVER_FILES=%q ' "$icd"
    printf 'DYLD_LIBRARY_PATH=%q ' "$build_dir"
    if [[ $metrics_enabled == 1 ]]; then
        printf 'SHADPS4_FRAME_METRICS_PATH=%q ' "$metrics_file"
    fi
    if [[ $metal_hud_enabled == 1 ]]; then
        printf 'MTL_HUD_ENABLED=1 '
    fi
    if [[ $flip_rate_override != auto ]]; then
        printf 'SHADPS4_VIDEOOUT_FLIP_RATE_OVERRIDE=%q ' "$flip_rate_override"
    fi
    printf '%q ' "${command[@]}"
    printf '\n'
    exit 0
fi

cache_tool=(python3 "$port_dir/scripts/shader_cache.py" --data-dir "$data_dir" --build-dir "$build_dir")
"${cache_tool[@]}" prepare
"${cache_tool[@]}" snapshot --label pre-run --if-present

export VK_DRIVER_FILES=$icd
export DYLD_LIBRARY_PATH="$build_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
if [[ $metrics_enabled == 1 ]]; then
    mkdir -p "$metrics_dir"
    if [[ -f $metrics_file ]]; then
        mv -f "$metrics_file" "$metrics_dir/previous-run.csv"
    fi
    export SHADPS4_FRAME_METRICS_PATH=$metrics_file
else
    unset SHADPS4_FRAME_METRICS_PATH
fi
if [[ $metal_hud_enabled == 1 ]]; then
    export MTL_HUD_ENABLED=1
else
    unset MTL_HUD_ENABLED
fi
if [[ $flip_rate_override == auto ]]; then
    unset SHADPS4_VIDEOOUT_FLIP_RATE_OVERRIDE
else
    export SHADPS4_VIDEOOUT_FLIP_RATE_OVERRIDE=$flip_rate_override
fi
if [[ -n $trace_imports ]]; then
    export SHADPS4_TRACE_IMPORTS=$trace_imports
else
    unset SHADPS4_TRACE_IMPORTS
fi
# Measured on FC26 gameplay (2026-11-05): buffer uploads before the session instead of splitting
# the open render pass (31 -> 43 FPS average), the 1x1 luminance readback without a GPU drain on
# every submit, and one fault per hot 64 KB block instead of one per 4 KB page (42% fewer faults;
# every long clean session ran with it). Each can be turned off by setting it to 0 before launching.
export SHADPS4_DEFER_UPLOADS=${SHADPS4_DEFER_UPLOADS:-1}
export SHADPS4_ASYNC_IMAGE_READBACK=${SHADPS4_ASYNC_IMAGE_READBACK:-1}
export SHADPS4_FAULT_EXPAND=${SHADPS4_FAULT_EXPAND:-1}
log=$data_dir/logs/last-run.console.log
if [[ -f $log ]]; then
    mv -f "$log" "$data_dir/logs/previous-run.console.log"
fi
echo "FC26 PS4 port: CUSA52342 01.25, 1920x1080 baseline, no upscaler"
echo "Data: $data_dir"
echo "Config: $config_mode ($runtime_config)"
echo "Run profile: $run_profile"
echo "Network: $network_mode"
echo "Direct memory access: $direct_memory_access"
if [[ $run_profile == diagnostic ]]; then
    echo "Log filter: $log_filter"
fi
echo "Vblank frequency: $vblank_frequency Hz"
echo "Video-out flip-rate override: $flip_rate_override"
if [[ -n $trace_imports ]]; then
    echo "Import trace: $trace_imports"
fi
echo "Patch: ${patch_file:-disabled}"
echo "Frame metrics: $([[ $metrics_enabled == 1 ]] && echo "$metrics_file" || echo disabled)"
echo "Metal HUD: $([[ $metal_hud_enabled == 1 ]] && echo enabled || echo disabled)"
cd "$data_dir"
set +e
"${command[@]}" 2>&1 | tee "$log"
run_exit_code=${PIPESTATUS[0]}
set -e
if ! "${cache_tool[@]}" snapshot --label post-run --exit-code "$run_exit_code" --if-present; then
    echo "WARNING: shader cache snapshot failed; preserving the partial archive" >&2
    "${cache_tool[@]}" prepare || true
fi
exit "$run_exit_code"

