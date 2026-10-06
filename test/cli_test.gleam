import gleam/option.{None, Some}
import gleeunit
import orbital/internal/cli.{
  EraseFlash, Esp32, Expand, Flash, Info, InstallWasm, Monitor, Pico, Uf2create,
  Wasm,
}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn esp32_flash_starts_at_the_current_partition_test() {
  let assert Ok(Flash(platform:, help: False)) = cli.parse(["flash", "esp32"])

  let assert Esp32(port:, baud:, offset:, dry_run:) = platform
  assert port == None
  assert baud == None
  assert offset == None
  assert dry_run == False
}

pub fn esp32_flash_accepts_an_explicit_port_test() {
  let assert Ok(Flash(platform: Esp32(port:, ..), help: False)) =
    cli.parse(["flash", "esp32", "--port", "/dev/ttyACM0"])

  assert port == Some("/dev/ttyACM0")
}

pub fn esp32_flash_offset_can_be_overridden_test() {
  let assert Ok(Flash(platform: Esp32(offset:, ..), help: False)) =
    cli.parse(["flash", "esp32", "--offset", "0x210000"])

  assert offset == Some("0x210000")
}

pub fn esp32_flash_rejects_a_bad_offset_test() {
  let assert Error(_) = cli.parse(["flash", "esp32", "--offset", "main"])
}

pub fn monitor_defaults_test() {
  let assert Ok(Monitor(port:, baud:, timeout:, reset: True, help: False)) =
    cli.parse(["monitor"])

  assert port == None
  assert baud == None
  assert timeout == None
}

pub fn monitor_flags_test() {
  let assert Ok(Monitor(port:, baud:, timeout:, reset: False, help: False)) =
    cli.parse([
      "monitor",
      "--port",
      "/dev/ttyACM0",
      "--baud",
      "9600",
      "--timeout",
      "0",
      "--no-reset",
    ])

  assert port == Some("/dev/ttyACM0")
  assert baud == Some(9600)
  assert timeout == Some(0)
}

pub fn expand_defaults_test() {
  let assert Ok(Expand(port:, help: False)) = cli.parse(["expand"])

  assert port == None
}

pub fn expand_accepts_an_explicit_port_test() {
  let assert Ok(Expand(port:, help: False)) =
    cli.parse(["expand", "--port", "/dev/ttyACM0"])

  assert port == Some("/dev/ttyACM0")
}

pub fn expand_help_test() {
  let assert Ok(Expand(help: True, ..)) = cli.parse(["expand", "--help"])
}

pub fn info_defaults_test() {
  let assert Ok(Info(help: False)) = cli.parse(["info"])
}

pub fn info_help_test() {
  let assert Ok(Info(help: True)) = cli.parse(["info", "--help"])
}

pub fn erase_flash_defaults_test() {
  let assert Ok(EraseFlash(port:, help: False)) = cli.parse(["erase-flash"])

  assert port == None
}

pub fn erase_flash_accepts_an_explicit_port_test() {
  let assert Ok(EraseFlash(port:, help: False)) =
    cli.parse(["erase-flash", "--port", "/dev/ttyACM0"])

  assert port == Some("/dev/ttyACM0")
}

pub fn erase_flash_help_test() {
  let assert Ok(EraseFlash(help: True, ..)) =
    cli.parse(["erase-flash", "--help"])
}

pub fn pico_flash_defaults_test() {
  let assert Ok(Flash(platform:, help: False)) = cli.parse(["flash", "pico"])

  let assert Pico(pico_path:, pico_reset:, picotool:, app_start:, family_id:) =
    platform
  assert pico_path == None
  assert pico_reset == None
  assert picotool == None
  assert app_start == None
  assert family_id == None
}

