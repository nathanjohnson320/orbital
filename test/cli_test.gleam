import gleam/option.{None, Some}
import gleeunit
import orbital/internal/cli.{Esp32, Flash, Monitor}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn esp32_flash_starts_at_the_current_partition_test() {
  let assert Ok(Flash(platform:, help: False)) =
    cli.parse(["flash", "esp32", "--port", "/dev/ttyACM0"])

  let assert Esp32(port:, baud:, offset:, dry_run:) = platform
  assert port == "/dev/ttyACM0"
  assert baud == None
  assert offset == "0x250000"
  assert dry_run == False
}

pub fn esp32_flash_offset_can_be_overridden_test() {
  let assert Ok(Flash(platform: Esp32(offset:, ..), help: False)) =
    cli.parse([
      "flash", "esp32", "--port", "/dev/ttyACM0", "--offset", "0x210000",
    ])

  assert offset == "0x210000"
}

pub fn esp32_flash_rejects_a_bad_offset_test() {
  let assert Error(_) =
    cli.parse(["flash", "esp32", "--port", "/dev/ttyACM0", "--offset", "main"])
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
