//// `orbital install` orchestration: resolve images, confirm, erase/flash,
//// and apply `--update` guardrails. Network listing/download is delegated to
//// `priv/firmware.py`; device I/O uses `orbital/internal/esp32`.

import filepath
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import orbital/internal/esp32
import orbital/internal/firmware
import simplifile

pub type Mode {
  Install
  Update
}

pub type Options {
  Options(
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    update: Bool,
    download_only: Bool,
    list_images: Bool,
    chip: Option(String),
    baud: Int,
    port: Option(String),
  )
}

pub type Error {
  FirmwareError(String)
  DeviceError(String)
  ToolingMissing(String)
  Cancelled
  Validation(String)
}

pub fn run(options: Options) -> Result(Nil, Error) {
  case options.list_images {
    True -> list_images(options)
    False ->
      case options.download_only {
        True -> download_only(options)
        False -> install_or_update(options)
      }
  }
}

fn list_images(options: Options) -> Result(Nil, Error) {
  let connected = case esp32.list_devices() {
    Ok(devices) ->
      devices
      |> list.map(fn(d) { firmware.chip_token(d.chip_family_name) })
      |> list.unique
      |> string.join(with: ",")
    Error(_) -> ""
  }
  use text <- result.try(
    list_images_ffi(
      option.unwrap(options.chip, ""),
      option.unwrap(options.repo, ""),
      connected,
    )
    |> map_tool_error,
  )
  io.print(text)
  case string.ends_with(text, "\n") {
    True -> Nil
    False -> io.println("")
  }
  Ok(Nil)
}

fn download_only(options: Options) -> Result(Nil, Error) {
  use image <- result.try(resolve_for_download(options))
  let path = option.unwrap(image.path, option.unwrap(image.img_path, image.name))
  io.println("")
  io.println(
    path
    <> " is ready. Install it, offline too, with:\n  gleam run -m orbital install --image "
    <> path,
  )
  Ok(Nil)
}

fn install_or_update(options: Options) -> Result(Nil, Error) {
  let mode = case options.update {
    True -> Update
    False -> Install
  }
  use device <- result.try(
    esp32.select_device(esp32.port_or_auto(options.port))
    |> map_esp32_error,
  )
  let chip = firmware.chip_token(device.chip_family_name)
  use image <- result.try(resolve_for_device(options, chip))
  use Nil <- result.try(check_chip(image, chip, device))
  use offset <- result.try(
    firmware.flash_offset_for(image, chip)
    |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
  )

  case mode {
    Install -> do_install(device, image, chip, offset, options.baud)
    Update -> do_update(device, image, chip, offset, options.baud)
  }
}

fn do_install(
  device: esp32.Device,
  image: firmware.Image,
  chip: String,
  offset: Int,
  baud: Int,
) -> Result(Nil, Error) {
  use path <- result.try(
    firmware.image_path(image)
    |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
  )
  use Nil <- result.try(confirm_install(device, image, chip, offset))
  io.println("Erasing and flashing")
  use Nil <- result.try(
    esp32.erase_flash(device.port) |> map_esp32_error,
  )
  process.sleep(3000)
  use Nil <- result.try(
    esp32.write_flash_image(port: device.port, baud:, address: offset, file_path: path)
    |> map_esp32_error,
  )
  io.println("")
  io.println(
    ansi.magenta(
      "Successfully installed AtomVM on "
      <> device.chip_family_name
      <> " - Port: "
      <> device.port
      <> " MAC: "
      <> device.mac_address,
    ),
  )
  io.println("")
  io.println("Your project can now be flashed with:")
  io.println("  gleam run -m orbital flash esp32")
  io.println("")
  Ok(Nil)
}

