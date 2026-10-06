import gleam/option.{None}
import gleeunit
import orbital/internal/wasm_firmware

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn parse_env_aliases_test() {
  let assert Ok(wasm_firmware.Node) = wasm_firmware.parse_env("node")
  let assert Ok(wasm_firmware.Node) = wasm_firmware.parse_env("nodejs")
  let assert Ok(wasm_firmware.Web) = wasm_firmware.parse_env("web")
  let assert Ok(wasm_firmware.Web) = wasm_firmware.parse_env("browser")
}

pub fn parse_runtime_dir_name_test() {
  let assert Ok(#(wasm_firmware.Node, "v0.6.6")) =
    wasm_firmware.parse_runtime_dir_name("AtomVM-node-v0.6.6")
  let assert Ok(#(wasm_firmware.Web, "v0.7.0-beta.0")) =
    wasm_firmware.parse_runtime_dir_name("AtomVM-web-v0.7.0-beta.0")
}

pub fn parse_runtime_asset_name_test() {
  let assert Ok(#(wasm_firmware.Node, "v0.6.6", "js")) =
    wasm_firmware.parse_runtime_asset_name("AtomVM-node-v0.6.6.js")
  let assert Ok(#(wasm_firmware.Web, "v0.6.6", "wasm")) =
    wasm_firmware.parse_runtime_asset_name("AtomVM-web-v0.6.6.wasm")
}

pub fn select_env_runtime_test() {
  let node =
    wasm_firmware.Runtime(
      env: wasm_firmware.Node,
      version: "v0.6.6",
      tag: "v0.6.6",
      path: None,
      js_url: None,
      wasm_url: None,
      js_sha256_url: None,
      wasm_sha256_url: None,
      js_size: None,
      wasm_size: None,
      prerelease: False,
    )
  let web = wasm_firmware.Runtime(..node, env: wasm_firmware.Web)
  let assert Ok(selected) =
    wasm_firmware.select_env_runtime([node, web], wasm_firmware.Node, "v0.6.6")
  assert selected.env == wasm_firmware.Node
}

pub fn runtime_dir_name_test() {
  assert wasm_firmware.runtime_dir_name(wasm_firmware.Node, "v0.6.6")
    == "AtomVM-node-v0.6.6"
  assert wasm_firmware.runtime_dir_name(wasm_firmware.Web, "v0.6.6")
    == "AtomVM-web-v0.6.6"
}