pub fn pico_flash_flags_test() {
  let assert Ok(Flash(
    platform: Pico(pico_path:, pico_reset:, picotool:, app_start:, family_id:),
    help: False,
  )) =
    cli.parse([
      "flash",
      "pico",
      "--pico-path",
      "/mnt/RPI-RP2",
      "--pico-reset",
      "/dev/ttyACM0",
      "--picotool",
      "/usr/bin/picotool",
      "--app-start",
      "0x10180000",
      "--family-id",
      "universal",
    ])

  assert pico_path == Some("/mnt/RPI-RP2")
  assert pico_reset == Some("/dev/ttyACM0")
  assert picotool == Some("/usr/bin/picotool")
  assert app_start == Some("0x10180000")
  assert family_id == Some("universal")
}

pub fn pico_flash_rejects_bad_family_id_test() {
  let assert Error(_) = cli.parse(["flash", "pico", "--family-id", "esp32"])
}

pub fn pico_flash_rejects_bad_app_start_test() {
  let assert Error(_) = cli.parse(["flash", "pico", "--app-start", "main"])
}

pub fn uf2create_defaults_test() {
  let assert Ok(Uf2create(output_file:, app_start:, family_id:, help: False)) =
    cli.parse(["uf2create"])

  assert output_file == None
  assert app_start == None
  assert family_id == None
}

pub fn uf2create_flags_test() {
  let assert Ok(Uf2create(output_file:, app_start:, family_id:, help: False)) =
    cli.parse([
      "uf2create",
      "--output-file",
      "app.uf2",
      "--app-start",
      "0x10180000",
      "--family-id",
      "data",
    ])

  assert output_file == Some("app.uf2")
  assert app_start == Some("0x10180000")
  assert family_id == Some("data")
}

pub fn uf2create_help_test() {
  let assert Ok(Uf2create(help: True, ..)) = cli.parse(["uf2create", "--help"])
}

pub fn wasm_flash_defaults_test() {
  let assert Ok(Flash(platform:, help: False)) = cli.parse(["flash", "wasm"])

  let assert Wasm(env:, image:, version:, repo:, output_dir:, atomvmlib:) =
    platform
  assert env == None
  assert image == None
  assert version == None
  assert repo == None
  assert output_dir == None
  assert atomvmlib == None
}

pub fn wasm_flash_flags_test() {
  let assert Ok(Flash(
    platform: Wasm(env:, image:, version:, repo:, output_dir:, atomvmlib:),
    help: False,
  )) =
    cli.parse([
      "flash",
      "wasm",
      "--env",
      "web",
      "--version",
      "v0.6.6",
      "--repo",
      "acme/builds",
      "--output-dir",
      "./dist",
      "--atomvmlib",
      "./atomvmlib.avm",
    ])

  assert env == Some("web")
  assert image == None
  assert version == Some("v0.6.6")
  assert repo == Some("acme/builds")
  assert output_dir == Some("./dist")
  assert atomvmlib == Some("./atomvmlib.avm")
}

pub fn install_wasm_defaults_test() {
  let assert Ok(InstallWasm(
    env:,
    image:,
    version:,
    repo:,
    download_only: False,
    list_images: False,
    with_atomvmlib: True,
    help: False,
  )) = cli.parse(["install", "wasm"])

  assert env == None
  assert image == None
  assert version == None
  assert repo == None
}

pub fn install_wasm_flags_test() {
  let assert Ok(InstallWasm(
    env:,
    version:,
    list_images: False,
    with_atomvmlib: False,
    help: False,
    ..,
  )) =
    cli.parse([
      "install",
      "wasm",
      "--env",
      "node",
      "--version",
      "v0.6.6",
      "--no-atomvmlib",
    ])

  assert env == Some("node")
  assert version == Some("v0.6.6")
}

pub fn install_wasm_list_images_test() {
  let assert Ok(InstallWasm(list_images: True, env:, ..)) =
    cli.parse(["install", "wasm", "--list-images", "--env", "web"])
  assert env == Some("web")
}

pub fn install_wasm_rejects_image_and_version_test() {
  let assert Error(cli.ConflictingFlags(_)) =
    cli.parse([
      "install",
      "wasm",
      "--image",
      "AtomVM-node-v0.6.6",
      "--version",
      "v0.6.6",
    ])
}
