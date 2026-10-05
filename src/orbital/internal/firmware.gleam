//// AtomVM ESP32 firmware image naming, offsets, and update planning.
////
//// Mirrors ExAtomVM's `Esp32FirmwareImages`: classifying `--image` arguments,
//// chip tokens, flash offsets, and related helpers. Bundle slicing, FLASH.txt
//// parsing, and bootloader checks live in `orbital/internal/firmware_bundle`.
//// GitHub listing/download/cache lives in `orbital/internal/firmware_fetch`.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import simplifile

pub const partition_table_offset = 0x8000

pub const partition_table_size = 0xC00

pub const bootloader_header_size = 0x70

pub type Channel {
  Stable
  Prerelease
  Nightly
  Local
  Custom
}

pub type Kind {
  Img
  Zip
}

/// Where an image came from (GitHub source, cache, or local path).
pub type Source {
  Atomvm
  Factory
  CustomRepo(String)
  Cache
  Build
  LocalSource
}

/// A firmware image descriptor (local path, cache entry, or published name).
pub type Image {
  Image(
    name: String,
    file: Option(String),
    kind: Kind,
    chip: Option(String),
    base_chip: Option(String),
    elixir: Option(Bool),
    features: List(String),
    version: Option(String),
    channel: Channel,
    stamp: Option(String),
    path: Option(String),
    img_path: Option(String),
    flash_offset: Option(Int),
    url: Option(String),
    size: Option(Int),
    sha256: Option(String),
    sha256_url: Option(String),
    tag: Option(String),
    source: Option(Source),
    published_at: Option(String),
  )
}

/// One binary listed in a bundle's FLASH.txt Contents section.
pub type FlashPart {
  FlashPart(name: String, offset: Int)
}

/// Parsed FLASH.txt header + Contents parts.
pub type FlashInfo {
  FlashInfo(
    image: Option(String),
    chip: String,
    build: Option(String),
    idf: Option(String),
    flash_offset: Int,
    app_offset: Option(Int),
    parts: List(FlashPart),
  )
}

