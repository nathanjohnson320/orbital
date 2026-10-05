import gleam/option
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