fn do_update(
  device: esp32.Device,
  image: firmware.Image,
  chip: String,
  offset: Int,
  baud: Int,
) -> Result(Nil, Error) {
  case device.atomvm_installed {
    False -> Error(FirmwareError(firmware.error_message(firmware.NotInstalled)))
    True -> {
      use path <- result.try(
        firmware.image_path(image)
        |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
      )
      use img_bytes <- result.try(
        simplifile.read_bits(path)
        |> result.map_error(fn(_) {
          FirmwareError("Could not read firmware image at " <> path)
        }),
      )
      use parts <- result.try(
        firmware.slice_image(img_bytes, offset)
        |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
      )
      use #(board_table, table_meta) <- result.try(
        esp32.read_flash_bytes(
          port: device.port,
          address: firmware.partition_table_offset,
          size: firmware.partition_table_size,
          reset_after: False,
        )
        |> map_esp32_error,
      )
      use #(board_bootloader, _) <- result.try(
        esp32.read_flash_bytes(
          port: device.port,
          address: table_meta.bootloader_offset,
          size: firmware.bootloader_header_size,
          reset_after: True,
        )
        |> map_esp32_error,
      )
      use Nil <- result.try(
        firmware.check_update_layout(
          board_table,
          parts.table,
          esp32.byte_size(parts.app),
          esp32.byte_size(parts.lib),
        )
        |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
      )
      use bootloaders <- result.try(
        firmware.check_bootloader(board_bootloader, parts.bootloader)
        |> result.map_error(fn(e) { FirmwareError(firmware.error_message(e)) }),
      )
      use Nil <- result.try(confirm_update(device, image, chip, parts, bootloaders))
      io.println("Updating")
      use directory <- result.try(
        simplifile.create_directory_all("_build/atomvm_update")
        |> result.map_error(fn(_) {
          FirmwareError("Could not create _build/atomvm_update")
        })
        |> result.replace("_build/atomvm_update"),
      )
      let app_path = filepath.join(directory, parts.app_name)
      let lib_path = filepath.join(directory, parts.lib_name)
      use Nil <- result.try(write_bits(app_path, parts.app))
      use Nil <- result.try(write_bits(lib_path, parts.lib))
      use Nil <- result.try(
        esp32.write_flash_parts(
          port: device.port,
          baud:,
          parts: [
            #(parts.app_offset, app_path),
            #(parts.lib_offset, lib_path),
          ],
        )
        |> map_esp32_error,
      )
      io.println("")
      io.println(
        ansi.magenta(
          "Successfully updated AtomVM on "
          <> device.chip_family_name
          <> " - Port: "
          <> device.port
          <> " MAC: "
          <> device.mac_address,
        ),
      )
      io.println("")
      io.println(
        "The application in main.avm was kept; a new one can be flashed with:",
      )
      io.println("  gleam run -m orbital flash esp32")
      io.println("")
      Ok(Nil)
    }
  }
}

fn resolve_for_download(options: Options) -> Result(firmware.Image, Error) {
  case options.image, options.version {
    Some(image), None ->
      case firmware.classify_image_arg(image, option.is_some(options.repo)) {
        Ok(firmware.PathArg(path)) ->
          ensure(mode: "path", chip: "", version: "", name: "", path:, repo: options.repo)
        Ok(firmware.NameArg(parsed)) ->
          ensure(
            mode: "name",
            chip: "",
            version: "",
            name: parsed.name,
            path: "",
            repo: options.repo,
          )
        Error(error) -> Error(FirmwareError(firmware.error_message(error)))
      }
    None, version -> {
      use chip <- result.try(download_chip(options))
      ensure(
        mode: "release",
        chip:,
        version: option.unwrap(version, ""),
        name: "",
        path: "",
        repo: options.repo,
      )
    }
    Some(_), Some(_) ->
      Error(Validation("--image and --version cannot be used together"))
  }
}

fn resolve_for_device(
  options: Options,
  chip: String,
) -> Result(firmware.Image, Error) {
  case options.image, options.version {
    Some(image), None ->
      case firmware.classify_image_arg(image, option.is_some(options.repo)) {
        Ok(firmware.PathArg(path)) ->
          ensure(mode: "path", chip: "", version: "", name: "", path:, repo: options.repo)
        Ok(firmware.NameArg(parsed)) ->
          ensure(
            mode: "name",
            chip:,
            version: "",
            name: parsed.name,
            path: "",
            repo: options.repo,
          )
        Error(error) -> Error(FirmwareError(firmware.error_message(error)))
      }
    None, version -> {
      case version {
        None ->
          io.println(
            "\n💡 Installing AtomVM latest stable release.\n   Nightly builds and images with extra components are listed with:\n   gleam run -m orbital install --list-images\n",
          )
        Some(_) -> Nil
      }
      ensure(
        mode: "release",
        chip:,
        version: option.unwrap(version, ""),
        name: "",
        path: "",
        repo: options.repo,
      )
    }
    Some(_), Some(_) ->
      Error(Validation("--image and --version cannot be used together"))
  }
}

