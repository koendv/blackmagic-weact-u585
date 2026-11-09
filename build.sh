#!/usr/bin/env bash
#
# Clone upstream Black Magic Debug and bmpflash, apply the patches in patches/, and build:
#  - the Black Magic Debug firmware for the WeAct Black Pill STM32U585
#  - bmpflash for Linux (x86_64)
#  - bmpflash for Windows (x86_64, MinGW-w64)
#
# Meant to run inside the image from docker/Dockerfile, see README.md. Results go to $OUT.
# Every *_REF can be overridden from the environment, e.g. BMD_REF=main to test against upstream main.

set -euo pipefail

# Pinned upstream revisions the patches are known to apply to and build with
: "${BMD_REPO:=https://codeberg.org/blackmagic-debug/blackmagic.git}"
: "${BMD_REF:=7f2ba9b3434cce835be51fe48d87b69774ba4446}"
: "${LIBOPENCM3_REPO:=https://codeberg.org/blackmagic-debug/libopencm3.git}"
: "${LIBOPENCM3_REF:=3622b6a078b45390c0da625e695d6f5e4cda8ba9}"
: "${BMPFLASH_REPO:=https://codeberg.org/blackmagic-debug/bmpflash.git}"
: "${BMPFLASH_REF:=06cde6b9c033e4af9571a440506cda88c91efb67}"
: "${SUBSTRATE_REPO:=https://github.com/bad-alloc-heavy-industries/substrate.git}"
: "${SUBSTRATE_REF:=cf4f3c55ce9695a558ddeb61518c9ad4ea5aef17}"

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WORK:=${TOP}/work}"
: "${OUT:=${TOP}/out}"

# This repository's revision, part of the version strings: its tag on a release build, its commit otherwise
: "${REPO_REV:=$(git -C "${TOP}" describe --tags --always --dirty 2>/dev/null || echo unknown)}"

# git am needs an identity to record the patched commits with
export GIT_COMMITTER_NAME="${GIT_COMMITTER_NAME:-weact-u585 build}"
export GIT_COMMITTER_EMAIL="${GIT_COMMITTER_EMAIL:-build@localhost}"

log() { printf '\n==> %s\n' "$*"; }

# fetch <repo> <ref> <dir>: check out a branch, tag or commit, shallow where the server allows it
fetch() {
	local repo="$1" ref="$2" dir="$3"
	rm -rf "${dir}"
	git init -q "${dir}"
	git -C "${dir}" remote add origin "${repo}"
	# Retry with back-off: Codeberg rate limits unauthenticated traffic, which shared CI runner IPs can hit
	local attempt delay=15
	for attempt in 1 2 3 4; do
		if git -C "${dir}" fetch -q --depth 1 origin "${ref}"; then
			git -C "${dir}" -c advice.detachedHead=false checkout -q FETCH_HEAD
			break
		fi
		# The server may refuse a shallow fetch of an unadvertised commit, so also try fetching everything
		if git -C "${dir}" fetch -q origin '+refs/heads/*:refs/remotes/origin/*' '+refs/tags/*:refs/tags/*'; then
			git -C "${dir}" -c advice.detachedHead=false checkout -q "${ref}" 2>/dev/null \
				|| git -C "${dir}" -c advice.detachedHead=false checkout -q "origin/${ref}"
			break
		fi
		if [ "${attempt}" -eq 4 ]; then
			echo "error: could not fetch ${ref} from ${repo}" >&2
			return 1
		fi
		echo "warning: fetching ${repo} failed (attempt ${attempt}), retrying in ${delay}s" >&2
		sleep "${delay}"
		delay=$((delay * 2))
	done
	printf '%-11s %s %s\n' "$(basename "${dir}")" "$(git -C "${dir}" rev-parse HEAD)" "${ref}" >> "${OUT}/versions.txt"
}

# fetch_history <dir>: fetch the full history and tags of a checkout, so `git describe` finds the release tags
fetch_history() {
	local dir="$1" attempt delay=15
	for attempt in 1 2 3 4; do
		if git -C "${dir}" fetch -q --unshallow --tags origin; then
			return 0
		fi
		if [ "${attempt}" -eq 4 ]; then
			echo "error: could not fetch the history of $(git -C "${dir}" remote get-url origin)" >&2
			return 1
		fi
		echo "warning: fetching history failed (attempt ${attempt}), retrying in ${delay}s" >&2
		sleep "${delay}"
		delay=$((delay * 2))
	done
}

