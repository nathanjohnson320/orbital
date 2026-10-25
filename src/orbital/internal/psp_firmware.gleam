//// PSP AtomVM firmware discovery for `install psp`.
////
//// Resolves a local `--image` (`EBOOT.PBP` or zip) or downloads a release
//// asset from `nathanjohnson320/atomvm-psp` (override with `--repo`).

import filepath
import gleam/bit_array
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

const default_repo = "nathanjohnson320/atomvm-psp"

const cache_dir_name = "firmware_images"

const page_size = 15

const user_agent =
  "orbital-firmware/1.0 (+https://github.com/nathanjohnson320/orbital)"

pub type Image {
  Image(
    name: String,
    file: String,
    version: String,
    tag: String,
    url: Option(String),
    /// Absolute path to a host `EBOOT.PBP` ready to copy.
    path: Option(String),
    size: Option(Int),
    prerelease: Bool,
  )
}

pub type Error {
  UnknownImage(String)
  ReleaseNotFound(String)
  NoReleaseAssets
  Network(String)
  FileError(String)
  EbootNotInZip(String)
}

pub fn error_message(error: Error) -> String {
  case error {
    UnknownImage(name) -> "Unknown PSP firmware image '" <> name <> "'."
    ReleaseNotFound(tag) -> "atomvm-psp release '" <> tag <> "' was not found."
    NoReleaseAssets ->
      "No AtomVM PSP EBOOT assets found in that release of "
      <> default_repo
      <> "."
    Network(reason) -> reason
    FileError(reason) -> reason
    EbootNotInZip(path) ->
      "No EBOOT.PBP found inside zip '"
      <> path
      <> "'. Expected EBOOT.PBP at the root or under PSP/GAME/ATOMVM/."
  }
}

pub fn default_firmware_repo() -> String {
  default_repo
}

/// Human-readable listing of remote + cached PSP EBOOT images.
pub fn list_images_text(repo: Option(String)) -> Result(String, Error) {
  use images <- result.try(list_remote_images(repo))
  let cached = list_cached_images()
  let remote_block = case images {
    [] -> "  (none found)"
    _ ->
      images
      |> list.map(fn(i) {
        "  "
        <> i.file
        <> case i.size {
          Some(size) -> "  " <> format_kb(size)
          None -> ""
        }
        <> case i.prerelease {
          True -> "  (prerelease)"
          False -> ""
        }
      })
      |> string.join(with: "\n")
  }
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
    "AtomVM PSP EBOOT images:\n"
    <> remote_block
    <> local_block
    <> "\n\nInstall with:\n  gleam run -m orbital install psp\n"
    <> "  gleam run -m orbital install psp --image <name-or-path>\n",
  )
}

/// Resolve an image: local EBOOT/zip path, published name, or release tag.
/// With neither `--image` nor `--version`, fetches the latest release asset.
pub fn resolve_image(
  image image: Option(String),
  version version: Option(String),
  repo repo: Option(String),
) -> Result(Image, Error) {
  case image {
    Some(path_or_name) ->
      case simplifile.is_file(path_or_name) {
        Ok(True) -> local_image(path_or_name)
        _ -> ensure_named(path_or_name, repo)
      }
    None -> ensure_version(version, repo)
  }
}

fn local_image(path: String) -> Result(Image, Error) {
  let file = filepath.base_name(path)
  let lower = string.lowercase(file)
  case string.ends_with(lower, ".pbp") {
    True ->
      Ok(Image(
        name: stem_name(file),
        file:,
        version: "local",
        tag: "local",
        url: None,
        path: Some(path),
        size: file_size(path),
        prerelease: False,
      ))
    False ->
      case string.ends_with(lower, ".zip") {
        True -> extract_eboot_from_zip(path)
        False ->
          Error(FileError(
            "PSP --image must be an EBOOT.PBP or a .zip containing one (got '"
            <> file
            <> "').",
          ))
      }
  }
}

fn extract_eboot_from_zip(path: String) -> Result(Image, Error) {
  use names <- result.try(
    zip_list_ffi(path)
    |> result.map_error(fn(reason) { FileError(reason) }),
  )
  use member <- result.try(select_eboot_member(names, path))
  use data <- result.try(
    zip_get_ffi(path, member)
    |> result.map_error(fn(reason) { FileError(reason) }),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(cache_dir_name)
    |> result.map_error(fn(_) {
      FileError("Could not create " <> cache_dir_name)
    }),
  )
  let out = filepath.join(cache_dir_name, "EBOOT.PBP")
  use Nil <- result.try(write_atomically(out, data))
  io.println("Extracted EBOOT.PBP from " <> filepath.base_name(path))
  Ok(Image(
    name: "EBOOT",
    file: "EBOOT.PBP",
    version: "local",
    tag: "local",
    url: None,
    path: Some(out),
    size: Some(bit_array.byte_size(data)),
    prerelease: False,
  ))
}

