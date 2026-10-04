//// Raspberry Pi Pico / RP2 helpers matching ExAtomVM's `pico.flash` and
//// `uf2create` tasks: UF2 conversion, mount defaults, serial BOOTSEL reset,
//// and copying the UF2 onto the mounted volume.

import envoy
import filepath
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import orbital/internal/executable
import simplifile

pub const default_app_start = 0x10180000

pub const default_family_id = "universal"

pub type FamilyId {
  Rp2040
  Rp2350Riscv
  Rp2350ArmS
  Rp2350ArmNs
  Absolute
  Data
  Universal
}

pub type Error {
  UnsupportedFamilyId(value: String)
  InvalidAppStart(value: String)
  CannotCreateUf2(reason: String)
  PicoNotMounted(path: String)
  MountTimeout(path: String)
  MountNotDirectory(path: String)
  ResetFailed(reason: String)
  CannotCopyUf2(reason: simplifile.FileError)
  SttyMissing
  PicotoolMissing
  PicotoolFailed(reason: String)
}

pub type FlashOptions {
  FlashOptions(
    pico_path: Option(String),
    pico_reset: Option(String),
    picotool: Option(String),
  )
}

pub type Uf2Options {
  Uf2Options(app_start: Option(String), family_id: Option(String))
}

/// Parse a `family_id` the same way ExAtomVM / uf2tool accept it.
pub fn parse_family_id(value: String) -> Result(FamilyId, Error) {
  case string.lowercase(string.trim(value)) {
    "rp2040" | ":rp2040" -> Ok(Rp2040)
    "rp2350_riscv" | ":rp2350_riscv" -> Ok(Rp2350Riscv)
    "rp2350_arm_s" | ":rp2350_arm_s" -> Ok(Rp2350ArmS)
    "rp2350_arm_ns" | ":rp2350_arm_ns" -> Ok(Rp2350ArmNs)
    "absolute" | ":absolute" -> Ok(Absolute)
    "data" | ":data" -> Ok(Data)
    "universal" | ":universal" -> Ok(Universal)
    other -> Error(UnsupportedFamilyId(other))
  }
}

/// Parse an app start address: `0x…`, `16#…`, or decimal.
pub fn parse_app_start(value: String) -> Result(Int, Error) {
  let trimmed = string.trim(value)
  case trimmed {
    "0x" <> hex | "0X" <> hex ->
      case int.base_parse(hex, 16) {
        Ok(address) -> Ok(address)
        Error(_) -> Error(InvalidAppStart(trimmed))
      }
    "16#" <> hex ->
      case int.base_parse(hex, 16) {
        Ok(address) -> Ok(address)
        Error(_) -> Error(InvalidAppStart(trimmed))
      }
    _ ->
      case int.parse(trimmed) {
        Ok(address) -> Ok(address)
        Error(_) -> Error(InvalidAppStart(trimmed))
      }
  }
}

pub fn family_id_to_string(family: FamilyId) -> String {
  case family {
    Rp2040 -> "rp2040"
    Rp2350Riscv -> "rp2350_riscv"
    Rp2350ArmS -> "rp2350_arm_s"
    Rp2350ArmNs -> "rp2350_arm_ns"
    Absolute -> "absolute"
    Data -> "data"
    Universal -> "universal"
  }
}

pub fn resolve_app_start(override: Option(String)) -> Result(Int, Error) {
  case override {
    Some(value) -> parse_app_start(value)
    None ->
      case envoy.get("ATOMVM_PICO_APP_START") {
        Ok(value) -> parse_app_start(value)
        Error(_) -> Ok(default_app_start)
      }
  }
}

pub fn resolve_family_id(override: Option(String)) -> Result(FamilyId, Error) {
  case override {
    Some(value) -> parse_family_id(value)
    None ->
      case envoy.get("ATOMVM_PICO_UF2_FAMILY") {
        Ok(value) -> parse_family_id(value)
        Error(_) -> Ok(Universal)
      }
  }
}

pub fn default_mount() -> String {
  default_mount_for_volume("RPI-RP2")
}

/// Mount path for a volume name (`RPI-RP2` or `RP2350`).
pub fn default_mount_for_volume(volume: String) -> String {
  case os_family() {
    "linux" -> {
      let user = case envoy.get("USER") {
        Ok(user) -> user
        Error(_) -> ""
      }
      "/run/media/" <> user <> "/" <> volume
    }
    "darwin" -> "/Volumes/" <> volume
    _ -> ""
  }
}

pub fn default_reset() -> String {
  case os_family() {
    "linux" -> "/dev/ttyACM*"
    "darwin" -> "/dev/cu.usbmodem14*"
    _ -> ""
  }
}

