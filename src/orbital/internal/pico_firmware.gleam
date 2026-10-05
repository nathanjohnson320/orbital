//// Pico / RP2 firmware image discovery and download for `install pico`.
////
//// Understands AtomVM release UF2 names (`AtomVM-pico_w-combined-…uf2`) and
//// caches them under `firmware_images/`, parallel to the ESP32 install path.

import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import simplifile

const atomvm_releases = "https://api.github.com/repos/atomvm/AtomVM/releases"

const cache_dir_name = "firmware_images"

const page_size = 15

const user_agent = "orbital-firmware/1.0 (+https://github.com/nathanjohnson320/orbital)"

pub type Board {
  Pico
  PicoW
  Pico2
  Pico2W
}

pub type Image {
  Image(
    name: String,
    file: String,
    board: Board,
    combined: Bool,
    version: String,
    tag: String,
    url: Option(String),
    path: Option(String),
    size: Option(Int),
    sha256_url: Option(String),
    prerelease: Bool,
  )
}

pub type Error {
  UnknownBoard(String)
  BoardRequired
  NoImageForBoard(board: String, tag: String)
  UnknownImage(String)
  ReleaseNotFound(String)
  Network(String)
  FileError(String)
  Sha256Mismatch(file: String)
}

pub fn parse_board(value: String) -> Result(Board, Error) {
  case string.lowercase(string.trim(value)) {
    "pico" -> Ok(Pico)
    "pico_w" | "picow" -> Ok(PicoW)
    "pico2" -> Ok(Pico2)
    "pico2_w" | "pico2w" -> Ok(Pico2W)
    other -> Error(UnknownBoard(other))
  }
}

pub fn board_token(board: Board) -> String {
  case board {
    Pico -> "pico"
    PicoW -> "pico_w"
    Pico2 -> "pico2"
    Pico2W -> "pico2_w"
  }
}

pub fn board_label(board: Board) -> String {
  case board {
    Pico -> "Raspberry Pi Pico"
    PicoW -> "Raspberry Pi Pico W"
    Pico2 -> "Raspberry Pi Pico 2"
    Pico2W -> "Raspberry Pi Pico 2 W"
  }
}

/// Default UF2 volume name for a board family.
pub fn default_volume_name(board: Board) -> String {
  case board {
    Pico | PicoW -> "RPI-RP2"
    Pico2 | Pico2W -> "RP2350"
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    UnknownBoard(value) ->
      "Unknown Pico board '"
      <> value
      <> "'. Use pico, pico_w, pico2, or pico2_w."
    BoardRequired ->
      "Pass --board pico|pico_w|pico2|pico2_w (or --image / --list-images)."
    NoImageForBoard(board:, tag:) ->
      "No AtomVM UF2 for board '" <> board <> "' in release " <> tag <> "."
    UnknownImage(name) -> "Unknown Pico firmware image '" <> name <> "'."
    ReleaseNotFound(tag) -> "AtomVM release '" <> tag <> "' was not found."
    Network(reason) -> reason
    FileError(reason) -> reason
    Sha256Mismatch(file:) -> "SHA256 mismatch for downloaded file " <> file
  }
}

/// List installable Pico UF2s from AtomVM (+ optional custom repo) and cache.
pub fn list_images_text(
  repo: Option(String),
  board_filter: Option(Board),
) -> Result(String, Error) {
  use images <- result.try(list_remote_images(repo))
  let images = case board_filter {
    None -> images
    Some(board) -> list.filter(images, fn(i) { i.board == board })
  }
  let cached = list_cached_images()
  let remote_block = render_image_lines(images)
  let local_block = case cached {
    [] -> ""
    _ ->
      "\nCached locally:\n"
      <> string.join(
        list.map(cached, fn(i) {
          "  "
          <> i.file
          <> case i.path {
            Some(path) -> "  (" <> path <> ")"
            None -> ""
          }
        }),
        with: "\n",
      )
  }
  Ok(
    "AtomVM Pico / Pico 2 UF2 images:\n"
    <> remote_block
    <> local_block
    <> "\n\nInstall with:\n  gleam run -m orbital install pico --board pico_w\n",
  )
}

/// Resolve an image for install/download: local path, published name, or board+version.
pub fn resolve_image(
  board board: Option(Board),
  image image: Option(String),
  version version: Option(String),
  repo repo: Option(String),
) -> Result(Image, Error) {
  case image {
    Some(path_or_name) ->
      case simplifile.is_file(path_or_name) {
        Ok(True) -> local_uf2(path_or_name, board)
        _ -> ensure_named(path_or_name, repo)
      }
    None ->
      case board {
        None -> Error(BoardRequired)
        Some(board) -> ensure_board_release(board, version, repo)
      }
  }
}

