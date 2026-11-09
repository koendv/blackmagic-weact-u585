# Notes

*Written by Claude (Anthropic's AI model) during development with Koen De Vleeschauwer. Not reviewed line by
line.*

Technical notes on this repository: how the build works, what the patches do, what was found and measured on
the hardware, what has been tested, and what is still open. For an introduction, see `README.md`.

## Contents

- [Build](#build)
- [Patches](#patches)
- [Firmware](#firmware)
- [Hardware findings](#hardware-findings)
- [Testing](#testing)
- [Open issues](#open-issues)

## Build

### Overview

The repository holds patches against upstream projects, not their sources. `build.sh` runs inside the image
built from `docker/Dockerfile` (Ubuntu 22.04, Arm GNU toolchain 15.2.Rel1, MinGW-w64, meson) and:

1. clones the upstream projects at the revisions pinned at the top of `build.sh`
2. applies `patches/blackmagic/*.patch` and `patches/bmpflash/*.patch` with `git am --3way`
3. tags the patched trees with a version string (see below)
4. builds the firmware, bmpflash for Linux and bmpflash for Windows (cross-compiled with MinGW-w64)
5. puts the results in `out/`

### Pinned upstream revisions

| Project    | Repository                                              | Revision   |
| ---------- | ------------------------------------------------------- | ---------- |
| blackmagic | https://codeberg.org/blackmagic-debug/blackmagic         | `7f2ba9b3` |
| libopencm3 | https://codeberg.org/blackmagic-debug/libopencm3         | `3622b6a0` |
| bmpflash   | https://codeberg.org/blackmagic-debug/bmpflash           | `06cde6b9` |
| substrate  | https://github.com/bad-alloc-heavy-industries/substrate  | `cf4f3c55` |

libopencm3 and substrate are pinned too because upstream's meson wrap files follow their head. Each revision
can be overridden from the environment (`BMD_REF`, `LIBOPENCM3_REF`, `BMPFLASH_REF`, `SUBSTRATE_REF`) with a
branch, tag or commit, e.g. `-e BMD_REF=main`. Fetches from Codeberg are retried with back-off, as Codeberg
rate limits unauthenticated traffic and CI runners share IP addresses.

### Outputs

| File                                           | What                                                       |
| ---------------------------------------------- | ---------------------------------------------------------- |
| `blackmagic-weact-u585-firmware.{elf,bin,hex}` | Black Magic Debug firmware for the board                   |
| `bmpflash-linux-x86_64`                        | bmpflash for Linux: static C++ runtime, needs glibc 2.34+ |
| `bmpflash-windows-x86_64.exe`                  | bmpflash for 64-bit Windows: one static executable         |
| `versions.txt`                                 | the exact upstream revisions and the version strings       |
| `SHA256SUMS`                                   | checksums of the above                                     |

Notes on the bmpflash builds: libusb is built without udev, so the Linux binary does not depend on libudev;
the Windows build uses MinGW's `-posix` compilers because substrate needs `std::thread` and `std::mutex`.

### Version strings

The firmware (`monitor version`, USB product string) and bmpflash (`--version`) report
`<upstream description>+weact-u585.<this repository's revision>`, e.g.
`v2.1.0-27-g7f2ba9b3+weact-u585.2bc967d`: 27 upstream commits after tag v2.1.0 at upstream commit 7f2ba9b3,
built from this repository's commit 2bc967d (or the release name, on a release build; `-dirty` with uncommitted
changes). bmpflash has no release tags upstream, so its upstream part is the commit hash.

`build.sh` fetches Black Magic Debug's full history and tags for this, describes the upstream commit before
patching, and tags the patched tree with the combined name, which meson's `vcs_tag` picks up.

Side effect: `/dev/serial/by-id/` names contain the product string, so they change with every firmware
version (as with upstream firmware). Match them on the serial number instead, e.g.
`usb-Black_Magic_Debug_*_50A5816C-if00`.

### Building locally

```sh
docker build -t weact-u585-builder docker
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD:/src" -w /src weact-u585-builder ./build.sh
```

### GitHub Actions

`.github/workflows/build.yml` builds the image (with layer caching), runs `build.sh` in it, and uploads `out/`
as the `blackmagic-weact-u585` artifact. It runs only by hand, from the Actions tab; pushes and pull
requests do not start it. The run takes other upstream revisions as inputs: set all three to `main` to check
that the patches still apply to and build with upstream (to notice when they stop applying or building).
Tested on GitHub: a build cloned from Codeberg, built, and produced the expected files and version strings.

Releases are made only by hand: run the workflow from the Actions tab with "release" ticked and a release
name (e.g. `v0.1`). The run refuses an empty, invalid or existing name, and custom upstream refs; the name
becomes the tag on the built commit and replaces the commit hash in the version strings (`REPO_REV`). The
release notes list `versions.txt`. Pushing a tag does not make a release.

`.github/workflows/delete-old-workflows.yml` deletes workflow runs (and their artifacts) older than 30 days,
keeping at least 2, on the 1st of every month. Releases are not affected.

### Updating the patches

Work in a clone with the series applied, on top of the pinned upstream revision. The quickest way is to
clone the tree the last build left behind, which has every patch applied as a commit:

```sh
git clone work/blackmagic /tmp/bmd && git clone work/blackmagic/deps/libopencm3 /tmp/bmd/deps/libopencm3
```

Change or add commits there, then regenerate the series without numbering, so unchanged patches stay
byte-identical:

```sh
git format-patch -N -o patches/blackmagic 7f2ba9b3..HEAD
```

When moving to a newer upstream, update the pinned revision in `build.sh` in the same commit.

## Patches

### patches/blackmagic

| Patch | Content |
| ----- | ------- |
| 0001  | The `weact-u585` platform: pins following the CubeMX project (see `cubemx/`), ST ROM DFU (BOOT0 + NRST or DFU detach), low GPIO speed on the debug pins, HSE/LSE start-up with LED blink codes; Release Power-down (`0xAB`) to the on-board Flash whenever its SPI bus starts |
| 0002  | `monitor memwatch`: backported from blackmagic-rtthread; floats via `ftoa()` from upstream PR #1655; output through `rtt_write()` |
| 0003  | DWT trace decoding: `monitor dwt`, `monitor swo top|graph|log|selftest`; the ITM/DWT decoder replaces upstream's ITM-only one |
| 0004  | Micro Trace Buffer: `monitor mtb [status|dump|size]` |
| 0005  | `monitor speedtest [COUNT [SIZE [ADDR]]]`, timed with the probe's SysTick |
| 0006  | Non-halting memory access by default on Cortex-M (not TI LM/TM4C); `monitor mem_nohalt` shared and also on RISC-V |
| 0007  | Calibrated bit-banging frequency, so `monitor frequency` reports the real SWD clock |
| 0008  | `monitor clocks`: crystal status, SYSCLK and USB clock sources |
| 0009  | SYSCLK from the 25MHz HSE crystal, with fallback to MSIS |
| 0010  | Standalone programming: long press on the user key programs a target from a `bmpflash provision` image; `monitor flasher info\|write` |

Patches 0002 to 0005 are backports from [blackmagic-rtthread](https://github.com/koendv/blackmagic-rtthread)
with the RT-Thread code removed. Not backported: the RT-Thread port itself, its semihosting port, its
`monitor rtt halt` override (replaced by upstream's `monitor mem_nohalt`), and `noackmode` (upstream already
has the `advertise_noackmode` option, enabled in this build).

### patches/bmpflash

| Patch | Content |
| ----- | ------- |
| 0001  | Built-in parameters for W25Q128JV parts (JEDEC ID `EF 40 18` and `EF 70 18`) that return no SFDP data |
| 0002  | `provision` skips sections without file contents (`.bss`): it used to store them with junk bytes at a flash address past the program, which a standalone programmer would write into the target |
| 0003  | Waits on the Flash time out (10 s busy, 100 ms Write Enable): a missing Flash reads as all highs, which looked busy forever and hung bmpflash; after Write Enable, check that WEL is set |
| 0004  | Before identifying the Flash: Release Power-down, wait until idle, Enable Reset + Reset Device back to back, wait for the reset; the sequence from SFUD as patched for the W25Q128JV in arm_can_tool |

### bmpflash provisioning format

`bmpflash provision` stores an image in the on-board SPI Flash, for standalone programming:

- the first 4KiB block is the header: `"BMPF"`, CRC32, section count (32-bit), then per section 16 bytes:
  offset in the SPI Flash (32-bit), length (32-bit), target address (64-bit), all little endian
- the header CRC32 covers the whole 4KiB block, computed with the CRC field set to `0xffffffff`: reflected
  polynomial `0xEDB88320`, register starting at 0 (bmpflash inverts its `0xffffffff` start value on entry),
  final inversion. In Python: `zlib.crc32(block, 0xffffffff)`
- each section's data starts on its own 4KiB block; the section data has no checksum
- only ARM ELF files are accepted

## Firmware

### Board and pins

The platform is derived from BMPv3. Pins follow `cubemx/weact-blackpill-u585ci.ioc`; see the platform README
(`src/platforms/weact-u585/README.md` once patched) for the full pinout. In short: SWCLK/TCK PB13,
SWDIO/TMS PB12, TDI PB15, TDO PB14, nRST PA15 (open drain), SWO PA1, AUX UARTs PA2/PA3 and PA9/PA10,
internal SPI Flash on PA4-PA7, LED PC13 (active low). Targets must be 3.3V: there are no level translators.

All 24 target families are built in. RVSWD (WCH's protocol for CH32V parts) is not: no probe firmware
implements it; upstream only supports it in BMDA through a WCH-Link adapter.

### Clocks

SYSCLK 160MHz from PLL1 fed by the 25MHz HSE (25 / 5 x 64 / 2), USB from HSI48 trimmed by the CRS, as in
WeAct's own examples for this board. If the HSE does not start within 100ms, SYSCLK comes from MSIS through
PLL1 instead. LED blink codes at boot: 3 = HSE did not start, 2 = LSE did not start.

### Monitor commands added

| Command | Purpose |
| ------- | ------- |
| `memwatch [/t] [[NAME] [/d\|/u\|/f\|/fN\|/x] ADDRESS]...`, `memwatch status` | report changes of up to 8 variables on the AUX serial port while the target runs |
| `dwt ...` | set up the target's DWT/ITM/TPIU for trace over SWO |
| `swo log\|top\|graph\|selftest` | decoded DWT output, PC-sample histogram, decoder self-test (no target needed) |
| `mtb status\|dump\|size` | Micro Trace Buffer (Cortex-M0+/M23/M33 parts that have one) |
| `speedtest [COUNT [SIZE [ADDR]]]` | SWD/JTAG write throughput to target RAM (RAM is restored) |
| `mem_nohalt [enable\|disable]` | override whether memory is read without halting (RTT, memwatch) |
| `clocks` | crystal status and clock sources |
| `flasher [info\|write]` | `info`: show the image stored in the on-board SPI Flash; `write`: program it into the target, verify it, and reset the target |

### Standalone programming

With a SPI Flash chip on the U3 footprint, a long press (about 1s) on KEY (PA0) programs a target from an
image stored with `bmpflash provision firmware.elf`, without a host; `monitor flasher write` does the same
from GDB. Ignored while GDB is attached to a target.

Sequence: check the image header (magic, CRC), scan SWD then JTAG, attach to each target found in turn (many
target drivers only build their Flash map on attach) and program the first whose Flash holds every section:
erase all section ranges first (sections can share a sector), write, verify by reading back, reset, detach.
Multi-core chips show up as several targets sharing one Flash map; the first core does the programming.

LED: fast blinking while programming, on for 3s on success; on failure an error code, shown three times:
2 = no valid image, 3 = no matching target, 4 = erase/write failed, 5 = verify failed, 6 = communication
error. A log goes to the second USB serial port, or to GDB for `monitor flasher write`.

Limits, by decision:

- No check that the image was built for the connected chip (bmpflash's format has no target identification);
  as with programming by hand, that is up to the operator. An STM32F411 image fits an AT32F405/435's Flash
  map, for instance, and would be programmed into it.
- No attach under reset. A target whose program locks the core up (e.g. a fault in the fault handler) cannot
  be attached normally; use GDB with `monitor connect_rst enable` for it. Deferred until upstream supports
  attach under reset.
- The section data has no checksum; a corrupted SPI Flash would be programmed and verified as stored.

## Hardware findings

### SWD failures were caused by GPIO slew rate

SWD to an STM32F411 over ~10cm jumper wires failed at every clock above ~100kHz, and connect-under-reset never
worked. The debug pins used the high output speed copied from BMPv3, which drives its debug lines through
buffers; this board drives the wires directly and the fast edges ring. Medium speed fails too; low speed
(`GPIO_OSPEED_2MHZ`) is reliable up to the fastest bit-banged clock. An earlier port of the user's
(`blackpill-u585`, after the `blackpill-f4` platforms) already used low speed, which is how this was found.

### Real SWD clock

BMD's generic U5 frequency calculation uses constants for an STM32F103 at 72MHz. Measured with the U585's
cycle counter, an SWD bit takes 35..40 + 40..41 x divider CPU cycles at 160MHz (the range depends on where
the code lands in Flash, as Flash has wait states), and ~25 cycles without delays (6.5MHz). Before patch 0007
the real clock was 2 to 4 times lower than reported. JTAG data shifts take ~83 + 40 x divider cycles, so JTAG
runs slower than reported at small dividers.

With calibrated frequencies, `monitor frequency 0` means *slowest possible* (upstream's definition): a scan
then takes hours. Recover with `dfu-util -d 1d50:6018 -e` (DFU detach is handled in the USB interrupt) and
use a real value, e.g. `monitor frequency 4M`.

### Firmware printf is integer only

The firmware maps `snprintf` to newlib's `sniprintf`: no `%f`/`%g`, no `%zu`, no `%llu`/`PRIu64`. A `%zu` in
the DWT self-test made `%s` dereference a small integer, which faults on the U5 (nothing is mapped at
address 0) and hung the probe. Upstream only uses `%zu` in `DEBUG_*` macros, which compile to nothing.
`general.h` must be included before any system header, as it sets the feature macros newlib needs.

### AUX serial output can be dropped

`debug_serial_send_stdout()` writes one USB packet and returns; data written while the previous packet is
still pending is dropped. memwatch therefore goes through `rtt_write()`, which retries for up to 25ms
(delivered lines doubled). The flip side: when nothing reads the AUX port, each line stalls the main loop
for up to 25ms, as RTT output already does. A zero-length packet does not help here; it only terminates a
transfer whose last packet was exactly 64 bytes.

### Other

- The U5's CRS trim field is 7 bits wide; libopencm3's `CRS_CR_TRIM` covers only 6.
- `rcc_clock_setup_pll()` in libopencm3 switches off every oscillator but MSIS, then waits without a timeout
  for the HSE when one is configured; patch 0009 therefore checks the HSE itself first.
- PLL1's R output only divides by 1 or even values on the U5.
- `gdb -batch` cannot manage a running target (`Cannot execute this command while the target is running`);
  tests of running-target features drive the GDB remote protocol directly instead.

### The on-board SPI Flash has no SFDP data

Measured with `tools/spi_probe.py` (read-only commands over the remote protocol):

| Command | Result |
| ------- | ------ |
| `9Fh` JEDEC ID | `EF 40 18`: W25Q128JV-IQ/JQ according to the datasheet |
| `90h`, `ABh` device ID | `17` |
| `0Bh` Fast Read, 1 dummy byte | same data as `03h` Read: opcode + 3 address bytes + 8 dummy clocks works |
| `4Bh` Unique ID, 4 dummy bytes | `d2 65 78 32 a7 37 2c 38`; each dummy byte more or less shifts it by one |
| `5Ah` Read SFDP, 1 dummy byte | `FF` for all 256 bytes (also with 0, 2 or 3 dummy bytes) |
| `35h` Status Register-2 | `00`: QE=0 |
| `15h` Status Register-3 | `60`: default output drive strength |

`5Ah` uses the same framing as `0Bh`, which reads correctly, so the firmware and bmpflash send it right: the
chip's SFDP area is blank. The W25Q128JV datasheet (rev F) says the JV supports SFDP (Winbond parts from date
code 1124, mid-2011, on) and that QE is factory fixed at 1 on the -IQ/-JQ parts that report `EF 40 18`. This
chip's top marking is `25Q128JVSQ` with date code 2030 (2020, week 30), as on a genuine -IQ made long after
SFDP was introduced, yet it reads QE=0 and has no SFDP data, contrary to
that datasheet: either a remarked or counterfeit part, or a genuine one that differs from the datasheet.

bmpflash finds this chip through its known-flash table (bmpflash patch 0001), which it checks before SFDP.
Any other chip fitted to the board goes through SFDP.

## Testing

Tested on the WeAct board with an STM32F411 Black Pill as target, over ~10cm jumper wires, with the CI-built
firmware (patches 0001-0009):

| Area | Result |
| ---- | ------ |
| USB, ROM DFU, DFU detach | enumerates; BOOT0 + NRST and `dfu-util -e` enter the ROM bootloader |
| SWD | scan, attach, Flash read 10/10 from ~0.1 to 6.5MHz; connect-under-reset works |
| `monitor frequency` | within ~6% of the measured SWCLK |
| memwatch | ~500 lines/s on the AUX port, watching the target's cycle counter |
| DWT decoder | `swo selftest` 15/15, 13/13 split across buffers; `dwt status` reads the target |
| MTB | component scan intact; `mtb status` reports "no mtb" on the F411 (Cortex-M4) |
| speedtest | ~180kB/s at the default clock; target RAM restored |
| mem_nohalt | toggles the flag; memwatch obeys it |
| Clocks | HSE and LSE run; SYSCLK from PLL1 (HSE); MSIS fallback tested with a build simulating a dead HSE |
| Standalone programming | `monitor flasher info\|write` (then named `standalone info\|run`) and the KEY long press work; `write` programmed and verified a 10kB image in under 1s |
| bmpflash | on Linux: `provision` of an F411 blinky (Arduino) and `read` of the whole 16MiB W25Q128JV (~200kB/s); header, CRC and all sections match the ELF. Windows: `--help` only (Wine) |

The F411 holds a U585-style image and sits in a HardFault loop with SysTick off: memwatch tests watch the
DWT cycle counter (`0xE0001004`, after setting `DWT_CTRL` bit 0), which runs anyway.

## Open issues

Untested:

1. GitHub Actions: the build with the pinned revisions works; a build against upstream `main`, the release
   and the cleanup workflow have not run yet.
2. bmpflash `write` on the W25Q128JV, the external SPI bus, and the Windows build on real Windows (`provision`
   and `read` work on Linux). bmpflash's SFDP parser has not seen real SFDP data: this board's Flash has
   none (see "The on-board SPI Flash has no SFDP data"). Untested on hardware: bmpflash 0003's Write Enable
   check (needs a write), and the firmware's Release Power-down.
3. SWO capture of a real trace (Manchester and UART), the AUX UARTs, JTAG, the external SPI bus, RISC-V,
   MTB on a part that has one, and the Cortex-M non-halting default on a target whose driver had not
   already opted in.
4. The debug build (`-Ddebug_output=true`) has not been compiled since the backports.

Deferred: attach under reset in standalone programming (see above).

Observed, unexplained: with this F411 and these wires, SWD under reset (`monitor connect_rst enable`) worked
at 1MHz in one session and only at 200kHz or below in a later one, while normal SWD worked at full speed.

Limits by design: single LED (UART activity flickers it); calibration drift between builds; no RVSWD.

Upkeep: the patches touch common upstream code (`command.c`, `cortexm.c`, `target.c`, `adi.c`, `main.c`,
`timing_stm32.c`, meson files) and 0003 replaces upstream's ITM decoder, so expect conflicts when moving to
a newer upstream; a manual build against upstream `main` is the early warning. Both upstream projects have a no-LLM policy
for contributions, so these patches are not intended for upstream.
