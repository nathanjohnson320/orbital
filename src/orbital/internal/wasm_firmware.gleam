//// AtomVM WebAssembly (Emscripten) runtime discovery and download.
////
//// ExAtomVM has no WASM tasks — AtomVM ships separate Node and browser
//// builds (`AtomVM-node-*.js`/`.wasm`, `AtomVM-web-*.js`/`.wasm`). The JS
//// loader always looks for `AtomVM.wasm` beside the script, so Orbital
//// caches each runtime under `firmware_images/AtomVM-<env>-<version>/`
//// with stable `AtomVM.js` + `AtomVM.wasm` names. `atomvmlib` is cached
//// next to those directories for use when running on Node.

import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import simplifile

const atomvm_releases = "https://api.github.com/repos/atomvm/AtomVM/releases"

const cache_dir_name = "firmware_images"

const page_size = 15

const user_agent = "orbital-firmware/1.0 (+https://github.com/nathanjohnson320/orbital)"

pub type Env {
  Node
  Web
}

/// A downloaded (or remote) Node/web AtomVM runtime pair.
pub type Runtime {
  Runtime(
    env: Env,
    version: String,
    tag: String,
    /// Directory containing `AtomVM.js` and `AtomVM.wasm`.
    path: Option(String),
    js_url: Option(String),
    wasm_url: Option(String),
    js_sha256_url: Option(String),
    wasm_sha256_url: Option(String),
    js_size: Option(Int),
    wasm_size: Option(Int),
    prerelease: Bool,
  )
}

pub type Error {
  UnknownEnv(String)
  EnvRequired
  NoRuntime(env: String, tag: String)
  UnknownRuntime(String)
  ReleaseNotFound(String)
  Network(String)
  FileError(String)
  Sha256Mismatch(file: String)
}

pub fn parse_env(value: String) -> Result(Env, Error) {
  case string.lowercase(string.trim(value)) {
    "node" | "nodejs" -> Ok(Node)
    "web" | "browser" -> Ok(Web)
    other -> Error(UnknownEnv(other))
  }
}

pub fn env_token(env: Env) -> String {
  case env {
    Node -> "node"
    Web -> "web"
  }
}

pub fn env_label(env: Env) -> String {
  case env {
    Node -> "Node.js"
    Web -> "browser (web)"
  }
}

pub fn error_message(error: Error) -> String {
  case error {
    UnknownEnv(value) ->
      "Unknown WASM env '" <> value <> "'. Use node, web, or all."
    EnvRequired -> "Pass --env node|web|all (or --image / --list-images)."
    NoRuntime(env:, tag:) ->
      "No AtomVM " <> env <> " WASM runtime in release " <> tag <> "."
    UnknownRuntime(name) -> "Unknown WASM runtime '" <> name <> "'."
    ReleaseNotFound(tag) -> "AtomVM release '" <> tag <> "' was not found."
    Network(reason) -> reason
    FileError(reason) -> reason
    Sha256Mismatch(file:) -> "SHA256 mismatch for downloaded file " <> file
  }
}

/// Absolute path to `AtomVM.js` inside a cached runtime directory.
pub fn js_path(runtime_dir: String) -> String {
  filepath.join(runtime_dir, "AtomVM.js")
}

/// Absolute path to `AtomVM.wasm` inside a cached runtime directory.
pub fn wasm_path(runtime_dir: String) -> String {
  filepath.join(runtime_dir, "AtomVM.wasm")
}

pub fn runtime_dir_name(env: Env, version: String) -> String {
  "AtomVM-" <> env_token(env) <> "-" <> version
}

