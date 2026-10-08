//// Shared ESP32 device helpers for Orbital commands.
////
//// Wraps the `orbital_esp` NIF (esp-serial-flasher + libserialport) for device
//// discovery, flash erase/read/write, and port selection. Pure partition /
//// image-header logic lives in `partition` and `image_header`; this module is
//// the device I/O boundary.

import filepath
import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import orbital/internal/image_header
import simplifile
import temporary

/// A connected ESP32-family board discovered over USB serial.
pub type Device {
  Device(
    port: String,
    chip_family_name: String,
    mac_address: String,
    usb_mode: String,
    atomvm_installed: Bool,
    build_info: List(String),
    features: List(String),
  )
}

/// Metadata returned after reading a flash region to a file.
pub type FlashRead {
  FlashRead(
    bootloader_offset: Int,
    chip_name: String,
    flash_size: Int,
    flash_size_id: Int,
    flash_size_name: String,
    bytes_written: Int,
    /// Absolute path where the flash bytes were written.
    output: String,
  )
}

pub type Error {
  /// Native flash NIF could not be located or loaded.
  ToolingMissing(reason: String)
  /// Helper ran but reported a device or protocol failure.
  DeviceError(reason: String)
}

/// List ESP32-like USB serial devices and probe each for AtomVM metadata.
pub fn list_devices() -> Result(List(Device), Error) {
  list_devices_ffi()
  |> map_ffi_error
}

/// Resolve `auto` to a single connected device port, or return an explicit port.
///
/// With zero devices or more than one, returns `DeviceError` with a message that
/// tells the caller to pass `--port`.
pub fn select_port(port: String) -> Result(String, Error) {
  select_port_ffi(port)
  |> map_ffi_error
}

/// Resolve a port and return the matching probed device record.
pub fn select_device(port: String) -> Result(Device, Error) {
  select_device_ffi(port)
  |> map_ffi_error
}

/// Flash a full firmware `.img` at `address`.
pub fn write_flash_image(
  port port: String,
  baud baud: Int,
  address address: Int,
  file_path file_path: String,
) -> Result(Nil, Error) {
  write_flash_image_ffi(port, baud, address, file_path)
  |> map_ffi_error
}

/// Flash multiple `(address, file)` parts in one session.
pub fn write_flash_parts(
  port port: String,
  baud baud: Int,
  parts parts: List(#(Int, String)),
) -> Result(Nil, Error) {
  write_flash_parts_ffi(port, baud, parts)
  |> map_ffi_error
}

/// Erase the entire flash of the device at `port` (`"auto"` allowed).
pub fn erase_flash(port: String) -> Result(Nil, Error) {
  erase_flash_ffi(port)
  |> map_ffi_error
}

/// Read `size` bytes from flash at `address` into `output_path`.
///
/// When `reset_after` is `True`, the chip is hard-reset after the read.
pub fn read_flash(
  port port: String,
  address address: Int,
  size size: Int,
  output_path output_path: String,
  reset_after reset_after: Bool,
) -> Result(FlashRead, Error) {
  read_flash_ffi(port, address, size, output_path, reset_after)
  |> map_ffi_error
}

/// Write the contents of `file_path` to flash at `address`.
pub fn write_flash_data(
  port port: String,
  address address: Int,
  file_path file_path: String,
) -> Result(Nil, Error) {
  write_flash_data_ffi(port, address, file_path)
  |> map_ffi_error
}

/// Update the bootloader flash-size header and rewrite the partition table.
///
/// Rewrites the size nibble in Gleam (`image_header`), then flashes both images.
pub fn write_flash_size_and_partition(
  port port: String,
  bootloader_offset bootloader_offset: Int,
  bootloader_path bootloader_path: String,
  partition_offset partition_offset: Int,
  partition_path partition_path: String,
  flash_size_name flash_size_name: String,
) -> Result(Nil, Error) {
  use bootloader <- result.try(
    simplifile.read_bits(bootloader_path)
    |> result.replace_error(DeviceError(
      reason: "Could not read staged bootloader at " <> bootloader_path,
    )),
  )
  use updated <- result.try(
    image_header.with_flash_size_name(bootloader, flash_size_name)
    |> result.map_error(fn(_) {
      DeviceError(reason: "Invalid bootloader image header")
    }),
  )
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let updated_path = filepath.join(directory, "bootloader-updated.bin")
    use Nil <- result.try(
      simplifile.write_bits(to: updated_path, bits: updated)
      |> result.replace_error(DeviceError(
        reason: "Could not stage updated bootloader",
      )),
    )
    write_flash_parts(
      port:,
      baud: 921_600,
      parts: [
        #(bootloader_offset, updated_path),
        #(partition_offset, partition_path),
      ],
    )
  }
  case outcome {
    Ok(result) -> result
    Error(_) ->
      Error(DeviceError(
        reason: "Could not write bootloader and partition table",
      ))
  }
}

