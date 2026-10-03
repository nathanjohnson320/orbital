//// Shared ESP32 device helpers for later Orbital commands.
////
//// Wraps `priv/esp32.py` (esptool / pyserial) for device discovery, flash
//// erase/read/write, and port selection. Pure partition / image-header logic
//// lives in `partition` and `image_header`; this module is the device I/O
//// boundary. No user-facing CLI commands are defined here.

import filepath
import gleam/bit_array
import gleam/dynamic/decode
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
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
  /// esptool / python / helper script could not be located or started.
  ToolingMissing(reason: String)
  /// Helper ran but reported a device or protocol failure.
  DeviceError(reason: String)
}

/// List ESP32-like USB serial devices and probe each for AtomVM metadata.
pub fn list_devices() -> Result(List(Device), Error) {
  use raw <- result.try(list_devices_ffi() |> map_ffi_error)
  case json.parse(raw, decode.list(device_decoder())) {
    Ok(devices) -> Ok(devices)
    Error(_) ->
      Error(DeviceError(
        reason: "ESP32 helper list-devices returned invalid JSON.",
      ))
  }
}

/// Resolve `auto` to a single connected device port, or return an explicit port.
///
/// With zero devices or more than one, returns `DeviceError` with a message that
/// tells the caller to pass `--port`.
pub fn select_port(port: String) -> Result(String, Error) {
  use raw <- result.try(select_port_ffi(port) |> map_ffi_error)
  case json.parse(raw, decode.at(["port"], decode.string)) {
    Ok(resolved) -> Ok(resolved)
    Error(_) ->
      Error(DeviceError(
        reason: "ESP32 helper select-port returned invalid JSON.",
      ))
  }
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
  use raw <- result.try(
    read_flash_ffi(port, address, size, output_path, reset_after)
    |> map_ffi_error,
  )
  case json.parse(raw, flash_read_decoder()) {
    Ok(meta) -> Ok(meta)
    Error(_) ->
      Error(DeviceError(
        reason: "ESP32 helper read-flash returned invalid JSON.",
      ))
  }
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
/// Uses esptool's image-header rewriter so flash mode/frequency stay `keep`
/// while the size matches `flash_size_name` (e.g. `"16MB"`).
pub fn write_flash_size_and_partition(
  port port: String,
  bootloader_offset bootloader_offset: Int,
  bootloader_path bootloader_path: String,
  partition_offset partition_offset: Int,
  partition_path partition_path: String,
  flash_size_name flash_size_name: String,
) -> Result(Nil, Error) {
  write_flash_size_and_partition_ffi(
    port,
    bootloader_offset,
    bootloader_path,
    partition_offset,
    partition_path,
    flash_size_name,
  )
  |> map_ffi_error
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

fn device_decoder() -> decode.Decoder(Device) {
  use port <- decode.field("port", decode.string)
  use chip_family_name <- decode.field("chip_family_name", decode.string)
  use mac_address <- decode.field("mac_address", decode.string)
  use usb_mode <- decode.field("usb_mode", decode.string)
  use atomvm_installed <- decode.field("atomvm_installed", decode.bool)
  use build_info <- decode.field("build_info", decode.list(decode.string))
  use features <- decode.field("features", decode.list(decode.string))
  decode.success(Device(
    port:,
    chip_family_name:,
    mac_address:,
    usb_mode:,
    atomvm_installed:,
    build_info:,
    features:,
  ))
}

fn flash_read_decoder() -> decode.Decoder(FlashRead) {
  use bootloader_offset <- decode.field("bootloader_offset", decode.int)
  use chip_name <- decode.field("chip_name", decode.string)
  use flash_size <- decode.field("flash_size", decode.int)
  use flash_size_id <- decode.field("flash_size_id", decode.int)
  use flash_size_name <- decode.field("flash_size_name", decode.string)
  use bytes_written <- decode.field("bytes_written", decode.int)
  use output <- decode.field("output", decode.string)
  decode.success(FlashRead(
    bootloader_offset:,
    chip_name:,
    flash_size:,
    flash_size_id:,
    flash_size_name:,
    bytes_written:,
    output:,
  ))
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
    string.contains(lowered, "cannot find")
    || string.contains(lowered, "not installed")
    || string.contains(lowered, "not found")
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

@external(erlang, "orbital_ffi", "esp32_list_devices")
fn list_devices_ffi() -> Result(String, String)

@external(erlang, "orbital_ffi", "esp32_select_port")
fn select_port_ffi(port: String) -> Result(String, String)

@external(erlang, "orbital_ffi", "esp32_erase_flash")
fn erase_flash_ffi(port: String) -> Result(Nil, String)

@external(erlang, "orbital_ffi", "esp32_read_flash")
fn read_flash_ffi(
  port: String,
  address: Int,
  size: Int,
  output_path: String,
  reset_after: Bool,
) -> Result(String, String)

@external(erlang, "orbital_ffi", "esp32_write_flash_data")
fn write_flash_data_ffi(
  port: String,
  address: Int,
  file_path: String,
) -> Result(Nil, String)

@external(erlang, "orbital_ffi", "esp32_write_flash_size_and_partition")
fn write_flash_size_and_partition_ffi(
  port: String,
  bootloader_offset: Int,
  bootloader_path: String,
  partition_offset: Int,
  partition_path: String,
  flash_size_name: String,
) -> Result(Nil, String)
