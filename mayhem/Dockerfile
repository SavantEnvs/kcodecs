# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form) for KCodecs (KDE Frameworks text-encoding library).
# Builds ON TOP of the org C/C++ base image (ghcr.io/savantenvs/base), which already provides
# debian + clang/llvm + libFuzzer/afl++ + the identities + the build-contract ENV.
#
# KCodecs is a CMake + Qt6Core + ECM (extra-cmake-modules) library. The upstream CMakeLists.txt
# requires ECM >= 6.30.0 (bumped from 6.29.0 by upstream after this port's original integration —
# resynced 2026-09-09) and Qt6Core >= 6.9.0 — newer than Debian trixie's shipped ECM 6.13.0 /
# Qt 6.8.2. Two additive, image-local fixes (neither touches an upstream file):
#   1. Qt6: pull qt6-base-dev + qt6-tools-dev from Debian SID (pinned via apt preferences so only
#      those packages come from sid, not a full-system upgrade) — precompiled binaries, ~6.10.2,
#      satisfies the >=6.9.0 floor. Fast (~40s, no compilation).
#   2. ECM: build extra-cmake-modules v6.30.0 FROM SOURCE into /opt/toolchains/ecm — it is pure
#      CMake modules (no compiled code), so this takes ~2s.
# Both happen HERE (root, online, at image-build time) so mayhem/build.sh's offline re-run only
# ever does `cmake configure + build` against what's already baked into the image (SPEC §6.5).

FROM ghcr.io/savantenvs/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: undefaulted ARG lets the base ENV (ASan+UBSan, halting) flow through when
# not passed; an explicit --build-arg SANITIZER_FLAGS="..." overrides it.
ARG SANITIZER_FLAGS
ARG COVERAGE_FLAGS=
ARG MAYHEM_JOBS=

USER root

# Qt6 (>=6.9.0) from Debian SID, pinned so ONLY these packages come from sid (Pin-Priority 100
# keeps trixie as the default source for everything else — no accidental full-system upgrade).
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    echo "deb http://deb.debian.org/debian sid main" > /etc/apt/sources.list.d/sid.list && \
    printf 'Package: *\nPin: release a=sid\nPin-Priority: 100\n' > /etc/apt/preferences.d/sid-pin && \
    apt-get update -qq && \
    apt-get install -yq --no-install-recommends -t sid \
        qt6-base-dev qt6-tools-dev \
        cmake ninja-build git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# ECM (>=6.30.0) built from source — pure CMake modules, no compiled code, seconds to build.
# Pinned to a tagged release so the baked toolchain is reproducible.
RUN git clone --depth 1 --branch v6.30.0 \
        https://invent.kde.org/frameworks/extra-cmake-modules.git /opt/toolchains/ecm-src && \
    cmake -S /opt/toolchains/ecm-src -B /opt/toolchains/ecm-build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/opt/toolchains/ecm -DBUILD_TESTING=OFF && \
    cmake --build /opt/toolchains/ecm-build -j"$(nproc)" && \
    cmake --install /opt/toolchains/ecm-build && \
    rm -rf /opt/toolchains/ecm-src /opt/toolchains/ecm-build

USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