fn download_chip(options: Options) -> Result(String, Error) {
  case options.chip {
    Some(chip) -> Ok(chip)
    None ->
      case esp32.list_devices() {
        Ok([device]) -> Ok(firmware.chip_token(device.chip_family_name))
        Ok([]) ->
          Error(Validation(
            "Pass --chip when using --download-only without a board connected.",
          ))
        Ok(_) ->
          Error(Validation(
            "Several boards connected; pass --chip for --download-only.",
          ))
        Error(error) -> Error(map_esp32_error_value(error))
      }
  }
}

fn check_chip(
  image: firmware.Image,
  chip: String,
  device: esp32.Device,
) -> Result(Nil, Error) {
  case firmware.compatible(image, chip) {
    Some(False) ->
      Error(FirmwareError(
        "Image "
        <> option.unwrap(image.file, image.name)
        <> " is for "
        <> option.unwrap(firmware.image_chip(image), "unknown")
        <> ", not "
        <> device.chip_family_name,
      ))
    _ -> Ok(Nil)
  }
}

fn confirm_install(
  device: esp32.Device,
  image: firmware.Image,
  chip: String,
  offset: Int,
) -> Result(Nil, Error) {
  let lines = firmware.describe(image, offset)
  let assert [first, ..rest] = lines
  let warnings =
    firmware.warnings(image, chip)
    |> list.map(fn(w) { "Warning: " <> w })
  let prompt =
    string.join(
      [
        "",
        "Erase the flash of "
          <> device.chip_family_name
          <> " - Port: "
          <> device.port
          <> " MAC: "
          <> device.mac_address,
        "and install " <> first,
        ..list.append(rest, list.append(warnings, ["Continue? [N/y]: "])),
      ],
      with: "\n",
    )
  ask(prompt)
}

fn confirm_update(
  device: esp32.Device,
  image: firmware.Image,
  chip: String,
  parts: firmware.UpdateParts,
  bootloaders: firmware.BootloaderCheck,
) -> Result(Nil, Error) {
  let board_idf = case bootloaders {
    firmware.BootloaderOk(board_idf:, ..) -> board_idf
    firmware.BootloaderWarn(board_idf:, ..) -> board_idf
  }
  let warning = case bootloaders {
    firmware.BootloaderWarn(warning:, ..) -> [warning]
    _ -> []
  }
  let installed = case device.build_info {
    [version, ..] if device.atomvm_installed -> version
    _ -> "unknown"
  }
  let summary = [
    "  installed: "
      <> installed
      <> case board_idf {
      Some(idf) -> " (bootloader ESP-IDF " <> idf <> ")"
      None -> ""
    },
    "  image:     "
      <> image.name
      <> case image.stamp {
      Some(stamp) -> ", build " <> stamp
      None -> ""
    },
    "  writing:   "
      <> parts.app_name
      <> " @ "
      <> firmware.format_hex(parts.app_offset)
      <> ", "
      <> parts.lib_name
      <> " @ "
      <> firmware.format_hex(parts.lib_offset),
  ]
  let warnings =
    list.append(firmware.warnings(image, chip), warning)
    |> list.map(fn(w) { "Warning: " <> w })
  let prompt =
    string.join(
      [
        "",
        "Update AtomVM on "
          <> device.chip_family_name
          <> " - Port: "
          <> device.port
          <> " MAC: "
          <> device.mac_address,
        ..list.append(summary, list.append(warnings, ["Continue? [N/y]: "])),
      ],
      with: "\n",
    )
  ask(prompt)
}

