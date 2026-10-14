import envoy
import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import simplifile

pub const default_version = "0.7.0-beta.0"

const default_checksum = "2244e40b11ba1231afed7c94c6ff158a6d394b72a4715fa313b941904ab8dc43"

const cache_root = "firmware_images/supported_api"

const user_agent = "orbital-supported-api/1.0 (+https://github.com/nathanjohnson320/orbital)"

pub type Source {
  Override
  Environment
  Official
}

pub type Api {
  Api(
    version: String,
    source: Source,
    directory: String,
    funcs: List(String),
    instructions: List(String),
    supported_erlang: List(Int),
  )
}

pub type Error {
  CannotRead(path: String)
  InvalidManifest(path: String)
  InvalidArchive(reason: String)
  Network(reason: String)
  ChecksumMismatch(expected: String, actual: String)
  UnsupportedRelease(expected: String, published: String)
  UnsupportedOtp(release: Int, supported: List(Int), version: String)
  CannotWrite(path: String)
}

type Release {
  Release(checksum: String)
}

type Manifest {
  Manifest(version: String, supported_erlang: List(Int))
}

pub fn resolve(override: Option(String)) -> Result(Api, Error) {
  case override {
    Some(directory) -> load(directory, Override)
    None ->
      case envoy.get("ATOMVM_SUPPORTED_API") {
        Ok(directory) -> load(directory, Environment)
        Error(_) -> resolve_official()
      }
  }
}

pub fn describe(api: Api) -> String {
  case api.source {
    Override -> "AtomVM " <> api.version <> " from --supported-api"
    Environment -> "AtomVM " <> api.version <> " from ATOMVM_SUPPORTED_API"
    Official -> "AtomVM " <> api.version <> " official supported API"
  }
}

pub fn check_otp(api: Api) -> Result(Nil, Error) {
  case api.supported_erlang {
    [] -> Ok(Nil)
    supported ->
      case int.parse(otp_release()) {
        Ok(release) ->
          case list.contains(supported, release) {
            True -> Ok(Nil)
            False ->
              Error(UnsupportedOtp(release:, supported:, version: api.version))
          }
        Error(_) -> Ok(Nil)
      }
  }
}

fn resolve_official() -> Result(Api, Error) {
  let directory =
    cache_root
    |> filepath.join(default_version)
    |> filepath.join(default_checksum)
  case load(directory, Official) {
    Ok(api) -> Ok(api)
    Error(_) -> download_official(directory)
  }
}

fn download_official(directory: String) -> Result(Api, Error) {
  let release_url =
    "https://hex.pm/api/packages/atomvm/releases/" <> default_version
  use release_text <- result.try(fetch_text(release_url, "application/json"))
  use release <- result.try(
    json.parse(release_text, release_decoder())
    |> result.map_error(fn(_) { Network("Invalid Hex release metadata") }),
  )
  let published = string.lowercase(release.checksum)
  use Nil <- result.try(bool_guard(
    published == default_checksum,
    UnsupportedRelease(default_checksum, published),
  ))

  let tarball_url =
    "https://repo.hex.pm/tarballs/atomvm-" <> default_version <> ".tar"
  use archive <- result.try(fetch_binary(
    tarball_url,
    "application/octet-stream",
  ))
  let actual =
    crypto.hash(crypto.Sha256, archive)
    |> bit_array.base16_encode
    |> string.lowercase
  use Nil <- result.try(bool_guard(
    actual == published,
    ChecksumMismatch(published, actual),
  ))
  use #(funcs, instructions, manifest) <- result.try(
    extract_supported_api(archive)
    |> result.map_error(InvalidArchive),
  )
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(_) { CannotWrite(directory) }),
  )
  use Nil <- result.try(write_bits(filepath.join(directory, "funcs.txt"), funcs))
  use Nil <- result.try(write_bits(
    filepath.join(directory, "instructions.txt"),
    instructions,
  ))
  use Nil <- result.try(write_bits(
    filepath.join(directory, "manifest.json"),
    manifest,
  ))
  load(directory, Official)
}

pub fn load(directory: String, source: Source) -> Result(Api, Error) {
  let funcs_path = filepath.join(directory, "funcs.txt")
  let instructions_path = filepath.join(directory, "instructions.txt")
  let manifest_path = filepath.join(directory, "manifest.json")
  use funcs <- result.try(read_lines(funcs_path))
  use instructions <- result.try(read_lines(instructions_path))
  use manifest_text <- result.try(
    simplifile.read(manifest_path)
    |> result.map_error(fn(_) { CannotRead(manifest_path) }),
  )
  use manifest <- result.try(
    json.parse(manifest_text, manifest_decoder())
    |> result.map_error(fn(_) { InvalidManifest(manifest_path) }),
  )
  Ok(Api(
    version: manifest.version,
    source:,
    directory:,
    funcs:,
    instructions:,
    supported_erlang: manifest.supported_erlang,
  ))
}

fn read_lines(path: String) -> Result(List(String), Error) {
  use text <- result.try(
    simplifile.read(path)
    |> result.map_error(fn(_) { CannotRead(path) }),
  )
  Ok(
    text
    |> string.split(on: "\n")
    |> list.map(string.trim)
    |> list.filter(fn(line) { line != "" }),
  )
}

fn fetch_text(url: String, accept: String) -> Result(String, Error) {
  use bytes <- result.try(fetch_binary(url, accept))
  bit_array.to_string(bytes)
  |> result.map_error(fn(_) { Network("Non-UTF8 response from " <> url) })
}

fn fetch_binary(url: String, accept: String) -> Result(BitArray, Error) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Network("Invalid URL: " <> url) }),
  )
  let req =
    req
    |> request.set_header("user-agent", user_agent)
    |> request.set_header("accept", accept)
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
  use checksum <- decode.field("checksum", decode.string)
  decode.success(Release(checksum:))
}

fn manifest_decoder() -> decode.Decoder(Manifest) {
  use version <- decode.field("atomvm_version", decode.string)
  use supported_erlang <- decode.optional_field(
    "supported_erlang",
    [],
    decode.list(decode.int),
  )
  decode.success(Manifest(version:, supported_erlang:))
}

fn write_bits(path: String, bits: BitArray) -> Result(Nil, Error) {
  simplifile.write_bits(to: path, bits:)
  |> result.map_error(fn(_) { CannotWrite(path) })
}

fn bool_guard(value: Bool, error: Error) -> Result(Nil, Error) {
  case value {
    True -> Ok(Nil)
    False -> Error(error)
  }
}

@external(erlang, "orbital_ffi", "extract_supported_api")
fn extract_supported_api(
  archive: BitArray,
) -> Result(#(BitArray, BitArray, BitArray), String)

@external(erlang, "orbital_ffi", "otp_release")
fn otp_release() -> String
