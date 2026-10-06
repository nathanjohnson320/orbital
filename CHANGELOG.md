# Changelog

## Unreleased

- Added WASM / Emscripten support (beyond ExAtomVM, which has no WASM tasks).
  AtomVM publishes separate Node and browser builds; Orbital downloads them
  into `firmware_images/AtomVM-{node,web}-<version>/` as `AtomVM.js` +
  `AtomVM.wasm` (the loader always looks for that wasm name).
  - `install wasm` (`--env node|web|all`, `--version`, `--list-images`,
    `--image`, `--repo`, `--no-atomvmlib`) caches runtimes and optionally
    `atomvmlib`.
  - `flash wasm` builds the project AVM and either runs it with Node
    (`node AtomVM.js app.avm atomvmlib.avm`, default `--env node`) or writes a
    browser bundle (`--env web`, `--output-dir`, default `wasm_out`) with
    `index.html`. Browser hosts still need COOP/COEP headers for
    SharedArrayBuffer.
- Pico `install pico` downloads AtomVM UF2s (prefers `-combined`), caches under
  `firmware_images/`, and loads with `picotool` (`load -f`) falling back to
  UF2 volume copy. Flags: `--board`, `--image`, `--version`, `--repo`,
  `--list-images`, `--download-only`, `--pico-path`, `--pico-reset`,
  `--picotool`.
- Pico flash parity with ExAtomVM: `flash pico` builds a UF2 (via `uf2tool`),
  optionally resets into BOOTSEL (`stty` / `picotool`), waits for the mount, and
  copies the UF2. Flags: `--pico-path`, `--pico-reset`, `--picotool`,
  `--app-start` (default `0x10180000`), `--family-id` (default `universal`).
- Added `uf2create` to build a Pico UF2 without flashing
  (`--output-file`, `--app-start`, `--family-id`).
- Added `install` to download/install/update AtomVM on ESP32 boards
  (`--image`, `--version`, `--repo`, `--update`, `--download-only`,
  `--list-images`, `--chip`, `--port`, `--baud`), with firmware caching under
  `firmware_images/` and ExAtomVM-compatible update guardrails. Listing and
  download use Gleam (`gleam_httpc` / `gleam_json`); only zip member reads and
  ESP32 device I/O still go through thin Erlang / `priv/esp32.py` helpers.
  Parity fixes vs ExAtomVM: exact-chip Elixir release selection, factory zip
  bundle verification + FLASH.txt update parts, reject `--download-only` with a
  local path, and richer `--list-images` rendering.
- Added an `expand` command that grows the final `main.avm` partition to the end
  of detected ESP32 flash and updates the bootloader flash-size header.
- Orbital now has an `info` command to list connected ESP32 boards and AtomVM
  install status.
- Orbital now has an `erase-flash` command to wipe an ESP32 board's flash.
- Added shared ESP32 device helpers (`orbital/internal/esp32`) backed by
  `priv/esp32.py` for listing devices, selecting a port, erasing flash, and
  reading/writing flash regions.
- Extended partition-table parsing with `main.avm` expansion helpers and added
  ESP32 image-header flash-size helpers for upcoming expand support.
- ESP32 flash reads the device partition table and writes the application at
  the `main.avm` address. `--offset` selects a different address.
- The ESP32 flash command lets esptool auto-detect the serial port when
  `--port` is omitted.
- Orbital now has a `monitor` command to show an ESP32 board's console.

## v1.1.0 - 2026-04-05

- Orbital now has a `build` command to allow you to bundle your project into an
  avm file.
- Improved the formatting of the help text on smaller terminals.
- Added a description to the help text of the `build` and `flash` commands.

## v1.0.0 - 2026-03-16

- First release!
