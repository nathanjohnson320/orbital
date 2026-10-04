import gleam/option
import gleam/string
import gleeunit
import gleeunit/should
import orbital/internal/esp32
import orbital/internal/image_header

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn flash_size_id_keeps_frequency_nibble_test() {
  image_header.flash_size_id(<<0xe9, 4, 2, 0x2f, 0, 0, 0, 0>>)
  |> should.equal(Ok(0x20))

  image_header.flash_size(<<0xe9, 4, 2, 0x2f>>)
  |> should.equal(Ok(0x400000))

  image_header.flash_size_id(<<0xe9, 4, 2, 0x3f, 0, 0, 0, 0>>)
  |> should.equal(Ok(0x30))

  image_header.flash_size(<<0xe9, 4, 2, 0x3f>>)
  |> should.equal(Ok(0x800000))

  image_header.flash_size_id(<<0xe9, 4, 2, 0x4f, 0, 0, 0, 0>>)
  |> should.equal(Ok(0x40))

  image_header.flash_size(<<0xe9, 4, 2, 0x4f>>)
  |> should.equal(Ok(0x1000000))

  image_header.flash_size_id(<<0xe9, 4, 2, 0x5f, 0, 0, 0, 0>>)
  |> should.equal(Ok(0x50))

  image_header.flash_size(<<0xe9, 4, 2, 0x5f>>)
  |> should.equal(Ok(0x2000000))
}

pub fn flash_size_rejects_invalid_headers_test() {
  image_header.flash_size(<<0xff, 0, 0, 0>>)
  |> should.equal(Error(image_header.InvalidImageHeader))

  image_header.flash_size(<<0xe9, 0, 0>>)
  |> should.equal(Error(image_header.InvalidImageHeader))
}

pub fn format_device_summarises_atomvm_status_test() {
  esp32.format_device(
    esp32.Device(
      port: "/dev/ttyUSB0",
      chip_family_name: "ESP32-S3",
      mac_address: "AA:BB:CC:DD:EE:FF",
      usb_mode: "USB_SERIAL_JTAG",
      atomvm_installed: True,
      build_info: ["v0.7.0"],
      features: ["WiFi"],
    ),
  )
  |> should.equal("ESP32-S3 AA:BB:CC:DD:EE:FF (AtomVM) - /dev/ttyUSB0")

  esp32.format_device(
    esp32.Device(
      port: "/dev/ttyACM0",
      chip_family_name: "ESP32",
      mac_address: "11:22:33:44:55:66",
      usb_mode: "None",
      atomvm_installed: False,
      build_info: [],
      features: [],
    ),
  )
  |> should.equal("ESP32 11:22:33:44:55:66 (no AtomVM) - /dev/ttyACM0")
}

pub fn format_info_report_mentions_boot_when_empty_test() {
  esp32.format_info_report([])
  |> should.equal(
    "Found no ESP32 devices.\n"
    <> "You may have to hold the BOOT button down while plugging in the device.",
  )
}

pub fn format_info_report_covers_device_fields_test() {
  let report =
    esp32.format_info_report([
      esp32.Device(
        port: "/dev/ttyUSB0",
        chip_family_name: "ESP32-S3",
        mac_address: "AA:BB:CC:DD:EE:FF",
        usb_mode: "USB_SERIAL_JTAG",
        atomvm_installed: True,
        build_info: ["v0.7.0", "esp32s3", "12:14:09", "Oct  3 2026", "v5.5.4"],
        features: ["WiFi", "BLE"],
      ),
      esp32.Device(
        port: "/dev/ttyACM0",
        chip_family_name: "ESP32",
        mac_address: "11:22:33:44:55:66",
        usb_mode: "None",
        atomvm_installed: False,
        build_info: [],
        features: [],
      ),
    ])

  should.be_true(string.contains(report, "Found 2 connected ESP32 boards:"))
  should.be_true(string.contains(report, "• ESP32-S3 - Port: /dev/ttyUSB0"))
  should.be_true(string.contains(report, "USB_MODE: USB_SERIAL_JTAG"))
  should.be_true(string.contains(report, "MAC: AA:BB:CC:DD:EE:FF"))
  should.be_true(string.contains(report, "AtomVM installed: yes"))
  should.be_true(string.contains(report, "Version: v0.7.0"))
  should.be_true(string.contains(report, "  · WiFi"))
  should.be_true(string.contains(report, "AtomVM installed: no"))
  should.be_true(string.contains(report, "Build info not available"))
}

pub fn port_or_auto_defaults_test() {
  esp32.port_or_auto(option.None)
  |> should.equal("auto")

  esp32.port_or_auto(option.Some("/dev/ttyUSB0"))
  |> should.equal("/dev/ttyUSB0")
}

pub fn hex_address_formats_offsets_test() {
  esp32.hex_address(0x8000)
  |> should.equal("0x8000")
}