/// Read a flash region into memory via a temporary file.
pub fn read_flash_bytes(
  port port: String,
  address address: Int,
  size size: Int,
  reset_after reset_after: Bool,
) -> Result(#(BitArray, FlashRead), Error) {
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let output_path = filepath.join(directory, "flash.bin")
    use meta <- result.try(read_flash(
      port:,
      address:,
      size:,
      output_path:,
      reset_after:,
    ))
    case simplifile.read_bits(output_path) {
      Ok(bytes) -> Ok(#(bytes, meta))
      Error(_) ->
        Error(DeviceError(
          reason: "Could not read the temporary flash dump at " <> output_path,
        ))
    }
  }
  case outcome {
    Ok(result) -> result
    Error(_) ->
      Error(DeviceError(reason: "Could not create a temporary flash dump."))
  }
}

/// Write raw bytes to flash by staging them in a temporary file.
pub fn write_flash_bytes(
  port port: String,
  address address: Int,
  data data: BitArray,
) -> Result(Nil, Error) {
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let file_path = filepath.join(directory, "payload.bin")
    case simplifile.write_bits(to: file_path, bits: data) {
      Error(_) ->
        Error(DeviceError(reason: "Could not stage flash payload on disk."))
      Ok(Nil) -> write_flash_data(port:, address:, file_path:)
    }
  }
  case outcome {
    Ok(result) -> result
    Error(_) ->
      Error(DeviceError(reason: "Could not create a temporary flash payload."))
  }
}

/// Format a device summary line for CLIs (`info`, install prompts, etc.).
pub fn format_device(device: Device) -> String {
  let atomvm = case device.atomvm_installed {
    True -> "AtomVM"
    False -> "no AtomVM"
  }
  device.chip_family_name
  <> " "
  <> device.mac_address
  <> " ("
  <> atomvm
  <> ") - "
  <> device.port
}

/// Full `info` report for zero or more connected devices.
pub fn format_info_report(devices: List(Device)) -> String {
  case devices {
    [] ->
      "Found no ESP32 devices.\n"
      <> "You may have to hold the BOOT button down while plugging in the device."
    _ -> {
      let count = list.length(devices)
      let heading = case count {
        1 -> "Found 1 connected ESP32:"
        n -> "Found " <> int.to_string(n) <> " connected ESP32 boards:"
      }
      let summary = case count > 1 {
        False -> ""
        True ->
          "\n"
          <> {
            list.map(devices, fn(device) {
              "• "
              <> pad_right(device.chip_family_name, 8)
              <> " - Port: "
              <> device.port
            })
            |> string.join(with: "\n")
          }
          <> "\n"
      }
      let details =
        list.map(devices, format_info_device)
        |> string.join(with: "\n")
      heading <> summary <> "\n" <> details <> "\n"
    }
  }
}

