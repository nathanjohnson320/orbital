//// PlayStation Portable helpers for Orbital's `install psp` / `flash psp`
//// commands. AtomVM runs as an EBOOT under CFW/PPSSPP; the app lives as
//// `app.avm` beside `EBOOT.PBP` under `PSP/GAME/ATOMVM/` (ms0 load).

import envoy
import filepath
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub const default_game_dir = "ATOMVM"

pub const default_app_avm = "app.avm"

pub const default_eboot = "EBOOT.PBP"

pub type FlashOptions {
  FlashOptions(psp_path: Option(String), game_dir: Option(String))
}

pub type InstallOptions {
  InstallOptions(psp_path: Option(String), game_dir: Option(String))
}

pub type Error {
  PspPathRequired
  GameDirMissing(path: String)
  GameDirNotDirectory(path: String)
  EbootMissing(path: String)
  CannotCreateGameDir(path: String, reason: simplifile.FileError)
  CannotCopyEboot(reason: simplifile.FileError)
  CannotCopyAvm(reason: simplifile.FileError)
  CannotWriteAvm(path: String, reason: simplifile.FileError)
}

pub fn error_message(error: Error) -> String {
  case error {
    PspPathRequired ->
      "Pass --psp-path to the ATOMVM game folder (or the Memory Stick / PPSSPP "
      <> "memstick root), or set ATOMVM_PSP_PATH.\n"
      <> "Example: ~/.config/ppsspp/PSP/GAME/ATOMVM"
    GameDirMissing(path:) ->
      "PSP game folder not found at '"
      <> path
      <> "'.\nInstall AtomVM first with:\n"
      <> "  gleam run -m orbital install psp --image /path/to/EBOOT.PBP"
    GameDirNotDirectory(path:) ->
      "Object found at PSP path '" <> path <> "' is not a directory."
    EbootMissing(path:) ->
      "No EBOOT.PBP in '"
      <> path
      <> "'.\nInstall AtomVM first with:\n"
      <> "  gleam run -m orbital install psp --image /path/to/EBOOT.PBP"
    CannotCreateGameDir(path:, ..) ->
      "I couldn't create the PSP game folder at '" <> path <> "'."
    CannotCopyEboot(_) -> "I couldn't copy EBOOT.PBP into the PSP game folder."
    CannotCopyAvm(_) -> "I couldn't copy app.avm into the PSP game folder."
    CannotWriteAvm(path:, ..) -> "I couldn't write '" <> path <> "'."
  }
}

/// Resolve the ATOMVM game directory from flag / env / OS defaults.
pub fn resolve_game_path(
  psp_path: Option(String),
  game_dir: Option(String),
) -> Result(String, Error) {
  let title = option.unwrap(game_dir, default_game_dir)
  case psp_path {
    Some(path) -> Ok(normalize_game_path(path, title))
    None ->
      case envoy.get("ATOMVM_PSP_PATH") {
        Ok(path) -> Ok(normalize_game_path(path, title))
        Error(_) ->
          case default_ppsspp_game_path(title) {
            Some(path) -> Ok(path)
            None -> Error(PspPathRequired)
          }
      }
  }
}

/// If `path` already looks like the game folder, use it; otherwise append
/// `PSP/GAME/<title>` under a memstick / PPSSPP root.
pub fn normalize_game_path(path: String, game_dir: String) -> String {
  let trimmed = strip_trailing_slashes(path)
  let base = filepath.base_name(trimmed)
  case string.uppercase(base) == string.uppercase(game_dir) {
    True -> trimmed
    False ->
      case string.ends_with(string.uppercase(trimmed), "/PSP/GAME") {
        True -> filepath.join(trimmed, game_dir)
        False ->
          trimmed
          |> filepath.join("PSP")
          |> filepath.join("GAME")
          |> filepath.join(game_dir)
      }
  }
}

pub fn default_ppsspp_game_path(game_dir: String) -> Option(String) {
  case os_family() {
    "linux" ->
      case envoy.get("HOME") {
        Ok(home) ->
          Some(
            home
            |> filepath.join(".config")
            |> filepath.join("ppsspp")
            |> filepath.join("PSP")
            |> filepath.join("GAME")
            |> filepath.join(game_dir),
          )
        Error(_) -> None
      }
    "darwin" ->
      case envoy.get("HOME") {
        Ok(home) ->
          Some(
            home
            |> filepath.join("Library")
            |> filepath.join("Application Support")
            |> filepath.join("ppsspp")
            |> filepath.join("PSP")
            |> filepath.join("GAME")
            |> filepath.join(game_dir),
          )
        Error(_) -> None
      }
    _ -> None
  }
}

/// Ensure the game directory exists (creating parents as needed).
///
/// Note: simplifile's `is_directory` returns `Ok(False)` for missing paths
/// (enoent), not `Error`, so we must attempt create when False.
pub fn ensure_game_dir(game_path: String) -> Result(Nil, Error) {
  case simplifile.is_directory(game_path) {
    Ok(True) -> Ok(Nil)
    Ok(False) | Error(_) ->
      case simplifile.is_file(game_path) {
        Ok(True) -> Error(GameDirNotDirectory(game_path))
        _ ->
          simplifile.create_directory_all(game_path)
          |> result.map_error(fn(reason) {
            CannotCreateGameDir(path: game_path, reason:)
          })
      }
  }
}

/// Require an existing game dir that already has EBOOT.PBP (for flash).
pub fn require_installed_game_dir(game_path: String) -> Result(Nil, Error) {
  case simplifile.is_directory(game_path) {
    Ok(True) -> {
      let eboot = filepath.join(game_path, default_eboot)
      case simplifile.is_file(eboot) {
        Ok(True) -> Ok(Nil)
        _ -> Error(EbootMissing(game_path))
      }
    }
    // simplifile returns Ok(False) for both missing paths and non-directories.
    Ok(False) ->
      case simplifile.is_file(game_path) {
        Ok(True) -> Error(GameDirNotDirectory(game_path))
        _ -> Error(GameDirMissing(game_path))
      }
    Error(_) -> Error(GameDirMissing(game_path))
  }
}

/// Copy a host EBOOT.PBP into the game folder.
pub fn install_eboot(
  eboot_src: String,
  options: InstallOptions,
) -> Result(String, Error) {
  use game_path <- result.try(resolve_game_path(
    options.psp_path,
    options.game_dir,
  ))
  use Nil <- result.try(ensure_game_dir(game_path))
  let dest = filepath.join(game_path, default_eboot)
  use Nil <- result.try(
    simplifile.copy(src: eboot_src, dest:)
    |> result.map_error(CannotCopyEboot),
  )
  io.println("Installed " <> default_eboot <> " → " <> dest)
  Ok(game_path)
}

/// Copy a project AVM to `app.avm` beside the installed EBOOT.
pub fn flash_avm(
  avm_path: String,
  options: FlashOptions,
) -> Result(String, Error) {
  use game_path <- result.try(resolve_game_path(
    options.psp_path,
    options.game_dir,
  ))
  use Nil <- result.try(require_installed_game_dir(game_path))
  let dest = filepath.join(game_path, default_app_avm)
  use Nil <- result.try(
    simplifile.copy(src: avm_path, dest:)
    |> result.map_error(CannotCopyAvm),
  )
  io.println("Flashed " <> default_app_avm <> " → " <> dest)
  Ok(dest)
}

fn strip_trailing_slashes(path: String) -> String {
  case string.ends_with(path, "/") {
    True -> strip_trailing_slashes(string.drop_end(path, 1))
    False -> path
  }
}

@external(erlang, "orbital_ffi", "os_family")
fn os_family() -> String
