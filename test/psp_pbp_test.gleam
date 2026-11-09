import gleam/bit_array
import gleam/string
import gleeunit
import orbital/internal/psp_pbp
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn read_title_from_fixture_test() {
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  let assert Ok("AtomVM-PSP") = psp_pbp.read_title(pbp)
}

pub fn with_title_shorter_rename_test() {
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  let assert Ok(#(patched, result)) = psp_pbp.with_title(pbp, "lucy_run")
  assert result.title == "lucy_run"
  assert result.truncated == False
  let assert Ok("lucy_run") = psp_pbp.read_title(patched)
  // PBP size unchanged (in-place slot rewrite).
  assert bit_array.byte_size(patched) == bit_array.byte_size(pbp)
}

pub fn with_title_equal_length_test() {
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  // Same byte length as "AtomVM-PSP" (10 chars).
  let assert Ok(#(patched, result)) = psp_pbp.with_title(pbp, "0123456789")
  assert result.title == "0123456789"
  assert result.truncated == False
  let assert Ok("0123456789") = psp_pbp.read_title(patched)
}

pub fn with_title_oversize_truncates_test() {
  let pbp = psp_pbp.test_fixture_pbp("Hi", 8)
  let assert Ok(#(patched, result)) =
    psp_pbp.with_title(pbp, "abcdefghijklmnop")
  assert result.truncated == True
  assert result.max_len == 8
  // max_len 8 → 7 payload bytes + NUL.
  assert result.title == "abcdefg"
  let assert Ok("abcdefg") = psp_pbp.read_title(patched)
}

pub fn with_title_rejects_empty_test() {
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  let assert Error(psp_pbp.EmptyTitle) = psp_pbp.with_title(pbp, "   ")
}

pub fn set_title_file_roundtrip_test() {
  let path = "build/psp-pbp-title-roundtrip.pbp"
  let assert Ok(_) = simplifile.create_directory_all("build")
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  let assert Ok(_) = simplifile.write_bits(path, pbp)

  let assert Ok(result) = psp_pbp.set_title_file(path, "lucy_run")
  assert result.title == "lucy_run"

  let assert Ok(bits) = simplifile.read_bits(path)
  let assert Ok("lucy_run") = psp_pbp.read_title(bits)
}

pub fn with_title_preserves_other_bytes_test() {
  let pbp = psp_pbp.test_fixture_pbp("AtomVM-PSP", 0x80)
  let assert Ok(#(patched, _)) = psp_pbp.with_title(pbp, "x")
  // Magic and trailing icon stub stay intact.
  assert bit_array.slice(patched, 0, 4) == bit_array.slice(pbp, 0, 4)
  let size = bit_array.byte_size(pbp)
  assert bit_array.slice(patched, size - 3, 3)
    == bit_array.slice(pbp, size - 3, 3)
  // Long titles that fit still leave padding zeros in the TITLE slot.
  let assert Ok(#(again, _)) =
    psp_pbp.with_title(patched, string.repeat("a", 40))
  let assert Ok(title) = psp_pbp.read_title(again)
  assert title == string.repeat("a", 40)
}
