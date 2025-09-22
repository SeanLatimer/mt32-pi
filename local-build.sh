#!/usr/bin/env bash
set -euo pipefail

# -------- Config (override via env or flags) --------
BOARDS_DEFAULT="pi2 pi3-64 pi4-64"
BOARDS="${BOARDS:-$BOARDS_DEFAULT}"
JOBS="${JOBS:-$(nproc || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"
WITH_HDMI="${WITH_HDMI:-1}"

# Optional: prepend extra bin dirs if you want, but not required
ARM_EABI_BIN="${ARM_EABI_BIN:-}"     # e.g. /opt/arm-none-eabi/bin
AARCH64_BIN="${AARCH64_BIN:-}"       # e.g. /opt/aarch64-none-elf/bin

# Optional soundfont inclusion
SOUNDFONT_PATH="${SOUNDFONT_PATH:-}" # path to "GeneralUser GS v1.511.sf2"

OUT_DIR="${OUT_DIR:-out}"
SDCARD_DIR="${SDCARD_DIR:-$OUT_DIR/sdcard}"

BOOT_HOME="external/circle-stdlib/libs/circle/boot"
WLAN_HOME="external/circle-stdlib/libs/circle/addon/wlan"

usage() {
  cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --boards "pi2 pi3-64 pi4-64"   Boards to build (default: "$BOARDS_DEFAULT")
  --jobs N                       Parallel build jobs (default: auto)
  --with-hdmi 0|1                Also build HDMI_CONSOLE variant (default: $WITH_HDMI)
  --arm-eabi-bin DIR             Prepend DIR to PATH for arm-none-eabi-* (optional)
  --aarch64-bin DIR              Prepend DIR to PATH for aarch64-none-elf-* (optional)
  --soundfont PATH               Include GeneralUser GS v1.511.sf2 from PATH (optional)
  --out DIR                      Output dir (default: $OUT_DIR)
  --help                         Show help

Notes:
- Toolchains must already be on PATH (directly or via your own ccache wrappers).
- No downloads are performed.
EOF
}

msg() { printf "\n\033[1;34m==> %s\033[0m\n" "$*"; }
warn(){ printf "\033[1;33m[warn]\033[0m %s\n" "$*" >&2; }
die() { printf "\033[1;31m[err]\033[0m %s\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --boards) BOARDS="$2"; shift 2;;
    --jobs) JOBS="$2"; shift 2;;
    --with-hdmi) WITH_HDMI="$2"; shift 2;;
    --arm-eabi-bin) ARM_EABI_BIN="$2"; shift 2;;
    --aarch64-bin) AARCH64_BIN="$2"; shift 2;;
    --soundfont) SOUNDFONT_PATH="$2"; shift 2;;
    --out) OUT_DIR="$2"; shift 2;;
    --help|-h) usage; exit 0;;
    *) die "Unknown arg: $1";;
  esac
done

[[ -f Makefile ]] || die "Run from repo root (Makefile not found)."

if [[ -n "$ARM_EABI_BIN" ]]; then export PATH="$ARM_EABI_BIN:$PATH"; fi
if [[ -n "$AARCH64_BIN" ]]; then export PATH="$AARCH64_BIN:$PATH"; fi

# Verify toolchains (whatever is first in PATH — wrappers or real — will be used)
need() { command -v "$1" >/dev/null || die "Missing tool on PATH: $1"; }
msg "Checking external toolchains (from PATH)"
need arm-none-eabi-gcc
need arm-none-eabi-g++
need aarch64-none-elf-gcc
need aarch64-none-elf-g++

# Submodules
msg "Fetching submodules"
make submodules

# Build
mkdir -p "$OUT_DIR/kernels" "$OUT_DIR/kernels-hdmi"

kernel_name_for_board() {
  case "$1" in
    pi2)     echo "kernel7" ;;
    pi3)     echo "kernel8-32" ;;
    pi3-64)  echo "kernel8" ;;
    pi4)     echo "kernel7l" ;;
    pi4-64)  echo "kernel8-rpi4" ;;
    *) die "Unknown board: $1" ;;
  esac
}

for board in $BOARDS; do
  kname="$(kernel_name_for_board "$board")"

  msg "Resetting state for $board"
  make mrproper

  msg "Build: BOARD=${board}"
  make -j"$JOBS" "BOARD=${board}"
  test -f "${kname}.img" || die "Expected ${kname}.img not produced for ${board}"
  cp -v "${kname}.img" "$OUT_DIR/kernels/${kname}.img"

  if [[ "$WITH_HDMI" == "1" ]]; then
    msg "Build (HDMI console): BOARD=${board}"
    make clean
    make -j"$JOBS" "BOARD=${board}" HDMI_CONSOLE=1
    test -f "${kname}.img" || die "Expected ${kname}.img (HDMI) not produced for ${board}"
    cp -v "${kname}.img" "$OUT_DIR/kernels-hdmi/${kname}.img"
  fi
