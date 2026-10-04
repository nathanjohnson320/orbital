"""ESP32 device helpers used by Orbital's Gleam FFI.

Talks to boards through the same Python environment as esptool/pyserial
(prefer the interpreter from esptool's shebang). Commands print machine-readable
JSON on stdout and human errors on stderr.

Subcommands:
  list-devices
  select-port --port PORT|auto
  select-device --port PORT|auto
  erase-flash --port PORT|auto
  read-flash --port PORT --address HEX|INT --size HEX|INT --output PATH [--reset-after]
  write-flash-data --port PORT --address HEX|INT --file PATH
  write-flash-image --port PORT --baud BAUD --address HEX|INT --file PATH
  write-flash-parts --port PORT --baud BAUD --part ADDRESS:FILE [--part ...]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="esp32.py", add_help=True)
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("list-devices", help="List connected ESP32-like devices")

    select = sub.add_parser("select-port", help="Resolve a serial port")
    select.add_argument("--port", default="auto")

    erase = sub.add_parser("erase-flash", help="Erase flash on a device")
    erase.add_argument("--port", default="auto")

    read = sub.add_parser("read-flash", help="Read a flash region to a file")
    read.add_argument("--port", required=True)
    read.add_argument("--address", required=True)
    read.add_argument("--size", required=True)
    read.add_argument("--output", required=True)
    read.add_argument("--reset-after", action="store_true")

    write = sub.add_parser("write-flash-data", help="Write raw bytes to flash")
    write.add_argument("--port", required=True)
    write.add_argument("--address", required=True)
    write.add_argument("--file", required=True)

    image = sub.add_parser(
        "write-flash-image", help="Flash a firmware .img at an offset"
    )
    image.add_argument("--port", required=True)
    image.add_argument("--baud", type=int, default=921600)
    image.add_argument("--address", required=True)
    image.add_argument("--file", required=True)

    parts = sub.add_parser(
        "write-flash-parts", help="Flash multiple address:file pairs"
    )
    parts.add_argument("--port", required=True)
    parts.add_argument("--baud", type=int, default=921600)
    parts.add_argument(
        "--part",
        action="append",
        required=True,
        help="ADDRESS:FILE, may be repeated",
    )

    select_device = sub.add_parser(
        "select-device", help="Resolve a port and return its device record"
    )
    select_device.add_argument("--port", default="auto")

    args = parser.parse_args(argv)

    try:
        if args.command == "list-devices":
            return emit(connected_devices())
        if args.command == "select-port":
            return emit({"port": resolve_esp_port(args.port)})
        if args.command == "select-device":
            return emit(select_device_record(args.port))
        if args.command == "erase-flash":
            erase_flash(resolve_esp_port(args.port))
            return emit({"ok": True})
        if args.command == "read-flash":
            meta = read_flash(
                resolve_esp_port(args.port),
                parse_int(args.address),
                parse_int(args.size),
                Path(args.output),
                reset_after=args.reset_after,
            )
            return emit(meta)
        if args.command == "write-flash-data":
            write_flash_data(
                resolve_esp_port(args.port),
                parse_int(args.address),
                Path(args.file).read_bytes(),
            )
            return emit({"ok": True})
        if args.command == "write-flash-image":
            write_flash_image(
                resolve_esp_port(args.port),
                args.baud,
                parse_int(args.address),
                Path(args.file),
            )
            return emit({"ok": True})
        if args.command == "write-flash-parts":
            parsed_parts = []
            for part in args.part:
                address_s, file_s = part.split(":", 1)
                parsed_parts.append((parse_int(address_s), Path(file_s)))
            write_flash_parts(resolve_esp_port(args.port), args.baud, parsed_parts)
            return emit({"ok": True})
    except LookupError as error:
        print(str(error), file=sys.stderr)
        return 1
    except ModuleNotFoundError:
        print(
            "esptool/pyserial is not installed for this Python.\n"
            "Install esptool, or install pyserial+esptool for python3.",
            file=sys.stderr,
        )
        return 1
    except Exception as error:  # noqa: BLE001 - surface to Gleam as a string
        print(f"ESP32 helper error: {error}", file=sys.stderr)
        return 1

    print(f"Unknown command: {args.command}", file=sys.stderr)
    return 1


def emit(payload: object) -> int:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


def parse_int(value: str) -> int:
    return int(value, 0)


def usb_candidate_ports() -> list[str]:
    import serial.tools.list_ports as list_ports

    devices: list[str] = []
    for info in list_ports.comports():
        if info.vid is None:
            continue
        device = info.device
        # macOS publishes every adapter twice; prefer the cu node.
        if sys.platform == "darwin" and device.startswith("/dev/tty."):
            continue
        devices.append(device)
    return devices


def connected_devices() -> list[dict]:
    from esptool.cmds import attach_flash, detect_chip, read_flash

    result: list[dict] = []
    for port in usb_candidate_ports():
        try:
            with detect_chip(port) as esp:
                description = esp.get_chip_description()
                features = list(esp.get_chip_features())
                mac_addr = ":".join(f"{byte:02X}" for byte in esp.read_mac())
                chip_family_name = esp.CHIP_NAME

                attach_flash(esp)
                app_header = read_flash(esp, 0x10030, 128, None)
                app_header_strings = [
                    part
                    for part in re.split(
                        "\x00", app_header.decode("utf-8", errors="replace")
                    )
                    if part
                ]

                usb_mode = esp.get_usb_mode()
                # Keep USB-OTG boards (e.g. ESP32-S2) usable after probing.
                esp.run_stub()

                atomvm_installed = "atomvm-esp32" in app_header_strings
                result.append(
                    {
                        "port": port,
                        "chip_family_name": chip_family_name,
                        "chip_description": description,
                        "features": features,
                        "build_info": app_header_strings,
                        "mac_address": mac_addr,
                        "usb_mode": str(usb_mode),
                        "atomvm_installed": atomvm_installed,
                    }
                )
        except Exception as error:  # noqa: BLE001 - skip non-ESP ports
            print(f"Skipping {port}: {error}", file=sys.stderr)
    return result


def resolve_esp_port(port: str) -> str:
    if port != "auto":
        return port

    devices = connected_devices()
    if len(devices) == 1:
        return devices[0]["port"]
    if not devices:
        raise LookupError(
            "Found no ESP32 devices.\n"
            "Hold BOOT while plugging in the device and try again."
        )
    lines = "\n".join(
        f"  {device['chip_family_name']} {device['mac_address']} - {device['port']}"
        for device in devices
    )
    raise LookupError(
        f"Several ESP32 devices found:\n{lines}\nPass one with --port."
    )


def erase_flash(port: str) -> None:
    import esptool

    command = [
        "--chip",
        "auto",
        "--port",
        port,
        "--after",
        "no-reset",
        "erase-flash",
    ]
    try:
        esptool.main(command)
    except SystemExit as exit_error:
        code = int(str(exit_error) or "0")
        if code != 0:
            raise RuntimeError(f"erase-flash failed with exit code {code}") from exit_error


def read_flash(
    port: str,
    address: int,
    size: int,
    output: Path,
    reset_after: bool = False,
) -> dict:
    from esptool.cmds import (
        attach_flash,
        detect_chip,
        detect_flash_size,
        read_flash as esptool_read_flash,
        reset_chip,
    )
    from esptool.util import flash_size_bytes

    with detect_chip(port) as esp:
        attach_flash(esp)
        try:
            flash_size_name = detect_flash_size(esp)
            if flash_size_name is None:
                raise RuntimeError("Unable to detect flash size")

            data = esptool_read_flash(
                esp,
                address,
                size,
                None,
                flash_size=flash_size_name,
                no_progress=True,
            )
            output.write_bytes(data)
            return {
                "bootloader_offset": esp.BOOTLOADER_FLASH_OFFSET,
                "chip_name": esp.CHIP_NAME,
                "flash_size": flash_size_bytes(flash_size_name),
                "flash_size_id": esp.parse_flash_size_arg(flash_size_name),
                "flash_size_name": flash_size_name,
                "bytes_written": len(data),
                "output": str(output),
            }
        finally:
            if reset_after:
                reset_chip(esp, "hard-reset")
            else:
                esp.run_stub()


def write_flash_data(port: str, address: int, data: bytes) -> None:
    from esptool.cmds import attach_flash, detect_chip, reset_chip, write_flash

    with detect_chip(port) as esp:
        attach_flash(esp)
        try:
            write_flash(esp, [(address, data)], flash_size="keep")
        finally:
            reset_chip(esp, "hard-reset")


def select_device_record(port: str) -> dict:
    resolved = resolve_esp_port(port)
    for device in connected_devices():
        if device["port"] == resolved:
            return device
    # Port was explicit but probing failed earlier; return a minimal record.
    return {
        "port": resolved,
        "chip_family_name": "unknown",
        "mac_address": "unknown",
        "usb_mode": "unknown",
        "atomvm_installed": False,
        "build_info": [],
        "features": [],
    }


def write_flash_image(port: str, baud: int, address: int, image: Path) -> None:
    import esptool

    if not image.is_file():
        raise LookupError(f"Firmware image not found: {image}")
    command = [
        "--chip",
        "auto",
        "--port",
        port,
        "--baud",
        str(baud),
        "write-flash",
        f"0x{address:x}",
        str(image),
    ]
    try:
        esptool.main(command)
    except SystemExit as exit_error:
        code = int(str(exit_error) or "0")
        if code != 0:
            raise RuntimeError(
                f"write-flash-image failed with exit code {code}"
            ) from exit_error


def write_flash_parts(
    port: str, baud: int, parts: list[tuple[int, Path]]
) -> None:
    import esptool

    command = [
        "--chip",
        "auto",
        "--port",
        port,
        "--baud",
        str(baud),
        "write-flash",
    ]
    for address, path in parts:
        if not path.is_file():
            raise LookupError(f"Firmware part not found: {path}")
        command.extend([f"0x{address:x}", str(path)])
    try:
        esptool.main(command)
    except SystemExit as exit_error:
        code = int(str(exit_error) or "0")
        if code != 0:
            raise RuntimeError(
                f"write-flash-parts failed with exit code {code}"
            ) from exit_error


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ModuleNotFoundError:
        print(
            "esptool/pyserial is not installed for this Python.\n"
            "Install esptool, or install pyserial+esptool for python3.",
            file=sys.stderr,
        )
        raise SystemExit(1)
