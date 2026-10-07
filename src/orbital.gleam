import argv
import filepath
import glam/doc.{type Document}
import gleam/dict
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/package_interface
import gleam/result
import gleam/string
import gleam_community/ansi
import orbital/internal/cli
import orbital/internal/esp32
import orbital/internal/executable.{type ExecutablePath}
import orbital/internal/image_header
import orbital/internal/install
import orbital/internal/monitor
import orbital/internal/partition
import orbital/internal/pico
import orbital/internal/pico_install
import orbital/internal/project.{
  type Project, CannotParseGleamToml, CannotReadGleamToml, CannotReadProjectName,
}
import orbital/internal/wasm
import orbital/internal/wasm_install
import simplifile.{Enoent}
import temporary
import term_size
import tom.{NotFound, WrongType}

const default_baud = 921_600

const default_monitor_baud = 115_200

const default_monitor_timeout = 10

fn print_document(document: Document) -> Nil {
  term_size.columns()
  |> result.unwrap(80)
  |> doc.to_string(document, _)
  |> io.println
}

/// The orbital command line interface entry point.
/// This is intended to be ran as a command line tool by running
/// `gleam run -m orbital`.
///
pub fn main() -> Nil {
  case cli.parse(argv.load().arguments) {
    Error(error) -> {
      cli.error_to_document(error)
      |> print_document

      exit(1)
    }

    Ok(cli.Usage) -> print_document(cli.usage_text())
    Ok(cli.Help) -> print_document(cli.usage_text())
    Ok(cli.Version) -> io.println(cli.orbital_version)

    Ok(cli.Build(help: True, ..)) -> print_document(cli.build_help_text(True))
    Ok(cli.Build(output_file:, help: False)) -> build(output_file)
    Ok(cli.List(help: True, ..)) -> print_document(cli.list_help_text(True))
    Ok(cli.List(input_file:, help: False)) -> list(input_file)

    Ok(cli.Uf2create(help: True, ..)) ->
      print_document(cli.uf2create_help_text(True))
    Ok(cli.Uf2create(output_file:, app_start:, family_id:, help: False)) ->
      uf2create(output_file, app_start, family_id)

    Ok(cli.Monitor(help: True, ..)) ->
      print_document(cli.monitor_help_text(True))
    Ok(cli.Monitor(port:, baud:, timeout:, reset:, help: False)) ->
      monitor(port, baud, timeout, reset)

    Ok(cli.Install(help: True, ..)) ->
      print_document(cli.install_help_text(True))
    Ok(cli.Install(
      image:,
      version:,
      repo:,
      update:,
      download_only:,
      list_images:,
      chip:,
      baud:,
      port:,
      help: False,
    )) ->
      run_install(install.Options(
        image:,
        version:,
        repo:,
        update:,
        download_only:,
        list_images:,
        chip:,
        baud: option.unwrap(baud, default_baud),
        port:,
      ))

    Ok(cli.InstallPico(help: True, ..)) ->
      print_document(cli.install_help_text(True))
    Ok(cli.InstallPico(
      board:,
      image:,
      version:,
      repo:,
      download_only:,
      list_images:,
      pico_path:,
      pico_reset:,
      picotool:,
      help: False,
    )) ->
      run_pico_install(pico_install.Options(
        board:,
        image:,
        version:,
        repo:,
        download_only:,
        list_images:,
        pico_path:,
        pico_reset:,
        picotool:,
      ))

    Ok(cli.InstallWasm(help: True, ..)) ->
      print_document(cli.install_help_text(True))
    Ok(cli.InstallWasm(
      env:,
      image:,
      version:,
      repo:,
      download_only:,
      list_images:,
      with_atomvmlib:,
      help: False,
    )) ->
      run_wasm_install(wasm_install.Options(
        env:,
        image:,
        version:,
        repo:,
        download_only:,
        list_images:,
        with_atomvmlib:,
      ))

    Ok(cli.Expand(help: True, ..)) -> print_document(cli.expand_help_text(True))
    Ok(cli.Expand(port:, help: False)) -> expand(port)

    Ok(cli.EraseFlash(help: True, ..)) ->
      print_document(cli.erase_flash_help_text(True))
    Ok(cli.EraseFlash(port:, help: False)) -> erase_flash(port)

    Ok(cli.Info(help: True)) -> print_document(cli.info_help_text(True))
    Ok(cli.Info(help: False)) -> info()

    // Flashing is the more involved step, and changes based on the device.
    Ok(cli.Flash(help: True, ..)) -> print_document(cli.flash_help_text(True))
    Ok(cli.Flash(help: False, platform:)) -> flash(platform)
  }
}

