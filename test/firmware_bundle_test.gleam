import gleam/bit_array
import gleam/crypto
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import orbital/internal/firmware
import orbital/internal/firmware_bundle
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_flash_txt_reads_parts_test() {
  let text =
    "AtomVM firmware image: AtomVM-esp32s3-nightly-0.7.img\n"
    <> "Chip: esp32s3\n"
    <> "AtomVM build: nightly-0.7+20260915.02e1603\n"
    <> "ESP-IDF: 5.5.4\n"
    <> "Flash offset: 0x0\n"
    <> "Application partition (main.avm): 0x250000\n"
    <> "\nContents\n--------\n\n"
    <> "The binaries are the parts of the image, byte for byte, at these offsets:\n"
    <> "  0x0       bootloader.bin\n"
    <> "  0x40      partition-table.bin\n"
    <> "  0x80      atomvm-esp32.bin\n"
    <> "  0x100     esp32boot.avm\n"
    <> "\nDebugging\n---------\n"
  let assert Ok(flash) = firmware_bundle.parse_flash_txt(text)
  assert flash.chip == "esp32s3"
  assert flash.flash_offset == 0x0
  assert flash.app_offset == Some(0x250000)
  assert flash.parts
    == [
      firmware.FlashPart("bootloader.bin", 0x0),
      firmware.FlashPart("partition-table.bin", 0x40),
      firmware.FlashPart("atomvm-esp32.bin", 0x80),
      firmware.FlashPart("esp32boot.avm", 0x100),
    ]
}

pub fn format_size_matches_exatomvm_test() {
  assert firmware_bundle.format_size(Some(2_197_764)) == "2.1 MB"
  assert firmware_bundle.format_size(Some(315_504)) == "309 KB"
  assert firmware_bundle.format_size(None) == ""
}

pub fn verify_bundle_members_accepts_parts_test() {
  let stem = "AtomVM-esp32s3-atomgl-nightly-0.7"
  let stamp = "nightly-0.7+20260915.02e1603"
  let bootloader = <<0xE9, 1, 2, 3, 0xAB, 0xAB, 0xAB, 0xAB>>
  let table = <<0xAA, 0x50, 1, 2, 3, 4>>
  let app = <<0xE9, 0xCD, 0xCD, 0xCD>>
  let lib = <<"#!/usr/bin/env AtomVM\n", 0x42, 0x42>>
  let image =
    pad_to(bootloader, 0x0)
    |> append_at(0x40, table)
    |> append_at(0x80, app)
    |> append_at(0x100, lib)
  let flash_txt =
    "Chip: esp32s3\nFlash offset: 0x0\n\nContents\n--------\n\n"
    <> "  0x0       bootloader.bin\n"
    <> "  0x40      partition-table.bin\n"
    <> "  0x80      atomvm-esp32.bin\n"
    <> "  0x100     esp32boot.avm\n"
  let sdkconfig = "CONFIG_APP_PROJECT_VER=\"" <> stamp <> "\"\n"
  let partitions = "nvs,data,nvs,0x9000,0x6000\n"
  let img_name = stem <> ".img"
  let sha_line = sha256_hex(image) <> "  " <> img_name <> "\n"
  let members = [
    #(img_name, image),
    #(img_name <> ".sha256", <<sha_line:utf8>>),
    #("sdkconfig", <<sdkconfig:utf8>>),
    #("partitions.csv", <<partitions:utf8>>),
    #("FLASH.txt", <<flash_txt:utf8>>),
    #("bootloader.bin", bootloader),
    #("partition-table.bin", table),
    #("atomvm-esp32.bin", app),
    #("esp32boot.avm", lib),
  ]
  let assert Ok(bundle) =
    firmware_bundle.verify_bundle_members(members, "b.zip", Some(stamp))
  assert bundle.stamp == Some(stamp)
  assert bundle.flash.chip == "esp32s3"
  let assert Ok(parts) = firmware_bundle.bundle_update_parts(bundle)
  assert parts.app_name == "atomvm-esp32.bin"
  assert parts.lib_name == "esp32boot.avm"
  assert parts.app_offset == 0x80
  assert parts.lib_offset == 0x100
}

fn string_contains(haystack: String, needle: String) -> Bool {
  case string.split_once(haystack, on: needle) {
    Ok(_) -> True
    Error(_) -> False
  }
}

fn sha256_hex(data: BitArray) -> String {
  bit_array.base16_encode(crypto.hash(crypto.Sha256, data))
  |> string.lowercase
}

fn pad_to(data: BitArray, _offset: Int) -> BitArray {
  data
}

fn append_at(image: BitArray, offset: Int, data: BitArray) -> BitArray {
  let gap = offset - bit_array.byte_size(image)
  case gap > 0 {
    True -> <<image:bits, erased(gap):bits, data:bits>>
    False -> <<image:bits, data:bits>>
  }
}

fn erased(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> <<0xFF, erased(n - 1):bits>>
  }
}

pub fn compare_bootloader_refuses_newer_board_test() {
  let board = bootloader_with_idf("v5.5.4")
  let image = bootloader_with_idf("v5.4.0")
  let assert Error(firmware.BootloaderNewer(board: "v5.5.4", image: "v5.4.0")) =
    firmware_bundle.check_bootloader(board, image)
}

pub fn compare_bootloader_allows_older_or_equal_board_test() {
  let board = bootloader_with_idf("v5.4.0")
  let image = bootloader_with_idf("v5.5.4")
  let assert Ok(firmware.BootloaderOk(..)) =
    firmware_bundle.check_bootloader(board, image)
}

fn bootloader_with_idf(version: String) -> BitArray {
  // Bytes 0..0x1f, then 0x50, 7 padding, 32-byte idf_ver
  let prefix = zeros(0x20)
  let idf = pad_idf(version)
  <<prefix:bits, 0x50, 0, 0, 0, 0, 0, 0, 0, idf:bits>>
}

fn zeros(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> <<0, zeros(n - 1):bits>>
  }
}

fn pad_idf(version: String) -> BitArray {
  let bytes = <<version:utf8, 0>>
  let len = bit_array.byte_size(bytes)
  case len >= 32 {
    True -> {
      let assert Ok(slice) = bit_array.slice(bytes, 0, 32)
      slice
    }
    False -> <<bytes:bits, zeros(32 - len):bits>>
  }
}
