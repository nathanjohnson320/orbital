import gleam/bit_array
import gleam/option.{None, Some}
import gleeunit
import orbital/internal/firmware
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_name_elixir_release_test() {
  let assert Ok(image) =
    firmware.parse_name("AtomVM-esp32s3-elixir-v0.6.6.img")
  assert image.name == "AtomVM-esp32s3-elixir-v0.6.6"
  assert image.chip == Some("esp32s3")
  assert image.base_chip == Some("esp32s3")
  assert image.elixir == Some(True)
  assert image.version == Some("v0.6.6")
  assert image.channel == firmware.Stable
  assert image.kind == firmware.Img
}

pub fn parse_name_nightly_zip_test() {
  let assert Ok(image) =
    firmware.parse_name(
      "AtomVM-esp32s3-atomgl-psram-nightly-0.7+20260915.02e1603.zip",
    )
  assert image.channel == firmware.Nightly
  assert image.features == ["atomgl", "psram"]
  assert image.stamp == Some("nightly-0.7+20260915.02e1603")
  assert image.kind == firmware.Zip
}

pub fn parse_name_rejects_uppercase_chip_test() {
  let assert Error(firmware.UnrecognizedName(_)) =
    firmware.parse_name("AtomVM-ESP32S3-elixir-v0.6.6.img")
}

pub fn chip_token_test() {
  assert firmware.chip_token("ESP32-S3") == "esp32s3"
  assert firmware.chip_token("ESP32-C61 (QFN32)") == "esp32c61"
}

pub fn flash_offset_for_known_chips_test() {
  let image =
    firmware.Image(
      name: "local",
      file: None,
      kind: firmware.Img,
      chip: Some("esp32s3"),
      base_chip: Some("esp32s3"),
      elixir: None,
      features: [],
      version: None,
      channel: firmware.Local,
      stamp: None,
      path: None,
      img_path: None,
      flash_offset: None,
    )
  let assert Ok(0x0) = firmware.flash_offset_for(image, "esp32s3")
  let assert Ok(0x1000) = firmware.flash_offset_for(image, "esp32")
  let assert Ok(0x2000) = firmware.flash_offset_for(image, "esp32p4")
}

pub fn classify_image_arg_path_test() {
  let path = "build/test-classify.img"
  let assert Ok(Nil) = simplifile.create_directory_all("build")
  let assert Ok(Nil) = simplifile.write(to: path, contents: "img")
  let assert Ok(firmware.PathArg(found)) =
    firmware.classify_image_arg(path, False)
  assert found == path
  let _ = simplifile.delete(path)
}

pub fn classify_image_arg_name_test() {
  let assert Ok(firmware.NameArg(image)) =
    firmware.classify_image_arg("AtomVM-esp32-elixir-v0.7.0", False)
  assert image.version == Some("v0.7.0")
}

pub fn classify_image_arg_custom_repo_basename_test() {
  let assert Ok(firmware.NameArg(image)) =
    firmware.classify_image_arg("custom-board.zip", True)
  assert image.channel == firmware.Custom
}

pub fn classify_image_arg_rejects_unknown_test() {
  let assert Error(firmware.UnrecognizedName(_)) =
    firmware.classify_image_arg("not-an-image", False)
}

pub fn parse_repo_arg_test() {
  let assert Ok("acme/builds") =
    firmware.parse_repo_arg("https://github.com/acme/builds.git")
  let assert Error(firmware.InvalidRepo(_)) = firmware.parse_repo_arg("nope")
}

pub fn compare_bootloader_refuses_newer_board_test() {
  let board = bootloader_with_idf("v5.5.4")
  let image = bootloader_with_idf("v5.4.0")
  let assert Error(firmware.BootloaderNewer(board: "v5.5.4", image: "v5.4.0")) =
    firmware.check_bootloader(board, image)
}

pub fn compare_bootloader_allows_older_or_equal_board_test() {
  let board = bootloader_with_idf("v5.4.0")
  let image = bootloader_with_idf("v5.5.4")
  let assert Ok(firmware.BootloaderOk(..)) =
    firmware.check_bootloader(board, image)
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
