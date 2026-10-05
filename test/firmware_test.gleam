import gleam/option.{None, Some}
import gleeunit
import orbital/internal/firmware

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_name_stable_img_test() {
  let assert Ok(image) =
    firmware.parse_name("AtomVM-esp32s3-elixir-v0.6.6.img")
  assert image.channel == firmware.Stable
  assert image.kind == firmware.Img
  assert image.chip == Some("esp32s3")
  assert image.elixir == Some(True)
}

pub fn parse_name_nightly_zip_test() {
  let assert Ok(image) =
    firmware.parse_name(
      "AtomVM-esp32s3-elixir-nightly-20240101.zip",
    )
  assert image.channel == firmware.Nightly
  assert image.kind == firmware.Zip
}

pub fn parse_name_rejects_uppercase_chip_test() {
  let assert Error(firmware.UnrecognizedName(_)) =
    firmware.parse_name("AtomVM-ESP32S3-elixir-v0.6.6.img")
}

pub fn chip_token_normalises_family_test() {
  assert firmware.chip_token("ESP32-S3") == "esp32s3"
  assert firmware.chip_token("ESP32-C61 (QFN32)") == "esp32c61"
}

pub fn flash_offset_for_known_chips_test() {
  let image =
    firmware.Image(
      name: "local",
      file: Some("local.img"),
      kind: firmware.Img,
      chip: None,
      base_chip: None,
      elixir: None,
      features: [],
      version: None,
      channel: firmware.Local,
      stamp: None,
      path: Some("local.img"),
      img_path: None,
      flash_offset: None,
      url: None,
      size: None,
      sha256: None,
      sha256_url: None,
      tag: None,
      source: Some(firmware.LocalSource),
      published_at: None,
    )
  let assert Ok(0x0) = firmware.flash_offset_for(image, "esp32s3")
  let assert Ok(0x1000) = firmware.flash_offset_for(image, "esp32")
  let assert Ok(0x2000) = firmware.flash_offset_for(image, "esp32p4")
}

pub fn classify_image_arg_path_and_name_test() {
  let assert Ok(firmware.NameArg(image)) =
    firmware.classify_image_arg("AtomVM-esp32-elixir-v0.7.0", False)
  assert image.chip == Some("esp32")

  let assert Ok(firmware.NameArg(image)) =
    firmware.classify_image_arg("custom-board.zip", True)
  assert image.channel == firmware.Custom

  let assert Error(firmware.UnrecognizedName(_)) =
    firmware.classify_image_arg("not-an-image", False)
}

pub fn parse_repo_arg_test() {
  let assert Ok("acme/builds") =
    firmware.parse_repo_arg("https://github.com/acme/builds.git")
  let assert Error(firmware.InvalidRepo(_)) = firmware.parse_repo_arg("nope")
}

pub fn select_release_image_prefers_elixir_test() {
  let assert Ok(esp32) =
    firmware.parse_name("AtomVM-esp32-elixir-v0.7.0-alpha.1.img")
  let assert Ok(esp32_erl) =
    firmware.parse_name("AtomVM-esp32-v0.7.0-alpha.1.img")
  let images = [esp32_erl, esp32]
  let assert Ok(selected) =
    firmware.select_release_image(images, "v0.7.0-alpha.1", "esp32")
  assert selected.elixir == Some(True)
}

pub fn gitignore_hint_test() {
  assert firmware.gitignore_hint(None) == Some(
    "Tip: add firmware_images/ to .gitignore, e.g.\n  echo '/firmware_images/' >> .gitignore",
  )
  assert firmware.gitignore_hint(Some("firmware_images/\n")) == None
}
