#!/bin/bash
# Run all test suites. Requires Xcode and Node.js.
set -uo pipefail
cd "$(dirname "$0")" || exit 1

usage() { printf 'Usage: %s [--cov]\n' "$0"; }
coverage=NO
case "${1-}" in
    "") ;;
    --cov) coverage=YES ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then usage >&2; exit 2; fi

mkdir -p build.noindex/UITests/Results || exit 1
result_dir=$(mktemp -d "build.noindex/UITests/Results/run.XXXXXXXX") || exit 1
result_bundle="$result_dir/UITests.xcresult"
failed=0
total_passed=0
total_failed=0
total_skipped=0
summary_complete=1

run_suite() {
    local log="$1"
    shift
    if "$@" > "$log" 2>&1; then
        return 0
    fi
    failed=1
    cat "$log" >&2
    printf '\nLog: %s\n' "$log" >&2
    return 1
}

print_counts() {
    local name="$1" counts="$2" passed failures skipped
    if [ -z "$counts" ]; then
        printf '%-12s counts unavailable\n' "$name"
        summary_complete=0
        failed=1
        return
    fi
    read -r passed failures skipped <<< "$counts"
    printf '%-12s %3d run, %3d passed, %3d failed' "$name" "$((passed + failures))" "$passed" "$failures"
    if [ "$skipped" -ne 0 ]; then printf ', %d skipped' "$skipped"; fi
    printf '\n'
    total_passed=$((total_passed + passed))
    total_failed=$((total_failed + failures))
    total_skipped=$((total_skipped + skipped))
    if [ "$failures" -ne 0 ]; then failed=1; fi
}

swift_flags=(--disable-swift-testing --disable-code-coverage)
if [ "$coverage" = YES ]; then
    swift_flags=(--disable-swift-testing --enable-code-coverage)
fi
swift_status=0
run_suite "$result_dir/swift.log" swift test "${swift_flags[@]}" || swift_status=1
run_suite "$result_dir/web.log" node test/tree.test.js || true
ui_status=0
run_suite "$result_dir/ui.log" xcodebuild test \
    -project MDPreview.xcodeproj \
    -scheme MDPreviewUI \
    -destination platform=macOS \
    -derivedDataPath build.noindex/UITests \
    -resultBundlePath "$result_bundle" \
    -enableCodeCoverage "$coverage" \
    -quiet || ui_status=1

swift_counts=$(awk '
    /^Test Case .* skipped / { skipped++ }
    /^[[:space:]]*Executed [0-9]+ tests?, with [0-9]+ failures?/ {
        tests = $2; failures = $5; found = 1
    }
    END { if (found) print tests - failures - skipped, failures, skipped + 0 }
' "$result_dir/swift.log")
web_counts=$(awk '/^[[:space:]]*Passed: [0-9]+[[:space:]]+Failed: [0-9]+/ { print $2, $4, 0 }' "$result_dir/web.log")
ui_counts=""
if [ -d "$result_bundle" ]; then
    ui_counts=$(xcrun xcresulttool get test-results summary --path "$result_bundle" --format json |
        python3 -c 'import json, sys
report = json.load(sys.stdin)
print(report["passedTests"], report["failedTests"], report["skippedTests"])') || ui_counts=""
fi

printf '\n=== Test summary ===\n'
print_counts Swift "$swift_counts"
print_counts Web "$web_counts"
print_counts "macOS UI" "$ui_counts"
if [ "$summary_complete" -eq 1 ]; then
    print_counts Total "$total_passed $total_failed $total_skipped"
fi

if [ "$coverage" = YES ]; then
    printf '\n=== Swift line coverage ===\n'
    if [ "$swift_status" -eq 0 ] && swift_coverage=$(xcrun llvm-cov report \
        .build/debug/FileScannerTests.xctest/Contents/MacOS/FileScannerTests \
        -instr-profile .build/debug/codecov/default.profdata \
        -ignore-filename-regex 'Tests/|\.build/' |
        awk '/^TOTAL / { printf "%s (%d/%d lines)\n", $10, $8-$9, $8; found=1 }
             END { if (!found) exit 1 }'); then
        printf 'Swift suite  %s\n' "$swift_coverage"
    else
        printf 'Swift suite  unavailable\n'
        failed=1
    fi

    if [ -d "$result_bundle" ] && ui_coverage=$(xcrun xccov view --report --json "$result_bundle" |
        python3 -c 'import json, sys
report = json.load(sys.stdin)
target = next(t for t in report["targets"] if t["name"] == "MDPreview.app")
print("{:.2%} ({}/{} lines)".format(target["lineCoverage"], target["coveredLines"], target["executableLines"]))'); then
        printf 'UI suite     %s' "$ui_coverage"
        if [ "$ui_status" -ne 0 ]; then printf ' (partial; suite failed)'; fi
        printf '\n'
    else
        printf 'UI suite     unavailable\n'
        failed=1
    fi
    printf 'Coverage is measured separately for each suite. Web JavaScript is excluded.\n'
fi

exit "$failed"
