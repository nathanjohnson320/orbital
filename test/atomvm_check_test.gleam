import filepath
import gleam/list
import orbital/internal/atomvm_check.{BeamInfo, Finding, FunctionInfo, Report}
import orbital/internal/supported_api.{type Api, Api, Override}
import simplifile

fn api(funcs: List(String), instructions: List(String)) -> Api {
  Api(
    version: "test",
    source: Override,
    directory: "test",
    funcs:,
    instructions:,
    supported_erlang: [],
  )
}

pub fn supported_calls_and_packaged_exports_pass_test() {
  let beams = [
    BeamInfo(module: "app", exports: ["app:start/0"], functions: [
      FunctionInfo(
        name: "app:start/0",
        calls: ["erlang:self/0", "helper:run/0"],
        local_calls: [],
        instructions: ["call_ext", "return"],
      ),
    ]),
    BeamInfo(module: "helper", exports: ["helper:run/0"], functions: [
      FunctionInfo(
        name: "helper:run/0",
        calls: [],
        local_calls: [],
        instructions: ["return"],
      ),
    ]),
  ]
  let report =
    atomvm_check.compare(
      beams,
      "app:start/0",
      api(["erlang:self/0"], ["call_ext", "return"]),
    )
  assert atomvm_check.is_compatible(report)
}

pub fn missing_entries_are_grouped_and_sorted_test() {
  let beams = [
    BeamInfo(module: "z", exports: ["z:run/0"], functions: [
      FunctionInfo(
        name: "z:run/0",
        calls: ["string:trim/2", "a:run/0"],
        local_calls: [],
        instructions: ["unsupported_op"],
      ),
    ]),
    BeamInfo(module: "a", exports: ["a:run/0"], functions: [
      FunctionInfo(
        name: "a:run/0",
        calls: ["string:trim/2"],
        local_calls: [],
        instructions: ["unsupported_op"],
      ),
    ]),
  ]
  let assert Report(
    missing_functions: [Finding(name: "string:trim/2", used_by: ["a", "z"])],
    missing_instructions: [Finding(name: "unsupported_op", used_by: ["a", "z"])],
    ..,
  ) = atomvm_check.compare(beams, "z:run/0", api([], []))
}

pub fn beam_disassembler_extracts_external_calls_test() {
  let assert Ok(files) = simplifile.get_files(filepath.join("build", "dev"))
  let assert Ok(path) =
    list.find(files, fn(path) {
      filepath.base_name(path) == "beam_check_fixture.beam"
    })
  let assert Ok([BeamInfo(module:, exports:, functions:)]) =
    atomvm_check.inspect_beam_files([path])

  assert module == "beam_check_fixture"
  assert list.contains(exports, "beam_check_fixture:reverse/1")
  let assert Ok(FunctionInfo(local_calls:, instructions:, ..)) =
    list.find(functions, fn(function) {
      function.name == "beam_check_fixture:reverse/1"
    })
  assert list.contains(local_calls, "beam_check_fixture:do_reverse/1")
  let assert Ok(FunctionInfo(calls:, ..)) =
    list.find(functions, fn(function) {
      function.name == "beam_check_fixture:do_reverse/1"
    })
  assert list.contains(calls, "lists:reverse/1")
  assert instructions != []

  let assert Ok(FunctionInfo(local_calls: [closure_target, ..], ..)) =
    list.find(functions, fn(function) {
      function.name == "beam_check_fixture:closure/0"
    })
  let assert Ok(FunctionInfo(calls: closure_calls, ..)) =
    list.find(functions, fn(function) { function.name == closure_target })
  assert list.contains(closure_calls, "lists:reverse/1")

  let assert Ok(FunctionInfo(calls: capture_calls, ..)) =
    list.find(functions, fn(function) {
      function.name == "beam_check_fixture:capture/0"
    })
  assert list.contains(capture_calls, "lists:reverse/1")
}

pub fn custom_supported_api_directory_loads_test() {
  let directory = "build/test-supported-api"
  let assert Ok(Nil) = simplifile.create_directory_all(directory)
  let assert Ok(Nil) =
    simplifile.write(
      "erlang:self/0\n",
      to: filepath.join(directory, "funcs.txt"),
    )
  let assert Ok(Nil) =
    simplifile.write(
      "return\n",
      to: filepath.join(directory, "instructions.txt"),
    )
  let assert Ok(Nil) =
    simplifile.write(
      "{\"schema\":1,\"atomvm_version\":\"custom\",\"supported_erlang\":[28]}",
      to: filepath.join(directory, "manifest.json"),
    )

  let assert Ok(loaded) = supported_api.load(directory, Override)
  assert loaded.version == "custom"
  assert loaded.funcs == ["erlang:self/0"]
  assert loaded.instructions == ["return"]
  assert loaded.supported_erlang == [28]
}

pub fn unsupported_otp_release_is_rejected_test() {
  let target = Api(..api([], []), supported_erlang: [999])
  let assert Error(supported_api.UnsupportedOtp(
    release:,
    supported: [999],
    version: "test",
  )) = supported_api.check_otp(target)
  assert release != 999
}
