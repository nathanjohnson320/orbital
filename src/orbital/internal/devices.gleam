//// Connected AtomVM targets for `orbital info`: ESP32 probes, Pico BOOTSEL
//// volumes, Pico USB serial, other USB serials, and a default PSP path.

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import orbital/internal/esp32
import orbital/internal/pico
import orbital/internal/psp
import simplifile

pub type UsbSerial {
  UsbSerial(port: String, description: String)
}

pub type PicoBootsel {
  PicoBootsel(label: String, board: String, path: String)
}

pub type Snapshot {
  Snapshot(
    esp32: Result(List(esp32.Device), String),
    pico_bootsel: List(PicoBootsel),
    pico_serial: List(UsbSerial),
    other_serial: List(UsbSerial),
    psp_path: Option(String),
  )
}

type PortInfo {
  PortInfo(name: String, description: String, transport: String)
}

/// Probe the host and format a multi-platform `info` report.
pub fn report() -> String {
  format_report(collect())
}

/// Gather connected / mounted AtomVM-related targets.
pub fn collect() -> Snapshot {
  let esp32_result = case esp32.list_devices() {
    Ok(devices) -> Ok(devices)
    Error(esp32.ToolingMissing(reason)) -> Error(reason)
    Error(esp32.DeviceError(reason)) -> Error(reason)
  }
  let esp_ports = case esp32_result {
    Ok(devices) -> list.map(devices, fn(device) { device.port })
    Error(_) -> []
  }

  let serials = case usb_ports() {
    Ok(ports) -> ports
    Error(_) -> []
  }
  let non_esp =
    list.filter(serials, fn(info) { !list.contains(esp_ports, info.name) })
  let #(pico_serial, other_serial) =
    list.partition(non_esp, fn(info) { is_pico_serial(info) })
    |> pair_map(fn(info) {
      UsbSerial(port: info.name, description: info.description)
    })

  Snapshot(
    esp32: esp32_result,
    pico_bootsel: detect_pico_bootsel(),
    pico_serial:,
    other_serial:,
    psp_path: detect_psp_path(),
  )
}

fn pair_map(
  parts: #(List(PortInfo), List(PortInfo)),
  map: fn(PortInfo) -> UsbSerial,
) -> #(List(UsbSerial), List(UsbSerial)) {
  let #(left, right) = parts
  #(list.map(left, map), list.map(right, map))
}

/// Pure formatter used by tests and `report`.
pub fn format_report(snapshot: Snapshot) -> String {
  let sections =
    list.filter(
      [
        format_esp32_section(snapshot.esp32),
        format_pico_bootsel_section(snapshot.pico_bootsel),
        format_pico_serial_section(snapshot.pico_serial),
        format_other_serial_section(snapshot.other_serial),
        format_psp_section(snapshot.psp_path),
      ],
      fn(section) { section != "" },
    )

  case sections {
    [] -> empty_hint()
    _ ->
      "Connected AtomVM targets\n\n"
      <> string.join(sections, with: "\n\n")
      <> "\n"
  }
}

fn empty_hint() -> String {
  "No AtomVM targets found.\n"
  <> "\n"
  <> "ESP32: hold BOOT while plugging in, then retry.\n"
  <> "Pico: hold BOOT, tap RESET (or replug); look for /Volumes/RPI-RP2 or /Volumes/RP2350.\n"
  <> "PSP: install PPSSPP or pass --psp-path to a Memory Stick / ATOMVM game folder.\n"
}

fn format_esp32_section(result: Result(List(esp32.Device), String)) -> String {
  case result {
    Error(reason) ->
      "ESP32\n" <> "  (could not probe ESP32 devices: " <> reason <> ")"
    Ok([]) -> ""
    Ok(devices) -> {
      let blocks =
        list.map(devices, format_esp32_device)
        |> string.join(with: "\n\n")
      "ESP32\n" <> blocks
    }
  }
}

fn format_esp32_device(device: esp32.Device) -> String {
  let atomvm = case device.atomvm_installed {
    True -> "yes"
    False -> "no"
  }
  let build = case device.build_info {
    [version, ..] -> "  Build: " <> version <> "\n"
    [] -> ""
  }
  "  "
  <> device.chip_family_name
  <> "  "
  <> device.port
  <> "  AtomVM: "
  <> atomvm
  <> "\n"
  <> "  MAC: "
  <> device.mac_address
  <> "\n"
  <> build
  <> "  → gleam run -m orbital flash esp32 --port "
  <> device.port
  <> "\n"
  <> "  → gleam run -m orbital monitor --port "
  <> device.port
}

