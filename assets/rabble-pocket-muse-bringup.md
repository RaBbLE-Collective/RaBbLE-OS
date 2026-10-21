# RaBbLE Pocket: Muse Gadget SDK Bring-up

Context file for Claude Code on my RaBbLE-OS laptop. Read all of it before running anything.

## Goal

Flash Meta's open-source Muse Gadget firmware onto my RaBbLE Pocket board to:

1. Prove the hardware works end to end (display, touch, mics, speaker, PMU, battery, buttons) on drivers someone else already debugged.
2. Learn the firmware structure, so I can later replace the Muse backend and avatar with RaBbLE's and keep the board layer, voice pipeline, and RTOS plumbing.

This is personal use only. Muse SDK tokens are for personal, non-commercial use (gadgets.muse.ai/sdk-terms). Nothing built on a Muse token ships to other people.

## Hardware

- Waveshare ESP32-S3-Touch-AMOLED-1.75 family: 466x466 round CO5300 AMOLED, CST9217 touch, ES8311 speaker codec, ES7210 dual mics, AXP2101 PMU, QMI8658 IMU, SD slot, 16 MB flash, 8 MB octal PSRAM.
- My notes say the exact variant may be the **1.75-B**. The SDK supports only the **1.75** (`s3n` profile) and the **1.75C** (`s3` profile). They differ in pin map (panel/touch reset, MCLK, PWR button wiring). **Confirm the variant from the board silkscreen and Waveshare's wiki before building. If it is neither 1.75 nor 1.75C exactly, stop and tell me.**
- Board is in my custom 3D-printed enclosure with an EEMB 402535 battery.

## Hard rules

- **Back up the current flash before writing anything.** My own firmware may be on it.
- **Never burn eFuses.** No Secure Boot, no flash encryption, no `CONFIG_HOMEHUB_PAIRING_EFUSE_AUTH`. This is a dev unit and must stay reflashable.
- **Never commit or print my SDK token in full.** It goes only in the build directory's `sdkconfig`.
- Do not run `erase-flash` unless I say so (it wipes pairing and Wi-Fi).
- Ask before anything that modifies system packages beyond the steps below.
- Use the SDK's own docs as the source of truth: `esp32/AGENTS.md` and `esp32/devices/README.md`. If this file and those disagree, follow the SDK and tell me.
- No em dashes in anything you write for me.

## Step 1: Toolchain

The SDK requires **ESP-IDF v6.0.1 exactly**. Other versions are unsupported. Its helper scripts look for it at `~/.espressif/esp-idf-v6.0.1` first (or `IDF_EXPORT` pointing at an `export.sh`).

1. Check whether I already have ESP-IDF installed and which version. If it is not v6.0.1, install v6.0.1 side by side at `~/.espressif/esp-idf-v6.0.1` following Espressif's official Linux install guide (target `esp32s3`). Do not remove other IDF versions.
2. Make sure my user is in the `dialout` group (or `uucp` on Arch-based systems) for serial access. If you add it, tell me to log out and back in.
3. Install the host tools the SDK needs: Python 3 and a C/C++ compiler.

## Step 2: Get the SDK

```sh
mkdir -p ~/RaBbLE-Collective/vendor && cd ~/RaBbLE-Collective/vendor
git clone https://github.com/facebookincubator/muse-gadget-sdk.git
cd muse-gadget-sdk/esp32
```

Read `AGENTS.md` and `devices/README.md` before continuing.

## Step 3: Identify the board and port

1. Plug in over USB-C (data cable). Native USB on the S3 shows up as `/dev/ttyACM*`.
2. Confirm with `tools/muse/ports.py --list` and `python -m esptool read-mac`.
3. Report back: port, MAC, and which board variant you believe this is and why.

## Step 4: Back up the existing firmware

Full 16 MB read, before any write:

```sh
mkdir -p ~/RaBbLE-Collective/backups
python -m esptool --chip esp32s3 -p /dev/ttyACM0 -b 460800 \
  read-flash 0 0x1000000 ~/RaBbLE-Collective/backups/pocket-$(date +%Y%m%d-%H%M).bin
```

