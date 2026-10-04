import gleam/option.{None}
import gleeunit
import orbital/internal/pico_firmware

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_board_aliases_test() {
  let assert Ok(pico_firmware.Pico) = pico_firmware.parse_board("pico")
  let assert Ok(pico_firmware.PicoW) = pico_firmware.parse_board("pico_w")
  let assert Ok(pico_firmware.PicoW) = pico_firmware.parse_board("picow")
  let assert Ok(pico_firmware.Pico2) = pico_firmware.parse_board("pico2")
  let assert Ok(pico_firmware.Pico2W) = pico_firmware.parse_board("pico2_w")
}

pub fn parse_uf2_name_combined_suffix_test() {
  let assert Ok(#(pico_firmware.PicoW, True, "v0.7.0-beta.0")) =
    pico_firmware.parse_uf2_name("AtomVM-pico_w-combined-v0.7.0-beta.0.uf2")
}

pub fn parse_uf2_name_combined_prefix_test() {
  let assert Ok(#(pico_firmware.Pico, True, "v0.7.0-alpha.1")) =
    pico_firmware.parse_uf2_name("AtomVM-combined-pico-v0.7.0-alpha.1.uf2")
}

pub fn parse_uf2_name_plain_test() {
  let assert Ok(#(pico_firmware.Pico2, False, "v0.6.6")) =
    pico_firmware.parse_uf2_name("AtomVM-pico2-v0.6.6.uf2")
}

pub fn select_board_image_prefers_combined_test() {
  let plain =
    pico_firmware.Image(
      name: "AtomVM-pico-v0.7.0",
      file: "AtomVM-pico-v0.7.0.uf2",
      board: pico_firmware.Pico,
      combined: False,
      version: "v0.7.0",
      tag: "v0.7.0",
      url: None,
      path: None,
      size: None,
      sha256_url: None,
      prerelease: False,
    )
  let combined =
    pico_firmware.Image(
      ..plain,
      name: "AtomVM-pico-combined-v0.7.0",
      file: "AtomVM-pico-combined-v0.7.0.uf2",
      combined: True,
    )
  let assert Ok(selected) =
    pico_firmware.select_board_image(
      [plain, combined],
      pico_firmware.Pico,
      "v0.7.0",
    )
  assert selected.combined == True
}

pub fn default_volume_name_test() {
  assert pico_firmware.default_volume_name(pico_firmware.Pico) == "RPI-RP2"
  assert pico_firmware.default_volume_name(pico_firmware.Pico2W) == "RP2350"
}
