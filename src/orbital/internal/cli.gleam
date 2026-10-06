import glam/doc.{type Document}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam_community/ansi
import hoist.{type ValidatedFlagSpecs}

pub const orbital_version = "v1.1.0"

pub type Command {
  Version
  Usage
  Help
  Flash(platform: FlashPlatform, help: Bool)
  Build(output_file: Option(String), help: Bool)
  List(input_file: Option(String), help: Bool)
  Uf2create(
    output_file: Option(String),
    app_start: Option(String),
    family_id: Option(String),
    help: Bool,
  )
  Monitor(
    port: Option(String),
    baud: Option(Int),
    timeout: Option(Int),
    reset: Bool,
    help: Bool,
  )
  Install(
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    update: Bool,
    download_only: Bool,
    list_images: Bool,
    chip: Option(String),
    baud: Option(Int),
    port: Option(String),
    help: Bool,
  )
  InstallPico(
    board: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    download_only: Bool,
    list_images: Bool,
    pico_path: Option(String),
    pico_reset: Option(String),
    picotool: Option(String),
    help: Bool,
  )
  InstallWasm(
    env: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    download_only: Bool,
    list_images: Bool,
    with_atomvmlib: Bool,
    help: Bool,
  )
  Expand(port: Option(String), help: Bool)
  EraseFlash(port: Option(String), help: Bool)
  Info(help: Bool)
}

/// `offset` is the flash address of `main.avm`. `None` means read that address
/// from the device's partition table.
pub type FlashPlatform {
  Esp32(
    port: Option(String),
    baud: Option(Int),
    offset: Option(String),
    dry_run: Bool,
  )
  Pico(
    pico_path: Option(String),
    pico_reset: Option(String),
    picotool: Option(String),
    app_start: Option(String),
    family_id: Option(String),
  )
  Wasm(
    env: Option(String),
    image: Option(String),
    version: Option(String),
    repo: Option(String),
    output_dir: Option(String),
    atomvmlib: Option(String),
  )
}

pub type ParsingState {
  ParsingBase
  ParsingFlash
  ParsingFlashEsp32
  ParsingFlashPico
  ParsingFlashWasm
  ParsingHelp
  ParsingBuild
  ParsingList
  ParsingUf2create
  ParsingMonitor
  ParsingInstall
  ParsingInstallPico
  ParsingInstallWasm
  ParsingExpand
  ParsingEraseFlash
  ParsingInfo
}

pub type CustomError {
  UnknownCommand(command: String)
}

pub type Error {
  HoistError(state: ParsingState, error: hoist.ParseError(CustomError))
  InvalidFlashPlatform(platform: String)
  MissingRequiredPositionalArgument(state: ParsingState, argument: String)
  MissingRequiredFlag(state: ParsingState, flag: String)
  InvalidFlagValue(
    state: ParsingState,
    flag: String,
    value: String,
    expected: String,
  )
  ConflictingFlags(message: String)
}

