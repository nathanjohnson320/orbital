//// AtomVM ESP32 firmware image naming, offsets, and update planning.
////
//// Mirrors ExAtomVM's `Esp32FirmwareImages`: classifying `--image` arguments,
//// chip tokens, flash offsets, slicing `factory` / `boot.avm` for `--update`,
//// and bootloader ESP-IDF guardrails. GitHub listing/download/cache lives in
//// `orbital/internal/firmware_fetch`.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import orbital/internal/partition.{type Partition}
import simplifile

pub const partition_table_offset = 0x8000

pub const partition_table_size = 0xC00

pub const bootloader_header_size = 0x70

const bootloader_desc_offset = 0x20

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
              ))
            }
          }
        }
      }
    }
    _ -> Error(UnrecognizedName(file))
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

/// Slice `factory` and `boot.avm` from a plain `.img` for `--update`.
pub fn slice_image(
  img: BitArray,
  base: Int,
) -> Result(UpdateParts, Error) {
  let table_start = partition_table_offset - base
  let need = table_start + partition_table_size
  case bit_array.byte_size(img) < need {
    True -> Error(BadImage("truncated firmware image"))
    False -> {
      use table <- result.try(slice_bytes(img, table_start, partition_table_size))
      use partitions <- result.try(
        partition.parse(table)
        |> result.map_error(fn(_) { PartitionMismatch("unreadable image table") }),
      )
      use factory <- result.try(named_partition(partitions, "factory"))
      use boot <- result.try(named_partition(partitions, "boot.avm"))
      use app <- result.try(partition_slice(img, base, factory))
      use lib <- result.try(partition_slice(img, base, boot))
      use bootloader <- result.try(slice_bytes(img, 0, table_start))
      Ok(UpdateParts(
        bootloader: trim_erased(bootloader),
        table:,
        app_offset: factory.offset,
        app_name: "factory.bin",
        app:,
        lib_offset: boot.offset,
        lib_name: "boot.avm",
        lib:,
      ))
    }
  }
}

/// Board `factory` / `boot.avm` must match the image; payloads must fit.
pub fn check_update_layout(
  board_table: BitArray,
  image_table: BitArray,
  app_size: Int,
  lib_size: Int,
) -> Result(Nil, Error) {
  use board <- result.try(
    partition.parse(board_table)
    |> result.map_error(fn(_) { PartitionMismatch("unreadable board table") }),
  )
  use image <- result.try(
    partition.parse(image_table)
    |> result.map_error(fn(_) { PartitionMismatch("unreadable image table") }),
  )
  use factory <- result.try(same_partition(board, image, "factory"))
  use boot <- result.try(same_partition(board, image, "boot.avm"))
  use Nil <- result.try(fits(app_size, factory))
  fits(lib_size, boot)
}

/// Refuse updating when the board bootloader is from a newer ESP-IDF.
pub fn check_bootloader(
  board_bootloader: BitArray,
  image_bootloader: BitArray,
) -> Result(BootloaderCheck, Error) {
  let board = idf_of(board_bootloader)
  let image = idf_of(image_bootloader)
  case compare_idf(board, image) {
    Gt -> {
      let board_s = option.unwrap(board, "unknown")
      let image_s = option.unwrap(image, "unknown")
      Error(BootloaderNewer(board: board_s, image: image_s))
    }
    Unknown ->
      Ok(BootloaderWarn(
        board_idf: board,
        image_idf: image,
        warning: "the ESP-IDF versions of the board's bootloader ("
          <> option.unwrap(board, "unknown")
          <> ") and of the image ("
          <> option.unwrap(image, "unknown")
          <> ") cannot be compared; a VM built with an older ESP-IDF than the bootloader does not start",
      ))
    Lt | Eq -> Ok(BootloaderOk(board_idf: board, image_idf: image))
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
  }
}

// --- Internal ----------------------------------------------------------------

type IdfOrder {
  Lt
  Eq
  Gt
  Unknown
}

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