fn flash(platform: cli.FlashPlatform) -> Nil {
  let flashed_device = case platform {
    cli.Esp32(port:, baud:, offset:, dry_run: True) -> {
      flash_esp32_dry_run(port, baud, offset)
      Ok(False)
    }
    cli.Esp32(port:, baud:, offset:, dry_run: False) -> {
      use _ <- result.try(do_flash_esp32(port, baud, offset))
      Ok(True)
    }
    cli.Pico(pico_path:, pico_reset:, picotool:, app_start:, family_id:) -> {
      use _ <- result.try(do_flash_pico(
        pico_path:,
        pico_reset:,
        picotool:,
        app_start:,
        family_id:,
      ))
      Ok(True)
    }
    cli.Wasm(env:, image:, version:, repo:, output_dir:, atomvmlib:) -> {
      use outcome <- result.try(do_flash_wasm(
        env:,
        image:,
        version:,
        repo:,
        output_dir:,
        atomvmlib:,
      ))
      Ok(outcome)
    }
  }

  case flashed_device {
    Ok(True) -> io.println(ansi.magenta("⚛️  flashed the device!"))
    Ok(False) -> Nil
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

fn flash_esp32_dry_run(
  port: Option(String),
  baud: Option(Int),
  offset: Option(String),
) -> Nil {
  let baud = option.unwrap(baud, default_baud) |> int.to_string
  let port_line = case port {
    Some(port) -> "    --port '" <> port <> "' \\"
    None -> ""
  }
  let address = option.unwrap(offset, "<MAIN_AVM_OFFSET>")
  let read_partition = case offset {
    Some(_) -> []
    None -> [
      "  esptool --chip auto \\",
      port_line,
      "    --baud " <> baud <> " \\",
      "    read-flash 0x8000 0xC00 <PARTITION_TABLE>",
      "",
    ]
  }
  let command =
    list.append(read_partition, [
      "  esptool --chip auto \\",
      port_line,
      "    --baud " <> baud <> " \\",
      "    --before default-reset --after hard-reset write-flash -u \\",
      "    --flash-mode keep --flash-freq keep --flash-size detect "
        <> address
        <> " \\",
      "    <AVM_FILE>",
    ])
    |> list.filter(keeping: fn(line) { line != "" })
    |> string.join(with: "\n")

  io.println("To flash the device I would run this command:\n\n" <> command)
}

fn run_install(options: install.Options) -> Nil {
  case install.run(options) {
    Ok(Nil) -> Nil
    Error(install.Cancelled) -> exit(0)
    Error(error) -> {
      let message = install.error_message(error)
      case message {
        "" -> Nil
        _ -> io.println(error_heading("install failed") <> "\n" <> message)
      }
      exit(1)
    }
  }
}

fn run_pico_install(options: pico_install.Options) -> Nil {
  case pico_install.run(options) {
    Ok(Nil) -> Nil
    Error(pico_install.Cancelled) -> exit(0)
    Error(error) -> {
      let message = pico_install.error_message(error)
      case message {
        "" -> Nil
        _ -> io.println(error_heading("install failed") <> "\n" <> message)
      }
      exit(1)
    }
  }
}

fn run_wasm_install(options: wasm_install.Options) -> Nil {
  case wasm_install.run(options) {
    Ok(Nil) -> Nil
    Error(error) -> {
      let message = wasm_install.error_message(error)
      case message {
        "" -> Nil
        _ -> io.println(error_heading("install failed") <> "\n" <> message)
      }
      exit(1)
    }
  }
}

fn monitor(
  port: Option(String),
  baud: Option(Int),
  timeout: Option(Int),
  reset: Bool,
) -> Nil {
  let port = option.unwrap(port, "auto")
  let baud = option.unwrap(baud, default_monitor_baud)
  let timeout = option.unwrap(timeout, default_monitor_timeout)
  case monitor.run(port, baud, reset, timeout) {
    Ok(Nil) ->
      case timeout {
        0 -> Nil
        1 -> io.println("Stopped after 1 second.")
        seconds ->
          io.println("Stopped after " <> int.to_string(seconds) <> " seconds.")
      }
    Error("") -> exit(1)
    Error(reason) -> {
      io.println_error(reason)
      exit(1)
    }
  }
}

fn expand(port: Option(String)) -> Nil {
  case do_expand(esp32.port_or_auto(port)) {
    Ok(AlreadyExpanded) ->
      io.println("Bootloader and main.avm already use the detected flash size.")
    Ok(Expanded) ->
      io.println(ansi.magenta(
        "⚛️  updated the bootloader flash size, expanded main.avm, and verified both!",
      ))
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

type ExpandOutcome {
  AlreadyExpanded
  Expanded
}

fn do_expand(port: String) -> Result(ExpandOutcome, Error) {
  use resolved_port <- result.try(
    esp32.select_port(port) |> result.map_error(Esp32HelperError),
  )
  io.println(ansi.dim("Expanding main.avm on '" <> resolved_port <> "'..."))

  let table_offset = partition.expected_table_offset()
  let table_size = partition.expected_table_size()

  use #(table, table_meta) <- result.try(
    esp32.read_flash_bytes(
      port: resolved_port,
      address: table_offset,
      size: table_size,
      reset_after: True,
    )
    |> result.map_error(Esp32HelperError),
  )

  use expansion <- result.try(
    partition.expand_partition(table, "main.avm", table_meta.flash_size)
    |> result.map_error(ExpandPartitionError),
  )

  let bootloader_offset = table_meta.bootloader_offset
  let bootloader_size = table_offset - bootloader_offset
  use Nil <- result.try(case bootloader_size > 0 {
    True -> Ok(Nil)
    False -> Error(InvalidBootloaderOffset)
  })

  use #(bootloader, _) <- result.try(
    esp32.read_flash_bytes(
      port: resolved_port,
      address: bootloader_offset,
      size: bootloader_size,
      reset_after: True,
    )
    |> result.map_error(Esp32HelperError),
  )

  use bootloader_flash_size <- result.try(
    image_header.flash_size(bootloader)
    |> result.map_error(ExpandImageHeaderError),
  )

  print_expansion_summary(
    resolved_port,
    table_meta,
    bootloader_flash_size,
    expansion,
  )

  case bootloader_flash_size == table_meta.flash_size && !expansion.changed {
    True -> Ok(AlreadyExpanded)
    False -> {
      use Nil <- result.try(apply_expansion(
        resolved_port,
        table_meta,
        bootloader,
        expansion,
      ))
      Ok(Expanded)
    }
  }
}

fn print_expansion_summary(
  port: String,
  table_meta: esp32.FlashRead,
  bootloader_flash_size: Int,
  expansion: partition.Expansion,
) -> Nil {
  let partition.Expansion(partition: current, updated_partition: updated, ..) =
    expansion
  io.println(
    "\nESP32: "
    <> table_meta.chip_name
    <> " on "
    <> port
    <> "\nDetected flash: "
    <> table_meta.flash_size_name
    <> " ("
    <> partition.hex_address(table_meta.flash_size)
    <> ")\nBootloader flash size: "
    <> format_byte_size(bootloader_flash_size)
    <> "\nmain.avm offset: "
    <> partition.hex_address(current.offset)
    <> "\nCurrent size: "
    <> format_byte_size(current.size)
    <> "\nExpanded size: "
    <> format_byte_size(updated.size)
    <> "\n",
  )
}

fn apply_expansion(
  port: String,
  table_meta: esp32.FlashRead,
  bootloader: BitArray,
  expansion: partition.Expansion,
) -> Result(Nil, Error) {
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let bootloader_path = filepath.join(directory, "bootloader.bin")
    let partition_path = filepath.join(directory, "partition-table.bin")

    use Nil <- result.try(
      simplifile.write_bits(to: bootloader_path, bits: bootloader)
      |> result.replace_error(ExpandStagingFailed),
    )
    use Nil <- result.try(
      simplifile.write_bits(to: partition_path, bits: expansion.partition_table)
      |> result.replace_error(ExpandStagingFailed),
    )
    use Nil <- result.try(
      esp32.write_flash_size_and_partition(
        port:,
        bootloader_offset: table_meta.bootloader_offset,
        bootloader_path:,
        partition_offset: partition.expected_table_offset(),
        partition_path:,
        flash_size_name: table_meta.flash_size_name,
      )
      |> result.map_error(Esp32HelperError),
    )

    use #(header, _) <- result.try(
      esp32.read_flash_bytes(
        port:,
        address: table_meta.bootloader_offset,
        size: 24,
        reset_after: True,
      )
      |> result.map_error(Esp32HelperError),
    )
    use #(table, _) <- result.try(
      esp32.read_flash_bytes(
        port:,
        address: partition.expected_table_offset(),
        size: partition.expected_table_size(),
        reset_after: True,
      )
      |> result.map_error(Esp32HelperError),
    )
    use flash_size_id <- result.try(
      image_header.flash_size_id(header)
      |> result.map_error(ExpandImageHeaderError),
    )

    case
      flash_size_id == table_meta.flash_size_id
      && table == expansion.partition_table
    {
      True -> Ok(Nil)
      False -> Error(ExpandVerificationFailed)
    }
  }

  case outcome {
    Ok(result) -> result
    Error(_) -> Error(ExpandStagingFailed)
  }
}