/// List Node/web runtimes from AtomVM releases (+ optional custom repo).
pub fn list_images_text(
  repo: Option(String),
  env_filter: Option(Env),
) -> Result(String, Error) {
  use runtimes <- result.try(list_remote_runtimes(repo))
  let runtimes = case env_filter {
    None -> runtimes
    Some(env) -> list.filter(runtimes, fn(r) { r.env == env })
  }
  let cached = list_cached_runtimes()
  let remote_block = render_runtime_lines(runtimes)
  let local_block = case cached {
    [] -> ""
    _ ->
      "\nCached locally:\n"
      <> string.join(
        list.map(cached, fn(r) {
          "  "
          <> runtime_dir_name(r.env, r.version)
          <> case r.path {
            Some(path) -> "  (" <> path <> ")"
            None -> ""
          }
        }),
        with: "\n",
      )
  }
  Ok(
    "AtomVM WebAssembly runtimes (Node.js / browser):\n"
    <> remote_block
    <> local_block
    <> "\n\nInstall with:\n  gleam run -m orbital install wasm --env node\n"
    <> "  gleam run -m orbital install wasm --env web\n",
  )
}

/// Resolve a Node or web runtime: local directory, published name, or env+version.
pub fn resolve_runtime(
  env env: Option(Env),
  image image: Option(String),
  version version: Option(String),
  repo repo: Option(String),
) -> Result(Runtime, Error) {
  case image {
    Some(path_or_name) ->
      case is_runtime_dir(path_or_name) {
        True -> local_runtime_dir(path_or_name, env)
        False -> ensure_named(path_or_name, repo)
      }
    None ->
      case env {
        None -> Error(EnvRequired)
        Some(env) -> ensure_env_release(env, version, repo)
      }
  }
}

pub fn ensure_env_release(
  env: Env,
  version: Option(String),
  repo: Option(String),
) -> Result(Runtime, Error) {
  case version {
    Some(_) -> {
      use release <- result.try(fetch_release(repo, version))
      use selected <- result.try(select_env_runtime(
        release_runtimes(release),
        env,
        release.tag_name,
      ))
      ensure_cached(selected)
    }
    None -> {
      case fetch_release(repo, None) {
        Ok(release) ->
          case
            select_env_runtime(release_runtimes(release), env, release.tag_name)
          {
            Ok(selected) -> ensure_cached(selected)
            Error(_) -> ensure_env_from_listing(env, repo)
          }
        Error(_) -> ensure_env_from_listing(env, repo)
      }
    }
  }
}

/// Ensure `atomvmlib-<version>.avm` is cached; returns its path.
pub fn ensure_atomvmlib(
  version: Option(String),
  repo: Option(String),
) -> Result(String, Error) {
  use release <- result.try(fetch_release(repo, version))
  case find_atomvmlib_asset(release) {
    None ->
      Error(FileError(
        "Release " <> release.tag_name <> " has no atomvmlib-*.avm asset.",
      ))
    Some(asset) -> {
      use Nil <- result.try(
        simplifile.create_directory_all(cache_dir_name)
        |> result.map_error(fn(_) {
          FileError("Could not create " <> cache_dir_name)
        }),
      )
      let path = filepath.join(cache_dir_name, asset.name)
      case simplifile.is_file(path) {
        Ok(True) -> {
          io.println("Using cached " <> path)
          Ok(path)
        }
        _ -> {
          io.println("Downloading " <> asset.name <> "…")
          use data <- result.try(download_verified_url(
            asset.url,
            asset.sha256_url,
            asset.name,
          ))
          use Nil <- result.try(write_atomically(path, data))
          print_gitignore_hint()
          Ok(path)
        }
      }
    }
  }
}

fn ensure_env_from_listing(
  env: Env,
  repo: Option(String),
) -> Result(Runtime, Error) {
  use runtimes <- result.try(list_remote_runtimes(repo))
  let for_env = list.filter(runtimes, fn(r) { r.env == env })
  case for_env {
    [runtime, ..] -> ensure_cached(runtime)
    [] -> Error(NoRuntime(env: env_token(env), tag: "recent releases"))
  }
}