pub fn resolve_pico_path(override: Option(String)) -> String {
  case override {
    Some(path) -> path
    None ->
      case envoy.get("ATOMVM_PICO_MOUNT_PATH") {
        Ok(path) -> path
        Error(_) -> default_mount()
      }
  }
}

pub fn resolve_pico_reset(override: Option(String)) -> String {
  case override {
    Some(path) -> path
    None ->
      case envoy.get("ATOMVM_PICO_RESET_DEV") {
        Ok(path) -> path
        Error(_) -> default_reset()
      }
  }
}

pub fn resolve_picotool(override: Option(String)) -> Option(String) {
  case override {
    Some(path) -> Some(path)
    None ->
      case envoy.get("ATOMVM_PICOTOOL_PATH") {
        Ok(path) -> Some(path)
        Error(_) ->
          case executable.find("picotool") {
            Ok(_) -> Some("picotool")
            Error(_) -> None
          }
      }
  }
}

/// Create a UF2 file from an AVM using uf2tool.
pub fn create_uf2(
  avm_path avm_path: String,
  uf2_path uf2_path: String,
  options options: Uf2Options,
) -> Result(Nil, Error) {
  use app_start <- result.try(resolve_app_start(options.app_start))
  use family <- result.try(resolve_family_id(options.family_id))
  uf2create_ffi(uf2_path, family_id_to_string(family), app_start, avm_path)
  |> result.map_error(CannotCreateUf2)
}

/// Flash a UF2 onto a mounted Pico volume, resetting into BOOTSEL when needed.
pub fn flash_uf2(
  uf2_path uf2_path: String,
  options options: FlashOptions,
) -> Result(Nil, Error) {
  let pico_path = resolve_pico_path(options.pico_path)
  let pico_reset = resolve_pico_reset(options.pico_reset)
  let picotool = resolve_picotool(options.picotool)

  use Nil <- result.try(maybe_reset(pico_path, pico_reset, picotool))
  use Nil <- result.try(check_pico_mount(pico_path))

  let dest = filepath.join(pico_path, filepath.base_name(uf2_path))
  simplifile.copy(src: uf2_path, dest:)
  |> result.map_error(CannotCopyUf2)
}

/// Install a firmware UF2: prefer `picotool load -f`, else mount-copy.
pub fn install_firmware_uf2(
  uf2_path uf2_path: String,
  options options: FlashOptions,
  volume volume: String,
) -> Result(Nil, Error) {
  let picotool = resolve_picotool(options.picotool)
  case picotool {
    Some(tool) ->
      case picotool_load(tool, uf2_path) {
        Ok(Nil) -> Ok(Nil)
        Error(error) -> {
          io.println(
            "picotool load failed ("
            <> error_message(error)
            <> "); falling back to UF2 volume copy…",
          )
          install_via_mount(uf2_path, options, volume)
        }
      }
    None -> install_via_mount(uf2_path, options, volume)
  }
}

fn install_via_mount(
  uf2_path: String,
  options: FlashOptions,
  volume: String,
) -> Result(Nil, Error) {
  let pico_path = case options.pico_path {
    Some(path) -> path
    None ->
      case envoy.get("ATOMVM_PICO_MOUNT_PATH") {
        Ok(path) -> path
        Error(_) -> default_mount_for_volume(volume)
      }
  }
  flash_uf2(
    uf2_path:,
    options: FlashOptions(..options, pico_path: Some(pico_path)),
  )
}

fn picotool_load(tool: String, uf2_path: String) -> Result(Nil, Error) {
  io.println("Loading " <> filepath.base_name(uf2_path) <> " with picotool…")
  // `-f` resets a running compatible device into BOOTSEL, loads, then returns
  // it to application mode. Virgin BOOTSEL devices accept load without `-f`.
  case run_named_executable(tool, ["load", "-f", uf2_path]) {
    Ok(0) -> Ok(Nil)
    Ok(_) ->
      case run_named_executable(tool, ["load", uf2_path]) {
        Ok(0) -> {
          let _ = run_named_executable(tool, ["reboot", "-f", "-a"])
          Ok(Nil)
        }
        Ok(code) ->
          Error(PicotoolFailed(
            "picotool load failed with status " <> int.to_string(code),
          ))
        Error(_) -> Error(PicotoolFailed("could not run picotool load"))
      }
    Error(_) -> Error(PicotoolMissing)
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    UnsupportedFamilyId(value:) ->
      "Unsupported family_id '"
      <> value
      <> "'. Use rp2040, data, absolute, rp2350_arm_s, rp2350_riscv, "
      <> "rp2350_arm_ns, or universal."
    InvalidAppStart(value:) ->
      "Invalid app start address '"
      <> value
      <> "'. Use a hex value like 0x10180000."
    CannotCreateUf2(reason:) -> "I couldn't create the UF2 file.\n" <> reason
    PicoNotMounted(path:) ->
      "Pico not mounted at '"
      <> path
      <> "'.\nHold BOOTSEL while plugging in the board, or pass --pico-path."
    MountTimeout(path:) ->
      "Timed out waiting for the Pico to mount at '" <> path <> "'."
    MountNotDirectory(path:) ->
      "Object found at pico mount path '" <> path <> "' is not a directory."
    ResetFailed(reason:) ->
      "I couldn't reset the Pico into BOOTSEL mode.\n" <> reason
    CannotCopyUf2(_) -> "I couldn't copy the UF2 file onto the Pico mount."
    SttyMissing ->
      "Unable to locate 'stty' or 'picotool'. Close the serial monitor before "
      <> "flashing, or install picotool for automatic disconnect and BOOTSEL mode."
    PicotoolMissing ->
      "picotool was not found. Install it or pass --picotool, or put the Pico "
      <> "in BOOTSEL mode so Orbital can copy the UF2 to the mounted volume."
    PicotoolFailed(reason:) -> reason
  }
}

