//// Serial console for `gleam run -m orbital monitor`.
////
//// Uses the orbital_serial NIF. Reset order matches ExAtomVM: assert RTS+DTR
//// after open, release RTS then DTR, optionally pulse RTS for the boot log.
////
//// Port auto-detect:
//// - single USB serial → use it (ESP32 or Pico)
//// - `esp32` → same ESP32 probe as flash
//// - `pico` → USB serials that are not probed ESP32 devices
//// - bare `monitor` with several ports → ESP32 probe when exactly one ESP32
////   answers; otherwise ask for a platform or `--port`

import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import orbital/internal/esp32

pub type SerialPort

pub type Target {
  Auto
  Esp32
  Pico
}

type PortInfo {
  PortInfo(name: String, description: String, transport: String)
}

type ReadResult {
  Bytes(BitArray)
  TimedOut
  PortGone
  Failed(String)
}

pub fn run(
  target: Target,
  port: String,
  baud: Int,
  reset: Bool,
  timeout_seconds: Int,
) -> Result(Nil, String) {
  use resolved <- result.try(resolve_port(target, port))
  io.println_error("Serial port " <> resolved)
  read_console(resolved, baud, reset, timeout_seconds)
}

fn resolve_port(target: Target, port: String) -> Result(String, String) {
  case port {
    "auto" -> resolve_auto(target)
    explicit -> Ok(explicit)
  }
}

fn resolve_auto(target: Target) -> Result(String, String) {
  use serials <- result.try(usb_ports())
  case target, serials {
    _, [only] -> Ok(only.name)

    Esp32, _ -> select_esp32_port()

    Pico, [] ->
      Error(
        "No serial port found.\n"
        <> "Hold BOOT, tap RESET, release BOOT, and try again.",
      )

    Pico, many -> select_pico_port(many)

    Auto, [] ->
      Error(
        "No serial port found.\n"
        <> "Hold BOOT, tap RESET, release BOOT, and try again.",
      )

    Auto, many ->
      case esp32.list_devices() {
        Ok([device]) -> Ok(device.port)
        Ok([]) ->
          Error(
            "Several serial ports found:\n"
            <> port_lines(many)
            <> "\nPass a platform (esp32 or pico) or --port.",
          )
        Ok(_) -> Error("Several ESP32 devices found.\nPass one with --port.")
        Error(esp32.ToolingMissing(reason)) -> Error(reason)
        Error(esp32.DeviceError(reason)) -> Error(reason)
      }
  }
}

fn select_esp32_port() -> Result(String, String) {
  esp32.select_port("auto")
  |> result.map_error(fn(error) {
    case error {
      esp32.ToolingMissing(reason) -> reason
      esp32.DeviceError(reason) -> reason
    }
  })
}

fn select_pico_port(serials: List(PortInfo)) -> Result(String, String) {
  let esp_ports = case esp32.list_devices() {
    Ok(devices) -> list.map(devices, fn(device) { device.port })
    Error(_) -> []
  }
  let candidates =
    list.filter(serials, fn(info) { !list.contains(esp_ports, info.name) })
  case candidates {
    [only] -> Ok(only.name)
    [] ->
      Error(
        "No Pico serial port found.\n" <> "Unplug other boards, or pass --port.",
      )
    many ->
      Error(
        "Several serial ports found:\n"
        <> port_lines(many)
        <> "\nPass one with --port.",
      )
  }
}

fn port_lines(ports: List(PortInfo)) -> String {
  ports
  |> list.map(fn(info) { "  " <> info.name })
  |> string.join("\n")
}

fn usb_ports() -> Result(List(PortInfo), String) {
  use rows <- result.try(list_ports_raw())
  let family = os_family()
  let ports =
    list.map(rows, fn(row) {
      let #(name, description, transport) = row
      PortInfo(name:, description:, transport:)
    })
  Ok(list.filter(ports, fn(info) { is_monitor_candidate(info, family) }))
}

fn is_monitor_candidate(info: PortInfo, family: String) -> Bool {
  let name = string.lowercase(info.name)
  let description = string.lowercase(info.description)
  let transport = string.lowercase(info.transport)
  let blob = name <> " " <> description <> " " <> transport
  let skip_macos_tty =
    family == "darwin" && string.starts_with(info.name, "/dev/tty.")
  let usbish =
    transport == "usb"
    || list.any(
      [
        "usb", "acm", "slab", "wch", "espressif", "cp210", "ch340", "ftdi",
        "cu.usb", "ttyacm", "ttyusb",
      ],
      fn(token) { string.contains(blob, token) },
    )
  !skip_macos_tty && usbish
}