fn select_eboot_member(
  names: List(String),
  zip_path: String,
) -> Result(String, Error) {
  let preferred = [
    "EBOOT.PBP",
    "PSP/GAME/ATOMVM/EBOOT.PBP",
    "GAME/ATOMVM/EBOOT.PBP",
    "ATOMVM/EBOOT.PBP",
  ]
  case
    list.find(preferred, fn(want) {
      list.any(names, fn(n) { string.uppercase(n) == string.uppercase(want) })
    })
  {
    Ok(want) ->
      list.find(names, fn(n) { string.uppercase(n) == string.uppercase(want) })
      |> result.replace_error(EbootNotInZip(zip_path))
    Error(Nil) ->
      case
        list.find(names, fn(n) {
          string.ends_with(string.uppercase(n), "EBOOT.PBP")
        })
      {
        Ok(name) -> Ok(name)
        Error(Nil) -> Error(EbootNotInZip(zip_path))
      }
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

fn ensure_version(
  version: Option(String),
  repo: Option(String),
) -> Result(Image, Error) {
  use release <- result.try(fetch_release(repo, version))
  case release_images(release) {
    [] -> Error(NoReleaseAssets)
    [image, ..] -> ensure_cached(image)
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
  let owner_repo = option.unwrap(repo, default_repo)
  let url =
    "https://api.github.com/repos/"
    <> owner_repo
    <> "/releases?per_page="
    <> int.to_string(page_size)
  use releases <- result.try(fetch_json_list(url))
  Ok(
    releases
    |> list.filter(fn(r) { !r.draft })
    |> list.flat_map(release_images),
  )
}

fn release_images(release: Release) -> List(Image) {
  list.filter_map(release.assets, fn(asset) {
    case is_psp_asset(asset.name) {
      False -> Error(Nil)
      True ->
        Ok(Image(
          name: stem_name(asset.name),
          file: asset.name,
          version: release.tag_name,
          tag: release.tag_name,
          url: Some(asset.url),
          path: None,
          size: asset.size,
          prerelease: release.prerelease,
        ))
    }
  })
}

/// Accept bare EBOOT.PBP, AtomVM*PSP*.{pbp,zip}, or *psp*.zip names.
pub fn is_psp_asset(file: String) -> Bool {
  let lower = string.lowercase(file)
  case string.ends_with(lower, ".pbp") {
    True -> True
    False ->
      string.ends_with(lower, ".zip")
      && { string.contains(lower, "psp") || string.contains(lower, "atomvm") }
  }
}

fn fetch_release(
  repo: Option(String),
  version: Option(String),
) -> Result(Release, Error) {
  let owner_repo = option.unwrap(repo, default_repo)
  let base = "https://api.github.com/repos/" <> owner_repo <> "/releases"
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
      case string.ends_with(string.lowercase(image.file), ".zip") {
        True -> extract_eboot_from_zip(path)
        False -> Ok(Image(..image, path: Some(path)))
      }
    }
    _ -> {
      io.println("Downloading " <> image.file <> "…")
      use data <- result.try(download(image))
      use Nil <- result.try(write_atomically(path, data))
      case string.ends_with(string.lowercase(image.file), ".zip") {
        True -> extract_eboot_from_zip(path)
        False ->
          Ok(
            Image(
              ..image,
              path: Some(path),
              size: Some(bit_array.byte_size(data)),
            ),
          )
      }
    }
  }
}

fn download(image: Image) -> Result(BitArray, Error) {
  use url <- result.try(case image.url {
    Some(url) -> Ok(url)
    None -> Error(FileError("Image has no download URL: " <> image.file))
  })
  fetch_binary(url)
}

fn list_cached_images() -> List(Image) {
  case simplifile.read_directory(cache_dir_name) {
    Ok(files) ->
      list.filter_map(files, fn(file) {
        case is_psp_asset(file) {
          False -> Error(Nil)
          True -> {
            let path = filepath.join(cache_dir_name, file)
            Ok(Image(
              name: stem_name(file),
              file:,
              version: "cached",
              tag: "cached",
              url: None,
              path: Some(path),
              size: file_size(path),
              prerelease: False,
            ))
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
    || string.lowercase(i.file) == wanted <> ".pbp"
    || string.lowercase(i.file) == wanted <> ".zip"
  })
  |> option.from_result
}

fn format_kb(bytes: Int) -> String {
  let kb = { bytes + 1023 } / 1024
  int.to_string(kb) <> " KB"
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

fn stem_name(file: String) -> String {
  let lower = string.lowercase(file)
  case string.ends_with(lower, ".pbp"), string.ends_with(lower, ".zip") {
    True, _ -> string.drop_end(file, 4)
    _, True -> string.drop_end(file, 4)
    False, False -> file
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

@external(erlang, "orbital_ffi", "zip_list")
fn zip_list_ffi(path: String) -> Result(List(String), String)

@external(erlang, "orbital_ffi", "zip_get")
fn zip_get_ffi(path: String, member: String) -> Result(BitArray, String)
