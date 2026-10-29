# Shared helpers for lab/run-lab.sh and lab/run-runtime-lab.sh (sourced, not run).
#
# Every check prints one line:
#   PASS  <what was checked and the value seen>
#   FAIL  <what was checked>: expected <x>, got <y>
#   SKIP  <check that this machine cannot run, and why>
# summary() prints the totals at the end and returns 1 if any check failed, so the
# script's exit code is 0 only when everything passed. Colours are used only when the
# output is a terminal, so `| tee lab.log` gives a clean log file.

if [[ -t 1 ]]; then
  _B=$'\033[1m' _G=$'\033[32m' _R=$'\033[31m' _Y=$'\033[33m' _N=$'\033[0m'
else
  _B='' _G='' _R='' _Y='' _N=''
fi
PASSED=0 FAILED=0 SKIPPED=0 FAILURES=() CURRENT_STEP="start" SUMMARY_DONE=''

step() { CURRENT_STEP=$*; printf '\n%s==> %s%s\n' "$_B" "$*" "$_N"; }
pass() { PASSED=$((PASSED + 1)); printf '  %sPASS%s  %s\n' "$_G" "$_N" "$*"; }
fail() { FAILED=$((FAILED + 1)); FAILURES+=("[$CURRENT_STEP] $*"); printf '  %sFAIL%s  %s\n' "$_R" "$_N" "$*"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  %sSKIP%s  %s\n' "$_Y" "$_N" "$*"; }

# check "description" command [args...]: PASS if the command succeeds.
check() { local d=$1; shift; if "$@"; then pass "$d"; else fail "$d"; fi; }

# expect "what" "<got>" "<want>": PASS if equal. The FAIL line shows both values.
expect() {
  if [[ "$2" == "$3" ]]; then pass "$1: $2"; else fail "$1: expected $3, got ${2:-nothing}"; fi
}

# accepted "description" file...: PASS if the API server accepts the manifests (dry run).
accepted() {
  local d=$1 out f args=(); shift
  for f; do args+=(-f "$f"); done
  if out=$(kubectl apply --dry-run=server "${args[@]}" 2>&1); then pass "$d"
  else printf '%s\n' "$out"; fail "$d"; fi
}

# wait_for <seconds> command [args...]: retry every 2 s until the command succeeds.
wait_for() {
  local end=$((SECONDS + $1)); shift
  until "$@"; do
    if (( SECONDS >= end )); then return 1; fi
    sleep 2
  done
}

# cpu_m <quantity>: Kubernetes CPU quantity in millicores (25m -> 25, 1 -> 1000, 0.5 -> 500).
cpu_m() {
  if [[ $1 == *m ]]; then echo "${1%m}"
  else awk -v v="$1" 'BEGIN { printf "%d\n", v * 1000 + 0.5 }'; fi
}

# summary ["note"]: totals, the list of failures, then an optional closing note.
summary() {
  SUMMARY_DONE=1
  local f total=$((PASSED + FAILED))
  printf '\n%s==> Summary%s\n' "$_B" "$_N"
  printf '%d check%s: %s%d passed%s, %s%d failed%s' "$total" "$([[ $total -eq 1 ]] || echo s)" \
    "$_G" "$PASSED" "$_N" "$([[ $FAILED -gt 0 ]] && echo "$_R")" "$FAILED" "$_N"
  if (( SKIPPED > 0 )); then printf ', %d skipped' "$SKIPPED"; fi
  printf '\n'
  for f in "${FAILURES[@]}"; do printf '  %sFAIL%s  %s\n' "$_R" "$_N" "$f"; done
  if [[ -n ${1:-} ]]; then printf '%s\n' "$1"; fi
  (( FAILED == 0 ))
}

# If a command fails outside a check (no network, cluster missing...), say where.
_lab_on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && -z $SUMMARY_DONE ]]; then
    printf '\n%sSTOPPED%s during "%s": a command failed (exit code %d). The error is above.\n' \
      "$_R" "$_N" "$CURRENT_STEP" "$rc"
    printf 'Checks before the stop: %d passed, %d failed.\n' "$PASSED" "$FAILED"
  fi
}
trap _lab_on_exit EXIT
