import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import orbital/internal/devices.{
  PicoBootsel, Snapshot, UsbSerial, format_report,
}
import orbital/internal/esp32

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn format_report_empty_hint_test() {
  let report =
    format_report(Snapshot(
      esp32: Ok([]),
      pico_bootsel: [],
      pico_serial: [],
      other_serial: [],
      psp_path: None,
    ))
  report
  |> string.contains("No AtomVM targets found.")
  |> should.be_true
  report
  |> string.contains("Pico:")
  |> should.be_true
  report
  |> string.contains("ESP32:")
  |> should.be_true
}

pub fn format_report_pico_bootsel_commands_test() {
  let report =
    format_report(Snapshot(
      esp32: Ok([]),
      pico_bootsel: [
        PicoBootsel(label: "Pico 2", board: "pico2", path: "/Volumes/RP2350"),
      ],
      pico_serial: [],
      other_serial: [],
      psp_path: None,
    ))
  report
  |> string.contains("Connected AtomVM targets")
  |> should.be_true
  report
  |> string.contains("Pico (BOOTSEL)")
  |> should.be_true
  report
  |> string.contains("/Volumes/RP2350")
  |> should.be_true
  report
  |> string.contains(
    "install pico --board pico2 --pico-path /Volumes/RP2350",
  )
  |> should.be_true
  report
  |> string.contains("flash pico --pico-path /Volumes/RP2350")
  |> should.be_true
}

pub fn format_report_pico_serial_and_other_test() {
  let report =
    format_report(Snapshot(
      esp32: Ok([]),
      pico_bootsel: [],
      pico_serial: [
        UsbSerial(
          port: "/dev/cu.usbmodem83201",
          description: "Raspberry Pi Pico",
        ),
      ],
      other_serial: [
        UsbSerial(
          port: "/dev/cu.usbmodem6564BBBE13391",
          description: "Keyboardio Model 100",
        ),
      ],
      psp_path: None,
    ))
  report
  |> string.contains("Pico (serial)")
  |> should.be_true
  report
  |> string.contains("monitor pico --port /dev/cu.usbmodem83201 -t 0")
  |> should.be_true
  report
  |> string.contains("BOOTSEL")
  |> should.be_true
  report
  |> string.contains("Other USB serial")
  |> should.be_true
  report
  |> string.contains("Keyboardio Model 100")
  |> should.be_true
  report
  |> string.contains("not an AtomVM flash target")
  |> should.be_true
}

pub fn format_report_esp32_and_psp_test() {
  let report =
    format_report(Snapshot(
      esp32: Ok([
        esp32.Device(
          port: "/dev/cu.usbserial-0001",
          chip_family_name: "ESP32-S3",
          mac_address: "aa:bb:cc:dd:ee:ff",
          usb_mode: "UART",
          atomvm_installed: True,
          build_info: ["v0.7.0"],
          features: [],
        ),
      ]),
      pico_bootsel: [],
      pico_serial: [],
      other_serial: [],
      psp_path: Some("/tmp/ppsspp/PSP/GAME/ATOMVM"),
    ))
  report
  |> string.contains("ESP32")
  |> should.be_true
  report
  |> string.contains("ESP32-S3")
  |> should.be_true
  report
  |> string.contains("AtomVM: yes")
  |> should.be_true
  report
  |> string.contains("flash esp32 --port /dev/cu.usbserial-0001")
  |> should.be_true
  report
  |> string.contains("PSP")
  |> should.be_true
  report
  |> string.contains("flash psp --psp-path /tmp/ppsspp/PSP/GAME/ATOMVM")
  |> should.be_true
}

pub fn format_report_esp32_probe_error_test() {
  let report =
    format_report(Snapshot(
      esp32: Error("native helper missing"),
      pico_bootsel: [],
      pico_serial: [],
      other_serial: [],
      psp_path: None,
    ))
  report
  |> string.contains("ESP32")
  |> should.be_true
  report
  |> string.contains("could not probe ESP32 devices")
  |> should.be_true
  report
  |> string.contains("native helper missing")
  |> should.be_true
}
