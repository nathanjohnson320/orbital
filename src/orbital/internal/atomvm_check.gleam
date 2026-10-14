import filepath
import gleam/list
import gleam/result
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
  Ok(compare(beams, entrypoint, api))
}

pub fn inspect_beam_files(
  paths: List(String),
) -> Result(List(BeamInfo), Error) {
  beam_inspect(paths)
  |> result.map_error(CannotInspect)
}

pub fn compare(beams: List(BeamInfo), entrypoint: String, api: Api) -> Report {
  let exports =
    beams
    |> list.flat_map(fn(beam) { beam.exports })
    |> list.append(api.funcs)
  let functions =
    beams
    |> list.flat_map(fn(beam) { beam.functions })
    |> reachable([entrypoint], [])
  let function_pairs =
    list.flat_map(functions, fn(function) {
      function.calls
      |> list.filter(fn(call) { !list.contains(exports, call) })
      |> list.map(fn(call) { #(call, module_name(function.name)) })
    })
  let instruction_pairs =
    list.flat_map(functions, fn(function) {
      function.instructions
      |> list.filter(fn(instruction) {
        !list.contains(api.instructions, instruction)
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
  visited: List(String),
) -> List(FunctionInfo) {
  case pending {
    [] ->
      list.filter(functions, fn(function) {
        list.contains(visited, function.name)
      })
    [name, ..rest] ->
      case list.contains(visited, name) {
        True -> reachable(functions, rest, visited)
        False ->
          case list.find(functions, fn(function) { function.name == name }) {
            Error(_) -> reachable(functions, rest, [name, ..visited])
            Ok(function) ->
              reachable(
                functions,
                list.append(function.local_calls, function.calls)
                  |> list.append(rest),
                [name, ..visited],
              )
          }
      }
  }
}

pub fn is_compatible(report: Report) -> Bool {
  report.missing_functions == [] && report.missing_instructions == []
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
  [functions, instructions]
  |> list.filter(fn(section) { section != "" })
  |> string.join(with: "\n\n")
}

fn select_beams(
  beam_files: List(String),
  packed_names: List(String),
) -> Result(List(String), Error) {
  list.try_map(packed_names, fn(name) {
    case list.find(beam_files, fn(path) { filepath.base_name(path) == name }) {
      Ok(path) -> Ok(path)
      Error(_) -> Error(CannotMatchPackedModule(name))
    }
  })
}

fn group(pairs: List(#(String, String))) -> List(Finding) {
  pairs
  |> list.map(fn(pair) { pair.0 })
  |> list.unique
  |> list.sort(by: string.compare)
  |> list.map(fn(name) {
    let modules =
      pairs
      |> list.filter_map(fn(pair) {
        case pair.0 == name {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
      |> list.unique
      |> list.sort(by: string.compare)
    Finding(name:, used_by: modules)
  })
}

fn format_findings(heading: String, findings: List(Finding)) -> String {
  case findings {
    [] -> ""
    _ -> {
      let lines =
        list.map(findings, fn(finding) {
          "* "
          <> finding.name
          <> " (called by "
          <> string.join(finding.used_by, with: ", ")
          <> ")"
        })
      string.join([heading <> ":", ..lines], with: "\n")
    }
  }
}

@external(erlang, "orbital_ffi", "beam_inspect")
fn beam_inspect(paths: List(String)) -> Result(List(BeamInfo), String)