/// A verified factory zip bundle (image + optional named parts).
pub type VerifiedBundle {
  VerifiedBundle(
    stem: String,
    image: BitArray,
    flash: FlashInfo,
    stamp: Option(String),
    parts: List(#(String, BitArray)),
    partitions_csv: Option(BitArray),
  )
}

pub type ImageArg {
  PathArg(String)
  NameArg(Image)
}

pub type UpdateParts {
  UpdateParts(
    bootloader: BitArray,
    table: BitArray,
    app_offset: Int,
    app_name: String,
    app: BitArray,
    lib_offset: Int,
    lib_name: String,
    lib: BitArray,
  )
}

pub type BootloaderCheck {
  BootloaderOk(board_idf: Option(String), image_idf: Option(String))
  BootloaderWarn(
    board_idf: Option(String),
    image_idf: Option(String),
    warning: String,
  )
}

pub type Error {
  UnrecognizedName(String)
  InvalidRepo(String)
  UnknownFlashOffset(String)
  FlashOffsetConflict(file: String, bundle: Int, table: Int)
  BadImage(String)
  PartitionMismatch(String)
  PartTooLarge(name: String, size: Int, max: Int)
  NotInstalled
  BootloaderNewer(board: String, image: String)
  FileError(String)
  Network(String)
  UnknownImage(String)
  ReleaseNotFound(String)
  NoElixirImage(tag: String, chip: String, erlang_name: String)
  NoImageForChip(tag: String, chip: String, chips: List(String))
  BadBundle(file: String, detail: String)
  StampMismatch(file: String, expected: String, actual: String)
}

/// Parse `AtomVM-<chip>[-elixir][-features...]-<version>[+stamp][.img|.zip]`.
pub fn parse_name(name_or_path: String) -> Result(Image, Error) {
  let file = basename(name_or_path)
  let #(stem, kind) = split_extension(file)
  let parts = string.split(stem, on: "-")
  case parts {
    [atomvm, chip, ..rest] -> {
      case string.lowercase(atomvm) == "atomvm" && valid_chip(chip) {
        False -> Error(UnrecognizedName(file))
        True -> {
          let #(flavor, version_tokens) =
            list.split_while(rest, fn(token) { !version_token(token) })
          case parse_version(version_tokens) {
            Error(_) -> Error(UnrecognizedName(file))
            Ok(#(version, stamp)) -> {
              let name = case string.split_once(stem, on: "+") {
                Ok(#(before, _)) -> before
                Error(_) -> stem
              }
              Ok(Image(
                name:,
                file: case kind {
                  Some(_) -> Some(file)
                  None -> None
                },
                kind: option.unwrap(kind, Img),
                chip: Some(chip),
                base_chip: Some(base_chip(chip)),
                elixir: Some(list.contains(flavor, "elixir")),
                features: list.filter(flavor, fn(token) { token != "elixir" }),
                version:,
                channel: channel(version),
                stamp:,
                path: None,
                img_path: None,
                flash_offset: None,
                url: None,
                size: None,
                sha256: None,
                sha256_url: None,
                tag: None,
                source: None,
                published_at: None,
              ))
            }
          }
        }
      }
    }
    _ -> Error(UnrecognizedName(file))
  }
}

/// The Elixir image of a release for `chip_token`, matched on the exact chip.
pub fn select_release_image(
  images: List(Image),
  tag: String,
  chip_token: String,
) -> Result(Image, Error) {
  let candidates =
    list.filter(images, fn(image) { image.chip == Some(chip_token) })
  case list.find(candidates, fn(image) { image.elixir == Some(True) }) {
    Ok(image) -> Ok(image)
    Error(Nil) ->
      case candidates {
        [] -> {
          let chips =
            images
            |> list.filter_map(fn(image) { option.to_result(image.chip, Nil) })
            |> list.unique
            |> list.sort(string.compare)
          Error(NoImageForChip(tag:, chip: chip_token, chips:))
        }
        [erlang, ..] ->
          Error(NoElixirImage(
            tag:,
            chip: chip_token,
            erlang_name: erlang.name,
          ))
      }
  }
}

/// Classify `--image`: existing file, published name, or custom-repo basename.
pub fn classify_image_arg(
  arg: String,
  custom_source: Bool,
) -> Result(ImageArg, Error) {
  case simplifile.is_file(arg) {
    Ok(True) -> Ok(PathArg(arg))
    Ok(False) | Error(_) ->
      case parse_name(arg) {
        Ok(Image(version: Some(_), ..) as image) -> Ok(NameArg(image))
        _ if custom_source ->
          Ok(NameArg(Image(..file_image(basename(arg)), channel: Custom)))
        _ -> Error(UnrecognizedName(arg))
      }
  }
}

/// Build a local image descriptor from a filesystem path.
pub fn local_image(path: String) -> Image {
  Image(..file_image(basename(path)), path: Some(path))
}

/// Path written to the device (`img_path` for extracted zips, else `path`).
pub fn image_path(image: Image) -> Result(String, Error) {
  case image.img_path, image.path {
    Some(path), _ -> Ok(path)
    None, Some(path) -> Ok(path)
    None, None -> Error(FileError("Image has no path on disk."))
  }
}

/// Normalize `--repo` to `OWNER/REPO`.
pub fn parse_repo_arg(arg: String) -> Result(String, Error) {
  let repo =
    arg
    |> string.trim
    |> strip_prefix("https://")
    |> strip_prefix("http://")
    |> strip_prefix("github.com/")
    |> string.trim_end
    |> strip_suffix("/")
    |> strip_suffix("/releases")
    |> strip_suffix(".git")

  case string.split(repo, on: "/") {
    [owner, name] ->
      case owner != "" && name != "" && valid_repo_part(owner) && valid_repo_part(name) {
        True -> Ok(owner <> "/" <> name)
        False -> Error(InvalidRepo(arg))
      }
    _ -> Error(InvalidRepo(arg))
  }
}

/// Chip token from esptool's `CHIP_NAME` (`"ESP32-S3"` → `"esp32s3"`).
pub fn chip_token(chip_family: String) -> String {
  let head = case string.split_once(chip_family, on: " ") {
    Ok(#(before, _)) -> before
    Error(_) -> chip_family
  }
  let head = case string.split_once(head, on: "(") {
    Ok(#(before, _)) -> before
    Error(_) -> head
  }
  head
  |> string.lowercase
  |> string.replace(each: "-", with: "")
}

/// Flash offset for a full-image install.
pub fn flash_offset_for(image: Image, chip: String) -> Result(Int, Error) {
  let table = dict_flash_offset(chip)
  case image.flash_offset, table {
    None, None -> Error(UnknownFlashOffset(chip))
    None, Some(offset) -> Ok(offset)
    Some(offset), None -> Ok(offset)
    Some(offset), Some(same) if offset == same -> Ok(offset)
    Some(bundle), Some(table_offset) ->
      Error(FlashOffsetConflict(
        file: option.unwrap(image.file, image.name),
        bundle:,
        table: table_offset,
      ))
  }
}

/// Whether the image targets `chip` (`None` chip → unknown / allow).
pub fn compatible(image: Image, chip: String) -> Option(Bool) {
  case image_chip(image) {
    None -> None
    Some(image_chip) -> Some(image_chip == chip)
  }
}

pub fn image_chip(image: Image) -> Option(String) {
  case image.base_chip {
    Some(chip) -> Some(chip)
    None -> None
  }
}

pub fn format_hex(value: Int) -> String {
  "0x" <> hex_digits(value)
}

pub fn describe(image: Image, flash_offset: Int) -> List(String) {
  let details =
    list.filter(
      [
        case image.stamp {
          Some(stamp) -> Some("  build:    " <> stamp)
          None -> None
        },
        case image.features {
          [] -> None
          features -> Some("  features: " <> string.join(features, with: ", "))
        },
        Some("  offset:   " <> format_hex(flash_offset)),
      ],
      option.is_some,
    )
    |> list.map(fn(item) {
      let assert Some(text) = item
      text
    })

  [image.name <> " (" <> origin(image) <> ")", ..details]
}

pub fn warnings(image: Image, chip: String) -> List(String) {
  list.filter(
    [
      case image.elixir {
        Some(False) ->
          Some(
            "this image has no Elixir/Gleam stdlib support; Gleam applications may not run on it",
          )
        _ -> None
      },
      case compatible(image, chip) {
        None ->
          Some(
            "the chip this image was built for is not known; esptool refuses images built for another chip",
          )
        _ -> None
      },
    ],
    option.is_some,
  )
  |> list.map(fn(item) {
    let assert Some(text) = item
    text
  })
}

pub fn error_message(error: Error) -> String {
  case error {
    UnrecognizedName(name) ->
      "--image must be an image file or the name of a published image: "
      <> name
      <> "; list them with --list-images"
    InvalidRepo(arg) ->
      "--repo must be a GitHub repository, OWNER/REPO or its URL: " <> arg
    UnknownFlashOffset(chip) ->
      "I do not know the flash offset for chip '" <> chip <> "'."
    FlashOffsetConflict(file:, bundle:, table:) ->
      "Flash offset conflict for "
      <> file
      <> ": bundle says "
      <> format_hex(bundle)
      <> " but chip table says "
      <> format_hex(table)
      <> "."
    BadImage(reason) -> "Bad firmware image: " <> reason
    PartitionMismatch(reason) -> "Partition layout mismatch: " <> reason
    PartTooLarge(name:, size:, max:) ->
      name
      <> " payload ("
      <> int.to_string(size)
      <> " bytes) does not fit the partition ("
      <> int.to_string(max)
      <> " bytes)."
    NotInstalled ->
      "AtomVM is not installed on this board; run install without --update."
    BootloaderNewer(board:, image:) ->
      "The board's bootloader is from ESP-IDF "
      <> board
      <> ", newer than the image ("
      <> image
      <> "); update refused."
    FileError(reason) -> reason
    Network(reason) -> reason
    UnknownImage(name) ->
      "Unknown image '" <> name <> "'. List them with --list-images."
    ReleaseNotFound(tag) -> "Release not found: " <> tag
    NoElixirImage(tag:, chip:, erlang_name:) ->
      "release "
      <> tag
      <> " has no Elixir image for "
      <> chip
      <> ", only the Erlang-only "
      <> erlang_name
    NoImageForChip(tag:, chip:, chips: []) ->
      "release "
      <> tag
      <> " has no image named for "
      <> chip
      <> "; custom builds are installed by name with --image"
    NoImageForChip(tag:, chip:, chips:) ->
      "release "
      <> tag
      <> " has no image for "
      <> chip
      <> "; it has images for: "
      <> string.join(chips, with: ", ")
    BadBundle(file:, detail:) ->
      file <> " is not a valid firmware bundle: " <> detail
    StampMismatch(file:, expected:, actual:) ->
      file
      <> " carries build "
      <> actual
      <> " while the release notes say "
      <> expected
      <> "; the factory may be publishing a new build, retry in a few minutes"
  }
}

/// Hint printed after a download when `firmware_images/` is not gitignored.
pub fn gitignore_hint(gitignore: Option(String)) -> Option(String) {
  let lines = case gitignore {
    None -> []
    Some(text) -> string.split(text, on: "\n")
  }
  let ignored =
    list.any(lines, fn(line) {
      let trimmed = string.trim(line)
      trimmed == "firmware_images"
        || trimmed == "firmware_images/"
        || trimmed == "/firmware_images"
        || trimmed == "/firmware_images/"
    })
  case ignored {
    True -> None
    False ->
      Some(
        "Tip: add firmware_images/ to .gitignore, e.g.\n  echo '/firmware_images/' >> .gitignore",
      )
  }
}

// --- Internal ----------------------------------------------------------------

fn file_image(file: String) -> Image {
  case parse_name(file) {
    Ok(image) -> Image(..image, channel: Local)
    Error(_) -> {
      let #(stem, kind) = split_extension(file)
      Image(
        name: stem,
        file: Some(file),
        kind: option.unwrap(kind, Img),
        chip: None,
        base_chip: None,
        elixir: None,
        features: [],
        version: None,
        channel: Local,
        stamp: None,
        path: None,
        img_path: None,
        flash_offset: None,
        url: None,
        size: None,
        sha256: None,
        sha256_url: None,
        tag: None,
        source: Some(LocalSource),
        published_at: None,
      )
    }
  }
}

fn split_extension(file: String) -> #(String, Option(Kind)) {
  case string.ends_with(file, ".img") {
    True -> #(string.drop_end(file, 4), Some(Img))
    False ->
      case string.ends_with(file, ".zip") {
        True -> #(string.drop_end(file, 4), Some(Zip))
        False -> #(file, None)
      }
  }
}

fn version_token(token: String) -> Bool {
  token == "nightly" || string.starts_with(token, "v") && digit_after_v(token)
}

fn digit_after_v(token: String) -> Bool {
  case string.drop_start(token, 1) {
    "" -> False
    rest ->
      case string.first(rest) {
        Ok(char) -> string.contains("0123456789", char)
        Error(_) -> False
      }
  }
}

fn parse_version(
  tokens: List(String),
) -> Result(#(Option(String), Option(String)), Nil) {
  case tokens {
    [] -> Ok(#(None, None))
    _ -> {
      let joined = string.join(tokens, with: "-")
      let #(version, stamp) = case string.split_once(joined, on: "+") {
        Ok(#(version, suffix)) -> #(version, Some(version <> "+" <> suffix))
        Error(_) -> #(joined, None)
      }
      case valid_version(version) || valid_channel(version) {
        True -> Ok(#(Some(version), stamp))
        False -> Error(Nil)
      }
    }
  }
}

fn channel(version: Option(String)) -> Channel {
  case version {
    None -> Local
    Some(version) ->
      case string.starts_with(version, "nightly") {
        True -> Nightly
        False ->
          case valid_stable(version) {
            True -> Stable
            False -> Prerelease
          }
      }
  }
}

/// `^esp32([a-z]\\d+)?(_[a-z0-9]+)*$` — matches ExAtomVM's chip token regex.
fn valid_chip(chip: String) -> Bool {
  case string.starts_with(chip, "esp32") {
    False -> False
    True -> {
      let rest = string.drop_start(chip, 5)
      case rest {
        "" -> True
        _ ->
          case string.split(rest, on: "_") {
            [first, ..variants] ->
              case first {
                "" ->
                  list.all(variants, valid_chip_variant)
                  && variants != []
                _ ->
                  valid_chip_family(first)
                  && list.all(variants, valid_chip_variant)
              }
            [] -> False
          }
      }
    }
  }
}

fn valid_chip_family(token: String) -> Bool {
  case string.to_graphemes(token) {
    [first, ..digits] ->
      is_lower_letter(first)
      && digits != []
      && list.all(digits, is_digit)
    [] -> False
  }
}

fn valid_chip_variant(token: String) -> Bool {
  token != ""
  && list.all(string.to_graphemes(token), fn(g) {
    is_lower_letter(g) || is_digit(g)
  })
}

fn is_lower_letter(g: String) -> Bool {
  string.contains("abcdefghijklmnopqrstuvwxyz", g)
}

fn is_digit(g: String) -> Bool {
  string.contains("0123456789", g)
}

fn valid_version(version: String) -> Bool {
  // vMAJOR.MINOR.PATCH with optional -prerelease tokens
  case string.starts_with(version, "v") {
    False -> False
    True -> {
      let body = string.drop_start(version, 1)
      let #(numbers, rest) = case string.split_once(body, on: "-") {
        Ok(#(numbers, rest)) -> #(numbers, Some(rest))
        Error(_) -> #(body, None)
      }
      case string.split(numbers, on: ".") {
        [a, b, c] ->
          is_int(a) && is_int(b) && is_int(c) && case rest {
            None -> True
            Some(r) -> r != ""
          }
        _ -> False
      }
    }
  }
}

fn valid_stable(version: String) -> Bool {
  case string.starts_with(version, "v") {
    False -> False
    True -> {
      let body = string.drop_start(version, 1)
      case string.split(body, on: ".") {
        [a, b, c] ->
          is_int(a) && is_int(b) && is_int(c) && !string.contains(c, "-")
        _ -> False
      }
    }
  }
}

fn valid_channel(version: String) -> Bool {
  case string.split(version, on: "-") {
    ["nightly", first, ..rest] -> first != "" || rest != []
    _ -> False
  }
}

fn valid_repo_part(part: String) -> Bool {
  part != ""
  && string.to_graphemes(part)
  |> list.all(fn(g) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-",
      g,
    )
  })
}

fn base_chip(chip: String) -> String {
  case string.split_once(chip, on: "_") {
    Ok(#(before, _)) -> before
    Error(_) -> chip
  }
}

fn dict_flash_offset(chip: String) -> Option(Int) {
  case chip {
    "esp32" | "esp32s2" -> Some(0x1000)
    "esp32s3" | "esp32c2" | "esp32c3" | "esp32c6" | "esp32c61" | "esp32h2" ->
      Some(0x0)
    "esp32c5" | "esp32p4" -> Some(0x2000)
    _ -> None
  }
}

fn origin(image: Image) -> String {
  let flavor = case image.elixir {
    Some(True) -> "Elixir"
    Some(False) -> "Erlang only"
    None -> "unknown"
  }
  case image.channel, image.version {
    Stable, Some(version) -> "stable release " <> version <> ", " <> flavor
    Prerelease, Some(version) -> "prerelease " <> version <> ", " <> flavor
    Nightly, Some(version) -> "nightly build " <> version <> ", " <> flavor
    Custom, Some(version) ->
      "custom build, release " <> version <> ", " <> flavor
    _, _ -> "local image, " <> flavor
  }
}

fn basename(path: String) -> String {
  case string.split(path, on: "/") {
    [] -> path
    parts -> {
      let assert Ok(last) = list.last(parts)
      last
    }
  }
}

fn strip_prefix(text: String, prefix: String) -> String {
  case string.starts_with(text, prefix) {
    True -> string.drop_start(text, string.length(prefix))
    False -> text
  }
}

fn strip_suffix(text: String, suffix: String) -> String {
  case string.ends_with(text, suffix) {
    True -> string.drop_end(text, string.length(suffix))
    False -> text
  }
}

fn is_int(text: String) -> Bool {
  case int.parse(text) {
    Ok(_) -> True
    Error(_) -> False
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
