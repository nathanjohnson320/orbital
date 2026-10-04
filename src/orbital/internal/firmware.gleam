//// AtomVM ESP32 firmware image naming, offsets, and update planning.
////
//// Mirrors ExAtomVM's `Esp32FirmwareImages`: classifying `--image` arguments,
//// chip tokens, flash offsets, slicing `factory` / `boot.avm` for `--update`,
//// and bootloader ESP-IDF guardrails. GitHub listing/download/cache lives in
//// `orbital/internal/firmware_fetch`.

import gleam/bit_array
import gleam/crypto
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

/// Parse a bundle FLASH.txt (chip + flash offset required).
pub fn parse_flash_txt(text: String) -> Result(FlashInfo, Error) {
  let lines = string.split(text, on: "\n")
  let chip = capture_line(lines, "Chip:")
  let flash_offset_raw = capture_line(lines, "Flash offset:")
  case chip, flash_offset_raw {
    None, _ -> Error(BadBundle(file: "FLASH.txt", detail: "missing Chip"))
    _, None ->
      Error(BadBundle(file: "FLASH.txt", detail: "missing Flash offset"))
    Some(chip), Some(raw) ->
      case parse_hex(string.trim(raw)) {
        Error(_) ->
          Error(BadBundle(file: "FLASH.txt", detail: "bad Flash offset"))
        Ok(flash_offset) ->
          Ok(FlashInfo(
            image: capture_line(lines, "AtomVM firmware image:"),
            chip: string.lowercase(string.trim(chip)),
            build: capture_line(lines, "AtomVM build:"),
            idf: capture_line(lines, "ESP-IDF:"),
            flash_offset:,
            app_offset: case
              capture_line(lines, "Application partition (main.avm):")
            {
              None -> None
              Some(value) ->
                case parse_hex(string.trim(value)) {
                  Ok(offset) -> Some(offset)
                  Error(_) -> None
                }
            },
            parts: flash_contents(lines),
          ))
      }
  }
}

