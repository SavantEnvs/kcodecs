#!/usr/bin/env bash
#
# mayhem/test.sh — RUN KCodecs' own QTest suite (already built by mayhem/build.sh into
# $SRC/build-test/bin/*, with the project's NORMAL flags, no sanitizers). Each binary is a
# dynamically-linked (Qt-linked) QTest executable that performs real known-answer assertions
# (QCOMPARE against the project's own base64/quoted-printable/RFC2047/RFC2231/uuencode/charset
# fixtures) and prints its own summary line on success:
#
#   Totals: <passed> passed, <failed> failed, <skipped> skipped, <blacklisted> blacklisted, <ms>ms
#
# We run each binary OURSELVES and parse THAT line straight out of its stdout — we do NOT go
# through ctest. ctest/meson-style runners judge a case purely by the child's exit code, and under
# the anti-reward-hack sabotage shim the child process itself gets `_exit(0)`'d by its constructor
# before it prints a single byte — so a ctest-based oracle would report "all green" on a neutered
# binary. Parsing the binary's OWN "Totals:" line instead degrades correctly: a neutered process
# never reaches the printf that emits it, so the regex finds nothing and we treat that as a hard
# failure (not a skip) for that binary.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BIN="$SRC/build-test/bin"
total_passed=0
total_failed=0
ran_any=0

# Each entry: binary [extra args...]. kencodingprobertest_bin mirrors upstream's own
# `add_test(... kencodingprobertest_bin "-iterations" "1")` (it is otherwise a benchmark that
# would run many iterations). base64benchmark is a QBENCHMARK-only binary upstream itself marks
# "not run automatically with ctest" — excluded here for the same reason.
declare -a suite=(
  "base45test"
  "codectest"
  "kcharsetstest"
  "kemailaddresstest"
  "rfc2047test"
  "kencodingproberunittest"
  "kencodingprobertest_bin -iterations 1"
)

for entry in "${suite[@]}"; do
  set -- $entry
  bin="$1"; shift
  path="$BIN/$bin"
  if [ ! -x "$path" ]; then
    echo "FATAL: $path missing or not executable — mayhem/build.sh did not stage it" >&2
    total_failed=$(( total_failed + 1 ))
    continue
  fi
  out="$("$path" "$@" 2>&1)"
  rc=$?
  echo "=== $bin $* (rc=$rc) ==="
  echo "$out"
  line="$(printf '%s\n' "$out" | grep -oE 'Totals: [0-9]+ passed, [0-9]+ failed' | tail -1)"
  if [ -z "$line" ]; then
    # No summary line at all (crashed before printing / process was neutered) — a hard failure,
    # never a skip: a missing Totals line is exactly the signature of a sabotaged binary.
    echo "FATAL: $bin produced no 'Totals:' summary line (rc=$rc) — treating as failed" >&2
    total_failed=$(( total_failed + 1 ))
    continue
  fi
  p=$(printf '%s' "$line" | grep -oE '^Totals: [0-9]+' | grep -oE '[0-9]+')
  f=$(printf '%s' "$line" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+')
  total_passed=$(( total_passed + p ))
  total_failed=$(( total_failed + f ))
  ran_any=1
done

if [ "$ran_any" -eq 0 ]; then
  echo "FATAL: no test binary produced a usable Totals line" >&2
  emit_ctrf qtest 0 1 0
  exit 1
fi

emit_ctrf qtest "$total_passed" "$total_failed" 0