done

# Package sdcard
msg "Preparing sdcard/"
rm -rf "$SDCARD_DIR"
mkdir -p "$SDCARD_DIR" "$SDCARD_DIR/firmware" "$SDCARD_DIR/docs" "$SDCARD_DIR/soundfonts"
cp -af sdcard/. "$SDCARD_DIR"/

[[ -d "$BOOT_HOME" ]] || die "Boot path not found: $BOOT_HOME"
[[ -d "$WLAN_HOME/firmware" ]] || die "WLAN firmware path not found: $WLAN_HOME/firmware"

msg "Building/collecting boot files"
make -C "$BOOT_HOME" firmware armstub64
cp -v \
  "$BOOT_HOME/armstub8-rpi4.bin" \
  "$BOOT_HOME/bcm2711-rpi-4-b.dtb" \
  "$BOOT_HOME/bcm2711-rpi-400.dtb" \
  "$BOOT_HOME/bcm2711-rpi-cm4.dtb" \
  "$BOOT_HOME/bootcode.bin" \
  "$BOOT_HOME/COPYING.linux" \
  "$BOOT_HOME/fixup_cd.dat" \
  "$BOOT_HOME/fixup4cd.dat" \
  "$BOOT_HOME/LICENCE.broadcom" \
  "$BOOT_HOME/start_cd.elf" \
  "$BOOT_HOME/start4cd.elf" \
  "$SDCARD_DIR"

msg "Collecting WLAN firmware"
make -C "$WLAN_HOME/firmware"
cp -v \
  "$WLAN_HOME/firmware/LICENCE.broadcom_bcm43xx" \
  "$WLAN_HOME/firmware/brcmfmac43430-sdio.bin" \
  "$WLAN_HOME/firmware/brcmfmac43430-sdio.txt" \
  "$WLAN_HOME/firmware/brcmfmac43436-sdio.bin" \
  "$WLAN_HOME/firmware/brcmfmac43436-sdio.txt" \
  "$WLAN_HOME/firmware/brcmfmac43436-sdio.clm_blob" \
  "$WLAN_HOME/firmware/brcmfmac43455-sdio.bin" \
  "$WLAN_HOME/firmware/brcmfmac43455-sdio.txt" \
  "$WLAN_HOME/firmware/brcmfmac43455-sdio.clm_blob" \
  "$WLAN_HOME/firmware/brcmfmac43456-sdio.bin" \
  "$WLAN_HOME/firmware/brcmfmac43456-sdio.txt" \
  "$WLAN_HOME/firmware/brcmfmac43456-sdio.clm_blob" \
  "$SDCARD_DIR/firmware"

msg "Adding kernels"
cp -v "$OUT_DIR/kernels/"kernel*.img "$SDCARD_DIR"
if [[ "$WITH_HDMI" == "1" ]]; then
  cp -v "$OUT_DIR/kernels-hdmi/"kernel*.img "$SDCARD_DIR" || warn "HDMI kernels not found"
fi

msg "Adding docs"
cp -v LICENSE README.md "$SDCARD_DIR/docs" 2>/dev/null || warn "LICENSE/README not found"

if [[ -n "$SOUNDFONT_PATH" ]]; then
  msg "Including soundfont: $SOUNDFONT_PATH"
  cp -v "$SOUNDFONT_PATH" "$SDCARD_DIR/soundfonts/GeneralUser GS v1.511.sf2"
else
  warn "No soundfont included (optional). Use --soundfont /path/to/GeneralUser\\ GS\\ v1.511.sf2"
fi

# Zip
PKG_NAME="mt32-pi-local-$(date +%Y%m%d%H%M%S).zip"
msg "Creating package: $OUT_DIR/$PKG_NAME"
mkdir -p "$OUT_DIR"
( cd "$SDCARD_DIR" && zip -qr "../$PKG_NAME" . )

msg "Done."
echo "Artifacts:"
echo "  $OUT_DIR/kernels/"
[[ "$WITH_HDMI" == "1" ]] && echo "  $OUT_DIR/kernels-hdmi/"
echo "  $SDCARD_DIR/"
echo "  $OUT_DIR/$PKG_NAME"
