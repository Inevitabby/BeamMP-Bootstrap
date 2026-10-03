#!/usr/bin/env bash
#
# COMPILE.sh - build the latest tagged BeamMP Launcher + Server for Linux.
#
# Place this script next to the repos:
#   ./COMPILE.sh  ./BeamMP-Launcher  ./BeamMP-Server
# Missing repos are cloned automatically, and vcpkg is installed into ./vcpkg
# if it doesn't exist. The BeamMP client mod is downloaded by the Launcher at
# runtime, so it is not built here.
#
# Optional environment overrides:
#   LAUNCHER_TAG=v2.x.y      build this Launcher tag instead of the latest
#   SERVER_TAG=v3.x.y        build this Server tag instead of the latest
#   VCPKG_ROOT=/path         use an existing vcpkg checkout
#   VCPKG_TARGET_TRIPLET=... default: x64-linux
#   JOBS=N                   default: nproc
#
# Output: ./dist/ (binaries + VERSIONS.txt) and a shareable .tar.gz in ./

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAUNCHER_DIR="$ROOT/BeamMP-Launcher"
SERVER_DIR="$ROOT/BeamMP-Server"
DIST_DIR="$ROOT/dist"

: "${VCPKG_ROOT:=$ROOT/vcpkg}"
: "${VCPKG_TARGET_TRIPLET:=x64-linux}"
: "${JOBS:=$(nproc)}"
: "${LAUNCHER_TAG:=}"
: "${SERVER_TAG:=}"
export VCPKG_ROOT VCPKG_DISABLE_METRICS=1

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWarning: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# --- sanity checks -----------------------------------------------------------
for cmd in git cmake make gcc g++ curl zip unzip tar pkg-config; do
    command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
done

# --- repos -------------------------------------------------------------------
clone_if_missing() {
    local url="$1" dir="$2"
    if [[ ! -d "$dir/.git" ]]; then
        log "Cloning $(basename "$dir")"
        git clone "$url" "$dir"
    fi
}

# Fetches tags and checks out the requested tag (or the latest one).
# Sets CHECKED_OUT_TAG.
checkout_tag() {
    local dir="$1" wanted="${2:-}" rev
    git -C "$dir" fetch --tags --force --prune
    if [[ -n "$wanted" ]]; then
        CHECKED_OUT_TAG="$wanted"
    else
        rev="$(git -C "$dir" rev-list --tags --max-count=1)"
        [[ -n "$rev" ]] || die "no tags found in $dir"
        CHECKED_OUT_TAG="$(git -C "$dir" describe --tags "$rev")"
    fi
    git -C "$dir" checkout "$CHECKED_OUT_TAG"
    git -C "$dir" submodule update --init --recursive --jobs 4
}

# --- vcpkg -------------------------------------------------------------------
ensure_vcpkg() {
    if [[ ! -d "$VCPKG_ROOT/.git" && ! -x "$VCPKG_ROOT/vcpkg" ]]; then
        log "Installing vcpkg into $VCPKG_ROOT"
        # Borrow objects from the Server's vcpkg submodule (if present) to avoid
        # downloading ~110 MB twice; --dissociate makes the copy self-contained.
        git clone --reference-if-able "$SERVER_DIR/.git/modules/vcpkg" --dissociate \
            https://github.com/microsoft/vcpkg.git "$VCPKG_ROOT"
    elif [[ -d "$VCPKG_ROOT/.git" ]]; then
        # Keep the checkout recent so it knows the manifest baseline of new tags.
        git -C "$VCPKG_ROOT" pull --ff-only \
            || warn "could not update vcpkg; continuing with the existing checkout"
    fi
    if [[ ! -x "$VCPKG_ROOT/vcpkg" ]]; then
        "$VCPKG_ROOT/bootstrap-vcpkg.sh" -disableMetrics
    fi
}

# --- build -------------------------------------------------------------------
build_launcher() {
    log "Building Launcher ($LAUNCHER_VERSION)"
    cmake -S "$LAUNCHER_DIR" -B "$LAUNCHER_DIR/bin" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_TOOLCHAIN_FILE="$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake" \
        -DVCPKG_TARGET_TRIPLET="$VCPKG_TARGET_TRIPLET"
    cmake --build "$LAUNCHER_DIR/bin" --parallel "$JOBS"
}

build_server() {
    log "Building Server ($SERVER_VERSION)"
    # sol2 3.3.1 (pinned by the Server) has a never-instantiated template bug that
    # GCC 14+ reports as a hard error; -Wno-template-body defers it to instantiation.
    cmake -S "$SERVER_DIR" -B "$SERVER_DIR/bin" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_CXX_FLAGS="-Wno-template-body"
    cmake --build "$SERVER_DIR/bin" --parallel "$JOBS" --config Release -t BeamMP-Server
}

# --- main --------------------------------------------------------------------
clone_if_missing https://github.com/BeamMP/BeamMP-Launcher.git "$LAUNCHER_DIR"
clone_if_missing https://github.com/BeamMP/BeamMP-Server.git   "$SERVER_DIR"

log "Checking out latest Launcher tag"
checkout_tag "$LAUNCHER_DIR" "$LAUNCHER_TAG"
LAUNCHER_VERSION="$CHECKED_OUT_TAG"

log "Checking out latest Server tag"
checkout_tag "$SERVER_DIR" "$SERVER_TAG"
SERVER_VERSION="$CHECKED_OUT_TAG"

ensure_vcpkg
build_launcher
build_server

# --- package -----------------------------------------------------------------
LAUNCHER_BIN="$LAUNCHER_DIR/bin/BeamMP-Launcher"
SERVER_BIN="$SERVER_DIR/bin/BeamMP-Server"
[[ -x "$LAUNCHER_BIN" ]] || die "Launcher binary not found at $LAUNCHER_BIN"
[[ -x "$SERVER_BIN"   ]] || die "Server binary not found at $SERVER_BIN"

log "Packaging into $DIST_DIR"
rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"
cp "$LAUNCHER_BIN" "$SERVER_BIN" "$DIST_DIR/"
strip --strip-unneeded "$DIST_DIR/BeamMP-Launcher" "$DIST_DIR/BeamMP-Server" 2>/dev/null || true

cat > "$DIST_DIR/VERSIONS.txt" <<EOF
BeamMP-Launcher: $LAUNCHER_VERSION
BeamMP-Server:   $SERVER_VERSION
Triplet:         $VCPKG_TARGET_TRIPLET
Built:           $(date -u +'%Y-%m-%d %H:%M UTC')
EOF

ARCHIVE="$ROOT/beammp-linux_launcher-${LAUNCHER_VERSION}_server-${SERVER_VERSION}.tar.gz"
tar -czf "$ARCHIVE" -C "$DIST_DIR" .

log "Done"
cat "$DIST_DIR/VERSIONS.txt"
echo
echo "Binaries: $DIST_DIR"
echo "Archive:  $ARCHIVE"