fn format_pico_bootsel_section(volumes: List(PicoBootsel)) -> String {
  case volumes {
    [] -> ""
    _ -> {
      let blocks =
        list.map(volumes, fn(volume) {
          "  "
          <> volume.label
          <> "  volume "
          <> volume.path
          <> "\n"
          <> "  → gleam run -m orbital install pico --board "
          <> volume.board
          <> " --pico-path "
          <> volume.path
          <> "\n"
          <> "  → gleam run -m orbital flash pico --pico-path "
          <> volume.path
        })
        |> string.join(with: "\n\n")
      "Pico (BOOTSEL)\n" <> blocks
    }
  }
}

fn format_pico_serial_section(ports: List(UsbSerial)) -> String {
  case ports {
    [] -> ""
    _ -> {
      let blocks =
        list.map(ports, fn(serial) {
          let label = case string.trim(serial.description) {
            "" -> "Pico USB serial"
            description -> description
          }
          "  "
          <> serial.port
          <> "  "
          <> label
          <> "\n"
          <> "  → gleam run -m orbital monitor pico --port "
          <> serial.port
          <> " -t 0\n"
          <> "  (flash/install need BOOTSEL — hold BOOT, tap RESET)"
        })
        |> string.join(with: "\n\n")
      "Pico (serial)\n" <> blocks
    }
  }
}

fn format_other_serial_section(ports: List(UsbSerial)) -> String {
  case ports {
    [] -> ""
    _ -> {
      let blocks =
        list.map(ports, fn(serial) {
          let label = case string.trim(serial.description) {
            "" -> "USB serial"
            description -> description
          }
          "  " <> serial.port <> "  " <> label
        })
        |> string.join(with: "\n")
      "Other USB serial\n"
      <> blocks
      <> "\n"
      <> "  (not an AtomVM flash target; pass --port explicitly if a Pico is also connected)"
    }
  }
}

fn format_psp_section(path: Option(String)) -> String {
  case path {
    None -> ""
    Some(path) ->
      "PSP\n"
      <> "  "
      <> path
      <> "\n"
      <> "  → gleam run -m orbital install psp --psp-path "
      <> path
      <> "\n"
      <> "  → gleam run -m orbital flash psp --psp-path "
      <> path
  }
}

fn detect_pico_bootsel() -> List(PicoBootsel) {
  list.filter_map(
    [
      #("RPI-RP2", "Pico", "pico"),
      #("RP2350", "Pico 2", "pico2"),
    ],
    fn(entry) {
      let #(volume, label, board) = entry
      let path = pico.default_mount_for_volume(volume)
      case path == "" {
        True -> Error(Nil)
        False ->
          case simplifile.is_directory(path) {
            Ok(True) -> Ok(PicoBootsel(label:, board:, path:))
            _ -> Error(Nil)
          }
      }
    },
  )
}

fn detect_psp_path() -> Option(String) {
  case psp.default_ppsspp_game_path(psp.default_game_dir) {
    None -> None
    Some(path) ->
      case simplifile.is_directory(path) {
        Ok(True) -> Some(path)
        _ -> None
      }
  }
}

fn is_pico_serial(info: PortInfo) -> Bool {
  looks_like_pico_usb(info.name, info.description, info.transport)
}

/// True when a USB serial description looks like a Pico / AtomVM CDC device
/// (not a random ACM gadget such as a Keyboardio).
pub fn looks_like_pico_usb(
  name: String,
  description: String,
  transport: String,
) -> Bool {
  let blob = string.lowercase(name <> " " <> description <> " " <> transport)
  list.any(
    ["pico", "raspberry", "atomvm", "rp2040", "rp2350", "rpi-rp2"],
    fn(token) { string.contains(blob, token) },
  )
}

fn usb_ports() -> Result(List(PortInfo), String) {
  use rows <- result.try(list_ports_raw())
  let family = os_family()
  let ports =
    list.map(rows, fn(row) {
      let #(name, description, transport) = row
      PortInfo(name:, description:, transport:)
    })
  Ok(list.filter(ports, fn(info) { is_usb_candidate(info, family) }))
}

fn is_usb_candidate(info: PortInfo, family: String) -> Bool {
  let name = string.lowercase(info.name)
  let description = string.lowercase(info.description)
  let transport = string.lowercase(info.transport)
  let blob = name <> " " <> description <> " " <> transport
  let skip_macos_tty =
    family == "darwin" && string.starts_with(info.name, "/dev/tty.")
  let usbish =
    transport == "usb"
    || list.any(
      [
        "usb", "acm", "slab", "wch", "espressif", "cp210", "ch340", "ftdi",
        "cu.usb", "ttyacm", "ttyusb",
      ],
      fn(token) { string.contains(blob, token) },
    )
  !skip_macos_tty && usbish
}

@external(erlang, "orbital_serial_ffi", "list_ports")
fn list_ports_raw() -> Result(List(#(String, String, String)), String)

@external(erlang, "orbital_serial_ffi", "os_family")
fn os_family() -> String
