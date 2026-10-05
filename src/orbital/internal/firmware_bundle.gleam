//// Firmware bundle slicing, FLASH.txt parsing, and bootloader checks.
////
//// Shared image types and naming live in `orbital/internal/firmware`.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import orbital/internal/firmware.{
  type BootloaderCheck, type Error, type FlashInfo, type FlashPart,
  type UpdateParts, type VerifiedBundle, BadBundle, BadImage, BootloaderNewer,
  BootloaderOk, BootloaderWarn, FlashInfo, FlashPart, Image, PartTooLarge,
  PartitionMismatch, StampMismatch, UpdateParts, VerifiedBundle, format_hex,
  parse_name, partition_table_offset, partition_table_size,
}
import orbital/internal/partition.{type Partition}

const bootloader_desc_offset = 0x20

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
