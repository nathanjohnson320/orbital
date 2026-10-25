//// `orbital install psp` orchestration: resolve an EBOOT image, confirm, and
//// copy it into `PSP/GAME/ATOMVM/` on a PPSSPP memstick or USB Memory Stick.

import gleam/io
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import gleam_community/ansi
import orbital/internal/psp
import orbital/internal/psp_firmware
import simplifile

pub type Options {
  Options(
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    download_only: Bool,
    list_images: Bool,
    psp_path: Option(String),
    game_dir: Option(String),
  )
}

pub type Error {
  Firmware(psp_firmware.Error)
  Device(psp.Error)
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
    Firmware(reason) -> psp_firmware.error_message(reason)
    Device(reason) -> psp.error_message(reason)
    Cancelled -> ""
    Validation(message) -> message
  }
}

fn list_images(options: Options) -> Result(Nil, Error) {
  use text <- result.try(
    psp_firmware.list_images_text(options.repo)
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
    <> " is ready. Install it with:\n  gleam run -m orbital install psp --image "
    <> path,
  )
  Ok(Nil)
}

fn do_install(options: Options) -> Result(Nil, Error) {
  use image <- result.try(resolve(options))
  use path <- result.try(case image.path {
    Some(path) -> Ok(path)
    None ->
      Error(Firmware(psp_firmware.FileError("Image has no path on disk.")))
  })
  use Nil <- result.try(case simplifile.is_file(path) {
    Ok(True) -> Ok(Nil)
    _ ->
      Error(
        Firmware(psp_firmware.FileError(
          "EBOOT image not found at '" <> path <> "'.",
        )),
      )
  })
  use Nil <- result.try(confirm(image, options))
  use game_path <- result.try(
    psp.install_eboot(
      path,
      psp.InstallOptions(psp_path: options.psp_path, game_dir: options.game_dir),
    )
    |> result.map_error(Device),
  )
  io.println("")
  io.println(ansi.magenta(
    "Successfully installed AtomVM on the PSP game folder",
  ))
  io.println("  " <> game_path)
  io.println("")
  io.println("Your project can now be flashed with:")
  io.println("  gleam run -m orbital flash psp")
  io.println("")
  Ok(Nil)
}

fn resolve(options: Options) -> Result(psp_firmware.Image, Error) {
  psp_firmware.resolve_image(
    image: options.image,
    version: options.version,
    repo: options.repo,
  )
  |> result.map_error(Firmware)
}

fn confirm(image: psp_firmware.Image, options: Options) -> Result(Nil, Error) {
  let path = unwrap(image.path, image.file)
  use game_path <- result.try(
    psp.resolve_game_path(options.psp_path, options.game_dir)
    |> result.map_error(Device),
  )
  io.println("")
  io.println("About to install:")
  io.println("  image:     " <> image.file)
  io.println("  version:   " <> image.version)
  io.println("  source:    " <> path)
  io.println("  game dir:  " <> game_path)
  io.println("")
  io.println(
    "This copies EBOOT.PBP into the PPSSPP memstick / Memory Stick GAME folder.",
  )
  io.println("")
  case confirm_prompt("Install AtomVM PSP EBOOT?") {
    True -> Ok(Nil)
    False -> Error(Cancelled)
  }
}

@external(erlang, "orbital_ffi", "confirm")
fn confirm_prompt(message: String) -> Bool