pub fn ensure_board_release(
  board: Board,
  version: Option(String),
  repo: Option(String),
) -> Result(Image, Error) {
  case version {
    Some(_) -> {
      use release <- result.try(fetch_release(repo, version))
      let images = release_images(release)
      use selected <- result.try(select_board_image(
        images,
        board,
        release.tag_name,
      ))
      ensure_cached(selected)
    }
    None -> {
      case fetch_release(repo, None) {
        Ok(release) ->
          case
            select_board_image(release_images(release), board, release.tag_name)
          {
            Ok(selected) -> ensure_cached(selected)
            Error(_) -> ensure_board_from_listing(board, repo)
          }
        Error(_) -> ensure_board_from_listing(board, repo)
      }
    }
  }
}

fn ensure_board_from_listing(
  board: Board,
  repo: Option(String),
) -> Result(Image, Error) {
  use images <- result.try(list_remote_images(repo))
  let for_board = list.filter(images, fn(i) { i.board == board })
  case list.find(for_board, fn(i) { i.combined }), for_board {
    Ok(image), _ -> ensure_cached(image)
    Error(Nil), [image, ..] -> ensure_cached(image)
    Error(Nil), [] ->
      Error(NoImageForBoard(board: board_token(board), tag: "recent releases"))
  }
}

fn ensure_named(name: String, repo: Option(String)) -> Result(Image, Error) {
  let wanted = string.lowercase(stem_name(name))
  case find_cached_by_name(wanted) {
    Some(image) -> Ok(image)
    None -> {
      use images <- result.try(list_remote_images(repo))
      case list.find(images, fn(i) { string.lowercase(i.name) == wanted }) {
        Ok(image) -> ensure_cached(image)
        Error(Nil) ->
          case
            list.find(images, fn(i) {
              string.lowercase(i.file) == string.lowercase(name)
            })
          {
            Ok(image) -> ensure_cached(image)
            Error(Nil) -> Error(UnknownImage(name))
          }
      }
    }
  }
}

