#!/usr/bin/env bash
# pushjob.sh — run a command and push its execution metrics to a Prometheus Pushgateway.
#
# Usage:
#   pushjob.sh -j <job_name> [-i <expected_interval_seconds>] [-l key=value]... [-u <pushgateway_url>] -- <command> [args...]
#
# Environment:
#   PUSHGATEWAY_URL         Pushgateway base URL (default: http://localhost:9091)
#   PUSHGATEWAY_BASIC_AUTH  Optional "user:password" for basic auth
#   PUSHGATEWAY_TIMEOUT     curl max time in seconds (default: 5)
#   PUSHJOB_INSTANCE        Value of the "instance" grouping label (default: short hostname)
#
# The wrapped command's exit code is always returned. A Pushgateway failure is
# logged on stderr but never changes the exit code of your job.

set -uo pipefail

readonly PUSHJOB_VERSION="1.0.0"
readonly LABEL_NAME_RE='^[a-zA-Z_][a-zA-Z0-9_]*$'
readonly LABEL_VALUE_RE='^[a-zA-Z0-9_.:-]+$'

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

log() { printf '[pushjob] %s\n' "$*" >&2; }

now() {
  # EPOCHREALTIME (bash >= 5) gives sub-second precision; fall back to whole seconds.
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    printf '%s' "${EPOCHREALTIME/,/.}"
  else
    date +%s
  fi
}

job_name=""
expected_interval=""
pushgateway_url="${PUSHGATEWAY_URL:-http://localhost:9091}"
instance="${PUSHJOB_INSTANCE:-$(hostname -s 2>/dev/null || hostname)}"
declare -a extra_labels=()

while getopts ":j:i:l:u:hV" opt; do
  case "$opt" in
    j) job_name="$OPTARG" ;;
    i) expected_interval="$OPTARG" ;;
    l) extra_labels+=("$OPTARG") ;;
    u) pushgateway_url="$OPTARG" ;;
    h) usage 0 ;;
    V) echo "pushjob ${PUSHJOB_VERSION}"; exit 0 ;;
    :) log "option -$OPTARG requires a value"; usage 2 ;;
    \?) log "unknown option -$OPTARG"; usage 2 ;;
  esac
done
shift $((OPTIND - 1))
[[ "${1:-}" == "--" ]] && shift

if [[ -z "$job_name" || $# -eq 0 ]]; then
  log "a job name (-j) and a command are required"
  usage 2
fi
if ! [[ "$job_name" =~ $LABEL_VALUE_RE ]]; then
  log "invalid job name '$job_name' (allowed: letters, digits, _ . : -)"
  exit 2
fi
if ! [[ "$instance" =~ $LABEL_VALUE_RE ]]; then
  log "invalid instance '$instance' (set PUSHJOB_INSTANCE)"
  exit 2
fi
if [[ -n "$expected_interval" && ! "$expected_interval" =~ ^[0-9]+$ ]]; then
  log "expected interval (-i) must be an integer number of seconds"
  exit 2
fi

grouping_path="/metrics/job/${job_name}/instance/${instance}"
# ${arr[@]+...} keeps bash < 4.4 happy with an empty array under set -u
for kv in ${extra_labels[@]+"${extra_labels[@]}"}; do
  key="${kv%%=*}"
  value="${kv#*=}"
  if [[ "$kv" != *=* ]] || ! [[ "$key" =~ $LABEL_NAME_RE ]] || ! [[ "$value" =~ $LABEL_VALUE_RE ]]; then
    log "invalid label '$kv' (expected key=value, value chars: letters, digits, _ . : -)"
    exit 2
  fi
  if [[ "$key" == "job" || "$key" == "instance" ]]; then
    log "label '$key' is reserved"
    exit 2
  fi
  grouping_path+="/${key}/${value}"
done

start="$(now)"
"$@"
exit_code=$?
end="$(now)"

duration="$(awk -v s="$start" -v e="$end" 'BEGIN { printf "%.3f", e - s }')"
end_int="${end%.*}"

body="# TYPE batchjob_duration_seconds gauge
batchjob_duration_seconds ${duration}
# TYPE batchjob_exit_code gauge
batchjob_exit_code ${exit_code}
# TYPE batchjob_last_run_timestamp_seconds gauge
batchjob_last_run_timestamp_seconds ${end_int}
"
if [[ $exit_code -eq 0 ]]; then
  body+="# TYPE batchjob_success gauge
batchjob_success 1
# TYPE batchjob_last_success_timestamp_seconds gauge
batchjob_last_success_timestamp_seconds ${end_int}
"
else
  body+="# TYPE batchjob_success gauge
batchjob_success 0
# TYPE batchjob_last_failure_timestamp_seconds gauge
batchjob_last_failure_timestamp_seconds ${end_int}
"
fi
if [[ -n "$expected_interval" ]]; then
  body+="# TYPE batchjob_expected_interval_seconds gauge
batchjob_expected_interval_seconds ${expected_interval}
"
fi

# POST (not PUT): only metrics with the same name are replaced, so
# last_success survives a failed run and last_failure survives a successful one.
declare -a curl_args=(--silent --show-error --fail --max-time "${PUSHGATEWAY_TIMEOUT:-5}"
  -X POST --data-binary @- "${pushgateway_url%/}${grouping_path}")
if [[ -n "${PUSHGATEWAY_BASIC_AUTH:-}" ]]; then
  curl_args=(-u "$PUSHGATEWAY_BASIC_AUTH" "${curl_args[@]}")
fi

if ! printf '%s' "$body" | curl "${curl_args[@]}"; then
  log "WARNING: failed to push metrics for job '$job_name' to ${pushgateway_url}"
fi

exit "$exit_code"