/// `CONFIG_APP_PROJECT_VER` from sdkconfig.
pub fn bundle_stamp(sdkconfig: String) -> Option(String) {
  case string.split_once(sdkconfig, on: "CONFIG_APP_PROJECT_VER=\"") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, on: "\"") {
        Ok(#(stamp, _)) -> Some(stamp)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

/// Verify extracted zip members as a factory firmware bundle.
pub fn verify_bundle_members(
  members: List(#(String, BitArray)),
  file: String,
  expected_stamp: Option(String),
) -> Result(VerifiedBundle, Error) {
  let names = list.map(members, fn(pair) { pair.0 })
  use img_name <- result.try(bundle_image_name(names, file))
  use Nil <- result.try(members_present(names, ["FLASH.txt"], file))
  use flash_bytes <- result.try(member_bytes(members, "FLASH.txt", file))
  use flash_text <- result.try(case bit_array.to_string(flash_bytes) {
    Ok(text) -> Ok(text)
    Error(_) -> Error(BadBundle(file:, detail: "unreadable FLASH.txt"))
  })
  use flash <- result.try(case parse_flash_txt(flash_text) {
    Ok(info) -> Ok(info)
    Error(BadBundle(_, detail)) -> Error(BadBundle(file:, detail:))
    Error(other) -> Error(other)
  })
  let part_names = list.map(flash.parts, fn(part) { part.name })
  let summed =
    list.append(
      [img_name, "sdkconfig", "partitions.csv", "FLASH.txt"],
      part_names,
    )
  let wanted = list.append([img_name <> ".sha256"], summed)
  use Nil <- result.try(members_present(names, wanted, file))
  use image <- result.try(member_bytes(members, img_name, file))
  use Nil <- result.try(
    check_listed_sha256(members, img_name <> ".sha256", [img_name], file),
  )
  use Nil <- result.try(case list.contains(names, "SHA256SUMS") {
    True -> check_listed_sha256(members, "SHA256SUMS", summed, file)
    False -> Ok(Nil)
  })
  use Nil <- result.try(check_parts_in_image(image, flash, members, file))
  use Nil <- result.try(check_bundle_chip(img_name, flash.chip, file))
  let stamp = case member_bytes(members, "sdkconfig", file) {
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Ok(text) -> bundle_stamp(text)
        Error(_) -> None
      }
    Error(_) -> None
  }
  use Nil <- result.try(check_stamp(stamp, expected_stamp, file))
  let parts =
    list.filter_map(part_names, fn(name) {
      case list.key_find(members, name) {
        Ok(data) -> Ok(#(name, data))
        Error(_) -> Error(Nil)
      }
    })
  let partitions_csv = case list.key_find(members, "partitions.csv") {
    Ok(data) -> Some(data)
    Error(_) -> None
  }
  Ok(VerifiedBundle(
    stem: string_replace_end(img_name, ".img", ""),
    image:,
    flash:,
    stamp:,
    parts:,
    partitions_csv:,
  ))
}

/// Update payloads from a verified zip bundle (FLASH.txt parts or sliced img).
pub fn bundle_update_parts(
  bundle: VerifiedBundle,
) -> Result(UpdateParts, Error) {
  case bundle.parts {
    [] -> slice_image(bundle.image, bundle.flash.flash_offset)
    parts -> {
      let offsets =
        list.map(bundle.flash.parts, fn(part) { #(part.name, part.offset) })
      let lib_name =
        list.find_map(parts, fn(pair) {
          case string.ends_with(pair.0, ".avm") {
            True -> Ok(pair.0)
            False -> Error(Nil)
          }
        })
      let wanted = [
        "bootloader.bin",
        "partition-table.bin",
        "atomvm-esp32.bin",
        option.unwrap(result_to_option(lib_name), "boot library"),
      ]
      let present = list.map(parts, fn(pair) { pair.0 })
      let missing =
        list.filter(wanted, fn(name) { !list.contains(present, name) })
      case missing, lib_name {
        [], Ok(lib) -> {
          use bootloader <- result.try(part_data(parts, "bootloader.bin"))
          use table <- result.try(part_data(parts, "partition-table.bin"))
          use app <- result.try(part_data(parts, "atomvm-esp32.bin"))
          use lib_bytes <- result.try(part_data(parts, lib))
          use app_offset <- result.try(part_offset(offsets, "atomvm-esp32.bin"))
          use lib_offset <- result.try(part_offset(offsets, lib))
          Ok(UpdateParts(
            bootloader:,
            table:,
            app_offset:,
            app_name: "atomvm-esp32.bin",
            app:,
            lib_offset:,
            lib_name: lib,
            lib: lib_bytes,
          ))
        }
        missing, _ ->
          Error(BadBundle(
            file: bundle.stem <> ".zip",
            detail: "missing "
              <> string.join(missing, with: ", "),
          ))
      }
    }
  }
}

/// Human-readable size matching ExAtomVM (`ceil` KB below 1 MB).
pub fn format_size(bytes: Option(Int)) -> String {
  case bytes {
    None -> ""
    Some(size) if size >= 1_048_576 -> {
      let mb = int.to_float(size) /. 1_048_576.0
      float_one(mb) <> " MB"
    }
    Some(size) -> int.to_string({ size + 1023 } / 1024) <> " KB"
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

fn capture_line(lines: List(String), prefix: String) -> Option(String) {
  case
    list.find_map(lines, fn(line) {
      case string.starts_with(line, prefix) {
        True -> Ok(string.trim(string.drop_start(line, string.length(prefix))))
        False -> Error(Nil)
      }
    })
  {
    Ok(value) if value != "" -> Some(value)
    _ -> None
  }
}

fn flash_contents(lines: List(String)) -> List(FlashPart) {
  lines
  |> list.drop_while(fn(line) { line != "Contents" })
  |> list.drop(2)
  |> list.take_while(fn(line) { !is_underline(line) })
  |> list.filter_map(fn(line) {
    case
      string.trim(line)
      |> string.split(on: " ")
      |> list.filter(fn(part) { part != "" })
    {
      [offset, name] ->
        case parse_hex(offset) {
          Ok(value) -> Ok(FlashPart(name:, offset: value))
          Error(_) -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn is_underline(line: String) -> Bool {
  line != "" && list.all(string.to_graphemes(line), fn(g) { g == "-" })
}

fn parse_hex(raw: String) -> Result(Int, Nil) {
  case string.starts_with(string.lowercase(raw), "0x") {
    True -> int.base_parse(string.drop_start(raw, 2), 16)
    False -> Error(Nil)
  }
}

fn bundle_image_name(
  names: List(String),
  file: String,
) -> Result(String, Error) {
  case list.filter(names, fn(n) { string.ends_with(n, ".img") }) {
    [name] -> Ok(name)
    _ -> Error(BadBundle(file:, detail: "expected exactly one .img member"))
  }
}

fn members_present(
  names: List(String),
  wanted: List(String),
  file: String,
) -> Result(Nil, Error) {
  let missing = list.filter(wanted, fn(name) { !list.contains(names, name) })
  case missing {
    [] -> Ok(Nil)
    _ ->
      Error(BadBundle(
        file:,
        detail: "missing " <> string.join(missing, with: ", "),
      ))
  }
}

fn member_bytes(
  members: List(#(String, BitArray)),
  name: String,
  file: String,
) -> Result(BitArray, Error) {
  case list.key_find(members, name) {
    Ok(data) -> Ok(data)
    Error(_) -> Error(BadBundle(file:, detail: "missing " <> name))
  }
}

fn check_listed_sha256(
  members: List(#(String, BitArray)),
  sums_name: String,
  names: List(String),
  file: String,
) -> Result(Nil, Error) {
  case list.key_find(members, sums_name) {
    Error(_) -> Ok(Nil)
    Ok(bytes) ->
      case bit_array.to_string(bytes) {
        Error(_) -> Error(BadBundle(file:, detail: "unreadable " <> sums_name))
        Ok(text) -> {
          let lines = parse_sha256_lines(text)
          list.try_fold(over: lines, from: Nil, with: fn(_, pair) {
            let #(hex, name) = pair
            case list.contains(names, name) {
              False -> Ok(Nil)
              True ->
                case list.key_find(members, name) {
                  Error(_) -> Ok(Nil)
                  Ok(data) -> {
                    let actual =
                      string.lowercase(
                        bit_array.base16_encode(crypto.hash(crypto.Sha256, data)),
                      )
                    case actual == string.lowercase(hex) {
                      True -> Ok(Nil)
                      False ->
                        Error(BadBundle(
                          file:,
                          detail: "sha256 mismatch for " <> name,
                        ))
                    }
                  }
                }
            }
          })
        }
      }
  }
}

fn parse_sha256_lines(text: String) -> List(#(String, String)) {
  list.filter_map(string.split(text, on: "\n"), fn(line) {
    let trimmed = string.trim(line)
    case string.split(trimmed, on: " ") {
      [hex, name, ..] ->
        case string.length(hex) == 64 {
          True -> {
            let name =
              name
              |> string.trim_start
              |> strip_star_prefix
            Ok(#(string.lowercase(hex), name))
          }
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn strip_star_prefix(name: String) -> String {
  case string.starts_with(name, "*") {
    True -> string.drop_start(name, 1)
    False -> name
  }
}

fn check_parts_in_image(
  image: BitArray,
  flash: FlashInfo,
  members: List(#(String, BitArray)),
  file: String,
) -> Result(Nil, Error) {
  list.try_fold(over: flash.parts, from: Nil, with: fn(_, part) {
    case list.key_find(members, part.name) {
      Error(_) ->
        Error(BadBundle(file:, detail: "missing part " <> part.name))
      Ok(data) -> {
        let start = part.offset - flash.flash_offset
        let size = bit_array.byte_size(data)
        case
          start >= 0
          && start + size <= bit_array.byte_size(image)
        {
          False ->
            Error(BadBundle(
              file:,
              detail: "part mismatch for "
                <> part.name
                <> " at "
                <> format_hex(part.offset),
            ))
          True ->
            case bit_array.slice(image, start, size) {
              Ok(slice) if slice == data -> Ok(Nil)
              _ ->
                Error(BadBundle(
                  file:,
                  detail: "part mismatch for "
                    <> part.name
                    <> " at "
                    <> format_hex(part.offset),
                ))
            }
        }
      }
    }
  })
}

fn check_bundle_chip(
  img_name: String,
  flash_chip: String,
  file: String,
) -> Result(Nil, Error) {
  case parse_name(img_name) {
    Ok(Image(base_chip: Some(chip), ..)) if chip != flash_chip ->
      Error(BadBundle(
        file:,
        detail: "chip "
          <> flash_chip
          <> " does not match image name chip "
          <> chip,
      ))
    _ -> Ok(Nil)
  }
}

fn check_stamp(
  stamp: Option(String),
  expected: Option(String),
  file: String,
) -> Result(Nil, Error) {
  case stamp, expected {
    Some(actual), Some(wanted) if actual != wanted ->
      Error(StampMismatch(file:, expected: wanted, actual:))
    _, _ -> Ok(Nil)
  }
}

fn part_data(
  parts: List(#(String, BitArray)),
  name: String,
) -> Result(BitArray, Error) {
  case list.key_find(parts, name) {
    Ok(data) -> Ok(data)
    Error(_) -> Error(BadBundle(file: name, detail: "missing part"))
  }
}

fn part_offset(
  offsets: List(#(String, Int)),
  name: String,
) -> Result(Int, Error) {
  case list.key_find(offsets, name) {
    Ok(offset) -> Ok(offset)
    Error(_) -> Error(BadBundle(file: name, detail: "missing offset"))
  }
}

fn result_to_option(result: Result(a, b)) -> Option(a) {
  case result {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn string_replace_end(value: String, suffix: String, with with_: String) -> String {
  case string.ends_with(value, suffix) {
    True -> string.drop_end(value, string.length(suffix)) <> with_
    False -> value
  }
}

fn float_one(value: Float) -> String {
  let tenths = float_round(value *. 10.0)
  let whole = tenths / 10
  let frac = tenths % 10
  int.to_string(whole) <> "." <> int.to_string(frac)
}

@external(erlang, "erlang", "round")
fn float_round(value: Float) -> Int
