#!/usr/bin/env bash
# perf_test.sh - Performance regression tests for agent-manager

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
AM_BIN="$PROJECT_DIR/am"

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
RESET='\033[0m'

ITERATIONS="${PERF_ITERATIONS:-100}"
BASELINE_P50="${PERF_BASELINE_P50:-500}"
BASELINE_P95="${PERF_BASELINE_P95:-1000}"
BASELINE_P99="${PERF_BASELINE_P99:-2000}"

calculate_percentile() {
    local percentile="$1"
    shift
    local values=("$@")
    local count=${#values[@]}
    local idx=$(( (count * percentile) / 100 ))
    [[ $idx -ge $count ]] && idx=$((count - 1))
    echo "${values[$idx]}"
}

run_perf_test() {
    local test_name="$1"
    local cmd="$2"

    echo "Running: $test_name ($ITERATIONS iterations)"
    echo "Command: $cmd"
    echo ""

    local latencies=()
    local i

    for i in $(seq 1 "$ITERATIONS"); do
        local start_ns end_ns elapsed_ms
        if command -v gdate &>/dev/null; then
            start_ns=$(gdate +%s%N)
        else
            start_ns=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
        fi

        eval "$cmd" >/dev/null 2>&1

        if command -v gdate &>/dev/null; then
            end_ns=$(gdate +%s%N)
        else
            end_ns=$(date +%s%N 2>/dev/null || echo $(($(date +%s) * 1000000000)))
        fi
        elapsed_ms=$(( (end_ns - start_ns) / 1000000 ))

        latencies+=("$elapsed_ms")

        if (( i % 10 == 0 )); then
            printf '\r  Progress: %d/%d' "$i" "$ITERATIONS"
        fi
    done
    printf '\r  Progress: %d/%d\n' "$ITERATIONS" "$ITERATIONS"

    mapfile -t latencies < <(printf '%s\n' "${latencies[@]}" | sort -n)
    unset IFS

    local p50 p95 p99
    p50=$(calculate_percentile 50 "${latencies[@]}")
    p95=$(calculate_percentile 95 "${latencies[@]}")
    p99=$(calculate_percentile 99 "${latencies[@]}")

    echo ""
    echo "Results:"
    printf '  P50: %dms\n' "$p50"
    printf '  P95: %dms\n' "$p95"
    printf '  P99: %dms\n' "$p99"
    echo ""

    local failed=0

    if (( p50 > BASELINE_P50 )); then
        echo -e "${RED}REGRESSION${RESET}: P50 ($p50 ms) exceeds baseline ($BASELINE_P50 ms)"
        failed=1
    else
        echo -e "${GREEN}PASS${RESET}: P50 within baseline"
    fi

    if (( p95 > BASELINE_P95 )); then
        echo -e "${RED}REGRESSION${RESET}: P95 ($p95 ms) exceeds baseline ($BASELINE_P95 ms)"
        failed=1
    else
        echo -e "${GREEN}PASS${RESET}: P95 within baseline"
    fi

    if (( p99 > BASELINE_P99 )); then
        echo -e "${YELLOW}WARNING${RESET}: P99 ($p99 ms) exceeds baseline ($BASELINE_P99 ms)"
    else
        echo -e "${GREEN}PASS${RESET}: P99 within baseline"
    fi

    echo ""
    return $failed
}

main() {
    echo "=== Agent Manager Performance Tests ==="
    echo ""

    if [[ ! -x "$AM_BIN" ]]; then
        echo -e "${RED}ERROR${RESET}: $AM_BIN not found or not executable"
        exit 1
    fi

    echo "Configuration:"
    echo "  Iterations: $ITERATIONS"
    echo "  Baseline P50: ${BASELINE_P50}ms"
    echo "  Baseline P95: ${BASELINE_P95}ms"
    echo "  Baseline P99: ${BASELINE_P99}ms"
    echo ""
    echo "To adjust baselines, set environment variables:"
    echo "  PERF_BASELINE_P50, PERF_BASELINE_P95, PERF_BASELINE_P99"
    echo "To adjust iteration count, set PERF_ITERATIONS"
    echo ""

    local exit_code=0

    if ! run_perf_test "am list-internal" "$AM_BIN list-internal"; then
        exit_code=1
    fi

    echo "=== Performance Test Complete ==="
    exit $exit_code
}

main "$@"
