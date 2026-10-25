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