pub fn parse(args: List(String)) -> Result(Command, Error) {
  let #(parsing_state, result) = parse_args(args)
  case result {
    Ok(hoist.Args(arguments: [], flags:)) ->
      case toggled(flags, "version") {
        // If there's no argument at all we just show the "usage" page.
        False -> Ok(Usage)
        // If the version flag was toggled we show the version.
        True -> Ok(Version)
      }

    // "help" is pretty straightforward, the parsing done by hoist
    // is plenty enough.
    Ok(hoist.Args(arguments: ["help"], flags: _)) -> Ok(Help)

    // "build" too since it only needs the help flag!
    Ok(hoist.Args(arguments: ["build"], flags:)) ->
      Ok(Build(
        output_file: option.from_result(find_flag_value(flags, "output-file")),
        help: toggled(flags, "help"),
      ))

    // "list" too since it only needs the help flag!
    Ok(hoist.Args(arguments: ["list"], flags:)) ->
      Ok(List(
        input_file: option.from_result(find_flag_value(flags, "file")),
        help: toggled(flags, "help"),
      ))

    // with "flash" we need a little additional checks: first we need to make
    // sure that the required platform positional argument was provided.
    // If "baud" was provided we need to validate that it's an Int. The ESP32
    // port is optional: esptool auto-detects it when `--port` is omitted.
    Ok(hoist.Args(arguments: ["flash", ..rest], flags:)) ->
      case toggled(flags, "help"), rest {
        True, _ ->
          Ok(Flash(
            platform: Esp32(
              port: None,
              baud: None,
              offset: None,
              dry_run: False,
            ),
            help: True,
          ))

        False, [] ->
          Error(MissingRequiredPositionalArgument(ParsingFlash, "[PLATFORM]"))

        False, [_, unknown, ..] ->
          UnknownCommand(unknown)
          |> hoist.CustomError
          |> HoistError(state: parsing_state)
          |> Error

        False, ["pico"] -> {
          use app_start <- app_start_flag(flags, ParsingFlashPico)
          use family_id <- family_id_flag(flags, ParsingFlashPico)
          Ok(Flash(
            platform: Pico(
              pico_path: option.from_result(find_flag_value(flags, "pico-path")),
              pico_reset: option.from_result(find_flag_value(
                flags,
                "pico-reset",
              )),
              picotool: option.from_result(find_flag_value(flags, "picotool")),
              app_start:,
              family_id:,
            ),
            help: False,
          ))
        }

        False, ["wasm"] ->
          Ok(Flash(
            platform: Wasm(
              env: option.from_result(find_flag_value(flags, "env")),
              image: option.from_result(find_flag_value(flags, "image")),
              version: option.from_result(find_flag_value(flags, "version")),
              repo: option.from_result(find_flag_value(flags, "repo")),
              output_dir: option.from_result(find_flag_value(
                flags,
                "output-dir",
              )),
              atomvmlib: option.from_result(find_flag_value(flags, "atomvmlib")),
            ),
            help: False,
          ))

        False, ["esp32"] -> {
          use baud <- optional_int_flag(flags, ParsingFlash, "baud")
          use offset <- offset_flag(flags, ParsingFlash)
          let dry_run = toggled(flags, "dry-run")
          Ok(Flash(
            platform: Esp32(
              port: option.from_result(find_flag_value(flags, "port")),
              baud:,
              offset:,
              dry_run:,
            ),
            help: False,
          ))
        }

        False, [platform] -> Error(InvalidFlashPlatform(platform))
      }

    Ok(hoist.Args(arguments: ["uf2create"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(Uf2create(
            output_file: None,
            app_start: None,
            family_id: None,
            help: True,
          ))
        False -> {
          use app_start <- app_start_flag(flags, ParsingUf2create)
          use family_id <- family_id_flag(flags, ParsingUf2create)
          Ok(Uf2create(
            output_file: option.from_result(find_flag_value(
              flags,
              "output-file",
            )),
            app_start:,
            family_id:,
            help: False,
          ))
        }
      }

    Ok(hoist.Args(arguments: ["monitor"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(Monitor(
            port: None,
            baud: None,
            timeout: None,
            reset: True,
            help: True,
          ))
        False -> {
          use baud <- optional_int_flag(flags, ParsingMonitor, "baud")
          use timeout <- optional_int_flag(flags, ParsingMonitor, "timeout")
          case baud, timeout {
            Some(baud), _ if baud < 1 ->
              Error(InvalidFlagValue(
                state: ParsingMonitor,
                flag: "baud",
                value: int.to_string(baud),
                expected: "an integer greater than zero",
              ))
            _, Some(timeout) if timeout < 0 ->
              Error(InvalidFlagValue(
                state: ParsingMonitor,
                flag: "timeout",
                value: int.to_string(timeout),
                expected: "a number of seconds, or 0 to run until interrupted",
              ))
            _, _ ->
              Ok(Monitor(
                port: option.from_result(find_flag_value(flags, "port")),
                baud:,
                timeout:,
                reset: !toggled(flags, "no-reset"),
                help: False,
              ))
          }
        }
      }

    Ok(hoist.Args(arguments: ["install"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(Install(
            image: None,
            version: None,
            repo: None,
            update: False,
            download_only: False,
            list_images: False,
            chip: None,
            baud: None,
            port: None,
            help: True,
          ))
        False -> parse_esp32_install(flags, ParsingInstall)
      }

    Ok(hoist.Args(arguments: ["install", "esp32"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(Install(
            image: None,
            version: None,
            repo: None,
            update: False,
            download_only: False,
            list_images: False,
            chip: None,
            baud: None,
            port: None,
            help: True,
          ))
        False -> parse_esp32_install(flags, ParsingInstall)
      }

    Ok(hoist.Args(arguments: ["install", "pico"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(InstallPico(
            board: None,
            image: None,
            version: None,
            repo: None,
            download_only: False,
            list_images: False,
            pico_path: None,
            pico_reset: None,
            picotool: None,
            help: True,
          ))
        False -> {
          let image = option.from_result(find_flag_value(flags, "image"))
          let version = option.from_result(find_flag_value(flags, "version"))
          let repo = option.from_result(find_flag_value(flags, "repo"))
          let board = option.from_result(find_flag_value(flags, "board"))
          let download_only = toggled(flags, "download-only")
          let list_images = toggled(flags, "list-images")
          use Nil <- result.try(validate_pico_install_flags(
            board:,
            image:,
            version:,
            download_only:,
            list_images:,
          ))
          Ok(InstallPico(
            board:,
            image:,
            version:,
            repo:,
            download_only:,
            list_images:,
            pico_path: option.from_result(find_flag_value(flags, "pico-path")),
            pico_reset: option.from_result(find_flag_value(flags, "pico-reset")),
            picotool: option.from_result(find_flag_value(flags, "picotool")),
            help: False,
          ))
        }
      }

    Ok(hoist.Args(arguments: ["install", "wasm"], flags:)) ->
      case toggled(flags, "help") {
        True ->
          Ok(InstallWasm(
            env: None,
            image: None,
            version: None,
            repo: None,
            download_only: False,
            list_images: False,
            with_atomvmlib: True,
            help: True,
          ))
        False -> {
          let image = option.from_result(find_flag_value(flags, "image"))
          let version = option.from_result(find_flag_value(flags, "version"))
          let repo = option.from_result(find_flag_value(flags, "repo"))
          let env = option.from_result(find_flag_value(flags, "env"))
          let download_only = toggled(flags, "download-only")
          let list_images = toggled(flags, "list-images")
          use Nil <- result.try(validate_wasm_install_flags(
            env:,
            image:,
            version:,
            download_only:,
            list_images:,
          ))
          Ok(InstallWasm(
            env:,
            image:,
            version:,
            repo:,
            download_only:,
            list_images:,
            with_atomvmlib: !toggled(flags, "no-atomvmlib"),
            help: False,
          ))
        }
      }

    Ok(hoist.Args(arguments: ["expand"], flags:)) ->
      case toggled(flags, "help") {
        True -> Ok(Expand(port: None, help: True))
        False ->
          Ok(Expand(
            port: option.from_result(find_flag_value(flags, "port")),
            help: False,
          ))
      }

    Ok(hoist.Args(arguments: ["erase-flash"], flags:)) ->
      case toggled(flags, "help") {
        True -> Ok(EraseFlash(port: None, help: True))
        False ->
          Ok(EraseFlash(
            port: option.from_result(find_flag_value(flags, "port")),
            help: False,
          ))
      }

    Ok(hoist.Args(arguments: ["info"], flags:)) ->
      Ok(Info(help: toggled(flags, "help")))

    // Any other command is invalid. Hoist should prevent against this, but
    // rather than panicking I just use the same error.
    Ok(hoist.Args(arguments: [command, ..], flags: _)) -> {
      UnknownCommand(command)
      |> hoist.CustomError
      |> HoistError(state: parsing_state)
      |> Error
    }

    Error(error) -> Error(HoistError(parsing_state, error))
  }
}

fn parse_args(
  args: List(String),
) -> #(ParsingState, Result(hoist.Args, hoist.ParseError(CustomError))) {
  let flags = base_flags()
  hoist.parse_with_hook(args, flags, ParsingBase, fn(state, command, _, flags) {
    case command, state {
      // The base cli only accepts "help", or "flash" as commands.
      "build", ParsingBase -> Ok(#(ParsingBuild, build_flags()))

      "flash", ParsingBase -> Ok(#(ParsingFlash, base_flash_flags()))
      "esp32", ParsingFlash -> Ok(#(ParsingFlashEsp32, esp_flash_flags()))
      "pico", ParsingFlash -> Ok(#(ParsingFlashPico, pico_flash_flags()))
      "wasm", ParsingFlash -> Ok(#(ParsingFlashWasm, wasm_flash_flags()))

      "list", ParsingBase -> Ok(#(ParsingList, list_flags()))
      "uf2create", ParsingBase -> Ok(#(ParsingUf2create, uf2create_flags()))
      "monitor", ParsingBase -> Ok(#(ParsingMonitor, monitor_flags()))
      "install", ParsingBase -> Ok(#(ParsingInstall, install_flags()))
      "esp32", ParsingInstall -> Ok(#(ParsingInstall, install_flags()))
      "pico", ParsingInstall -> Ok(#(ParsingInstallPico, pico_install_flags()))
      "wasm", ParsingInstall -> Ok(#(ParsingInstallWasm, wasm_install_flags()))
      "expand", ParsingBase -> Ok(#(ParsingExpand, expand_flags()))
      "erase-flash", ParsingBase ->
        Ok(#(ParsingEraseFlash, erase_flash_flags()))
      "info", ParsingBase -> Ok(#(ParsingInfo, info_flags()))
      "help", ParsingBase -> Ok(#(ParsingHelp, help_flags()))
      _, ParsingBase -> Error(UnknownCommand(command:))

      // The "help" command accepts no subcommands
      _, ParsingHelp -> Error(UnknownCommand(command:))

      // The "build" command accepts no subcommands
      _, ParsingBuild -> Error(UnknownCommand(command:))

      // The "list" command accepts no subcommands
      _, ParsingList -> Error(UnknownCommand(command:))

      // The "uf2create" command accepts no subcommands
      _, ParsingUf2create -> Error(UnknownCommand(command:))

      // The "monitor" command accepts no subcommands
      _, ParsingMonitor -> Error(UnknownCommand(command:))

      // The "install" command takes esp32/pico/wasm platforms
      _, ParsingInstall | _, ParsingInstallPico | _, ParsingInstallWasm ->
        Ok(#(state, flags))

      // The "expand" command accepts no subcommands
      _, ParsingExpand -> Error(UnknownCommand(command:))

      // The "erase-flash" command accepts no subcommands
      _, ParsingEraseFlash -> Error(UnknownCommand(command:))

      // The "info" command accepts no subcommands
      _, ParsingInfo -> Error(UnknownCommand(command:))

      // The "flash" command takes positional arguments, but no subcommands, so
      // there's no need to special case any of them as they don't change the
      // accepted flags
      _, ParsingFlash
      | _, ParsingFlashEsp32
      | _, ParsingFlashPico
      | _, ParsingFlashWasm
      -> Ok(#(state, flags))
    }
  })
}

fn base_flags() -> ValidatedFlagSpecs {
  let assert Ok(base_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
      hoist.new_flag("version")
        |> hoist.with_short_alias("v")
        |> hoist.as_toggle,
    ])
  base_flags
}

fn help_flags() -> ValidatedFlagSpecs {
  let assert Ok(help_flags) = hoist.validate_flag_specs([])
  help_flags
}

fn build_flags() -> ValidatedFlagSpecs {
  let assert Ok(build_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
      hoist.new_flag("output-file")
        |> hoist.with_short_alias("o"),
    ])
  build_flags
}

fn list_flags() -> ValidatedFlagSpecs {
  let assert Ok(list_avm_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
      hoist.new_flag("file")
        |> hoist.with_short_alias("f"),
    ])
  list_avm_flags
}

fn base_flash_flags() -> ValidatedFlagSpecs {
  let assert Ok(flash_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
      |> hoist.with_short_alias("h")
      |> hoist.as_toggle,
    ])
  flash_flags
}

fn esp_flash_flags() -> ValidatedFlagSpecs {
  let assert Ok(esp_flash_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("port")
        |> hoist.with_short_alias("p"),
      hoist.new_flag("baud")
        |> hoist.with_short_alias("b"),
      hoist.new_flag("dry-run")
        |> hoist.with_short_alias("d")
        |> hoist.as_toggle,
      hoist.new_flag("offset"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  esp_flash_flags
}

fn pico_flash_flags() -> ValidatedFlagSpecs {
  let assert Ok(pico_flash_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("pico-path"),
      hoist.new_flag("pico-reset"),
      hoist.new_flag("picotool"),
      hoist.new_flag("app-start"),
      hoist.new_flag("family-id"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  pico_flash_flags
}

fn wasm_flash_flags() -> ValidatedFlagSpecs {
  let assert Ok(wasm_flash_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("env"),
      hoist.new_flag("image"),
      hoist.new_flag("version"),
      hoist.new_flag("repo"),
      hoist.new_flag("output-dir")
        |> hoist.with_short_alias("o"),
      hoist.new_flag("atomvmlib"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  wasm_flash_flags
}

fn uf2create_flags() -> ValidatedFlagSpecs {
  let assert Ok(uf2create_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
      hoist.new_flag("output-file")
        |> hoist.with_short_alias("o"),
      hoist.new_flag("app-start"),
      hoist.new_flag("family-id"),
    ])
  uf2create_flags
}

fn monitor_flags() -> ValidatedFlagSpecs {
  let assert Ok(monitor_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("port")
        |> hoist.with_short_alias("p"),
      hoist.new_flag("baud")
        |> hoist.with_short_alias("b"),
      hoist.new_flag("timeout")
        |> hoist.with_short_alias("t"),
      hoist.new_flag("no-reset")
        |> hoist.as_toggle,
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  monitor_flags
}

fn install_flags() -> ValidatedFlagSpecs {
  let assert Ok(install_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("image"),
      hoist.new_flag("version"),
      hoist.new_flag("repo"),
      hoist.new_flag("update")
        |> hoist.as_toggle,
      hoist.new_flag("download-only")
        |> hoist.as_toggle,
      hoist.new_flag("list-images")
        |> hoist.as_toggle,
      hoist.new_flag("chip"),
      hoist.new_flag("baud")
        |> hoist.with_short_alias("b"),
      hoist.new_flag("port")
        |> hoist.with_short_alias("p"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  install_flags
}

fn pico_install_flags() -> ValidatedFlagSpecs {
  let assert Ok(pico_install_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("board"),
      hoist.new_flag("image"),
      hoist.new_flag("version"),
      hoist.new_flag("repo"),
      hoist.new_flag("download-only")
        |> hoist.as_toggle,
      hoist.new_flag("list-images")
        |> hoist.as_toggle,
      hoist.new_flag("pico-path"),
      hoist.new_flag("pico-reset"),
      hoist.new_flag("picotool"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  pico_install_flags
}

fn wasm_install_flags() -> ValidatedFlagSpecs {
  let assert Ok(wasm_install_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("env"),
      hoist.new_flag("image"),
      hoist.new_flag("version"),
      hoist.new_flag("repo"),
      hoist.new_flag("download-only")
        |> hoist.as_toggle,
      hoist.new_flag("list-images")
        |> hoist.as_toggle,
      hoist.new_flag("no-atomvmlib")
        |> hoist.as_toggle,
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  wasm_install_flags
}

fn parse_esp32_install(
  flags: List(hoist.Flag),
  state: ParsingState,
) -> Result(Command, Error) {
  use baud <- optional_int_flag(flags, state, "baud")
  let image = option.from_result(find_flag_value(flags, "image"))
  let version = option.from_result(find_flag_value(flags, "version"))
  let repo = option.from_result(find_flag_value(flags, "repo"))
  let chip = option.from_result(find_flag_value(flags, "chip"))
  let update = toggled(flags, "update")
  let download_only = toggled(flags, "download-only")
  let list_images = toggled(flags, "list-images")
  use Nil <- result.try(validate_install_flags(
    image:,
    version:,
    update:,
    download_only:,
    list_images:,
    chip:,
  ))
  case baud {
    Some(baud) if baud < 1 ->
      Error(InvalidFlagValue(
        state:,
        flag: "baud",
        value: int.to_string(baud),
        expected: "an integer greater than zero",
      ))
    _ ->
      Ok(Install(
        image:,
        version:,
        repo:,
        update:,
        download_only:,
        list_images:,
        chip:,
        baud:,
        port: option.from_result(find_flag_value(flags, "port")),
        help: False,
      ))
  }
}

fn expand_flags() -> ValidatedFlagSpecs {
  let assert Ok(expand_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("port")
        |> hoist.with_short_alias("p"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  expand_flags
}

fn erase_flash_flags() -> ValidatedFlagSpecs {
  let assert Ok(erase_flash_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("port")
        |> hoist.with_short_alias("p"),
      hoist.new_flag("help")
        |> hoist.with_short_alias("h")
        |> hoist.as_toggle,
    ])
  erase_flash_flags
}

fn validate_install_flags(
  image image: Option(String),
  version version: Option(String),
  update update: Bool,
  download_only download_only: Bool,
  list_images list_images: Bool,
  chip chip: Option(String),
) -> Result(Nil, Error) {
  case list_images {
    True ->
      case
        option.is_some(image)
        || option.is_some(version)
        || update
        || download_only
      {
        True ->
          Error(ConflictingFlags(
            "--list-images cannot be combined with --image, --version, --update or --download-only",
          ))
        False -> Ok(Nil)
      }
    False ->
      case download_only && update {
        True ->
          Error(ConflictingFlags(
            "--download-only and --update cannot be used together",
          ))
        False ->
          case option.is_some(image) && option.is_some(version) {
            True ->
              Error(ConflictingFlags(
                "--image and --version cannot be used together",
              ))
            False ->
              case chip, download_only, image {
                Some(_), True, None -> Ok(Nil)
                Some(_), _, _ ->
                  Error(ConflictingFlags(
                    "--chip only applies to --list-images, and to --download-only without --image",
                  ))
                None, _, _ -> Ok(Nil)
              }
          }
      }
  }
}

fn validate_pico_install_flags(
  board board: Option(String),
  image image: Option(String),
  version version: Option(String),
  download_only download_only: Bool,
  list_images list_images: Bool,
) -> Result(Nil, Error) {
  case list_images {
    True ->
      case option.is_some(image) || option.is_some(version) || download_only {
        True ->
          Error(ConflictingFlags(
            "--list-images cannot be combined with --image, --version or --download-only",
          ))
        False -> Ok(Nil)
      }
    False ->
      case option.is_some(image) && option.is_some(version) {
        True ->
          Error(ConflictingFlags(
            "--image and --version cannot be used together",
          ))
        False ->
          case option.is_some(image) || option.is_some(board) || download_only {
            True ->
              case download_only, image, board {
                True, None, None ->
                  Error(ConflictingFlags(
                    "--download-only needs --board or --image",
                  ))
                _, _, _ -> Ok(Nil)
              }
            False ->
              Error(ConflictingFlags(
                "Pass --board pico|pico_w|pico2|pico2_w, or --image / --list-images",
              ))
          }
      }
  }
}

fn validate_wasm_install_flags(
  env env: Option(String),
  image image: Option(String),
  version version: Option(String),
  download_only download_only: Bool,
  list_images list_images: Bool,
) -> Result(Nil, Error) {
  let _ = download_only
  let _ = env
  case list_images {
    True ->
      case option.is_some(image) || option.is_some(version) || download_only {
        True ->
          Error(ConflictingFlags(
            "--list-images cannot be combined with --image, --version or --download-only",
          ))
        False -> Ok(Nil)
      }
    False ->
      case option.is_some(image) && option.is_some(version) {
        True ->
          Error(ConflictingFlags(
            "--image and --version cannot be used together",
          ))
        False -> Ok(Nil)
      }
  }
}

fn info_flags() -> ValidatedFlagSpecs {
  let assert Ok(info_flags) =
    hoist.validate_flag_specs([
      hoist.new_flag("help")
      |> hoist.with_short_alias("h")
      |> hoist.as_toggle,
    ])
  info_flags
}

const default_monitor_baud = "115200"

const default_monitor_timeout = "10"

// --- HELPERS TO WORK WITH FLAGS ----------------------------------------------

fn find_flag_value(flags: List(hoist.Flag), name: String) {
  list.find_map(flags, fn(flag) {
    case flag {
      hoist.ValueFlag(name: actual, value:) if actual == name -> Ok(value)
      hoist.CountFlag(..) | hoist.ValueFlag(..) | hoist.ToggleFlag(..) ->
        Error(Nil)
    }
  })
}

fn optional_int_flag(
  flags: List(hoist.Flag),
  state: ParsingState,
  flag: String,
  continue: fn(Option(Int)) -> Result(a, Error),
) -> Result(a, Error) {
  case find_flag_value(flags, flag) {
    Error(_) -> continue(None)
    Ok(value) ->
      case int.parse(value) {
        Ok(parsed) -> continue(Some(parsed))
        Error(_) ->
          Error(InvalidFlagValue(
            state:,
            flag: flag,
            value:,
            expected: "an integer",
          ))
      }
  }
}

fn offset_flag(
  flags: List(hoist.Flag),
  state: ParsingState,
  continue: fn(Option(String)) -> Result(a, Error),
) -> Result(a, Error) {
  case find_flag_value(flags, "offset") {
    Error(_) -> continue(None)
    Ok(value) ->
      case is_hex_address(value) {
        True -> continue(Some(value))
        False ->
          Error(InvalidFlagValue(
            state:,
            flag: "offset",
            value:,
            expected: "a hex address like 0x2b8000",
          ))
      }
  }
}

fn app_start_flag(
  flags: List(hoist.Flag),
  state: ParsingState,
  continue: fn(Option(String)) -> Result(a, Error),
) -> Result(a, Error) {
  case find_flag_value(flags, "app-start") {
    Error(_) -> continue(None)
    Ok(value) ->
      case is_app_start_address(value) {
        True -> continue(Some(value))
        False ->
          Error(InvalidFlagValue(
            state:,
            flag: "app-start",
            value:,
            expected: "an address like 0x10180000",
          ))
      }
  }
}

fn family_id_flag(
  flags: List(hoist.Flag),
  state: ParsingState,
  continue: fn(Option(String)) -> Result(a, Error),
) -> Result(a, Error) {
  case find_flag_value(flags, "family-id") {
    Error(_) -> continue(None)
    Ok(value) ->
      case is_family_id(value) {
        True -> continue(Some(value))
        False ->
          Error(InvalidFlagValue(
            state:,
            flag: "family-id",
            value:,
            expected: "rp2040, data, absolute, rp2350_arm_s, rp2350_riscv, rp2350_arm_ns, or universal",
          ))
      }
  }
}

fn is_app_start_address(value: String) -> Bool {
  case value {
    "0x" <> digits | "0X" <> digits -> digits != "" && hex_digits(digits)
    "16#" <> digits -> digits != "" && hex_digits(digits)
    _ ->
      case int.parse(value) {
        Ok(_) -> True
        Error(_) -> False
      }
  }
}

fn is_family_id(value: String) -> Bool {
  case string.lowercase(string.trim(value)) {
    "rp2040"
    | ":rp2040"
    | "rp2350_riscv"
    | ":rp2350_riscv"
    | "rp2350_arm_s"
    | ":rp2350_arm_s"
    | "rp2350_arm_ns"
    | ":rp2350_arm_ns"
    | "absolute"
    | ":absolute"
    | "data"
    | ":data"
    | "universal"
    | ":universal" -> True
    _ -> False
  }
}

fn is_hex_address(value: String) -> Bool {
  case value {
    "0x" <> digits | "0X" <> digits -> digits != "" && hex_digits(digits)
    _ -> False
  }
}

fn hex_digits(digits: String) -> Bool {
  digits
  |> string.to_graphemes
  |> list.all(fn(digit) {
    case digit {
      "0"
      | "1"
      | "2"
      | "3"
      | "4"
      | "5"
      | "6"
      | "7"
      | "8"
      | "9"
      | "a"
      | "b"
      | "c"
      | "d"
      | "e"
      | "f"
      | "A"
      | "B"
      | "C"
      | "D"
      | "E"
      | "F" -> True
      _ -> False
    }
  })
}

fn toggled(flags: List(hoist.Flag), name: String) {
  list.contains(flags, hoist.ToggleFlag(name))
}

pub fn usage_text() -> Document {
  [
    doc.from_string(ansi.magenta("⚛️  orbital - " <> orbital_version)),
    doc.lines(2),
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "[COMMAND]",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Commands:")),
    doc.line,
    command_line("  build        ", "build your code into an 'avm' file"),
    doc.line,
    command_line("  flash        ", "build and flash your code to a device"),
    doc.line,
    command_line("  uf2create    ", "build a Pico UF2 from your project"),
    doc.line,
    command_line("  info         ", "list connected ESP32 boards"),
    doc.line,
    command_line("  list         ", "list the contents of an 'avm' file"),
    doc.line,
    command_line("  monitor      ", "show the console of an ESP32 board"),
    doc.line,
    command_line("  install      ", "install AtomVM on ESP32, Pico, or WASM"),
    doc.line,
    command_line("  expand       ", "grow main.avm to the end of ESP32 flash"),
    doc.line,
    command_line("  erase-flash  ", "erase the flash of an ESP32 board"),
    doc.line,
    command_line("  help         ", "show this help text"),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line("  -v, --version  ", "print orbital's version"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn flash_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        "Build your project into an 'avm' file and flash it to the given device."
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "flash [PLATFORM] <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Platforms:")),
    doc.line,
    command_line("  esp32  ", "this will require `esptool` installed"),
    doc.line,
    flag_line(
      "    -p, --port     <STRING>  ",
      "serial port. esptool auto-detects it when omitted",
    ),
    doc.line,
    flag_line_with_default(
      "    -b, --baud     <INT>     ",
      "the baud used when flashing the device",
      "921_600",
    ),
    doc.line,
    flag_line(
      "    -d, --dry-run            ",
      "only show the command used to flash the device",
    ),
    doc.line,
    flag_line(
      "    --offset       <HEX>    ",
      "flash address. Read from the device's main.avm partition when omitted",
    ),
    doc.lines(2),
    command_line("  pico   ", "copy a UF2 onto a mounted Pico / Pico 2"),
    doc.line,
    flag_line(
      "    --pico-path    <PATH>   ",
      "Pico mount point (default: OS RPI-RP2 volume)",
    ),
    doc.line,
    flag_line(
      "    --pico-reset   <PATH>   ",
      "serial device glob used to enter BOOTSEL",
    ),
    doc.line,
    flag_line(
      "    --picotool     <PATH>   ",
      "optional picotool for BOOTSEL reset fallback",
    ),
    doc.line,
    flag_line_with_default(
      "    --app-start    <HEX>    ",
      "flash address of the application in the UF2",
      "0x10180000",
    ),
    doc.line,
    flag_line_with_default(
      "    --family-id    <ID>     ",
      "UF2 family (universal targets Pico and Pico 2)",
      "universal",
    ),
    doc.lines(2),
    command_line(
      "  wasm   ",
      "run under Node.js or export a browser WASM bundle",
    ),
    doc.line,
    flag_line_with_default(
      "    --env          <ENV>   ",
      "node runs the AVM; web writes a browser bundle",
      "node",
    ),
    doc.line,
    flag_line(
      "    --image        <PATH|NAME> ",
      "cached runtime directory or published AtomVM-node/web name",
    ),
    doc.line,
    flag_line(
      "    --version      <TAG>    ",
      "AtomVM release tag for the WASM runtime",
    ),
    doc.line,
    flag_line(
      "    --repo         <OWNER/REPO> ",
      "extra GitHub repository of custom builds",
    ),
    doc.line,
    flag_line_with_default(
      "    -o, --output-dir <PATH> ",
      "directory for --env web browser files",
      "wasm_out",
    ),
    doc.line,
    flag_line(
      "    --atomvmlib    <PATH>  ",
      "optional atomvmlib.avm (downloaded to match --version when omitted)",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Other flags:")),
    doc.line,
    flag_line("  -h, --help               ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn uf2create_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        [
          flex_text(
            "Build your project into an 'avm' file and convert it to a Pico UF2.",
          ),
          doc.line,
          flex_text(
            "`flash pico` runs this automatically; use this command when you "
            <> "only need the UF2 file.",
          ),
        ]
        |> doc.concat
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "uf2create <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line_with_default(
      "  -o, --output-file  <PATH>  ",
      "the path to write the UF2 file to",
      "\"name_of_your_project.uf2\"",
    ),
    doc.line,
    flag_line_with_default(
      "  --app-start        <HEX>   ",
      "flash address of the application in the UF2",
      "0x10180000",
    ),
    doc.line,
    flag_line_with_default(
      "  --family-id        <ID>    ",
      "UF2 family (universal targets Pico and Pico 2)",
      "universal",
    ),
    doc.line,
    flag_line("  -h, --help                  ", "show this help text"),
  ]
  |> doc.concat
}

pub fn build_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        [
          flex_text("Build your project into an 'avm' file."),
          doc.line,
          flex_text(
            "This is handy if you need to interact with the 'avm' file with "
            <> "additional tooling, otherwise you can use the `flash` command "
            <> "directly.",
          ),
        ]
        |> doc.concat
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "build <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line_with_default(
      "  -o, --output-file  <PATH>  ",
      "the path to write the 'avm' file to",
      "\"name_of_your_project.avm\"",
    ),
    doc.line,
    flag_line("  -h, --help                 ", "show this help text"),
  ]
  |> doc.concat
}

pub fn list_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        [flex_text("List the contents of an 'avm' file.")]
        |> doc.concat
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "list <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line_with_default(
      "  -f, --file  <PATH>  ",
      "the path to the 'avm' file",
      "\"name_of_your_project.avm\"",
    ),
    doc.line,
    flag_line("  -h, --help          ", "show this help text"),
  ]
  |> doc.concat
}

pub fn monitor_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        "Show what an ESP32 board writes on its serial port."
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "monitor <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line(
      "  -p, --port      <PATH>  ",
      "serial port. Chosen automatically when only one board is connected",
    ),
    doc.line,
    flag_line_with_default(
      "  -b, --baud      <INT>   ",
      "console baud rate. This is not the flashing baud",
      default_monitor_baud,
    ),
    doc.line,
    flag_line_with_default(
      "  -t, --timeout   <INT>   ",
      "stop after this many seconds. 0 reads until Ctrl+C, pressed twice",
      default_monitor_timeout,
    ),
    doc.line,
    flag_line(
      "  --no-reset              ",
      "do not reset the board, show its output from now on",
    ),
    doc.line,
    flag_line("  -h, --help              ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn install_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        "Install AtomVM firmware on a connected board."
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "install [PLATFORM] <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Platforms:")),
    doc.line,
    command_line("  esp32  ", "default when PLATFORM is omitted"),
    doc.line,
    flag_line(
      "    --image           <PATH|NAME>  ",
      "local .img/.zip or a published image name",
    ),
    doc.line,
    flag_line(
      "    --version         <TAG>        ",
      "AtomVM release tag to install (Elixir image)",
    ),
    doc.line,
    flag_line(
      "    --repo            <OWNER/REPO> ",
      "extra GitHub repository of custom builds",
    ),
    doc.line,
    flag_line(
      "    --update                       ",
      "update VM and boot.avm only; keep NVS and main.avm",
    ),
    doc.line,
    flag_line(
      "    --download-only                ",
      "download into firmware_images/ without flashing",
    ),
    doc.line,
    flag_line(
      "    --list-images                  ",
      "list installable images instead of installing",
    ),
    doc.line,
    flag_line(
      "    --chip            <CHIP|all>   ",
      "with --list-images or --download-only",
    ),
    doc.line,
    flag_line_with_default(
      "    -b, --baud        <INT>        ",
      "baud rate used when flashing",
      "921600",
    ),
    doc.line,
    flag_line(
      "    -p, --port         <PATH>       ",
      "serial port. Chosen automatically when only one board is connected",
    ),
    doc.lines(2),
    command_line(
      "  pico   ",
      "download a release UF2 and load it with picotool",
    ),
    doc.line,
    flag_line(
      "    --board           <BOARD>      ",
      "pico, pico_w, pico2, or pico2_w",
    ),
    doc.line,
    flag_line(
      "    --image           <PATH|NAME>  ",
      "local .uf2 or a published image name",
    ),
    doc.line,
    flag_line(
      "    --version         <TAG>        ",
      "AtomVM release tag (prefers combined UF2)",
    ),
    doc.line,
    flag_line(
      "    --repo            <OWNER/REPO> ",
      "extra GitHub repository of custom builds",
    ),
    doc.line,
    flag_line(
      "    --download-only                ",
      "download into firmware_images/ without flashing",
    ),
    doc.line,
    flag_line(
      "    --list-images                  ",
      "list installable Pico UF2s",
    ),
    doc.line,
    flag_line(
      "    --pico-path       <PATH>       ",
      "UF2 mount point fallback when picotool is unavailable",
    ),
    doc.line,
    flag_line(
      "    --pico-reset      <PATH>       ",
      "serial device glob used before mount-copy",
    ),
    doc.line,
    flag_line(
      "    --picotool        <PATH>       ",
      "picotool executable for force-load",
    ),
    doc.lines(2),
    command_line("  wasm   ", "download AtomVM Node.js / browser WASM runtimes"),
    doc.line,
    flag_line_with_default(
      "    --env             <ENV>        ",
      "node, web, or all",
      "all",
    ),
    doc.line,
    flag_line(
      "    --image           <PATH|NAME>  ",
      "cached runtime directory or published AtomVM-node/web name",
    ),
    doc.line,
    flag_line(
      "    --version         <TAG>        ",
      "AtomVM release tag to download",
    ),
    doc.line,
    flag_line(
      "    --repo            <OWNER/REPO> ",
      "extra GitHub repository of custom builds",
    ),
    doc.line,
    flag_line(
      "    --download-only                ",
      "same as install for WASM (runtimes are only cached)",
    ),
    doc.line,
    flag_line(
      "    --list-images                  ",
      "list Node/web WASM runtimes",
    ),
    doc.line,
    flag_line(
      "    --no-atomvmlib                 ",
      "skip downloading atomvmlib-*.avm",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Other flags:")),
    doc.line,
    flag_line("  -h, --help                       ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn expand_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        {
          "Expand the final main.avm partition to the end of the detected ESP32 flash, "
          <> "and update the bootloader flash-size header when needed."
        }
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "expand <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line(
      "  -p, --port      <PATH>  ",
      "serial port. Chosen automatically when only one board is connected",
    ),
    doc.line,
    flag_line("  -h, --help              ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn erase_flash_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        "Erase the entire flash of a connected ESP32 board."
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "erase-flash <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line(
      "  -p, --port      <PATH>  ",
      "serial port. Chosen automatically when only one board is connected",
    ),
    doc.line,
    flag_line("  -h, --help              ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn info_help_text(description: Bool) -> Document {
  [
    case description {
      False -> doc.empty
      True ->
        "List connected ESP32 boards and whether AtomVM is installed on them."
        |> flex_text
        |> doc.append(doc.lines(2))
    },
    doc.from_string(
      ansi.magenta("Usage: ")
      <> ansi.green("gleam run -m orbital ")
      <> "info <FLAGS>",
    ),
    doc.lines(2),
    doc.from_string(ansi.magenta("Flags:")),
    doc.line,
    flag_line("  -h, --help  ", "show this help text"),
  ]
  |> doc.concat
  |> doc.group
}

pub fn help_text_for_state(state: ParsingState) -> Document {
  case state {
    ParsingBase -> usage_text()
    ParsingFlash | ParsingFlashEsp32 | ParsingFlashPico | ParsingFlashWasm ->
      flash_help_text(False)
    ParsingHelp -> usage_text()
    ParsingBuild -> build_help_text(False)
    ParsingList -> list_help_text(False)
    ParsingUf2create -> uf2create_help_text(False)
    ParsingMonitor -> monitor_help_text(False)
    ParsingInstall | ParsingInstallPico | ParsingInstallWasm ->
      install_help_text(False)
    ParsingExpand -> expand_help_text(False)
    ParsingEraseFlash -> erase_flash_help_text(False)
    ParsingInfo -> info_help_text(False)
  }
}

fn command_line(name: String, description: String) -> Document {
  doc.concat([
    invisible_green(name),
    flex_text(description)
      |> doc.nest(by: string.length(name)),
  ])
}

fn flag_line(name: String, description: String) -> Document {
  doc.concat([
    doc.from_string(name),
    flex_text(description)
      |> doc.nest(by: string.length(name)),
  ])
}

fn flag_line_with_default(
  name: String,
  description: String,
  default: String,
) -> Document {
  [
    doc.from_string(name),
    [
      flex_text(description),
      doc.space,
      flex_text("(default: " <> default <> ")"),
    ]
      |> doc.concat
      |> doc.group
      |> doc.nest(by: string.length(name)),
  ]
  |> doc.concat
}

fn flex_text(text: String) -> Document {
  string.split(text, on: " ")
  |> list.map(doc.from_string)
  |> doc.join(doc.flex_space)
  |> doc.group
}

fn error_heading(title: String) -> Document {
  doc.from_string(ansi.bold(ansi.red("Error: ") <> title))
}

pub fn error_to_document(error: Error) -> Document {
  case error {
    MissingRequiredPositionalArgument(state:, argument:) ->
      doc.concat([
        error_heading("missing argument " <> argument),
        doc.lines(2),
        help_text_for_state(state),
      ])

    MissingRequiredFlag(state:, flag:) ->
      doc.concat([
        error_heading("missing flag --" <> flag),
        doc.lines(2),
        help_text_for_state(state),
      ])

    InvalidFlagValue(state:, flag:, value:, expected:) ->
      doc.concat([
        error_heading("invalid --" <> flag <> " value"),
        doc.line,
        flex_text(
          "The flag --"
          <> flag
          <> " expects "
          <> expected
          <> " but it was given the value '"
          <> value
          <> "'",
        ),
        doc.lines(2),
        help_text_for_state(state),
      ])

    InvalidFlashPlatform(platform:) ->
      doc.concat([
        error_heading("invalid platform"),
        doc.line,
        flex_text("'" <> platform <> "' is not a supported platform."),
        doc.lines(2),
        help_text_for_state(ParsingFlash),
      ])

    ConflictingFlags(message:) ->
      doc.concat([
        error_heading("conflicting flags"),
        doc.line,
        flex_text(message),
        doc.lines(2),
        help_text_for_state(ParsingInstall),
      ])

    HoistError(state:, error: hoist.UnknownFlag(flag)) ->
      doc.concat([
        error_heading("unknown flag '" <> flag <> "'"),
        case state {
          ParsingFlash ->
            doc.concat([
              doc.line,
              doc.from_string("Hint: make sure to first specify a platform."),
            ])
          _ -> doc.empty
        },
        doc.lines(2),
        help_text_for_state(state),
      ])

    HoistError(state:, error: hoist.ValueNotProvided(flag:)) ->
      doc.concat([
        error_heading("missing value for flag '" <> flag <> "'"),
        doc.line,
        flex_text(
          "The flag '"
          <> flag
          <> "' must have a value, but no value was passed to it",
        ),
        doc.lines(2),
        help_text_for_state(state),
      ])

    HoistError(state:, error: hoist.ValueNotSupported(flag:, given:)) ->
      doc.concat([
        error_heading("invalid " <> flag <> " value"),
        doc.line,
        flex_text(
          "The flag --"
          <> flag
          <> " is used as a toggle and expects no value,"
          <> " but it was given the value '"
          <> given
          <> "'",
        ),
        doc.lines(2),
        help_text_for_state(state),
      ])

    HoistError(
      state:,
      error: hoist.CustomError(value: UnknownCommand(command:)),
    ) ->
      doc.concat([
        error_heading("unknown command '" <> command <> "'"),
        doc.lines(2),
        help_text_for_state(state),
      ])
  }
}

fn invisible_green(text: String) -> Document {
  doc.concat([
    doc.zero_width_string("\u{1b}[0;32m"),
    doc.from_string(text),
    doc.zero_width_string("\u{1b}[0m"),
  ])
}
