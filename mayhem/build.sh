#!/usr/bin/env bash
#
# mayhem/build.sh — build KCodecs' fuzz harness, standalone reproducer, and its own test suite.
#
# KCodecs already ships an OSS-Fuzz-style libFuzzer harness at
# autotests/ossfuzz/kcodecs_fuzzer.cc (guarded by the upstream CMake option BUILD_FUZZERS, default
# OFF) that drives KCodecs::Codec::encode/decode for base64, quoted-printable, RFC2231, uuencode
# and KEncodingProber over the raw fuzz input — REUSED here verbatim, no new harness file needed.
# We just enable BUILD_FUZZERS=ON with our sanitizer/debug flags threaded through CMAKE_*_FLAGS so
# the upstream option builds it for us; the KF6Codecs library itself gets $SANITIZER_FLAGS AND an
# unconditional -fsanitize=fuzzer-no-link so it carries SanCov coverage even when SANITIZER_FLAGS is
# empty (--build-arg SANITIZER_FLAGS=), not just the harness translation unit.
#
# Produces:
#   /mayhem/kcodecs_fuzzer              libFuzzer harness (ASan+UBSan+SanCov, DWARF3, static-linked)
#   /mayhem/kcodecs_fuzzer-standalone   run-once reproducer for the same harness
#   $SRC/build-test/bin/*               KCodecs' own QTest suite, built with NORMAL (unsanitized)
#                                        flags — mayhem/test.sh only RUNS these.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

# ECM built into the image at /opt/toolchains/ecm (mayhem/Dockerfile); Qt6 (>=6.9.0) from the
# baked sid packages is on the normal system CMake search path already.
export CMAKE_PREFIX_PATH="/opt/toolchains/ecm${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# LIB_BUILD_FLAGS = SANITIZER_FLAGS + SanitizerCoverage (-fsanitize=fuzzer-no-link), added
# UNCONDITIONALLY (even when SANITIZER_FLAGS is empty) — otherwise the fuzzed KF6Codecs code has no
# coverage instrumentation and Mayhem records 0 edges even though the harness itself "fuzzes".
LIB_BUILD_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link"

cd "$SRC"

# Fleet policy: disable LeakSanitizer by default for every ASan-built binary (leaks aren't the bug
# class this fleet fuzzes for; ASan's memory-corruption checks and UBSan stay fully active). Compile
# the __lsan_is_turned_off() hook once and link its object into every binary produced below.
LSAN_OFF_O="/tmp/lsan_off.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$LSAN_OFF_O"

# ---------------------------------------------------------------------------
# 1) Sanitized + coverage-instrumented static build of KF6Codecs + the libFuzzer harness
#    (upstream's own BUILD_FUZZERS=ON CMake target, using $LIB_FUZZING_ENGINE for the link).
#    LIB_FUZZING_ENGINE is passed straight into CMake's target_link_libraries() as ${fuzzing_engine};
#    appending ";$LSAN_OFF_O" makes CMake treat it as a second, separate link item (a bare semicolon
#    in an unquoted CMake variable reference is the list separator) so the lsan_off object gets
#    linked in alongside -fsanitize=fuzzer, with no CMakeLists.txt edits needed.
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-fuzz"
LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE;$LSAN_OFF_O" \
cmake -B "$SRC/build-fuzz" -G Ninja \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$LIB_BUILD_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$LIB_BUILD_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_FUZZERS=ON -DBUILD_TESTING=OFF
cmake --build "$SRC/build-fuzz" -j"$MAYHEM_JOBS"
cp "$SRC/build-fuzz/bin/fuzzers/kcodecs_fuzzer" /mayhem/kcodecs_fuzzer

# ---------------------------------------------------------------------------
# 2) Same harness, linked against $STANDALONE_FUZZ_MAIN instead of libFuzzer: a run-once,
#    non-fuzzer reproducer. Compile the driver as C first (STANDALONE_FUZZ_MAIN is a .c file) and
#    hand CMake the resulting .o as a full path via LIB_FUZZING_ENGINE — target_link_libraries
#    accepts an absolute object-file path as a raw link item, so upstream's CMakeLists (which just
#    does target_link_libraries(kcodecs_fuzzer PRIVATE KF6Codecs ${fuzzing_engine})) needs no edits.
# ---------------------------------------------------------------------------
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o

rm -rf "$SRC/build-standalone"
LIB_FUZZING_ENGINE="/tmp/standalone_main.o;$LSAN_OFF_O" \
cmake -B "$SRC/build-standalone" -G Ninja \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DCMAKE_C_FLAGS="$LIB_BUILD_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_CXX_FLAGS="$LIB_BUILD_FLAGS $DEBUG_FLAGS" \
      -DCMAKE_EXE_LINKER_FLAGS="$SANITIZER_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_FUZZERS=ON -DBUILD_TESTING=OFF
cmake --build "$SRC/build-standalone" -j"$MAYHEM_JOBS"
cp "$SRC/build-standalone/bin/fuzzers/kcodecs_fuzzer" /mayhem/kcodecs_fuzzer-standalone

# ---------------------------------------------------------------------------
# 3) KCodecs' own QTest suite, built with NORMAL (unsanitized) flags — an independent, clean build
#    so mayhem/test.sh stays an honest functional oracle. Statically linked so test.sh needs no
#    LD_LIBRARY_PATH juggling (and so the anti-sabotage check's LD_PRELOAD shim can neuter the
#    binaries cleanly: they're dynamically linked ELFs living under $SRC, outside the shim's
#    /usr,/bin,/lib allow-list).
# ---------------------------------------------------------------------------
rm -rf "$SRC/build-test"
cmake -B "$SRC/build-test" -G Ninja -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" \
      -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTING=ON -DBUILD_FUZZERS=OFF
cmake --build "$SRC/build-test" -j"$MAYHEM_JOBS"
