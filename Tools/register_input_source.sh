#!/bin/sh
# Register a newly installed Ogura as an input source without logging out.
# Registration is per login session, so run this in the account that uses Ogura.
set -eu

app_path="${1:-/Library/Input Methods/Ogura.app}"
if [ ! -d "$app_path" ]; then
    echo "not found: $app_path" >&2
    exit 1
fi

swift - "$app_path" <<'SWIFT'
import Carbon
let path = CommandLine.arguments[1]
let status = TISRegisterInputSource(URL(fileURLWithPath: path) as CFURL)
if status != noErr {
    print("TISRegisterInputSource failed: \(status)")
    exit(1)
}
print("registered: \(path)")
SWIFT
