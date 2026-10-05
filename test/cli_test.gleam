import gleam/option.{None, Some}
import gleeunit
import orbital/internal/cli.{Esp32, Flash, Monitor}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn esp32_flash_auto_detects_port_test() {
  let assert Ok(Flash(platform:, help: False)) = cli.parse(["flash", "esp32"])

  let assert Esp32(port:, baud:, dry_run:) = platform
  assert port == None
  assert baud == None
  assert dry_run == False
}

pub fn esp32_flash_accepts_an_explicit_port_test() {
  let assert Ok(Flash(platform: Esp32(port:, ..), help: False)) =
    cli.parse(["flash", "esp32", "--port", "/dev/ttyACM0"])

  assert port == Some("/dev/ttyACM0")
}

pub fn monitor_defaults_test() {
  let assert Ok(Monitor(port:, baud:, timeout:, reset: True, help: False)) =
    cli.parse(["monitor"])

  assert port == None
  assert baud == None
  assert timeout == None
}

pub fn monitor_flags_test() {
  let assert Ok(Monitor(port:, baud:, timeout:, reset: False, help: False)) =
    cli.parse([
      "monitor",
      "--port",
      "/dev/ttyACM0",
      "--baud",
      "9600",
      "--timeout",
      "0",
      "--no-reset",
    ])

  assert port == Some("/dev/ttyACM0")
  assert baud == Some(9600)
  assert timeout == Some(0)
}