# version_tag <dir> <upstream description>: tag the patched tree so `git describe`, and with it the version
# string meson builds into the binary, names the upstream commit and this repository's revision
version_tag() {
	local dir="$1" upstream="$2"
	local version="${upstream}+weact-u585.${REPO_REV}"
	git -C "${dir}" tag -f "${version}" >/dev/null
	printf '%-11s %s\n' "version" "$(basename "${dir}") ${version}" >> "${OUT}/versions.txt"
}

# apply <dir> <patch dir>: apply a patch series as commits
apply() {
	local dir="$1" patches="$2"
	shopt -s nullglob
	local series=("${patches}"/*.patch)
	shopt -u nullglob
	if [ "${#series[@]}" -gt 0 ]; then
		git -C "${dir}" am -q --3way "${series[@]}"
	fi
}

rm -rf "${OUT}"
mkdir -p "${WORK}" "${OUT}"
: > "${OUT}/versions.txt"

log "Fetching sources"
fetch "${BMD_REPO}" "${BMD_REF}" "${WORK}/blackmagic"
# Black Magic Debug versions are derived from its release tags, which need the history
fetch_history "${WORK}/blackmagic"
# Populate the libopencm3 subproject ourselves, its wrap file follows upstream head
fetch "${LIBOPENCM3_REPO}" "${LIBOPENCM3_REF}" "${WORK}/blackmagic/deps/libopencm3"
fetch "${BMPFLASH_REPO}" "${BMPFLASH_REF}" "${WORK}/bmpflash"
# Likewise substrate, whose wrap file follows upstream head
fetch "${SUBSTRATE_REPO}" "${SUBSTRATE_REF}" "${WORK}/bmpflash/deps/substrate"

# Describe the upstream commits before patching (bmpflash has no release tags, so that is its commit hash)
BMD_UPSTREAM="$(git -C "${WORK}/blackmagic" describe --tags --always)"
BMPFLASH_UPSTREAM="$(git -C "${WORK}/bmpflash" describe --tags --always)"

log "Applying patches"
apply "${WORK}/blackmagic" "${TOP}/patches/blackmagic"
apply "${WORK}/bmpflash" "${TOP}/patches/bmpflash"
version_tag "${WORK}/blackmagic" "${BMD_UPSTREAM}"
version_tag "${WORK}/bmpflash" "${BMPFLASH_UPSTREAM}"

log "Building Black Magic Debug firmware for the WeAct Black Pill STM32U585"
(
	cd "${WORK}/blackmagic"
	rm -rf build
	meson setup build --cross-file=cross-file/weact-u585.ini
	meson compile -C build
	for ext in elf bin; do
		cp "build/blackmagic_weact_u585_firmware.${ext}" "${OUT}/blackmagic-weact-u585-firmware.${ext}"
	done
	arm-none-eabi-objcopy -O ihex build/blackmagic_weact_u585_firmware.elf "${OUT}/blackmagic-weact-u585-firmware.hex"
	arm-none-eabi-size build/blackmagic_weact_u585_firmware.elf
)

log "Building bmpflash for Linux (x86_64)"
(
	cd "${WORK}/bmpflash"
	rm -rf build-linux
	meson setup build-linux \
		--native-file="${TOP}/cross-file/linux-x86_64.ini" \
		--force-fallback-for=libusb-1.0 \
		-Ddefault_library=static \
		-Dlibusb:udev=disabled
	meson compile -C build-linux
	cp build-linux/src/bmpflash "${OUT}/bmpflash-linux-x86_64"
	strip "${OUT}/bmpflash-linux-x86_64"
)

log "Building bmpflash for Windows (x86_64, MinGW-w64)"
(
	cd "${WORK}/bmpflash"
	rm -rf build-windows
	meson setup build-windows \
		--cross-file="${TOP}/cross-file/mingw-w64-x86_64.ini" \
		-Ddefault_library=static
	meson compile -C build-windows
	cp build-windows/src/bmpflash.exe "${OUT}/bmpflash-windows-x86_64.exe"
	x86_64-w64-mingw32-strip "${OUT}/bmpflash-windows-x86_64.exe"
)

log "Results"
cat "${OUT}/versions.txt"
(cd "${OUT}" && file -- * && sha256sum -- * > SHA256SUMS)
