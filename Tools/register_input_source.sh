#!/bin/sh
# Register a newly installed Ogura as an input source without logging out.
# Registration is per login session, so run this in the account that uses Ogura. Needs the Swift toolchain (Xcode);
# the installer package does the same with a compiled copy of Tools/RegisterInputSource.swift.
set -eu

app_path="${1:-/Library/Input Methods/Ogura.app}"
exec swift "$(dirname "$0")/RegisterInputSource.swift" "$app_path"
