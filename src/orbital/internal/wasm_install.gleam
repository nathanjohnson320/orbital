//// `orbital install wasm` orchestration: download AtomVM Node/web WASM
//// runtimes (and optionally atomvmlib) into `firmware_images/`.

import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some, unwrap}
import gleam/result
import gleam_community/ansi
import orbital/internal/wasm_firmware

pub type Options {
  Options(
    env: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    download_only: Bool,
    list_images: Bool,
    with_atomvmlib: Bool,
  )
}

pub type Error {
  Firmware(wasm_firmware.Error)
  Validation(String)
}

pub fn run(options: Options) -> Result(Nil, Error) {
  case options.list_images {
    True -> list_images(options)
    False -> do_install(options)
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    Firmware(reason) -> wasm_firmware.error_message(reason)
    Validation(message) -> message
  }
}

fn list_images(options: Options) -> Result(Nil, Error) {
  use filter <- result.try(case options.env {
    None -> Ok(None)
    Some(env) ->
      wasm_firmware.parse_env(env)
      |> result.map(Some)
      |> result.map_error(Firmware)
  })
  use text <- result.try(
    wasm_firmware.list_images_text(options.repo, filter)
    |> result.map_error(Firmware),
  )
  io.println(text)
  Ok(Nil)
}

fn do_install(options: Options) -> Result(Nil, Error) {
  use runtimes <- result.try(case options.image {
    Some(image) -> {
      use env <- result.try(optional_env(options.env))
      wasm_firmware.resolve_runtime(
        env:,
        image: Some(image),
        version: options.version,
        repo: options.repo,
      )
      |> result.map(fn(runtime) { [runtime] })
      |> result.map_error(Firmware)
    }
    None -> {
      use envs <- result.try(resolve_envs(options.env))
      list.try_map(envs, fn(env) {
        wasm_firmware.resolve_runtime(
          env: Some(env),
          image: None,
          version: options.version,
          repo: options.repo,
        )
        |> result.map_error(Firmware)
      })
    }
  })
  use Nil <- result.try(case options.with_atomvmlib {
    False -> Ok(Nil)
    True -> {
      let version = case runtimes {
        [first, ..] -> Some(first.version)
        [] -> options.version
      }
      wasm_firmware.ensure_atomvmlib(version, options.repo)
      |> result.map(fn(_) { Nil })
      |> result.map_error(Firmware)
    }
  })
  list.each(runtimes, fn(runtime) {
    let path = unwrap(runtime.path, runtime_dir_label(runtime))
    io.println("")
    io.println(ansi.magenta(
      "Successfully cached AtomVM "
      <> wasm_firmware.env_label(runtime.env)
      <> " WASM "
      <> runtime.version,
    ))
    io.println("  " <> path)
  })
  io.println("")
  io.println("Run your project with:")
  io.println("  gleam run -m orbital flash wasm")
  io.println("Or export a browser bundle with:")
  io.println("  gleam run -m orbital flash wasm --env web")
  io.println("")
  let _ = options.download_only
  Ok(Nil)
}

fn resolve_envs(env: Option(String)) -> Result(List(wasm_firmware.Env), Error) {
  case env {
    None -> Ok([wasm_firmware.Node, wasm_firmware.Web])
    Some("all") -> Ok([wasm_firmware.Node, wasm_firmware.Web])
    Some(raw) ->
      wasm_firmware.parse_env(raw)
      |> result.map(fn(e) { [e] })
      |> result.map_error(Firmware)
  }
}

fn optional_env(
  env: Option(String),
) -> Result(Option(wasm_firmware.Env), Error) {
  case env {
    None | Some("all") -> Ok(None)
    Some(raw) ->
      wasm_firmware.parse_env(raw)
      |> result.map(Some)
      |> result.map_error(Firmware)
  }
}

fn runtime_dir_label(runtime: wasm_firmware.Runtime) -> String {
  wasm_firmware.runtime_dir_name(runtime.env, runtime.version)
}
