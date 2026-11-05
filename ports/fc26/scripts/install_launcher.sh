#!/usr/bin/env bash

set -euo pipefail

port_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
launcher_source="$port_dir/launcher"
application=${FC26_LAUNCHER_APP:-/Applications/EA SPORTS FC 26 Port.app}
contents="$application/Contents"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$launcher_source/Info.plist" "$contents/Info.plist"
cp "$launcher_source/FC26Port" "$contents/MacOS/FC26Port"
chmod +x "$contents/MacOS/FC26Port"
if [[ -L $contents/Resources/run.sh ]]; then
    unlink "$contents/Resources/run.sh"
fi
plutil -insert FC26RunnerPath -string "$port_dir/scripts/run.sh" "$contents/Info.plist"

plutil -lint "$contents/Info.plist" >/dev/null
codesign --force --deep --sign - "$application" >/dev/null

echo "Installed FC26 launcher: $application"
echo "Runner: $port_dir/scripts/run.sh"