fn format_byte_size(bytes: Int) -> String {
  int.to_string(bytes) <> " bytes (" <> partition.hex_address(bytes) <> ")"
}

fn erase_flash(port: Option(String)) -> Nil {
  let port = esp32.port_or_auto(port)
  case do_erase_flash(port) {
    Ok(resolved_port) ->
      io.println(ansi.magenta(
        "⚛️  erased the flash on '" <> resolved_port <> "'!",
      ))
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

fn do_erase_flash(port: String) -> Result(String, Error) {
  use resolved_port <- result.try(
    esp32.select_port(port) |> result.map_error(Esp32HelperError),
  )
  io.println(ansi.dim("Erasing flash on '" <> resolved_port <> "'..."))
  use Nil <- result.try(
    esp32.erase_flash(resolved_port) |> result.map_error(Esp32HelperError),
  )
  Ok(resolved_port)
}

fn info() -> Nil {
  case esp32.list_devices() {
    Ok(devices) -> io.println(esp32.format_info_report(devices))
    Error(error) -> {
      io.println(error_to_string(Esp32HelperError(error)))
      exit(1)
    }
  }
}

fn build(output_file: Option(String)) -> Nil {
  case do_build(output_file) {
    Ok(output_path) -> {
      let output_path = string.remove_prefix(output_path, "./")
      io.println(ansi.magenta(
        "⚛️  built your project to the '" <> output_path <> "' file!",
      ))
    }
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

fn uf2create(
  output_file: Option(String),
  app_start: Option(String),
  family_id: Option(String),
) -> Nil {
  case do_uf2create(output_file, app_start, family_id) {
    Ok(output_path) -> {
      let output_path = string.remove_prefix(output_path, "./")
      io.println(ansi.magenta(
        "⚛️  created the '" <> output_path <> "' UF2 file!",
      ))
    }
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

fn list(input_file: Option(String)) -> Nil {
  case do_list(input_file) {
    Ok(_) -> Nil
    Error(error) -> {
      io.println(error_to_string(error))
      exit(1)
    }
  }
}

fn do_flash_esp32(
  port: Option(String),
  baud: Option(Int),
  offset: Option(String),
) -> Result(Nil, Error) {
  // To flash to an esp device we need esptool to be installed and available in
  // the path!
  use esptool <- result.try(
    executable.find("esptool")
    |> result.replace_error(CannotFindEsptoolExecutable),
  )

  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let output_path = filepath.join(directory, "build.avm")
    use output_path <- result.try(do_build(Some(output_path)))
    use offset <- result.try(resolve_offset(
      esptool,
      directory,
      port,
      baud,
      offset,
    ))

    // If the root project was compiled successufully we're good to go: we can
    // now pack all the produced `.beam` files into an `.avm` file ready to be
    // flushed into the device.
    io.println(ansi.dim("Writing main.avm at " <> offset))
    use Nil <- try_step("Flashing the 'avm' file into the device...", fn() {
      esp_flash_to_device(esptool, output_path, port, baud, offset)
    })
    Ok(Nil)
  }

  case outcome {
    Ok(result) -> result
    Error(_) -> Error(CannotFlashWithEsptool(-1))
  }
}

fn do_flash_pico(
  pico_path pico_path: Option(String),
  pico_reset pico_reset: Option(String),
  picotool picotool: Option(String),
  app_start app_start: Option(String),
  family_id family_id: Option(String),
) -> Result(Nil, Error) {
  use project <- result.try(
    project.load()
    |> result.map_error(CannotIdentifyProject),
  )
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let avm_path = filepath.join(directory, "build.avm")
    let uf2_path = filepath.join(directory, project.name <> ".uf2")
    use _ <- result.try(do_build(Some(avm_path)))

    use Nil <- try_step("Creating the UF2 file...", fn() {
      pico.create_uf2(
        avm_path:,
        uf2_path:,
        options: pico.Uf2Options(app_start:, family_id:),
      )
      |> result.map_error(PicoError)
    })
    use Nil <- try_step("Flashing the UF2 onto the Pico...", fn() {
      pico.flash_uf2(
        uf2_path:,
        options: pico.FlashOptions(pico_path:, pico_reset:, picotool:),
      )
      |> result.map_error(PicoError)
    })
    Ok(Nil)
  }

  case outcome {
    Ok(result) -> result
    Error(_) ->
      Error(
        PicoError(pico.CannotCreateUf2("could not create a temporary directory")),
      )
  }
}

/// Returns `True` when a device-like run completed (Node), `False` after a
/// browser export (no physical flash).
fn do_flash_wasm(
  env env: Option(String),
  image image: Option(String),
  version version: Option(String),
  repo repo: Option(String),
  output_dir output_dir: Option(String),
  atomvmlib atomvmlib: Option(String),
) -> Result(Bool, Error) {
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let avm_path = filepath.join(directory, "build.avm")
    use avm_path <- result.try(do_build(Some(avm_path)))
    use Nil <- try_step("Deploying to AtomVM WASM...", fn() {
      wasm.flash(
        avm_path,
        wasm.FlashOptions(
          env:,
          image:,
          version:,
          repo:,
          output_dir:,
          atomvmlib:,
        ),
      )
      |> result.map_error(WasmError)
    })
    // Success text is printed by the WASM deployer (Node run / web export).
    Ok(False)
  }

  case outcome {
    Ok(result) -> result
    Error(_) ->
      Error(WasmError(wasm.FileError("could not create a temporary directory")))
  }
}

fn do_uf2create(
  output_file: Option(String),
  app_start: Option(String),
  family_id: Option(String),
) -> Result(String, Error) {
  use project <- result.try(
    project.load()
    |> result.map_error(CannotIdentifyProject),
  )
  let avm_path = default_avm_file_name(project)
  use _ <- result.try(do_build(Some(avm_path)))

  let uf2_path = option.unwrap(output_file, default_uf2_file_name(project))
  use Nil <- try_step("Creating the UF2 file...", fn() {
    pico.create_uf2(
      avm_path:,
      uf2_path:,
      options: pico.Uf2Options(app_start:, family_id:),
    )
    |> result.map_error(PicoError)
  })
  Ok(uf2_path)
}

/// Returns the path to the built file!
fn do_build(output_file: Option(String)) -> Result(String, Error) {
  // In order to do anything useful we need to make sure Gleam is installed
  // (we'll need to run it to compile the project), and that we're inside a
  // Gleam project.
  use gleam <- result.try(
    executable.find("gleam")
    |> result.replace_error(CannotFindGleamExecutable),
  )
  use project <- result.try(
    project.load()
    |> result.map_error(CannotIdentifyProject),
  )

  // The gleam compiler doesn't recompile the root project when running a module
  // from a dependency (`gleam run -m orbital`).
  // This is quite nice as it allows us to run deps even if our own code is not
  // in a compiling state.
  // However, in our case we actually want to make sure that when "orbital" is
  // running it is using the most recent version of the code: it would be quite
  // confusing to run `gleam run -m orbital` and it flushes an outdated version
  // of the code because we forgot to run `gleam build && gleam run -m orbital`.
  // So we start by compiling the root project:
  use Nil <- try_step("Compiling your Gleam project...", fn() {
    compile(gleam, project)
  })
  use Nil <- try_step("Looking for a suitable entrypoint...", fn() {
    validate_entrypoint(gleam, project)
  })

  // If the root project was compiled successufully we're good to go: we can
  // now pack all the produced `.beam` files into an `.avm` file ready to be
  // flushed into the device.
  let output_path = option.unwrap(output_file, default_avm_file_name(project))
  use Nil <- try_step("Building the 'avm' file...", fn() {
    bundle_beam_files(project, output_path)
  })

  Ok(output_path)
}

/// Given a project, this returns the default name used by the tool to put the
/// 'avm' built file.
fn default_avm_file_name(project: Project) -> String {
  project.root_directory
  |> filepath.join(project.name <> ".avm")
}

fn default_uf2_file_name(project: Project) -> String {
  project.root_directory
  |> filepath.join(project.name <> ".uf2")
}

fn do_list(input_file: Option(String)) -> Result(Nil, Error) {
  use input_file <- result.try(case input_file {
    Some(input_file) -> Ok(input_file)
    None ->
      project.load()
      |> result.map_error(CannotIdentifyProject)
      |> result.map(default_avm_file_name)
  })

  use files <- try_step("Reading the 'avm' file...", fn() {
    packbeam_list(input_file)
    |> result.replace_error(CannotReadAvmFile(input_file))
  })

  let files =
    list.map(files, fn(file) { "  - " <> file })
    |> string.join(with: "\n")

  io.println("Files bundled in `" <> input_file <> "`:\n" <> files)
  Ok(Nil)
}

@external(erlang, "erlang", "halt")
fn exit(status_code: Int) -> a

type Error {
  CannotFindGleamExecutable
  CannotIdentifyProject(reason: project.Error)
  CannotSpawnGleamCompiler
  CannotSpawnEsptool
  CannotCompileProject
  CannotListBeamFiles(reason: simplifile.FileError)
  OutputFileIsDirectory(file: String)

  CannotReadAvmFile(file: String)

  CannotReadPackageInterface(reason: simplifile.FileError)
  CannotParsePackageInterface(reason: json.DecodeError)
  CannotFindEntrypointModule(module: String)
  CannotFindEntrypointFunction(module: String)
  EntrypointFunctionHasWrongArity(module: String)
  CannotFindEsptoolExecutable

  CannotFlashWithEsptool(esptool_status_code: Int)
  PicoError(reason: pico.Error)
  WasmError(reason: wasm.Error)
  EsptoolCannotOpenPort(port: String)
  CannotReadPartitionTable
  CannotFindMainPartition
  Esp32HelperError(reason: esp32.Error)
  ExpandPartitionError(reason: partition.Error)
  ExpandImageHeaderError(reason: image_header.Error)
  InvalidBootloaderOffset
  ExpandStagingFailed
  ExpandVerificationFailed
}

fn error_to_string(error: Error) -> String {
  let title = case error {
    CannotFindEntrypointModule(_) -> "missing entrypoint module"
    CannotFindEntrypointFunction(_) -> "missing entrypoint function"
    EntrypointFunctionHasWrongArity(_) -> "wrong entrypoint function"
    CannotCompileProject -> "invalid Gleam project"
    CannotFindEsptoolExecutable -> "missing 'esptool'"
    CannotFlashWithEsptool(_)
    | EsptoolCannotOpenPort(_)
    | PicoError(_)
    | WasmError(_)
    | CannotReadPartitionTable
    | CannotFindMainPartition -> "cannot flash device"
    Esp32HelperError(esp32.ToolingMissing(_)) -> "missing ESP32 tooling"
    // Shared by info, erase-flash, expand, and later device commands.
    Esp32HelperError(esp32.DeviceError(_)) -> "ESP32 device error"
    ExpandPartitionError(_)
    | ExpandImageHeaderError(_)
    | InvalidBootloaderOffset
    | ExpandStagingFailed
    | ExpandVerificationFailed -> "cannot expand main.avm"
    OutputFileIsDirectory(_) -> "invalid output file"
    CannotReadAvmFile(_) -> "cannot read the 'avm' file"

    // Unusual errors that should never happen, I'm not fretting over a perfect
    // name here.
    CannotIdentifyProject(CannotParseGleamToml)
    | CannotIdentifyProject(CannotReadProjectName(NotFound(..)))
    | CannotIdentifyProject(CannotReadProjectName(WrongType(..))) ->
      "invalid Gleam project"
    CannotIdentifyProject(CannotReadGleamToml(_)) -> "cannot read `gleam.toml`"
    CannotFindGleamExecutable -> "cannot find gleam exectuable"
    CannotSpawnGleamCompiler -> "cannot check Gleam project"
    CannotSpawnEsptool -> "cannot flash to device"
    CannotListBeamFiles(_)
    | CannotReadPackageInterface(_)
    | CannotParsePackageInterface(_) -> "cannot build the 'avm' file"
  }

  let body = case error {
    CannotFindEntrypointModule(module:) ->
      "Make sure to define a `"
      <> module
      <> "` module with a public `start()` function.\n"
      <> "That is the entrypoint used by AtomVM."

    CannotFindEntrypointFunction(module:) ->
      "Make sure the `"
      <> module
      <> "` module defines a public `start()` function.\n"
      <> "That is the entrypoint used by AtomVM."

    EntrypointFunctionHasWrongArity(module:) ->
      "The `start` function in the `"
      <> module
      <> "` module must have no arguments to be a valid entrypoint."

    CannotCompileProject ->
      "It seems like your project has some compilation errors.\n"
      <> "Make sure to fix all errors and run `gleam run -m orbital` again."

    CannotFindEsptoolExecutable ->
      "To flash a device 'esptool' needs to be installed, but I couldn't "
      <> "find it in your PATH.\n"
      <> "Hint: you can find installation instructions at\n"
      <> "https://docs.espressif.com/projects/esptool/en/latest/esp32/installation.html"

    CannotFlashWithEsptool(esptool_status_code:) ->
      "The call to 'esptool' failed with status code: "
      <> int.to_string(esptool_status_code)
      <> "."

    PicoError(reason:) -> pico.error_message(reason)

    WasmError(reason:) -> wasm.error_message(reason)

    EsptoolCannotOpenPort(port:) ->
      "The port '"
      <> port
      <> "' is busy or doesn't exist.\n"
      <> "Hint: make sure the port is correct and the device connected."

    CannotReadPartitionTable ->
      "I couldn't read the partition table from the device.\n"
      <> "Hint: hold BOOT, tap RESET, release BOOT, and try again."

    CannotFindMainPartition ->
      "The partition table has no main.avm slot.\n"
      <> "Hint: pass --offset with the address printed in the boot log."

    Esp32HelperError(esp32.ToolingMissing(reason:)) ->
      reason
      <> "\nHint: install esptool so Orbital can use its Python environment:\n"
      <> "https://docs.espressif.com/projects/esptool/en/latest/esp32/installation.html"

    Esp32HelperError(esp32.DeviceError(reason:)) -> reason

    ExpandPartitionError(reason:) -> expand_partition_error_message(reason)

    ExpandImageHeaderError(image_header.InvalidImageHeader) ->
      "The ESP32 bootloader image header is invalid."

    ExpandImageHeaderError(image_header.UnsupportedFlashSize) ->
      "The ESP32 bootloader declares an unsupported flash size."

    InvalidBootloaderOffset -> "Esptool returned an invalid bootloader offset."

    ExpandStagingFailed ->
      "I couldn't prepare the bootloader or partition table for writing.\n"
      <> bug_report_call_to_action()

    ExpandVerificationFailed ->
      "Bootloader or partition table verification failed after flashing."

    OutputFileIsDirectory(file:) ->
      "'"
      <> file
      <> "' is an existing directory.\n"
      <> "Hint: pick a different name for your output file."

    CannotReadAvmFile(file:) ->
      "Make sure that `" <> file <> "` exists and is a valid 'avm' file."

    // We're modelling these errors, but they should technically never happen
    // (so I'm not fretting over perfect error messages): one woulnd't even be
    // able to run `gleam` if any of these were to take place!
    CannotListBeamFiles(_) ->
      "An unexpected error while trying to figure out the files to include "
      <> "in the 'avm' file."
    CannotFindGleamExecutable -> "Make sure 'gleam' is in your path."
    CannotSpawnGleamCompiler ->
      "I couldn't check if your project has any compilation errors.\n"
      <> bug_report_call_to_action()
    CannotSpawnEsptool ->
      "I ran into an unexpected error trying to run 'esptool'.\n"
      <> bug_report_call_to_action()
    CannotIdentifyProject(CannotReadGleamToml(Enoent)) ->
      "It looks like this Gleam project doesn't have a 'gleam.toml' file, make "
      <> "sure to create one first."
    CannotIdentifyProject(CannotReadGleamToml(_)) ->
      "An unexpected error happened while trying to read this project's "
      <> "'gleam.toml' file."
    CannotIdentifyProject(CannotParseGleamToml) ->
      "It looks like this project's 'gleam.toml' file is invalid."
    CannotIdentifyProject(CannotReadProjectName(NotFound(..))) ->
      "This project's 'gleam.toml' file doesn't have the required `name` "
      <> "field, make sure to add one."
    CannotIdentifyProject(CannotReadProjectName(WrongType(..))) ->
      "This project's name in the 'gleam.toml' file is not a string."
    CannotReadPackageInterface(_) ->
      "I couldn't analyse your project's modules.\n"
      <> bug_report_call_to_action()
    CannotParsePackageInterface(_) ->
      "The project's package interface seems to be invalid.\n"
      <> bug_report_call_to_action()
  }

  error_heading(title) <> "\n" <> body
}

fn expand_partition_error_message(reason: partition.Error) -> String {
  case reason {
    partition.InvalidPartitionTable ->
      "The ESP32 returned an invalid partition table from flash offset 0x8000."
    partition.CorruptPartitionData ->
      "The partition table at flash offset 0x8000 contains corrupt data."
    partition.PartitionNotFound(name) ->
      "The device partition table does not contain a " <> name <> " partition."
    partition.DuplicatePartition(name) ->
      "The device partition table contains more than one "
      <> name
      <> " partition."
    partition.InvalidPartitionType(name) ->
      "The " <> name <> " entry is not a data partition."
    partition.PartitionNotLast(name:, next:) ->
      "Cannot expand "
      <> name
      <> " because partition "
      <> next
      <> " follows it.\nExpanding it would overwrite another partition."
    partition.PartitionExceedsFlash(name) ->
      "Partition " <> name <> " extends beyond the detected physical flash."
    partition.OverlappingPartitions(first:, second:) ->
      "Partitions "
      <> first
      <> " and "
      <> second
      <> " overlap; refusing to modify the table."
    partition.InvalidFlashSize ->
      "Esptool returned an invalid physical flash size."
  }
}

fn bug_report_call_to_action() -> String {
  "This is most likely a bug, please open a bug report at\n"
  <> "https://github.com/giacomocavalieri/orbital/issues/new"
}

fn error_heading(title: String) -> String {
  ansi.bold(ansi.red("Error: ") <> title)
}

/// Compiles the given project using the provided Gleam executable.
///
fn compile(gleam: ExecutablePath, project: Project) -> Result(Nil, Error) {
  use exit_code <- result.try(
    executable.run(gleam, project.root_directory, ["build"])
    |> result.replace_error(CannotSpawnGleamCompiler),
  )
  case exit_code {
    0 -> Ok(Nil)
    _ -> Error(CannotCompileProject)
  }
}

/// Makes sure that the project has a valid entry point, suitable to be used by
/// AtomVM.
///
fn validate_entrypoint(
  gleam: ExecutablePath,
  project: Project,
) -> Result(Nil, Error) {
  // We need to first build the project's package interface, that has info about
  // all the functions defined by the project.
  // We do that in a temporary directory so it gets cleaned up automatically!
  let outcome = {
    use directory <- temporary.create(temporary.directory())
    let file = filepath.join(directory, "package_interface.json")
    let options = ["export", "package-interface", "--out", file]
    use _ <- result.try(
      executable.run(gleam, project.root_directory, options)
      |> result.replace_error(CannotSpawnGleamCompiler),
    )
    use package_interface <- result.try(
      simplifile.read(file)
      |> result.map_error(CannotReadPackageInterface),
    )
    use package_interface <- result.try(
      json.parse(package_interface, package_interface.decoder())
      |> result.map_error(CannotParsePackageInterface),
    )
    use entrypoint_module <- result.try(
      dict.get(package_interface.modules, project.name)
      |> result.replace_error(CannotFindEntrypointModule(project.name)),
    )
    use entrypoint_function <- result.try(
      dict.get(entrypoint_module.functions, "start")
      |> result.replace_error(CannotFindEntrypointFunction(project.name)),
    )
    case entrypoint_function.parameters {
      [] -> Ok(Nil)
      _ -> Error(EntrypointFunctionHasWrongArity(project.name))
    }
  }

  case outcome {
    Ok(result) -> result
    Error(error) -> Error(CannotReadPackageInterface(error))
  }
}

/// Bundles all the `.beam` files of the project into a single `.avm` file
/// located at the given path.
///
fn bundle_beam_files(
  project: Project,
  output_path: String,
) -> Result(Nil, Error) {
  use beam_files <- result.try(
    list_beam_files(project)
    |> result.map_error(CannotListBeamFiles),
  )
  packbeam_create(output_path:, start_module: project.name, beam_files:)
}

/// Lists all the `.beam` files under the given project's build directory.
///
fn list_beam_files(
  project: Project,
) -> Result(List(String), simplifile.FileError) {
  let build_directory =
    filepath.join(project.root_directory, "build")
    |> filepath.join("dev")
    |> filepath.join("erlang")

  use files <- result.try(simplifile.get_files(build_directory))
  let beam_files =
    list.filter(files, keeping: fn(file) {
      filepath.extension(file) == Ok("beam")
    })

  Ok(beam_files)
}

@external(erlang, "orbital_ffi", "packbeam_create")
fn packbeam_create(
  output_path output_path: String,
  start_module module: String,
  beam_files files: List(String),
) -> Result(Nil, Error)

@external(erlang, "orbital_ffi", "packbeam_list")
fn packbeam_list(input_path input_path: String) -> Result(List(String), Nil)

fn resolve_offset(
  esptool: ExecutablePath,
  directory: String,
  port: Option(String),
  baud: Option(Int),
  offset: Option(String),
) -> Result(String, Error) {
  case offset {
    Some(offset) -> Ok(offset)
    None -> read_main_avm_offset(esptool, directory, port, baud)
  }
}

fn read_main_avm_offset(
  esptool: ExecutablePath,
  directory: String,
  port: Option(String),
  baud: Option(Int),
) -> Result(String, Error) {
  let table_path = filepath.join(directory, "partition-table.bin")
  let baud = option.unwrap(baud, default_baud) |> int.to_string
  let port_arguments = case port {
    Some(port) -> ["--port", port]
    None -> []
  }
  let outcome =
    executable.run(
      esptool,
      ".",
      list.append(port_arguments, [
        "--chip", "auto", "--baud", baud, "read-flash", "--no-progress",
        "0x8000", "0xC00", table_path,
      ]),
    )

  case outcome {
    Ok(0) ->
      case simplifile.read_bits(table_path) {
        Ok(table) ->
          case partition.main_avm_offset(table) {
            Ok(offset) -> Ok(partition.hex_address(offset))
            Error(_) -> Error(CannotFindMainPartition)
          }
        Error(_) -> Error(CannotReadPartitionTable)
      }
    Ok(2) -> Error(EsptoolCannotOpenPort(option.unwrap(port, "auto")))
    Ok(_) -> Error(CannotReadPartitionTable)
    Error(_) -> Error(CannotSpawnEsptool)
  }
}

fn esp_flash_to_device(
  esptool: ExecutablePath,
  output_path: String,
  port: Option(String),
  baud: Option(Int),
  offset: String,
) -> Result(Nil, Error) {
  let baud = option.unwrap(baud, default_baud) |> int.to_string
  let port_arguments = case port {
    Some(port) -> ["--port", port]
    None -> []
  }
  let outcome =
    executable.run(
      esptool,
      ".",
      list.append(port_arguments, [
        "--chip", "auto", "--baud", baud, "--before", "default-reset", "--after",
        "hard-reset", "write-flash", "-u", "--flash-mode", "keep",
        "--flash-freq", "keep", "--flash-size", "detect", offset, output_path,
      ]),
    )

  case outcome {
    Ok(0) -> Ok(Nil)
    Ok(2) -> Error(EsptoolCannotOpenPort(option.unwrap(port, "auto")))
    Ok(n) -> Error(CannotFlashWithEsptool(n))
    Error(_) -> Error(CannotSpawnEsptool)
  }
}

// --- CLI PRETTY PRINTING -----------------------------------------------------

fn try_step(
  line: String,
  do: fn() -> Result(a, b),
  then: fn(a) -> Result(c, b),
) -> Result(c, b) {
  io.println(ansi.dim(line))
  let result = do()
  delete_line()
  result.try(result, then)
}

fn delete_line() -> Nil {
  let go_back_to_previous_line = "\u{1b}[1F"
  let delete_entire_line = "\u{1b}[2K"
  io.print(go_back_to_previous_line <> delete_entire_line)
}