fn format_info_device(device: Device) -> String {
  let installed = case device.atomvm_installed {
    True -> "yes"
    False -> "no"
  }
  let features = case device.features {
    [] -> "  (none)"
    features ->
      list.map(features, fn(feature) { "  · " <> feature })
      |> string.join(with: "\n")
  }
  [
    "━━━━━━━━━━━━━━━━━━━━━━",
    device.chip_family_name <> " - Port: " <> device.port,
    "USB_MODE: " <> device.usb_mode,
    "MAC: " <> device.mac_address,
    "AtomVM installed: " <> installed,
    "",
    "Build Information:",
    ..list.append(format_build_info(device.build_info), [
      "",
      "Features:",
      features,
    ])
  ]
  |> string.join(with: "\n")
}

fn format_build_info(build_info: List(String)) -> List(String) {
  case build_info {
    [version, target, time, date, sdk] -> [
      "  Version: " <> version,
      "  Target:  " <> target,
      "  Built:   " <> time <> " " <> date,
      "  SDK:     " <> sdk,
    ]
    [] -> ["  Build info not available"]
    infos ->
      list.index_map(infos, fn(info, index) {
        "  Info " <> int.to_string(index + 1) <> ": " <> info
      })
  }
}

fn pad_right(text: String, width: Int) -> String {
  let padding = width - string.length(text)
  case padding > 0 {
    True -> text <> string.repeat(" ", padding)
    False -> text
  }
}

/// Prefer an explicit port, otherwise `"auto"`.
pub fn port_or_auto(port: Option(String)) -> String {
  case port {
    Some(port) -> port
    None -> "auto"
  }
}

/// Hex helper for flash addresses.
pub fn hex_address(value: Int) -> String {
  "0x" <> hex_digits(value)
}

/// Length of a bit array, for callers staging payloads.
pub fn byte_size(data: BitArray) -> Int {
  bit_array.byte_size(data)
}

fn map_ffi_error(result: Result(a, String)) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(reason) -> Error(classify_error(reason))
  }
}

fn classify_error(reason: String) -> Error {
  let lowered = string.lowercase(reason)
  case
    string.contains(lowered, "nif not loaded")
    || string.contains(lowered, "need priv/orbital_esp")
  {
    True -> ToolingMissing(reason:)
    False -> DeviceError(reason:)
  }
}

fn hex_digits(value: Int) -> String {
  let assert Ok(nibble) = int.remainder(value, 16)
  let rest = value / 16
  let digit = string.slice("0123456789abcdef", nibble, 1)
  case rest {
    0 -> digit
    _ -> hex_digits(rest) <> digit
  }
}

@external(erlang, "orbital_esp_ffi", "list_devices")
fn list_devices_ffi() -> Result(List(Device), String)

@external(erlang, "orbital_esp_ffi", "select_port")
fn select_port_ffi(port: String) -> Result(String, String)

@external(erlang, "orbital_esp_ffi", "select_device")
fn select_device_ffi(port: String) -> Result(Device, String)

@external(erlang, "orbital_esp_ffi", "erase_flash")
fn erase_flash_ffi(port: String) -> Result(Nil, String)

@external(erlang, "orbital_esp_ffi", "read_flash")
fn read_flash_ffi(
  port: String,
  address: Int,
  size: Int,
  output_path: String,
  reset_after: Bool,
) -> Result(FlashRead, String)

@external(erlang, "orbital_esp_ffi", "write_flash_data")
fn write_flash_data_ffi(
  port: String,
  address: Int,
  file_path: String,
) -> Result(Nil, String)

@external(erlang, "orbital_esp_ffi", "write_flash_image")
fn write_flash_image_ffi(
  port: String,
  baud: Int,
  address: Int,
  file_path: String,
) -> Result(Nil, String)

@external(erlang, "orbital_esp_ffi", "write_flash_parts")
fn write_flash_parts_ffi(
  port: String,
  baud: Int,
  parts: List(#(Int, String)),
) -> Result(Nil, String)
