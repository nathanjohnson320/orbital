//// `orbital install pico` orchestration: resolve UF2 images, confirm, and
//// flash AtomVM onto a Pico / Pico 2 with picotool (mount-copy fallback).

import gleam/io
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import gleam_community/ansi
import orbital/internal/pico
import orbital/internal/pico_firmware

pub type Options {
  Options(
    board: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    download_only: Bool,
    list_images: Bool,
    pico_path: Option(String),
    pico_reset: Option(String),
    picotool: Option(String),
  )
}

pub type Error {
  Firmware(pico_firmware.Error)
  Device(pico.Error)
  Cancelled
  Validation(String)
}

pub fn run(options: Options) -> Result(Nil, Error) {
  case options.list_images {
    True -> list_images(options)
    False ->
      case options.download_only {
        True -> download_only(options)
        False -> do_install(options)
      }
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    Firmware(reason) -> pico_firmware.error_message(reason)
    Device(reason) -> pico.error_message(reason)
    Cancelled -> ""
    Validation(message) -> message
  }
}

fn list_images(options: Options) -> Result(Nil, Error) {
  use filter <- result.try(case options.board {
    None -> Ok(None)
    Some(board) ->
      pico_firmware.parse_board(board)
      |> result.map(Some)
      |> result.map_error(Firmware)
  })
  use text <- result.try(
    pico_firmware.list_images_text(options.repo, filter)
    |> result.map_error(Firmware),
  )
  io.println(text)
  Ok(Nil)
}

fn download_only(options: Options) -> Result(Nil, Error) {
  use image <- result.try(resolve(options))
  let path = unwrap(image.path, image.file)
  io.println("")
  io.println(
    path
    <> " is ready. Install it with:\n  gleam run -m orbital install pico --image "
    <> path,
  )
  Ok(Nil)
}

fn do_install(options: Options) -> Result(Nil, Error) {
  use image <- result.try(resolve(options))
  use path <- result.try(case image.path {
    Some(path) -> Ok(path)
    None ->
      Error(Firmware(pico_firmware.FileError("Image has no path on disk.")))
  })
  use Nil <- result.try(confirm(image))
  use Nil <- result.try(
    pico.install_firmware_uf2(
      uf2_path: path,
      options: pico.FlashOptions(
        pico_path: options.pico_path,
        pico_reset: options.pico_reset,
        picotool: options.picotool,
      ),
      volume: pico_firmware.default_volume_name(image.board),
    )
    |> result.map_error(Device),
  )
  io.println("")
  io.println(ansi.magenta(
    "Successfully installed AtomVM on "
    <> pico_firmware.board_label(image.board),
  ))
  io.println("")
  io.println("Your project can now be flashed with:")
  io.println("  gleam run -m orbital flash pico")
  io.println("")
  Ok(Nil)
}

fn resolve(options: Options) -> Result(pico_firmware.Image, Error) {
  use board <- result.try(case options.board {
    None -> Ok(None)
    Some(board) ->
      pico_firmware.parse_board(board)
      |> result.map(Some)
      |> result.map_error(Firmware)
  })
  pico_firmware.resolve_image(
    board:,
    image: options.image,
    version: options.version,
    repo: options.repo,
  )
  |> result.map_error(Firmware)
}

fn confirm(image: pico_firmware.Image) -> Result(Nil, Error) {
  let path = unwrap(image.path, image.file)
  let combined = case image.combined {
    True -> "combined UF2 (VM + atomvmlib)"
    False -> "AtomVM UF2"
  }
  io.println("")
  io.println("About to install:")
  io.println("  board:    " <> pico_firmware.board_label(image.board))
  io.println("  image:    " <> image.file <> " (" <> combined <> ")")
  io.println("  version:  " <> image.version)
  io.println("  path:     " <> path)
  io.println("")
  io.println(
    "A brand-new Pico may still need one BOOTSEL press if picotool cannot "
    <> "force-reset it yet.",
  )
  io.println("")
  case
    confirm_prompt(
      "Install AtomVM on " <> pico_firmware.board_label(image.board) <> "?",
    )
  {
    True -> Ok(Nil)
    False -> Error(Cancelled)
  }
}

@external(erlang, "orbital_ffi", "confirm")
fn confirm_prompt(message: String) -> Bool
