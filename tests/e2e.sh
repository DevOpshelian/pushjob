#!/usr/bin/env bash
# End-to-end test of the Bash wrapper against a real Pushgateway.
# Usage: PUSHGATEWAY_URL=http://localhost:9091 tests/e2e.sh
set -euo pipefail

PG="${PUSHGATEWAY_URL:-http://localhost:9091}"
WRAPPER="$(cd "$(dirname "$0")/.." && pwd)/pushjob.sh"
export PUSHJOB_INSTANCE="e2e-host"
fail=0

check() {
  local desc="$1" pattern="$2"
  local metrics
  metrics="$(curl -fsS "${PG}/metrics")"
  if grep -Eq "$pattern" <<<"$metrics"; then
    echo "ok   - $desc"
  else
    echo "FAIL - $desc (pattern: $pattern)"
    fail=1
  fi
}

# 1. Successful job keeps its exit code and pushes success metrics
"$WRAPPER" -j e2e_ok -i 3600 -l env=test -- true
check "success metric" '^batchjob_success\{.*job="e2e_ok".*\} 1$'
check "expected interval" '^batchjob_expected_interval_seconds\{.*job="e2e_ok".*\} 3600$'
check "extra label" 'batchjob_success\{env="test",instance="e2e-host",job="e2e_ok"\}'

# 2. Failed job returns the command exit code
set +e
"$WRAPPER" -j e2e_ok -l env=test -- sh -c 'exit 3'
rc=$?
set -e
if [[ $rc -eq 3 ]]; then echo "ok   - exit code propagated"; else echo "FAIL - exit code $rc != 3"; fail=1; fi
check "failure metric" '^batchjob_success\{.*job="e2e_ok".*\} 0$'
check "exit code metric" '^batchjob_exit_code\{.*job="e2e_ok".*\} 3$'
# POST semantics: last_success from run 1 must survive the failed run 2
check "last_success kept after failure" '^batchjob_last_success_timestamp_seconds\{.*job="e2e_ok".*\} [0-9.e+]+$'
check "last_failure set" '^batchjob_last_failure_timestamp_seconds\{.*job="e2e_ok".*\} [0-9.e+]+$'

# 3. Pushgateway unreachable: job result unchanged
set +e
PUSHGATEWAY_TIMEOUT=2 "$WRAPPER" -u http://127.0.0.1:1 -j e2e_unreachable -- true 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 0 ]]; then echo "ok   - unreachable pushgateway does not fail the job"; else echo "FAIL - rc=$rc"; fail=1; fi

# 4. Invalid input is rejected
set +e
"$WRAPPER" -j 'bad/name' -- true 2>/dev/null
rc=$?
set -e
if [[ $rc -eq 2 ]]; then echo "ok   - invalid job name rejected"; else echo "FAIL - rc=$rc"; fail=1; fi

exit "$fail"
