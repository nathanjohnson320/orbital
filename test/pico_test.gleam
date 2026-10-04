import gleam/option.{None, Some}
import gleeunit
import orbital/internal/pico
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_family_id_accepts_exatomvm_values_test() {
  let assert Ok(pico.Universal) = pico.parse_family_id("universal")
  let assert Ok(pico.Rp2040) = pico.parse_family_id("rp2040")
  let assert Ok(pico.Data) = pico.parse_family_id("data")
  let assert Ok(pico.Rp2350ArmS) = pico.parse_family_id(":rp2350_arm_s")
  let assert Ok(pico.Rp2350Riscv) = pico.parse_family_id("rp2350_riscv")
  let assert Ok(pico.Rp2350ArmNs) = pico.parse_family_id("rp2350_arm_ns")
  let assert Ok(pico.Absolute) = pico.parse_family_id("absolute")
}

pub fn parse_family_id_rejects_unknown_values_test() {
  let assert Error(pico.UnsupportedFamilyId("esp32")) =
    pico.parse_family_id("esp32")
}

pub fn parse_app_start_accepts_hex_and_decimal_test() {
  let assert Ok(0x10180000) = pico.parse_app_start("0x10180000")
  let assert Ok(0x10180000) = pico.parse_app_start("16#10180000")
  let assert Ok(16) = pico.parse_app_start("16")
}

pub fn parse_app_start_rejects_junk_test() {
  let assert Error(pico.InvalidAppStart("main")) = pico.parse_app_start("main")
}

pub fn resolve_defaults_match_exatomvm_test() {
  let assert Ok(0x10180000) = pico.resolve_app_start(None)
  let assert Ok(pico.Universal) = pico.resolve_family_id(None)
  let assert Ok(0x200000) = pico.resolve_app_start(Some("0x200000"))
  let assert Ok(pico.Data) = pico.resolve_family_id(Some("data"))
}

pub fn create_uf2_writes_a_file_test() {
  let assert Ok(_) = simplifile.create_directory_all("build")
  let avm = "build/test-empty.avm"
  let uf2 = "build/test-empty.uf2"
  let assert Ok(_) = simplifile.write_bits(avm, <<0, 1, 2, 3, 4, 5, 6, 7>>)
  let _ = simplifile.delete(uf2)

  let assert Ok(Nil) =
    pico.create_uf2(
      avm_path: avm,
      uf2_path: uf2,
      options: pico.Uf2Options(
        app_start: Some("0x10180000"),
        family_id: Some("rp2040"),
      ),
    )

  let assert Ok(True) = simplifile.is_file(uf2)
  let assert Ok(bits) = simplifile.read_bits(uf2)
  // UF2 blocks begin with the magic "UF2\n"
  assert bits != <<>>
  assert string_starts_with_uf2(bits)
}

fn string_starts_with_uf2(bits: BitArray) -> Bool {
  case bits {
    <<0x55, 0x46, 0x32, 0x0A, _rest:bits>> -> True
    _ -> False
  }
}
