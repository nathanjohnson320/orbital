# Changelog

## Unreleased

- Added an `expand` command that grows the final `main.avm` partition to the end
  of detected ESP32 flash and updates the bootloader flash-size header.
- Orbital now has an `info` command to list connected ESP32 boards and AtomVM
  install status.
- Orbital now has an `erase-flash` command to wipe an ESP32 board's flash.
- Added shared ESP32 device helpers (`orbital/internal/esp32`) backed by
  `priv/esp32.py` for listing devices, selecting a port, erasing flash, and
  reading/writing flash regions. Follow-up PRs will wire the `install`
  command.
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
