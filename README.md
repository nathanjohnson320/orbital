# ⚛️ orbital

[![Package Version](https://img.shields.io/hexpm/v/orbital)](https://hex.pm/packages/orbital)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/orbital/)

Build and flash Gleam projects to devices running [AtomVM](https://atomvm.org).

![A video showcasing the 'orbital' workflow:
The command 'gleam run -m orbital flash esp32 --port /dev/tty.usbserial001'
is ran in a terminal window.
After a short while the message 'Done' is displayed and the command
'screen' is ran to show that the code was flashed and is running on an esp device
](https://github.com/user-attachments/assets/5c50358e-31a3-443e-b2da-2f12a58d356b)

Add it to your project as a dev dependency:

```sh
gleam add --dev orbital
```

Your project must have a module with a `start` function that takes no arguments:

```gleam
import gleam/io

pub fn start() {
  io.println("Hello, from AtomVM!")
}
```

### ESP32

Install AtomVM on the board once, then build/flash your app and watch the
console:

```sh
gleam run -m orbital info
gleam run -m orbital install
gleam run -m orbital flash esp32
gleam run -m orbital expand
gleam run -m orbital monitor
gleam run -m orbital erase-flash
```

`info` lists connected ESP32 boards and whether AtomVM is already installed.

`install` downloads the latest AtomVM release (or a local `--image` / release
`--version`), erases flash, and writes the firmware. Use `--update` later to
replace only the VM and `boot.avm` while keeping NVS and `main.avm`.
`--list-images` shows published and cached images; downloads land in
`firmware_images/`.

`flash` reads the device partition table and writes the application at the
`main.avm` address. Pass `--offset 0x2b8000` to choose an address yourself.
The flash NIF auto-detects the serial port; pass `--port /dev/some_device`
when more than one board is connected.

`expand` grows the final `main.avm` partition to the end of the detected flash
and updates the bootloader flash-size header when needed. Use it when an app
no longer fits the stock `main.avm` slot.

`monitor` reads the serial console for 10 seconds. `--timeout 0` reads until
Ctrl+C. The port is chosen when only one USB serial device is connected.

`erase-flash` wipes the entire flash of a connected ESP32. Pass `--port` when
more than one board is connected.

### Raspberry Pi Pico

Install AtomVM once (prefers a combined release UF2; uses `picotool` when
available, otherwise BOOTSEL volume copy):

```sh
gleam run -m orbital install pico --board pico_w
gleam run -m orbital install pico --list-images
```

A brand-new board may still need one BOOTSEL press if nothing on it can answer
`picotool -f` yet. Then flash your Gleam app:

```sh
gleam run -m orbital flash pico
```

Orbital packs the project, converts it to UF2 (`uf2tool`, default family
`universal` for Pico and Pico 2), resets into BOOTSEL when a matching serial
device is present, and copies the UF2 onto the mounted `RPI-RP2` / `RP2350`
volume.

```sh
gleam run -m orbital uf2create
gleam run -m orbital flash pico --pico-path /Volumes/RPI-RP2 --family-id data
```

### PlayStation Portable (CFW / PPSSPP)

AtomVM on PSP is a homebrew `EBOOT.PBP` (from
[atomvm-psp](https://github.com/nathanjohnson320/atomvm-psp)), not MCU firmware.
Install the EBOOT once into `PSP/GAME/ATOMVM/`, then flash your Gleam app as
`app.avm` beside it (ms0 load / hot-swap).

```sh
gleam run -m orbital install psp --list-images
gleam run -m orbital install psp --image /path/to/EBOOT.PBP
gleam run -m orbital flash psp
gleam run -m orbital flash psp --psp-path ~/.config/ppsspp/PSP/GAME/ATOMVM
```

`install psp` currently expects a local `--image` (bare `EBOOT.PBP` or a zip
containing one); atomvm-psp has no published GitHub release assets yet. Default
`--psp-path` is the PPSSPP memstick `GAME/ATOMVM` folder when present, otherwise
pass `--psp-path` to a Memory Stick root or the `ATOMVM` game directory.

`flash psp` builds and checks your project AVM, then copies it to
`app.avm` next to the installed EBOOT. Extra `*.avm` files in that folder can be
hot-swapped from AtomVM's on-device picker after `start/0` returns.

### WebAssembly (Emscripten)

AtomVM ships separate Node.js and browser WASM builds. ExAtomVM does not wrap
them; Orbital downloads the release assets and either runs your `.avm` under
Node or writes a small browser bundle.

```sh
gleam run -m orbital install wasm --list-images
gleam run -m orbital install wasm --env node
gleam run -m orbital flash wasm
gleam run -m orbital flash wasm --env web --output-dir ./wasm_out
```

`install wasm` caches `AtomVM.js` / `AtomVM.wasm` under
`firmware_images/AtomVM-{node,web}-<version>/` (and `atomvmlib` by default).
`flash wasm` builds your project, then runs `node AtomVM.js app.avm
atomvmlib.avm`. With `--env web` it copies the runtime, AVM, and an
`index.html` into `--output-dir` (default `wasm_out`). Serve that directory
over localhost or HTTPS with COOP/COEP headers so SharedArrayBuffer works.

And you're good to go! To get an overview of all the available commands and
options you can run:

```sh
gleam run -m orbital help
```

## AtomVM compatibility checks

`build`, `flash`, and `uf2create` inspect the BEAM modules retained in the
application and fail when they use functions or instructions unavailable in
AtomVM. Run the same check without keeping an `.avm` file with:

```sh
gleam run -m orbital check
```

Orbital checks against AtomVM `0.7.0-beta.0` by default. On first use it
downloads the official `funcs.txt`, `instructions.txt`, and `manifest.json`
from the checksummed `atomvm` Hex package and caches them under
`firmware_images/supported_api/`.

Custom firmware can supply the files generated by AtomVM's `supported_api`
build target:

```sh
gleam run -m orbital check --supported-api /path/to/supported_api
ATOMVM_SUPPORTED_API=/path/to/supported_api gleam run -m orbital flash esp32
```

`--supported-api` is also accepted by `build`, `flash`, and `uf2create`.
The official manifest is a standard-build, cross-platform baseline; use a
custom manifest when firmware adds NIFs or removes standard features. Static
checks cannot discover function names constructed for dynamic `apply` calls.

## FAQ

- **What's AtomVM?**

  AtomVM is a lightweight implementation of the BEAM, optimized to run on tiny
  micro-controllers. You can read more about it [here!](https://atomvm.org)

- **How can I install AtomVM?**

  Prefer `gleam run -m orbital install` (or `install --list-images` to pick a
  build). You can also follow the
  [getting started guide.](https://doc.atomvm.org/latest/getting-started-guide.html)

- **Can I run any Gleam program on AtomVM?**

  AtomVM implements a constrained subset of the Erlang's standard library, so if
  your Gleam code or dependencies use unsupported functions Orbital reports
  them during `check`, `build`, or `flash`. Calls assembled dynamically can
  still produce an `undef` error at runtime.

- **What can I do to help?**

  AtomVM is a wicked cool project, enabling developers to run Erlang, Elixir and
  Gleam code on tiny embedded devices, as cheap as 2$!
  If you think this project is cool, please
  [consider sponsoring it!](https://github.com/sponsors/atomvm)

## Local Development

`monitor` and ESP32 flash/info use native NIFs under `priv/native/`. 
Published packages ship `priv/orbital_serial-<triple>.so`
`priv/orbital_esp-<triple>.so` (e.g. `aarch64-apple-darwin`); a local
`orbital_serial.so` / `orbital_esp.so` from `make -C priv/native` overrides
them on the host.

To rebuild every supported triple on a Mac (Darwin arm64/x86_64, Linux gnu
arm64/x86_64, Windows gnu x86_64):

```sh
brew install zig
make -C priv/native prebuilts
```

`orbital_serial` vendors libserialport (LGPL-3.0+);
`orbital_esp` vendors Espressif’s esp-serial-flasher (Apache-2.0).