#!/bin/zsh
# Builds the Core tests in release and runs them in several processes at once: `swift test` runs the tests of one
# process on the main actor one after another (most of them convert), so the processes are what runs in parallel.
# Each test file runs in a process of its own, and the files in `split` below one process per test function. The
# release build threads its code generation (-num-threads), which SwiftPM does not do by default.
#
# The numbers come from the CPU's cores, by performance level (Apple silicon has two or three, the fastest first). The
# build threads its code generation on all of them, as Xcode does. Each test process runs on one core and mostly waits
# for the GPU, which all the processes share: as many processes at a time as the cores of the fastest level and half
# of the others. On an M5 Max (6 super and 12 performance cores), the tests took 12.4 s with 12 processes, 14.7 s with
# 6 and 13.1 s with 18; on an M1 (4 performance and 4 efficiency cores) that is 6 processes.
#
# Usage: Tools/test_core_parallel.sh [--no-build] [--jobs <n>]
#   --no-build   run the tests already built
#   --jobs <n>   processes at a time, in place of the number from the cores
# The build goes to build/core-tests (its own build folder: other flags would rebuild everything) and each process's
# output to build/core-tests-logs. Exits with 1 when a test fails or fewer tests ran than the bundle lists.
set -e -o pipefail
cd "$(dirname "$0")/.."

levels=$(sysctl -n hw.nperflevels 2>/dev/null || echo 0)
cores=0
fastest=0
described=()
for ((level = 0; level < levels; level++)); do
    count=$(sysctl -n "hw.perflevel$level.physicalcpu")
    if [ "$level" -eq 0 ]; then
        fastest=$count
    fi
    cores=$((cores + count))
    described+=("$(sysctl -n "hw.perflevel$level.name") $count")
done
if [ "$cores" -eq 0 ]; then
    # No performance levels (an Intel Mac): every core alike
    cores=$(sysctl -n hw.physicalcpu)
    fastest=$cores
    described=("$cores")
fi
jobs=$(( fastest + (cores - fastest) / 2 ))
build=true
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --no-build) build=false ;;
        --jobs) jobs="${2:?--jobs needs a number}"; shift ;;
        *) echo "Unknown parameter passed: $1"; exit 1 ;;
    esac
    shift
done

echo "CPU: ${(j:, :)described} コア → ビルドのスレッド $cores、テストのプロセス $jobs"
scratch=build/core-tests
logs=build/core-tests-logs
if [ "$build" = true ]; then
    swift build --package-path Core -c release --build-tests -Xswiftc -enable-testing \
        -Xswiftc -num-threads -Xswiftc "$cores" --scratch-path "$scratch"
fi

developer="$(xcode-select -p)"
helper="$developer/Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
bundle="$PWD/$scratch/arm64-apple-macosx/release/CorePackageTests.xctest/Contents/MacOS/CorePackageTests"
frameworks="$developer/Platforms/MacOSX.platform/Developer/Library/Frameworks:$developer/Platforms/MacOSX.platform/Developer/Library/PrivateFrameworks"
libraries="$developer/Platforms/MacOSX.platform/Developer/usr/lib"
rm -rf "$logs"
mkdir -p "$logs"

# One process for each file with tests; the slowest files one process for each of their test functions. A test's id is
# <module>.<suite>/<function>(…)/<file>:<line>:<column> (no suite for a free function), which the filters match
tests=Core/Tests/CoreTests
split=(BackgroundConversionTests.swift TypingPauseTests.swift)
parts=()
for file in $(grep -rl '@Test' --include='*.swift' "$tests" | sort); do
    name=${file:t}
    if (( ${split[(Ie)$name]} )); then
        for function in $(awk '/@Test/ { wanted = 1 } wanted && match($0, /func [A-Za-z0-9_]+\(/) { print substr($0, RSTART + 5, RLENGTH - 6); wanted = 0 }' "$file"); do
            parts+=("${name%.swift}.$function|[./]$function\\(.*\\)/${name//./\\.}:")
        done
    else
        parts+=("${name%.swift}|/${name//./\\.}:")
    fi
done

# macOS drops DYLD_* when it starts a system program (zsh, env), so they go in env's arguments
export frameworks libraries helper bundle logs
# Separated by NUL, so xargs takes the filters as they are
print -N $parts | xargs -0 -P "$jobs" -n 1 zsh -c '
    env DYLD_FRAMEWORK_PATH="$frameworks" DYLD_LIBRARY_PATH="$libraries" \
        "$helper" --test-bundle-path "$bundle" --testing-library swift-testing --filter "${1#*|}" > "$logs/${1%%|*}.log" 2>&1 || true
' part

listed=$(env DYLD_FRAMEWORK_PATH="$frameworks" DYLD_LIBRARY_PATH="$libraries" \
    "$helper" --test-bundle-path "$bundle" --testing-library swift-testing --list-tests 2>/dev/null | grep -c .)
ran=$(grep -ho 'Test run with [0-9]* test' "$logs"/*.log | awk '{ s += $4 } END { print s + 0 }')
failed=0
for log in "$logs"/*.log; do
    if ! grep -q 'Test run with .* passed' "$log"; then
        failed=$((failed + 1))
        echo "失敗: ${log:t:r}"
        grep -E '✘|Fatal|error:' "$log" | head -5
    fi
done
echo "${#parts} プロセスで $ran 件のテストを実行（バンドルにあるのは $listed 件）、失敗したプロセスは $failed"
if [ "$failed" -gt 0 ] || [ "$ran" -lt "$listed" ]; then
    exit 1
fi