fn ensure_named(name: String, repo: Option(String)) -> Result(Runtime, Error) {
  let wanted = string.lowercase(stem_name(name))
  case find_cached_by_name(wanted) {
    Some(runtime) -> Ok(runtime)
    None -> {
      use runtimes <- result.try(list_remote_runtimes(repo))
      case
        list.find(runtimes, fn(r) {
          string.lowercase(runtime_dir_name(r.env, r.version)) == wanted
          || string.lowercase("AtomVM-" <> env_token(r.env) <> "-" <> r.version)
          == wanted
        })
      {
        Ok(runtime) -> ensure_cached(runtime)
        Error(Nil) -> Error(UnknownRuntime(name))
      }
    }
  }
}

fn local_runtime_dir(path: String, env: Option(Env)) -> Result(Runtime, Error) {
  let js = js_path(path)
  let wasm = wasm_path(path)
  use Nil <- result.try(case simplifile.is_file(js) {
    Ok(True) -> Ok(Nil)
    _ -> Error(FileError("Missing AtomVM.js in " <> path))
  })
  use Nil <- result.try(case simplifile.is_file(wasm) {
    Ok(True) -> Ok(Nil)
    _ -> Error(FileError("Missing AtomVM.wasm in " <> path))
  })
  let base = filepath.base_name(path)
  case parse_runtime_dir_name(base) {
    Ok(#(parsed_env, version)) ->
      Ok(Runtime(
        env: parsed_env,
        version:,
        tag: version,
        path: Some(path),
        js_url: None,
        wasm_url: None,
        js_sha256_url: None,
        wasm_sha256_url: None,
        js_size: None,
        wasm_size: None,
        prerelease: string.contains(version, "-"),
      ))
    Error(_) ->
      case env {
        Some(env) ->
          Ok(Runtime(
            env:,
            version: "local",
            tag: "local",
            path: Some(path),
            js_url: None,
            wasm_url: None,
            js_sha256_url: None,
            wasm_sha256_url: None,
            js_size: None,
            wasm_size: None,
            prerelease: False,
          ))
        None ->
          Error(FileError(
            "Could not infer WASM env from '"
            <> base
            <> "'. Pass --env node|web.",
          ))
      }
  }
}

pub fn select_env_runtime(
  runtimes: List(Runtime),
  env: Env,
  tag: String,
) -> Result(Runtime, Error) {
  case list.find(runtimes, fn(r) { r.env == env }) {
    Ok(runtime) -> Ok(runtime)
    Error(Nil) -> Error(NoRuntime(env: env_token(env), tag:))
  }
}

/// Parse `AtomVM-node-v0.6.6` / `AtomVM-web-v0.7.0-beta.0` directory names.
pub fn parse_runtime_dir_name(name: String) -> Result(#(Env, String), Error) {
  let parts = string.split(name, on: "-")
  case parts {
    ["AtomVM", env_token, ..version_parts]
    | ["atomvm", env_token, ..version_parts] -> {
      use env <- result.try(parse_env(env_token))
      case version_parts {
        [] -> Error(UnknownRuntime(name))
        parts -> {
          let version = string.join(parts, with: "-")
          case string.starts_with(version, "v") {
            True -> Ok(#(env, version))
            False -> Error(UnknownRuntime(name))
          }
        }
      }
    }
    _ -> Error(UnknownRuntime(name))
  }
}

/// Parse release asset names `AtomVM-node-v0.6.6.js` / `.wasm`.
pub fn parse_runtime_asset_name(
  file: String,
) -> Result(#(Env, String, String), Error) {
  let lower = string.lowercase(file)
  let #(ext, stem) = case string.ends_with(lower, ".js") {
    True -> #("js", string.drop_end(file, 3))
    False ->
      case string.ends_with(lower, ".wasm") {
        True -> #("wasm", string.drop_end(file, 5))
        False -> #("", file)
      }
  }
  case ext {
    "" -> Error(UnknownRuntime(file))
    kind -> {
      use #(env, version) <- result.try(parse_runtime_dir_name(stem))
      Ok(#(env, version, kind))
    }
  }
}

// --- Listing / download ------------------------------------------------------

type Release {
  Release(tag_name: String, draft: Bool, prerelease: Bool, assets: List(Asset))
}

type Asset {
  Asset(name: String, url: String, size: Option(Int))
}

type AtomvmlibAsset {
  AtomvmlibAsset(name: String, url: String, sha256_url: Option(String))
}

fn list_remote_runtimes(repo: Option(String)) -> Result(List(Runtime), Error) {
  let url = case repo {
    Some(repo) ->
      "https://api.github.com/repos/"
      <> repo
      <> "/releases?per_page="
      <> int.to_string(page_size)
    None -> atomvm_releases <> "?per_page=" <> int.to_string(page_size)
  }
  use releases <- result.try(fetch_json_list(url))
  Ok(
    releases
    |> list.filter(fn(r) { !r.draft })
    |> list.flat_map(release_runtimes),
  )
}

fn release_runtimes(release: Release) -> List(Runtime) {
  let sidecars =
    list.filter_map(release.assets, fn(asset) {
      case string.ends_with(asset.name, ".sha256") {
        True -> Ok(#(string.drop_end(asset.name, 7), asset.url))
        False -> Error(Nil)
      }
    })

  let parsed =
    list.filter_map(release.assets, fn(asset) {
      case parse_runtime_asset_name(asset.name) {
        Error(_) -> Error(Nil)
        Ok(#(env, version, kind)) -> Ok(#(env, version, kind, asset))
      }
    })

  // Group js+wasm pairs by env+version.
  let keys =
    parsed
    |> list.map(fn(entry) {
      let #(env, version, _, _) = entry
      #(env, version)
    })
    |> list.unique

  list.filter_map(keys, fn(key) {
    let #(env, version) = key
    let js =
      list.find(parsed, fn(entry) {
        let #(e, v, kind, _) = entry
        e == env && v == version && kind == "js"
      })
    let wasm =
      list.find(parsed, fn(entry) {
        let #(e, v, kind, _) = entry
        e == env && v == version && kind == "wasm"
      })
    case js, wasm {
      Ok(#(_, _, _, js_asset)), Ok(#(_, _, _, wasm_asset)) ->
        Ok(Runtime(
          env:,
          version:,
          tag: release.tag_name,
          path: None,
          js_url: Some(js_asset.url),
          wasm_url: Some(wasm_asset.url),
          js_sha256_url: sidecar_url(sidecars, js_asset.name),
          wasm_sha256_url: sidecar_url(sidecars, wasm_asset.name),
          js_size: js_asset.size,
          wasm_size: wasm_asset.size,
          prerelease: release.prerelease,
        ))
      _, _ -> Error(Nil)
    }
  })
}

fn find_atomvmlib_asset(release: Release) -> Option(AtomvmlibAsset) {
  let sidecars =
    list.filter_map(release.assets, fn(asset) {
      case string.ends_with(asset.name, ".sha256") {
        True -> Ok(#(string.drop_end(asset.name, 7), asset.url))
        False -> Error(Nil)
      }
    })
  list.find(release.assets, fn(asset) {
    let lower = string.lowercase(asset.name)
    string.starts_with(lower, "atomvmlib-") && string.ends_with(lower, ".avm")
  })
  |> option.from_result
  |> option.map(fn(asset) {
    AtomvmlibAsset(
      name: asset.name,
      url: asset.url,
      sha256_url: sidecar_url(sidecars, asset.name),
    )
  })
}

fn fetch_release(
  repo: Option(String),
  version: Option(String),
) -> Result(Release, Error) {
  let base = case repo {
    Some(repo) -> "https://api.github.com/repos/" <> repo <> "/releases"
    None -> atomvm_releases
  }
  case version {
    None -> fetch_json_release(base <> "/latest")
    Some(tag) ->
      case fetch_json_release(base <> "/tags/" <> uri.percent_encode(tag)) {
        Ok(release) -> Ok(release)
        Error(Network(reason)) ->
          case string.contains(reason, "404") {
            True -> Error(ReleaseNotFound(tag))
            False -> Error(Network(reason))
          }
        Error(other) -> Error(other)
      }
  }
}

fn ensure_cached(runtime: Runtime) -> Result(Runtime, Error) {
  let dir_name = runtime_dir_name(runtime.env, runtime.version)
  let dir = filepath.join(cache_dir_name, dir_name)
  use Nil <- result.try(
    simplifile.create_directory_all(dir)
    |> result.map_error(fn(_) { FileError("Could not create " <> dir) }),
  )
  let js = js_path(dir)
  let wasm = wasm_path(dir)
  case simplifile.is_file(js), simplifile.is_file(wasm) {
    Ok(True), Ok(True) -> {
      io.println("Using cached " <> dir)
      Ok(Runtime(..runtime, path: Some(dir)))
    }
    _, _ -> {
      io.println(
        "Downloading AtomVM "
        <> env_token(runtime.env)
        <> " "
        <> runtime.version
        <> "…",
      )
      use js_url <- result.try(case runtime.js_url {
        Some(url) -> Ok(url)
        None -> Error(FileError("Runtime has no JS download URL"))
      })
      use wasm_url <- result.try(case runtime.wasm_url {
        Some(url) -> Ok(url)
        None -> Error(FileError("Runtime has no WASM download URL"))
      })
      use js_data <- result.try(download_verified_url(
        js_url,
        runtime.js_sha256_url,
        "AtomVM.js",
      ))
      use wasm_data <- result.try(download_verified_url(
        wasm_url,
        runtime.wasm_sha256_url,
        "AtomVM.wasm",
      ))
      use Nil <- result.try(write_atomically(js, js_data))
      use Nil <- result.try(write_atomically(wasm, wasm_data))
      print_gitignore_hint()
      Ok(Runtime(..runtime, path: Some(dir)))
    }
  }
}

fn download_verified_url(
  url: String,
  sha256_url: Option(String),
  label: String,
) -> Result(BitArray, Error) {
  use data <- result.try(fetch_binary(url))
  case sha256_url {
    None -> Ok(data)
    Some(sha_url) -> {
      use expected <- result.try(fetch_text(sha_url))
      let expected = string.lowercase(string.trim(first_token(expected)))
      let actual =
        crypto.hash(crypto.Sha256, data)
        |> bit_array.base16_encode
        |> string.lowercase
      case expected == actual {
        True -> Ok(data)
        False -> Error(Sha256Mismatch(label))
      }
    }
  }
}

fn list_cached_runtimes() -> List(Runtime) {
  case simplifile.read_directory(cache_dir_name) {
    Ok(entries) ->
      list.filter_map(entries, fn(entry) {
        let path = filepath.join(cache_dir_name, entry)
        case is_runtime_dir(path) {
          True ->
            case local_runtime_dir(path, None) {
              Ok(runtime) -> Ok(runtime)
              Error(_) -> Error(Nil)
            }
          False -> Error(Nil)
        }
      })
    Error(_) -> []
  }
}

fn find_cached_by_name(wanted: String) -> Option(Runtime) {
  list.find(list_cached_runtimes(), fn(r) {
    string.lowercase(runtime_dir_name(r.env, r.version)) == wanted
  })
  |> option.from_result
}

fn is_runtime_dir(path: String) -> Bool {
  case simplifile.is_directory(path) {
    Ok(True) ->
      case
        simplifile.is_file(js_path(path)),
        simplifile.is_file(wasm_path(path))
      {
        Ok(True), Ok(True) -> True
        _, _ -> False
      }
    _ -> False
  }
}

fn render_runtime_lines(runtimes: List(Runtime)) -> String {
  case runtimes {
    [] -> "  (none found)"
    _ ->
      runtimes
      |> list.map(fn(r) {
        let channel = case r.prerelease {
          True -> " (prerelease)"
          False -> ""
        }
        let size = case r.js_size, r.wasm_size {
          Some(js), Some(wasm) -> "  " <> format_kb(js + wasm)
          _, _ -> ""
        }
        "  "
        <> env_token(r.env)
        <> "  "
        <> runtime_dir_name(r.env, r.version)
        <> channel
        <> size
      })
      |> string.join(with: "\n")
  }
}

fn format_kb(bytes: Int) -> String {
  let kb = { bytes + 1023 } / 1024
  int.to_string(kb) <> " KB"
}

fn print_gitignore_hint() -> Nil {
  case simplifile.read(".gitignore") {
    Ok(text) ->
      case string.contains(text, "firmware_images") {
        True -> Nil
        False -> {
          io.println("")
          io.println(
            "Tip: add /firmware_images/ to .gitignore so downloaded runtimes stay local.",
          )
        }
      }
    Error(_) -> {
      io.println("")
      io.println(
        "Tip: add /firmware_images/ to .gitignore so downloaded runtimes stay local.",
      )
    }
  }
}

fn write_atomically(path: String, data: BitArray) -> Result(Nil, Error) {
  let part = path <> ".part"
  use Nil <- result.try(
    simplifile.write_bits(to: part, bits: data)
    |> result.map_error(fn(_) { FileError("Could not write " <> part) }),
  )
  simplifile.rename(at: part, to: path)
  |> result.map_error(fn(_) { FileError("Could not finalize " <> path) })
}

fn sidecar_url(
  sidecars: List(#(String, String)),
  name: String,
) -> Option(String) {
  list.key_find(sidecars, name) |> option.from_result
}

fn stem_name(file: String) -> String {
  case string.ends_with(string.lowercase(file), ".js") {
    True -> string.drop_end(file, 3)
    False ->
      case string.ends_with(string.lowercase(file), ".wasm") {
        True -> string.drop_end(file, 5)
        False -> file
      }
  }
}

fn first_token(text: String) -> String {
  case string.split(string.trim(text), on: " ") {
    [first, ..] -> first
    [] -> text
  }
}

// --- HTTP / JSON -------------------------------------------------------------

fn fetch_json_release(url: String) -> Result(Release, Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, release_decoder()) {
    Ok(release) -> Ok(release)
    Error(_) -> Error(Network("Invalid GitHub release JSON from " <> url))
  }
}

fn fetch_json_list(url: String) -> Result(List(Release), Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, decode.list(release_decoder())) {
    Ok(releases) -> Ok(releases)
    Error(_) -> Error(Network("Invalid GitHub releases JSON from " <> url))
  }
}

fn fetch_text(url: String) -> Result(String, Error) {
  use bytes <- result.try(fetch_binary(url))
  bit_array.to_string(bytes)
  |> result.map_error(fn(_) { Network("Non-UTF8 response from " <> url) })
}

fn fetch_binary(url: String) -> Result(BitArray, Error) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Network("Invalid URL: " <> url) }),
  )
  let req =
    req
    |> request.set_header("user-agent", user_agent)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_body(<<>>)
  let config =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.timeout(120_000)
  case httpc.dispatch_bits(config, req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    Ok(response) ->
      Error(Network("HTTP " <> int.to_string(response.status) <> " for " <> url))
    Error(httpc.FailedToConnect(..)) ->
      Error(Network("Network error for " <> url))
    Error(httpc.ResponseTimeout) -> Error(Network("Timed out fetching " <> url))
    Error(httpc.InvalidUtf8Response) ->
      Error(Network("Invalid response from " <> url))
  }
}

fn release_decoder() -> decode.Decoder(Release) {
  use tag_name <- decode.field("tag_name", decode.string)
  use draft <- decode.field("draft", decode.bool)
  use prerelease <- decode.field("prerelease", decode.bool)
  use assets <- decode.field("assets", decode.list(asset_decoder()))
  decode.success(Release(tag_name:, draft:, prerelease:, assets:))
}

fn asset_decoder() -> decode.Decoder(Asset) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("browser_download_url", decode.string)
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  decode.success(Asset(name:, url:, size:))
}