fn read_console(
  port_name: String,
  baud: Int,
  reset: Bool,
  timeout_seconds: Int,
) -> Result(Nil, String) {
  let deadline: Option(Int) = case timeout_seconds {
    0 -> None
    seconds -> Some(monotonic_time_ms() + seconds * 1000)
  }

  case open_configured(port_name, baud) {
    Error(reason) -> Error(reason)
    Ok(port) -> {
      case reset {
        True -> {
          set_rts_line(port, True, False)
          sleep_ms(100)
          set_rts_line(port, False, False)
        }
        False -> Nil
      }
      let #(at_line_start, _) =
        console_loop(port, port_name, baud, deadline, True, <<>>)
      let _ = ensure_newline(at_line_start)
      close(port)
      Ok(Nil)
    }
  }
}

fn open_configured(port_name: String, baud: Int) -> Result(SerialPort, String) {
  use port <- result.try(open(port_name, baud))
  set_rts_line(port, True, True)
  set_dtr(port, True)
  set_rts_line(port, False, True)
  set_dtr(port, False)
  Ok(port)
}

/// On Windows, rewrite DTR after RTS so usbser.sys applies the lines.
fn set_rts_line(port: SerialPort, rts: Bool, dtr: Bool) -> Nil {
  set_rts(port, rts)
  case os_family() == "windows" {
    True -> set_dtr(port, dtr)
    False -> Nil
  }
}

fn console_loop(
  port: SerialPort,
  port_name: String,
  baud: Int,
  deadline: Option(Int),
  at_line_start: Bool,
  pending: BitArray,
) -> #(Bool, BitArray) {
  case expired(deadline) {
    True -> #(at_line_start, pending)
    False ->
      case read(port, 1024, 100) {
        Bytes(data) -> {
          let #(text, next_pending) = utf8_feed(pending, data)
          let next_start = write_text(text, at_line_start)
          console_loop(
            port,
            port_name,
            baud,
            deadline,
            next_start,
            next_pending,
          )
        }
        TimedOut ->
          console_loop(port, port_name, baud, deadline, at_line_start, pending)
        PortGone | Failed(_) -> {
          let _ = ensure_newline(at_line_start)
          write_stdout("Waiting for the board to reconnect")
          close(port)
          case wait_reconnect(port_name, baud, deadline) {
            Error(Nil) -> #(True, <<>>)
            Ok(new_port) -> {
              write_stdout("\n")
              console_loop(new_port, port_name, baud, deadline, True, <<>>)
            }
          }
        }
      }
  }
}

fn wait_reconnect(
  port_name: String,
  baud: Int,
  deadline: Option(Int),
) -> Result(SerialPort, Nil) {
  case expired(deadline) {
    True -> Error(Nil)
    False -> {
      sleep_ms(500)
      case open_configured(port_name, baud) {
        Ok(port) -> Ok(port)
        Error(_) -> {
          write_stdout(".")
          wait_reconnect(port_name, baud, deadline)
        }
      }
    }
  }
}

fn expired(deadline: Option(Int)) -> Bool {
  case deadline {
    None -> False
    Some(ms) -> monotonic_time_ms() >= ms
  }
}

fn write_text(text: String, at_line_start: Bool) -> Bool {
  case text {
    "" -> at_line_start
    _ -> {
      write_stdout(text)
      string.ends_with(text, "\n")
    }
  }
}

fn ensure_newline(at_line_start: Bool) -> Bool {
  case at_line_start {
    True -> True
    False -> {
      write_stdout("\n")
      True
    }
  }
}

@external(erlang, "orbital_serial_ffi", "list_ports")
fn list_ports_raw() -> Result(List(#(String, String, String)), String)

@external(erlang, "orbital_serial_ffi", "open")
fn open(name: String, baud: Int) -> Result(SerialPort, String)

@external(erlang, "orbital_serial_ffi", "close")
fn close(port: SerialPort) -> Nil

@external(erlang, "orbital_serial_ffi", "read")
fn read(port: SerialPort, max_bytes: Int, timeout_ms: Int) -> ReadResult

@external(erlang, "orbital_serial_ffi", "set_rts")
fn set_rts(port: SerialPort, value: Bool) -> Nil

@external(erlang, "orbital_serial_ffi", "set_dtr")
fn set_dtr(port: SerialPort, value: Bool) -> Nil

@external(erlang, "orbital_serial_ffi", "write_stdout")
fn write_stdout(text: String) -> Nil

@external(erlang, "orbital_serial_ffi", "os_family")
fn os_family() -> String

@external(erlang, "orbital_serial_ffi", "monotonic_time_ms")
fn monotonic_time_ms() -> Int

@external(erlang, "orbital_serial_ffi", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

@external(erlang, "orbital_serial_ffi", "utf8_feed")
fn utf8_feed(pending: BitArray, data: BitArray) -> #(String, BitArray)
