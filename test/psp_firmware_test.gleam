import gleam/option.{None}
import gleeunit
import orbital/internal/psp_firmware

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn is_psp_asset_recognises_eboot_and_zips_test() {
  assert psp_firmware.is_psp_asset("EBOOT.PBP") == True
  assert psp_firmware.is_psp_asset("AtomVM-psp-v0.1.0.zip") == True
  assert psp_firmware.is_psp_asset("hello.uf2") == False
  assert psp_firmware.is_psp_asset("notes.txt") == False
}

pub fn resolve_image_requires_image_or_version_test() {
  let assert Error(psp_firmware.ImageRequired) =
    psp_firmware.resolve_image(image: None, version: None, repo: None)
}