fn local_uf2(path: String, board: Option(Board)) -> Result(Image, Error) {
  let file = filepath.base_name(path)
  case parse_uf2_name(file) {
    Ok(#(board_parsed, combined, version)) ->
      Ok(Image(
        name: stem_name(file),
        file:,
        board: board_parsed,
        combined:,
        version:,
        tag: version,
        url: None,
        path: Some(path),
        size: file_size(path),
        sha256_url: None,
        prerelease: string.contains(version, "-"),
      ))
    Error(_) ->
      case board {
        Some(board) ->
          Ok(Image(
            name: stem_name(file),
            file:,
            board:,
            combined: string.contains(string.lowercase(file), "combined"),
            version: "local",
            tag: "local",
            url: None,
            path: Some(path),
            size: file_size(path),
            sha256_url: None,
            prerelease: False,
          ))
        None ->
          Error(FileError(
            "Could not infer Pico board from '"
            <> file
            <> "'. Pass --board pico|pico_w|pico2|pico2_w.",
          ))
      }
  }
}

/// Prefer a combined UF2 for the board; fall back to the plain AtomVM UF2.
pub fn select_board_image(
  images: List(Image),
  board: Board,
  tag: String,
) -> Result(Image, Error) {
  let for_board = list.filter(images, fn(i) { i.board == board })
  case list.find(for_board, fn(i) { i.combined }) {
    Ok(image) -> Ok(image)
    Error(Nil) ->
      case for_board {
        [image, ..] -> Ok(image)
        [] -> Error(NoImageForBoard(board: board_token(board), tag:))
      }
  }
}

/// Parse `AtomVM-<board>[-combined]-<version>.uf2` and
/// `AtomVM-combined-<board>-<version>.uf2`.
pub fn parse_uf2_name(file: String) -> Result(#(Board, Bool, String), Error) {
  let lower = string.lowercase(file)
  case string.ends_with(lower, ".uf2") {
    False -> Error(UnknownImage(file))
    True -> {
      let stem = string.drop_end(file, 4)
      let parts = string.split(stem, on: "-")
      case parts {
        ["AtomVM", "combined", board_token, ..version_parts]
        | ["atomvm", "combined", board_token, ..version_parts] ->
          parse_board_version(board_token, version_parts, True, file)
        ["AtomVM", board_token, "combined", ..version_parts]
        | ["atomvm", board_token, "combined", ..version_parts] ->
          parse_board_version(board_token, version_parts, True, file)
        ["AtomVM", board_token, ..version_parts]
        | ["atomvm", board_token, ..version_parts] ->
          parse_board_version(board_token, version_parts, False, file)
        _ -> Error(UnknownImage(file))
      }
    }
  }
}

fn parse_board_version(
  board_token: String,
  version_parts: List(String),
  combined: Bool,
  file: String,
) -> Result(#(Board, Bool, String), Error) {
  use board <- result.try(parse_board(board_token))
  case version_parts {
    [] -> Error(UnknownImage(file))
    parts -> {
      let version = string.join(parts, with: "-")
      case string.starts_with(version, "v") {
        True -> Ok(#(board, combined, version))
        False -> Error(UnknownImage(file))
      }
    }
  }
}

// --- Listing / download ------------------------------------------------------

type Release {
  Release(tag_name: String, draft: Bool, prerelease: Bool, assets: List(Asset))
}

type Asset {
  Asset(name: String, url: String, size: Option(Int))
}

fn list_remote_images(repo: Option(String)) -> Result(List(Image), Error) {
  let url = case repo {
    Some(repo) ->
      "https://api.github.com/repos/"
      <> repo
      <> "/releases?per_page="
      <> int.to_string(page_size)
    None -> atomvm_releases <> "?per_page=" <> int.to_string(page_size)
  }
  use releases <- result.try(fetch_json_list(url))
  Ok(
    releases
    |> list.filter(fn(r) { !r.draft })
    |> list.flat_map(release_images),
  )
}

fn release_images(release: Release) -> List(Image) {
  let sidecars =
    list.filter_map(release.assets, fn(asset) {
      case string.ends_with(asset.name, ".sha256") {
        True -> Ok(#(string.drop_end(asset.name, 7), asset.url))
        False -> Error(Nil)
      }
    })
  list.filter_map(release.assets, fn(asset) {
    case parse_uf2_name(asset.name) {
      Error(_) -> Error(Nil)
      Ok(#(board, combined, version)) ->
        Ok(Image(
          name: stem_name(asset.name),
          file: asset.name,
          board:,
          combined:,
          version:,
          tag: release.tag_name,
          url: Some(asset.url),
          path: None,
          size: asset.size,
          sha256_url: sidecar_url(sidecars, asset.name),
          prerelease: release.prerelease,
        ))
    }
  })
}

fn fetch_release(
  repo: Option(String),
  version: Option(String),
) -> Result(Release, Error) {
  let base = case repo {
    Some(repo) -> "https://api.github.com/repos/" <> repo <> "/releases"
    None -> atomvm_releases
  }
  case version {
    None -> fetch_json_release(base <> "/latest")
    Some(tag) ->
      case fetch_json_release(base <> "/tags/" <> uri.percent_encode(tag)) {
        Ok(release) -> Ok(release)
        Error(Network(reason)) ->
          case string.contains(reason, "404") {
            True -> Error(ReleaseNotFound(tag))
            False -> Error(Network(reason))
          }
        Error(other) -> Error(other)
      }
  }
}

fn ensure_cached(image: Image) -> Result(Image, Error) {
  use Nil <- result.try(
    simplifile.create_directory_all(cache_dir_name)
    |> result.map_error(fn(_) {
      FileError("Could not create " <> cache_dir_name)
    }),
  )
  let path = filepath.join(cache_dir_name, image.file)
  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println("Using cached " <> path)
      Ok(Image(..image, path: Some(path)))
    }
    _ -> {
      io.println("Downloading " <> image.file <> "…")
      use data <- result.try(download_verified(image))
      use Nil <- result.try(write_atomically(path, data))
      print_gitignore_hint()
      Ok(
        Image(..image, path: Some(path), size: Some(bit_array.byte_size(data))),
      )
    }
  }
}

fn download_verified(image: Image) -> Result(BitArray, Error) {
  use url <- result.try(case image.url {
    Some(url) -> Ok(url)
    None -> Error(FileError("Image has no download URL: " <> image.file))
  })
  use data <- result.try(fetch_binary(url))
  case image.sha256_url {
    None -> Ok(data)
    Some(sha_url) -> {
      use expected <- result.try(fetch_text(sha_url))
      let expected = string.lowercase(string.trim(first_token(expected)))
      let actual =
        crypto.hash(crypto.Sha256, data)
        |> bit_array.base16_encode
        |> string.lowercase
      case expected == actual {
        True -> Ok(data)
        False -> Error(Sha256Mismatch(image.file))
      }
    }
  }
}

fn list_cached_images() -> List(Image) {
  case simplifile.read_directory(cache_dir_name) {
    Ok(files) ->
      list.filter_map(files, fn(file) {
        case string.ends_with(file, ".uf2") {
          False -> Error(Nil)
          True -> {
            let path = filepath.join(cache_dir_name, file)
            case local_uf2(path, None) {
              Ok(image) -> Ok(image)
              Error(_) -> Error(Nil)
            }
          }
        }
      })
    Error(_) -> []
  }
}

fn find_cached_by_name(wanted: String) -> Option(Image) {
  list.find(list_cached_images(), fn(i) {
    string.lowercase(i.name) == wanted
    || string.lowercase(i.file) == wanted
    || string.lowercase(i.file) == wanted <> ".uf2"
  })
  |> option.from_result
}

fn render_image_lines(images: List(Image)) -> String {
  case images {
    [] -> "  (none found)"
    _ ->
      images
      |> list.map(fn(i) {
        let combined = case i.combined {
          True -> " combined"
          False -> ""
        }
        let channel = case i.prerelease {
          True -> " (prerelease)"
          False -> ""
        }
        "  "
        <> board_token(i.board)
        <> combined
        <> "  "
        <> i.file
        <> channel
        <> case i.size {
          Some(size) -> "  " <> format_kb(size)
          None -> ""
        }
      })
      |> string.join(with: "\n")
  }
}

fn format_kb(bytes: Int) -> String {
  let kb = { bytes + 1023 } / 1024
  int.to_string(kb) <> " KB"
}

fn print_gitignore_hint() -> Nil {
  case simplifile.read(".gitignore") {
    Ok(text) ->
      case string.contains(text, "firmware_images") {
        True -> Nil
        False -> {
          io.println("")
          io.println(
            "Tip: add /firmware_images/ to .gitignore so downloaded UF2s stay local.",
          )
        }
      }
    Error(_) -> {
      io.println("")
      io.println(
        "Tip: add /firmware_images/ to .gitignore so downloaded UF2s stay local.",
      )
    }
  }
}

fn write_atomically(path: String, data: BitArray) -> Result(Nil, Error) {
  let part = path <> ".part"
  use Nil <- result.try(
    simplifile.write_bits(to: part, bits: data)
    |> result.map_error(fn(_) { FileError("Could not write " <> part) }),
  )
  simplifile.rename(at: part, to: path)
  |> result.map_error(fn(_) { FileError("Could not finalize " <> path) })
}

fn sidecar_url(
  sidecars: List(#(String, String)),
  name: String,
) -> Option(String) {
  list.key_find(sidecars, name) |> option.from_result
}

fn stem_name(file: String) -> String {
  case string.ends_with(string.lowercase(file), ".uf2") {
    True -> string.drop_end(file, 4)
    False -> file
  }
}

fn first_token(text: String) -> String {
  case string.split(string.trim(text), on: " ") {
    [first, ..] -> first
    [] -> text
  }
}

fn file_size(path: String) -> Option(Int) {
  case simplifile.file_info(path) {
    Ok(info) -> Some(info.size)
    Error(_) -> None
  }
}

// --- HTTP / JSON -------------------------------------------------------------

fn fetch_json_release(url: String) -> Result(Release, Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, release_decoder()) {
    Ok(release) -> Ok(release)
    Error(_) -> Error(Network("Invalid GitHub release JSON from " <> url))
  }
}

fn fetch_json_list(url: String) -> Result(List(Release), Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, decode.list(release_decoder())) {
    Ok(releases) -> Ok(releases)
    Error(_) -> Error(Network("Invalid GitHub releases JSON from " <> url))
  }
}

fn fetch_text(url: String) -> Result(String, Error) {
  use bytes <- result.try(fetch_binary(url))
  bit_array.to_string(bytes)
  |> result.map_error(fn(_) { Network("Non-UTF8 response from " <> url) })
}

fn fetch_binary(url: String) -> Result(BitArray, Error) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Network("Invalid URL: " <> url) }),
  )
  let req =
    req
    |> request.set_header("user-agent", user_agent)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_body(<<>>)
  let config =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.timeout(120_000)
  case httpc.dispatch_bits(config, req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    Ok(response) ->
      Error(Network("HTTP " <> int.to_string(response.status) <> " for " <> url))
    Error(httpc.FailedToConnect(..)) ->
      Error(Network("Network error for " <> url))
    Error(httpc.ResponseTimeout) -> Error(Network("Timed out fetching " <> url))
    Error(httpc.InvalidUtf8Response) ->
      Error(Network("Invalid response from " <> url))
  }
}

fn release_decoder() -> decode.Decoder(Release) {
  use tag_name <- decode.field("tag_name", decode.string)
  use draft <- decode.field("draft", decode.bool)
  use prerelease <- decode.field("prerelease", decode.bool)
  use assets <- decode.field("assets", decode.list(asset_decoder()))
  decode.success(Release(tag_name:, draft:, prerelease:, assets:))
}

fn asset_decoder() -> decode.Decoder(Asset) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("browser_download_url", decode.string)
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  decode.success(Asset(name:, url:, size:))
}
