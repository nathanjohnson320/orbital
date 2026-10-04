//// `orbital install` orchestration: resolve images, confirm, erase/flash,
//// and apply `--update` guardrails. Image listing/download is Gleam
//// (`firmware_fetch` + `gleam_httpc`); device I/O uses `orbital/internal/esp32`.

import filepath
import gleam/erlang/process
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import orbital/internal/esp32
import orbital/internal/firmware
import orbital/internal/firmware_fetch
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
  let #(filter, header) = list_filter(options.chip)
  use text <- result.try(
    firmware_fetch.list_images_text(options.repo, filter, header)
    |> map_firmware_error,
  )
  io.println(text)
  Ok(Nil)
}

fn list_filter(
  chip: Option(String),
) -> #(Option(List(String)), List(String)) {
  case chip {
    Some("all") -> #(None, [])
    Some(chip) -> #(Some([chip]), [])
    None ->
      case esp32.list_devices() {
        Ok([]) -> #(None, ["No ESP32 device found, listing every image."])
        Ok(devices) -> {
          let chips =
            devices
            |> list.map(fn(d) { firmware.chip_token(d.chip_family_name) })
            |> list.unique
          #(Some(chips), list.map(devices, connected_line))
        }
        Error(_) -> #(
          None,
          ["Could not probe ESP32 devices, listing every image."],
        )
      }
  }
}

fn connected_line(device: esp32.Device) -> String {
  let installed = case device.atomvm_installed, device.build_info {
    True, [version, ..] -> version
    True, [] -> "installed"
    False, _ -> "no AtomVM"
  }
  "Connected: "
  <> device.chip_family_name
  <> " on "
  <> device.port
  <> ", installed: "
  <> installed
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
    firmware.flash_offset_for(image, chip) |> map_firmware_error,
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
  use path <- result.try(firmware.image_path(image) |> map_firmware_error)
  use Nil <- result.try(confirm_install(device, image, chip, offset))
  io.println("Erasing and flashing")
  use Nil <- result.try(esp32.erase_flash(device.port) |> map_esp32_error)
  process.sleep(3000)
  use Nil <- result.try(
    esp32.write_flash_image(
      port: device.port,
      baud:,
      address: offset,
      file_path: path,
    )
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
      use parts <- result.try(
        firmware_fetch.update_parts(image, offset) |> map_firmware_error,
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
        |> map_firmware_error,
      )
      use bootloaders <- result.try(
        firmware.check_bootloader(board_bootloader, parts.bootloader)
        |> map_firmware_error,
      )
      use Nil <- result.try(confirm_update(
        device,
        image,
        chip,
        parts,
        bootloaders,
      ))
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
          Error(Validation(
            "--download-only needs a published image, " <> path <> " is a file",
          ))
        Ok(firmware.NameArg(parsed)) ->
          firmware_fetch.ensure_name(parsed.name, options.repo)
          |> map_firmware_error
        Error(error) -> Error(FirmwareError(firmware.error_message(error)))
      }
    None, version -> {
      use chip <- result.try(download_chip(options))
      firmware_fetch.ensure_release(chip, version, options.repo)
      |> map_firmware_error
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
          firmware_fetch.ensure_path(path) |> map_firmware_error
        Ok(firmware.NameArg(parsed)) ->
          firmware_fetch.ensure_name(parsed.name, options.repo)
          |> map_firmware_error
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
      firmware_fetch.ensure_release(chip, version, options.repo)
      |> map_firmware_error
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

fn write_bits(path: String, data: BitArray) -> Result(Nil, Error) {
  simplifile.write_bits(to: path, bits: data)
  |> result.map_error(fn(_) { FirmwareError("Could not write " <> path) })
}

fn map_firmware_error(result: Result(a, firmware.Error)) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(error) -> Error(FirmwareError(firmware.error_message(error)))
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
    FirmwareError(reason)
    | DeviceError(reason)
    | ToolingMissing(reason)
    | Validation(reason) -> reason
    Cancelled -> ""
  }
}

@external(erlang, "orbital_ffi", "confirm")
fn confirm_ffi(prompt: String) -> Bool