fn valid_chip(chip: String) -> Bool {
  case string.starts_with(chip, "esp32") {
    False -> False
    True ->
      string.to_graphemes(chip)
      |> list.all(fn(g) {
        string.contains("abcdefghijklmnopqrstuvwxyz0123456789_", g)
      })
  }
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

fn named_partition(
  partitions: List(Partition),
  name: String,
) -> Result(Partition, Error) {
  case list.filter(partitions, fn(p) { p.name == name }) {
    [partition] -> Ok(partition)
    [] -> Error(PartitionMismatch("missing " <> name))
    _ -> Error(PartitionMismatch("duplicate " <> name))
  }
}

fn same_partition(
  board: List(Partition),
  image: List(Partition),
  name: String,
) -> Result(Partition, Error) {
  use on_board <- result.try(named_partition(board, name))
  use in_image <- result.try(named_partition(image, name))
  case
    on_board.type_ == in_image.type_
    && on_board.subtype == in_image.subtype
    && on_board.offset == in_image.offset
    && on_board.size == in_image.size
  {
    True -> Ok(in_image)
    False ->
      Error(PartitionMismatch(
        name
        <> " differs between board and image (type/subtype/offset/size must match)",
      ))
  }
}

fn fits(size: Int, partition: Partition) -> Result(Nil, Error) {
  case size <= partition.size {
    True -> Ok(Nil)
    False ->
      Error(PartTooLarge(name: partition.name, size:, max: partition.size))
  }
}

fn partition_slice(
  img: BitArray,
  base: Int,
  partition: Partition,
) -> Result(BitArray, Error) {
  let start = partition.offset - base
  case start >= 0 && start < bit_array.byte_size(img) {
    False -> Error(BadImage("no data for " <> partition.name))
    True -> {
      let available = bit_array.byte_size(img) - start
      let take = int.min(partition.size, available)
      use data <- result.try(slice_bytes(img, start, take))
      let trimmed = trim_erased(data)
      case bit_array.byte_size(trimmed) == 0 {
        True -> Error(BadImage("no data for " <> partition.name))
        False -> Ok(trimmed)
      }
    }
  }
}

fn slice_bytes(
  data: BitArray,
  start: Int,
  size: Int,
) -> Result(BitArray, Error) {
  case bit_array.slice(data, start, size) {
    Ok(bytes) -> Ok(bytes)
    Error(_) -> Error(BadImage("truncated firmware image"))
  }
}

fn trim_erased(data: BitArray) -> BitArray {
  trim_erased_loop(data, bit_array.byte_size(data))
}

fn trim_erased_loop(data: BitArray, size: Int) -> BitArray {
  case size {
    0 -> <<>>
    _ ->
      case bit_array.slice(data, size - 1, 1) {
        Ok(<<0xff>>) -> trim_erased_loop(data, size - 1)
        _ ->
          case bit_array.slice(data, 0, size) {
            Ok(bytes) -> bytes
            Error(_) -> <<>>
          }
      }
  }
}

fn idf_of(bootloader: BitArray) -> Option(String) {
  case bit_array.slice(bootloader, bootloader_desc_offset, 1 + 7 + 32) {
    Ok(<<0x50, _:bytes-size(7), idf_ver:bytes-size(32)>>) ->
      Some(nul_terminate(idf_ver))
    _ -> None
  }
}

fn nul_terminate(bytes: BitArray) -> String {
  case bytes {
    <<>> -> ""
    <<0, _:bits>> -> ""
    <<byte, rest:bits>> ->
      case bit_array.to_string(<<byte>>) {
        Ok(char) -> char <> nul_terminate(rest)
        Error(_) -> nul_terminate(rest)
      }
    _ -> ""
  }
}

fn compare_idf(a: Option(String), b: Option(String)) -> IdfOrder {
  case a, b {
    Some(a), Some(b) ->
      case idf_version(a), idf_version(b) {
        Some(x), Some(y) ->
          case int.compare(x.0, y.0) {
            order.Lt -> Lt
            order.Gt -> Gt
            order.Eq ->
              case int.compare(x.1, y.1) {
                order.Lt -> Lt
                order.Gt -> Gt
                order.Eq ->
                  case int.compare(x.2, y.2) {
                    order.Lt -> Lt
                    order.Gt -> Gt
                    order.Eq -> Eq
                  }
              }
          }
        _, _ -> Unknown
      }
    _, _ -> Unknown
  }
}

fn idf_version(version: String) -> Option(#(Int, Int, Int)) {
  let body = case string.starts_with(version, "v") {
    True -> string.drop_start(version, 1)
    False -> version
  }
  case string.split(body, on: ".") {
    [major, minor] ->
      case int.parse(major), int.parse(minor) {
        Ok(a), Ok(b) -> Some(#(a, b, 0))
        _, _ -> None
      }
    [major, minor, patch, ..] -> {
      let patch = case string.split_once(patch, on: "-") {
        Ok(#(before, _)) -> before
        Error(_) -> patch
      }
      case int.parse(major), int.parse(minor), int.parse(patch) {
        Ok(a), Ok(b), Ok(c) -> Some(#(a, b, c))
        _, _, _ -> None
      }
    }
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
