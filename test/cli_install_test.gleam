import gleam/option.{None, Some}
import gleeunit
import orbital/internal/cli.{Install}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn install_help_test() {
  let assert Ok(Install(help: True, ..)) = cli.parse(["install", "--help"])
}

pub fn install_defaults_test() {
  let assert Ok(Install(
    image:,
    version:,
    repo:,
    update:,
    download_only:,
    list_images:,
    chip:,
    baud:,
    port:,
    help: False,
  )) = cli.parse(["install"])

  assert image == None
  assert version == None
  assert repo == None
  assert update == False
  assert download_only == False
  assert list_images == False
  assert chip == None
  assert baud == None
  assert port == None
}

pub fn install_all_flags_test() {
  let assert Ok(Install(
    image:,
    version: None,
    repo:,
    update: True,
    download_only: False,
    list_images: False,
    chip: None,
    baud:,
    port:,
    help: False,
  )) =
    cli.parse([
      "install",
      "--image",
      "./fw.img",
      "--repo",
      "acme/builds",
      "--update",
      "--baud",
      "115200",
      "--port",
      "/dev/ttyACM0",
    ])

  assert image == Some("./fw.img")
  assert repo == Some("acme/builds")
  assert baud == Some(115_200)
  assert port == Some("/dev/ttyACM0")
}

pub fn install_rejects_image_and_version_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse(["install", "--image", "x.img", "--version", "v0.6.6"])
}

pub fn install_rejects_list_images_with_update_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse(["install", "--list-images", "--update"])
}

pub fn install_rejects_download_only_with_update_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse(["install", "--download-only", "--update"])
}

pub fn install_rejects_chip_without_list_or_download_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse(["install", "--chip", "esp32s3"])
}

pub fn install_allows_chip_with_list_images_test() {
  let assert Ok(Install(list_images: True, chip:, ..)) =
    cli.parse(["install", "--list-images", "--chip", "esp32s3"])
  assert chip == Some("esp32s3")
}

pub fn install_allows_chip_with_download_only_test() {
  let assert Ok(Install(download_only: True, chip:, image: None, ..)) =
    cli.parse(["install", "--download-only", "--chip", "esp32s3"])
  assert chip == Some("esp32s3")
}

pub fn install_rejects_chip_with_download_only_and_image_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse([
      "install",
      "--download-only",
      "--image",
      "AtomVM-esp32-elixir-v0.6.6",
      "--chip",
      "esp32",
    ])
}

pub fn install_esp32_platform_alias_test() {
  let assert Ok(Install(list_images: True, ..)) =
    cli.parse(["install", "esp32", "--list-images"])
}
