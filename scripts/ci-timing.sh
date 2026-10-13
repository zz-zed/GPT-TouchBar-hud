#!/usr/bin/env bash
# Optional timing; never changes the arguments, flags, or exit status of a test.

ci_time() {
    local phase="$1" label="$2"
    shift 2
    if [[ -z "${CI_TIMING_DIR:-}" ]]; then
        "$@"
    else
        python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ci_timing.py" \
            run --phase "$phase" --label "$label" -- "$@"
    fi
}

# Every existing script that sources the module-cache helper gets compiler
# measurements. Absolute compiler paths used for SDK/version queries bypass this.
swiftc() {
    if [[ -z "${CI_TIMING_DIR:-}" ]]; then
        command swiftc "$@"
    else
        ci_time compile-link "$(basename "${BASH_SOURCE[1]}"):swiftc" "$(type -P swiftc)" "$@"
    fi
}