Adjust the port. Verify the file is exactly 16,777,216 bytes and record its sha256. Restore later with `write-flash 0 <file>`.

## Step 5: SDK token

I will get my token from gadgets.muse.ai > Account > SDK tokens (starts with `mgst_`). Ask me for it when you need it. Set `CONFIG_GADGET_SDK_TOKEN` in the build directory's `sdkconfig` per `AGENTS.md`.

## Step 6: Build and flash

For the plain 1.75 the helper profile is `s3n` (`waveshare-s3-175`); for the 1.75C it is `s3`.

```sh
tools/muse/board.sh build s3n
tools/muse/board.sh flash s3n
```

Equivalent manual build, if the helper misbehaves:

```sh
idf.py -B build-muse-waveshare-s3-175 -DIDF_TARGET=esp32s3 \
  -DSDKCONFIG=build-muse-waveshare-s3-175/sdkconfig \
  -DSDKCONFIG_DEFAULTS="sdkconfig.defaults;devices/sdkconfig.muse;devices/sdkconfig.muse-waveshare-s3-175" build
```

Then add `-p PORT flash` with the same arguments. If the chip will not enter the bootloader: hold BOOT, tap RESET, release BOOT, retry.

Watch the boot log with `tools/muse/monitor.py PORT` and confirm it prints `muse: board: Waveshare ESP32-S3-Touch-AMOLED-1.75`.

## Step 7: Pair and smoke test

Pair from the Muse app on my phone: Settings > Devices. Then walk me through checking:

- [ ] Display renders, round layout correct, brightness changes
- [ ] Touch works
- [ ] BOOT (lower button) is push-to-talk; PWR (upper) is aux, long hold powers off via PMU
- [ ] Mic capture works (talk turn gets transcribed)
- [ ] Speaker works (the SDK has chirp and loopback test hooks in `components/muse/muse_voice.h`)
- [ ] Battery percentage and charging status read correctly on battery and USB
- [ ] Screen sleeps on battery and wakes on a button press
- [ ] Note the boot time and idle current if measurable

Log anything that fails with the relevant monitor output.

## Step 8: Study notes for the RaBbLE port (read only, no changes yet)

After it works, write `~/RaBbLE-Collective/notes/muse-sdk-map.md` covering:

- **Board layer:** `components/muse/boards/board_waveshare_s3_175c.c` (drives both 1.75 and 1.75C) and the `muse_board_t` vtable in `components/muse/muse_board.h`.
- **Backend seam:** the `muse_hatch_*` API in `components/muse/muse_chat.h`, implemented by `muse_chat_session.cpp` (Noise over WebSocket to the Muse VM). This is what RaBbLE replaces with sCoRE or the home box.
- **Avatar seam:** a custom `components/muse/avatar/muse_pixel.c` implementing `muse_pixel_render(pose)` is picked up by CMake. Note the default avatar (Jollybot) is **not** Apache-licensed and must never ship in a RaBbLE build.
- **TTS hook:** `start_tts` in `muse_chat_session.cpp` (Muse does not speak gadget replies).
- **Unused hardware:** QMI8658 IMU and the SD slot are not used by the SDK. These are RaBbLE work (mood inputs, local capture storage).
- **Home Link plumbing in `main/`** (BLE pairing, Noise control, VM API, tunnel) that RaBbLE would replace.
- Anything that looks fragile, surprising, or license-relevant.

## Licensing reminders

- SDK code: Apache 2.0. Keep license headers and NOTICE on any file reused in RaBbLE firmware.
- Jollybot avatar: excluded from Apache 2.0. Do not copy.
- Using the code does not require a Muse token. Only the Muse service does.

## Restore path

If anything goes wrong: put the board in bootloader mode (hold BOOT, tap RESET) and write back the Step 4 backup with esptool `write-flash 0 <backup.bin>`.
