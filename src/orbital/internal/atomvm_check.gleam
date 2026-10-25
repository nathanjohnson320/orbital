import filepath
import gleam/dict
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import orbital/internal/supported_api.{type Api}

pub type BeamInfo {
  BeamInfo(module: String, exports: List(String), functions: List(FunctionInfo))
}

pub type FunctionInfo {
  FunctionInfo(
    name: String,
    calls: List(String),
    local_calls: List(String),
    instructions: List(String),
  )
}

pub type Finding {
  Finding(name: String, used_by: List(String))
}

pub type Report {
  Report(
    checked_modules: Int,
    missing_functions: List(Finding),
    missing_instructions: List(Finding),
  )
}

pub type Error {
  CannotInspect(reason: String)
  CannotMatchPackedModule(name: String)
  MissingEntrypointModule(module: String)
  MissingEntrypointFunction(module: String)
  WrongEntrypointArity(module: String)
}

pub fn inspect(
  beam_files: List(String),
  packed_names: List(String),
  entrypoint: String,
  api: Api,
) -> Result(Report, Error) {
  use selected <- result.try(select_beams(beam_files, packed_names))
  use beams <- result.try(
    beam_inspect(selected)
    |> result.map_error(CannotInspect),
  )
  use Nil <- result.try(ensure_entrypoint(beams, entrypoint))
  Ok(compare(beams, entrypoint, api))
}

/// Confirms the AtomVM entrypoint MFA is exported by a packed module.
///
/// This replaces a separate `gleam export package-interface` pass: after
/// `gleam build`, the BEAM export table is enough to require `name:start/0`.
///
pub fn ensure_entrypoint(
  beams: List(BeamInfo),
  entrypoint: String,
) -> Result(Nil, Error) {
  let module = module_name(entrypoint)
  case list.find(beams, fn(beam) { beam.module == module }) {
    Error(_) -> Error(MissingEntrypointModule(module))
    Ok(beam) ->
      case list.contains(beam.exports, entrypoint) {
        True -> Ok(Nil)
        False ->
          case has_start_export(beam.exports, module) {
            True -> Error(WrongEntrypointArity(module))
            False -> Error(MissingEntrypointFunction(module))
          }
      }
  }
}

fn has_start_export(exports: List(String), module: String) -> Bool {
  let prefix = module <> ":start/"
  list.any(exports, fn(name) { string.starts_with(name, prefix) })
}

pub fn inspect_beam_files(
  paths: List(String),
) -> Result(List(BeamInfo), Error) {
  beam_inspect(paths)
  |> result.map_error(CannotInspect)
}

pub fn compare(beams: List(BeamInfo), entrypoint: String, api: Api) -> Report {
  // Packed locals and anonymous Gleam captures (fun Mod:Fun/Arity) live in
  // beam.functions but are often not exported. Count every packed function
  // name as available, plus the official / custom supported API.
  let available =
    beams
    |> list.flat_map(fn(beam) { list.map(beam.functions, fn(f) { f.name }) })
    |> list.append(api.funcs)
    |> set.from_list
  let instructions = set.from_list(api.instructions)
  let functions =
    beams
    |> list.flat_map(fn(beam) { beam.functions })
    |> reachable([entrypoint])
  let function_pairs =
    list.flat_map(functions, fn(function) {
      function.calls
      |> list.filter(fn(call) { !set.contains(available, call) })
      |> list.map(fn(call) { #(call, module_name(function.name)) })
    })
  let instruction_pairs =
    list.flat_map(functions, fn(function) {
      function.instructions
      |> list.filter(fn(instruction) {
        !set.contains(instructions, instruction)
      })
      |> list.map(fn(instruction) { #(instruction, module_name(function.name)) })
    })
  Report(
    checked_modules: list.length(beams),
    missing_functions: group(function_pairs),
    missing_instructions: group(instruction_pairs),
  )
}

fn module_name(mfa: String) -> String {
  case string.split_once(mfa, on: ":") {
    Ok(#(module, _)) -> module
    Error(_) -> mfa
  }
}

fn reachable(
  functions: List(FunctionInfo),
  pending: List(String),
) -> List(FunctionInfo) {
  let by_name =
    list.fold(functions, dict.new(), fn(acc, function) {
      dict.insert(acc, function.name, function)
    })
  do_reachable(by_name, pending, set.new(), [])
}

fn do_reachable(
  by_name: dict.Dict(String, FunctionInfo),
  pending: List(String),
  visited: set.Set(String),
  found: List(FunctionInfo),
) -> List(FunctionInfo) {
  case pending {
    [] -> found
    [name, ..rest] ->
      case set.contains(visited, name) {
        True -> do_reachable(by_name, rest, visited, found)
        False -> {
          let visited = set.insert(visited, name)
          case dict.get(by_name, name) {
            Error(_) -> do_reachable(by_name, rest, visited, found)
            Ok(function) ->
              do_reachable(
                by_name,
                list.append(function.local_calls, function.calls)
                  |> list.append(rest),
                visited,
                [function, ..found],
              )
          }
        }
      }
  }
}

pub fn is_compatible(report: Report) -> Bool {
  report.missing_functions == [] && report.missing_instructions == []
}

fn select_beams(
  beam_files: List(String),
  packed_names: List(String),
) -> Result(List(String), Error) {
  let by_name =
    list.fold(beam_files, dict.new(), fn(acc, path) {
      dict.insert(acc, filepath.base_name(path), path)
    })
  list.try_map(packed_names, fn(name) {
    case dict.get(by_name, name) {
      Ok(path) -> Ok(path)
      Error(_) -> Error(CannotMatchPackedModule(name))
    }
  })
}

fn group(pairs: List(#(String, String))) -> List(Finding) {
  pairs
  |> list.fold(dict.new(), fn(acc, pair) {
    let #(name, module) = pair
    let modules = case dict.get(acc, name) {
      Ok(existing) -> [module, ..existing]
      Error(_) -> [module]
    }
    dict.insert(acc, name, modules)
  })
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(name, modules) = entry
    Finding(
      name:,
      used_by: modules
        |> list.unique
        |> list.sort(by: string.compare),
    )
  })
  |> list.sort(by: fn(a, b) { string.compare(a.name, b.name) })
}

pub fn format_report(report: Report, api: Api) -> String {
  let functions =
    format_findings(
      "Functions not available on " <> supported_api.describe(api),
      report.missing_functions,
    )
  let instructions =
    format_findings(
      "Instructions not implemented by " <> supported_api.describe(api),
      report.missing_instructions,
    )
  let body =
    [functions, instructions]
    |> list.filter(fn(section) { section != "" })
    |> string.join(with: "\n\n")
  body
  <> "\n\nHint: use `--supported-api` or `ATOMVM_SUPPORTED_API` for custom firmware."
  <> "\nStatic checks cannot see names built for dynamic `apply` calls."
}

fn format_findings(heading: String, findings: List(Finding)) -> String {
  case findings {
    [] -> ""
    _ -> {
      let lines =
        list.map(findings, fn(finding) {
          "* "
          <> finding.name
          <> " (used by "
          <> string.join(finding.used_by, with: ", ")
          <> ")"
        })
      string.join([heading <> ":", ..lines], with: "\n")
    }
  }
}

@external(erlang, "orbital_ffi", "beam_inspect")
fn beam_inspect(paths: List(String)) -> Result(List(BeamInfo), String)
