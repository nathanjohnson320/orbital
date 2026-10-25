import gleam/option.{None, Some}
import gleeunit
import orbital/internal/psp
import simplifile

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn normalize_game_path_keeps_atomvm_folder_test() {
  assert psp.normalize_game_path(
      "/home/me/.config/ppsspp/PSP/GAME/ATOMVM",
      "ATOMVM",
    )
    == "/home/me/.config/ppsspp/PSP/GAME/ATOMVM"

  assert psp.normalize_game_path(
      "/home/me/.config/ppsspp/PSP/GAME/ATOMVM/",
      "ATOMVM",
    )
    == "/home/me/.config/ppsspp/PSP/GAME/ATOMVM"
}

pub fn normalize_game_path_appends_under_game_test() {
  assert psp.normalize_game_path("/home/me/.config/ppsspp/PSP/GAME", "ATOMVM")
    == "/home/me/.config/ppsspp/PSP/GAME/ATOMVM"
}

pub fn normalize_game_path_appends_under_memstick_root_test() {
  assert psp.normalize_game_path("/media/stick", "ATOMVM")
    == "/media/stick/PSP/GAME/ATOMVM"
}

pub fn install_and_flash_roundtrip_test() {
  let assert Ok(_) = simplifile.create_directory_all("build/psp-test-stick")
  let stick = "build/psp-test-stick"
  let eboot_src = "build/psp-test-eboot.PBP"
  let avm_src = "build/psp-test-app.avm"
  let assert Ok(_) = simplifile.write_bits(eboot_src, <<"EBOOT-FAKE":utf8>>)
  let assert Ok(_) = simplifile.write_bits(avm_src, <<"AVM-FAKE":utf8>>)

  let assert Ok(game_path) =
    psp.install_eboot(
      eboot_src,
      psp.InstallOptions(psp_path: Some(stick), game_dir: None),
    )
  assert game_path == stick <> "/PSP/GAME/ATOMVM"
  let assert Ok(True) = simplifile.is_file(game_path <> "/EBOOT.PBP")

  let assert Ok(dest) =
    psp.flash_avm(
      avm_src,
      psp.FlashOptions(psp_path: Some(game_path), game_dir: None),
    )
  assert dest == game_path <> "/app.avm"
  let assert Ok(True) = simplifile.is_file(dest)

  let assert Ok(bits) = simplifile.read_bits(dest)
  assert bits == <<"AVM-FAKE":utf8>>
}

pub fn flash_requires_eboot_test() {
  let assert Ok(_) = simplifile.create_directory_all("build/psp-empty-game")
  let game = "build/psp-empty-game/ATOMVM"
  let assert Ok(_) = simplifile.create_directory_all(game)
  let avm_src = "build/psp-missing-eboot.avm"
  let assert Ok(_) = simplifile.write_bits(avm_src, <<"x":utf8>>)

  let assert Error(psp.EbootMissing(_)) =
    psp.flash_avm(
      avm_src,
      psp.FlashOptions(psp_path: Some(game), game_dir: Some("ATOMVM")),
    )
}

pub fn resolve_game_path_uses_override_test() {
  let assert Ok(path) =
    psp.resolve_game_path(Some("/tmp/stick"), Some("ATOMVM"))
  assert path == "/tmp/stick/PSP/GAME/ATOMVM"
}
