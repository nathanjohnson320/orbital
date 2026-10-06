//// Run or export a Gleam `.avm` against AtomVM's Emscripten (WASM) builds.
////
//// - Node: `node AtomVM.js app.avm atomvmlib.avm`
//// - Web: copy runtime + AVM + a small `index.html` that loads the module
////   (host must send COOP/COEP headers; see AtomVM docs).

import filepath
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import orbital/internal/executable
import orbital/internal/wasm_firmware
import simplifile

pub type FlashOptions {
  FlashOptions(
    env: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    output_dir: Option(String),
    atomvmlib: Option(String),
  )
}

pub type Error {
  Firmware(wasm_firmware.Error)
  MissingNode
  NodeFailed(status: Int)
  CannotRunNode
  FileError(String)
  Validation(String)
}

pub fn error_message(error: Error) -> String {
  case error {
    Firmware(reason) -> wasm_firmware.error_message(reason)
    MissingNode ->
      "To run AtomVM WASM on Node.js, `node` needs to be installed and on your PATH."
    NodeFailed(status:) ->
      "AtomVM (node) exited with status " <> int.to_string(status) <> "."
    CannotRunNode -> "I couldn't start `node` to run the AtomVM WASM runtime."
    FileError(reason) -> reason
    Validation(message) -> message
  }
}

/// Build artefacts are supplied by the caller (`avm_path`). This resolves the
/// runtime and either runs it under Node or writes a browser bundle.
pub fn flash(avm_path: String, options: FlashOptions) -> Result(Nil, Error) {
  use env <- result.try(resolve_env(options.env))
  use runtime <- result.try(
    wasm_firmware.resolve_runtime(
      env: Some(env),
      image: options.image,
      version: options.version,
      repo: options.repo,
    )
    |> result.map_error(Firmware),
  )
  use runtime_dir <- result.try(case runtime.path {
    Some(path) -> Ok(path)
    None -> Error(Firmware(wasm_firmware.FileError("Runtime has no path")))
  })
  use lib_path <- result.try(resolve_atomvmlib(options, runtime.version))

  case env {
    wasm_firmware.Node -> run_node(runtime_dir, avm_path, lib_path)
    wasm_firmware.Web ->
      export_web(
        runtime_dir,
        avm_path,
        lib_path,
        option.unwrap(options.output_dir, "wasm_out"),
      )
  }
}

fn resolve_env(value: Option(String)) -> Result(wasm_firmware.Env, Error) {
  case value {
    None -> Ok(wasm_firmware.Node)
    Some(raw) ->
      wasm_firmware.parse_env(raw)
      |> result.map_error(Firmware)
  }
}

fn resolve_atomvmlib(
  options: FlashOptions,
  runtime_version: String,
) -> Result(Option(String), Error) {
  case options.atomvmlib {
    Some(path) ->
      case simplifile.is_file(path) {
        Ok(True) -> Ok(Some(path))
        _ -> Error(FileError("atomvmlib not found at " <> path))
      }
    None ->
      case runtime_version {
        "local" -> Ok(None)
        version ->
          wasm_firmware.ensure_atomvmlib(Some(version), options.repo)
          |> result.map(Some)
          |> result.map_error(Firmware)
      }
  }
}

fn run_node(
  runtime_dir: String,
  avm_path: String,
  lib_path: Option(String),
) -> Result(Nil, Error) {
  use node <- result.try(
    executable.find("node")
    |> result.replace_error(MissingNode),
  )
  let js = wasm_firmware.js_path(runtime_dir)
  let args = case lib_path {
    Some(lib) -> [js, avm_path, lib]
    None -> [js, avm_path]
  }
  io.println(
    "Running: node "
    <> string.join(list.map(args, fn(a) { "'" <> a <> "'" }), with: " "),
  )
  case run_streaming(node, ".", args) {
    Ok(0) -> {
      io.println(ansi.magenta("⚛️  ran your project on AtomVM WASM (Node.js)!"))
      Ok(Nil)
    }
    Ok(status) -> Error(NodeFailed(status))
    Error(_) -> Error(CannotRunNode)
  }
}

fn export_web(
  runtime_dir: String,
  avm_path: String,
  lib_path: Option(String),
  output_dir: String,
) -> Result(Nil, Error) {
  use Nil <- result.try(
    simplifile.create_directory_all(output_dir)
    |> result.map_error(fn(_) {
      FileError("Could not create output directory " <> output_dir)
    }),
  )
  use Nil <- result.try(copy_file(
    wasm_firmware.js_path(runtime_dir),
    filepath.join(output_dir, "AtomVM.js"),
  ))
  use Nil <- result.try(copy_file(
    wasm_firmware.wasm_path(runtime_dir),
    filepath.join(output_dir, "AtomVM.wasm"),
  ))
  let avm_name = filepath.base_name(avm_path)
  use Nil <- result.try(copy_file(avm_path, filepath.join(output_dir, avm_name)))
  use Nil <- result.try(case lib_path {
    None -> Ok(Nil)
    Some(lib) -> copy_file(lib, filepath.join(output_dir, filepath.base_name(lib)))
  })
  let html = web_index_html(avm_name, lib_path)
  use Nil <- result.try(
    simplifile.write(to: filepath.join(output_dir, "index.html"), contents: html)
    |> result.map_error(fn(_) {
      FileError("Could not write " <> filepath.join(output_dir, "index.html"))
    }),
  )
  io.println("")
  io.println(ansi.magenta("⚛️  wrote AtomVM WASM browser bundle to " <> output_dir <> "/"))
  io.println(
    "Serve it over localhost/HTTPS with Cross-Origin-Opener-Policy: same-origin",
  )
  io.println(
    "and Cross-Origin-Embedder-Policy: require-corp (AtomVM needs SharedArrayBuffer).",
  )
  Ok(Nil)
}

fn web_index_html(avm_name: String, lib_path: Option(String)) -> String {
  let arguments = case lib_path {
    Some(lib) ->
      "[\"./"
      <> avm_name
      <> "\", \"./"
      <> filepath.base_name(lib)
      <> "\"]"
    None -> "[\"./" <> avm_name <> "\"]"
  }
  "<!doctype html>
<html lang=\"en\">
  <head>
    <meta charset=\"utf-8\" />
    <title>AtomVM WASM</title>
  </head>
  <body>
    <h1>AtomVM</h1>
    <p>Check the browser console for application output.</p>
    <script>
      var Module = {
        arguments: "
  <> arguments
  <> ",
      };
    </script>
    <script src=\"./AtomVM.js\"></script>
  </body>
</html>
"
}

fn copy_file(from: String, to: String) -> Result(Nil, Error) {
  use bits <- result.try(
    simplifile.read_bits(from)
    |> result.map_error(fn(_) { FileError("Could not read " <> from) }),
  )
  simplifile.write_bits(to:, bits:)
  |> result.map_error(fn(_) { FileError("Could not write " <> to) })
}

@external(erlang, "orbital_ffi", "run_streaming_executable")
fn run_streaming(
  executable_path path: executable.ExecutablePath,
  working_directory directory: String,
  command_line_arguments arguments: List(String),
) -> Result(Int, Nil)