fn ask(prompt: String) -> Result(Nil, Error) {
  case confirm_ffi(prompt) {
    True -> Ok(Nil)
    False -> {
      io.println("Cancelled.")
      Error(Cancelled)
    }
  }
}

fn ensure(
  mode mode: String,
  chip chip: String,
  version version: String,
  name name: String,
  path path: String,
  repo repo: Option(String),
) -> Result(firmware.Image, Error) {
  use raw <- result.try(
    ensure_ffi(mode, chip, version, name, path, option.unwrap(repo, ""))
    |> map_tool_error,
  )
  case json.parse(raw, image_decoder()) {
    Ok(image) -> Ok(image)
    Error(_) ->
      Error(FirmwareError("firmware helper returned invalid image JSON."))
  }
}

fn image_decoder() -> decode.Decoder(firmware.Image) {
  use name <- decode.field("name", decode.string)
  use file <- decode.optional_field("file", None, decode.optional(decode.string))
  use kind_s <- decode.optional_field("kind", "img", decode.string)
  use chip <- decode.optional_field("chip", None, decode.optional(decode.string))
  use base_chip <- decode.optional_field(
    "base_chip",
    None,
    decode.optional(decode.string),
  )
  use elixir <- decode.optional_field(
    "elixir",
    None,
    decode.optional(decode.bool),
  )
  use features <- decode.optional_field(
    "features",
    [],
    decode.list(decode.string),
  )
  use version <- decode.optional_field(
    "version",
    None,
    decode.optional(decode.string),
  )
  use channel_s <- decode.optional_field("channel", "local", decode.string)
  use stamp <- decode.optional_field("stamp", None, decode.optional(decode.string))
  use path <- decode.optional_field("path", None, decode.optional(decode.string))
  use img_path <- decode.optional_field(
    "img_path",
    None,
    decode.optional(decode.string),
  )
  use flash_offset <- decode.optional_field(
    "flash_offset",
    None,
    decode.optional(decode.int),
  )
  decode.success(firmware.Image(
    name:,
    file:,
    kind: case kind_s {
      "zip" -> firmware.Zip
      _ -> firmware.Img
    },
    chip:,
    base_chip:,
    elixir:,
    features:,
    version:,
    channel: channel_from_string(channel_s),
    stamp:,
    path:,
    img_path:,
    flash_offset:,
  ))
}

fn channel_from_string(value: String) -> firmware.Channel {
  case value {
    "stable" -> firmware.Stable
    "prerelease" -> firmware.Prerelease
    "nightly" -> firmware.Nightly
    "custom" -> firmware.Custom
    _ -> firmware.Local
  }
}

fn write_bits(path: String, data: BitArray) -> Result(Nil, Error) {
  simplifile.write_bits(to: path, bits: data)
  |> result.map_error(fn(_) { FirmwareError("Could not write " <> path) })
}

fn map_tool_error(result: Result(a, String)) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(reason) ->
      case string.contains(string.lowercase(reason), "cannot find") {
        True -> Error(ToolingMissing(reason))
        False -> Error(FirmwareError(reason))
      }
  }
}

fn map_esp32_error(result: Result(a, esp32.Error)) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(map_esp32_error_value(error))
  }
}

fn map_esp32_error_value(error: esp32.Error) -> Error {
  case error {
    esp32.ToolingMissing(reason:) -> ToolingMissing(reason)
    esp32.DeviceError(reason:) -> DeviceError(reason)
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    FirmwareError(reason) | DeviceError(reason) | ToolingMissing(reason) | Validation(
      reason,
    ) -> reason
    Cancelled -> ""
  }
}

@external(erlang, "orbital_ffi", "firmware_list_images")
fn list_images_ffi(
  chip: String,
  repo: String,
  connected_chips: String,
) -> Result(String, String)

@external(erlang, "orbital_ffi", "firmware_ensure")
fn ensure_ffi(
  mode: String,
  chip: String,
  version: String,
  name: String,
  path: String,
  repo: String,
) -> Result(String, String)

@external(erlang, "orbital_ffi", "confirm")
fn confirm_ffi(prompt: String) -> Bool