fn maybe_reset(
  pico_path: String,
  pico_reset: String,
  picotool: Option(String),
) -> Result(Nil, Error) {
  case needs_reset(pico_reset) {
    None -> Ok(Nil)
    Some(reset_port) -> {
      use Nil <- result.try(do_reset(reset_port, picotool))
      io.println(
        "Waiting for the device at path "
        <> pico_path
        <> " to settle and mount...",
      )
      wait_for_mount(pico_path, 0)
    }
  }
}

fn needs_reset(reset_pattern: String) -> Option(String) {
  case reset_pattern {
    "" -> None
    _ ->
      list.find_map(wildcard(reset_pattern), fn(device) {
        case simplifile.file_info(device) {
          Ok(info) ->
            case simplifile.file_info_type(info) {
              // Character devices show up as Other on Unix.
              simplifile.Other -> Ok(device)
              _ -> Error(Nil)
            }
          Error(_) -> Error(Nil)
        }
      })
      |> option.from_result
  }
}

fn do_reset(
  reset_port: String,
  picotool: Option(String),
) -> Result(Nil, Error) {
  case try_stty_reset(reset_port) {
    Ok(Nil) -> {
      process.sleep(200)
      Ok(Nil)
    }
    Error(_) ->
      case picotool {
        None -> Error(SttyMissing)
        Some(tool) -> {
          io.println(
            "Warning: stty reset failed.\nFor faster flashing remember to disconnect serial monitor first.",
          )
          io.println(
            "Disconnecting serial monitor with `picotool reboot -f -u` in 5 seconds...",
          )
          process.sleep(5000)
          run_picotool(tool)
        }
      }
  }
}

fn try_stty_reset(reset_port: String) -> Result(Nil, Error) {
  use stty <- result.try(
    executable.find("stty")
    |> result.replace_error(SttyMissing),
  )
  let flag = case os_family() {
    "linux" -> "-F"
    _ -> "-f"
  }
  case executable.run(stty, ".", [flag, reset_port, "1200"]) {
    Ok(0) -> Ok(Nil)
    Ok(_) | Error(_) -> Error(ResetFailed("stty could not open " <> reset_port))
  }
}

fn run_picotool(tool: String) -> Result(Nil, Error) {
  case run_named_executable(tool, ["reboot", "-f", "-u"]) {
    Ok(0) -> Ok(Nil)
    Ok(code) ->
      Error(ResetFailed("picotool failed with status " <> int.to_string(code)))
    Error(_) -> Error(ResetFailed("could not run picotool"))
  }
}

fn wait_for_mount(mount: String, count: Int) -> Result(Nil, Error) {
  case count >= 30 {
    True -> Error(MountTimeout(mount))
    False ->
      case simplifile.is_directory(mount) {
        Ok(True) -> Ok(Nil)
        Ok(False) -> Error(MountNotDirectory(mount))
        Error(_) -> {
          process.sleep(1000)
          wait_for_mount(mount, count + 1)
        }
      }
  }
}

fn check_pico_mount(mount: String) -> Result(Nil, Error) {
  case simplifile.is_directory(mount) {
    Ok(True) -> Ok(Nil)
    Ok(False) -> Error(MountNotDirectory(mount))
    Error(_) -> Error(PicoNotMounted(mount))
  }
}

@external(erlang, "orbital_ffi", "os_family")
fn os_family() -> String

@external(erlang, "orbital_ffi", "wildcard")
fn wildcard(pattern: String) -> List(String)

@external(erlang, "orbital_ffi", "uf2create")
fn uf2create_ffi(
  output_path: String,
  family_id: String,
  start_addr: Int,
  image_path: String,
) -> Result(Nil, String)

@external(erlang, "orbital_ffi", "run_named_executable")
fn run_named_executable(
  name: String,
  arguments: List(String),
) -> Result(Int, Nil)
