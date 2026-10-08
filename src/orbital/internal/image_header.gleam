//// ESP32 / ESP-IDF application image header helpers.
////
//// The first bytes of a bootloader or app image carry the flash size in the
//// high nibble of byte 3. Used by `expand` when rewriting the bootloader
//// header to match detected flash.

import gleam/bit_array
import gleam/int
import gleam/result

pub type Error {
  InvalidImageHeader
  UnsupportedFlashSize
}

/// Flash-size id nibble shifted into the high 4 bits (matches esptool / IDF).
pub fn flash_size_id(image: BitArray) -> Result(Int, Error) {
  case image {
    <<0xe9, _segments, _mode, size_frequency, _rest:bits>> ->
      Ok(int.bitwise_and(size_frequency, 0xf0))
    _ -> Error(InvalidImageHeader)
  }
}

/// Flash capacity in bytes encoded by an image header.
pub fn flash_size(image: BitArray) -> Result(Int, Error) {
  case flash_size_id(image) {
    Ok(0x00) -> Ok(1 * 1024 * 1024)
    Ok(0x10) -> Ok(2 * 1024 * 1024)
    Ok(0x20) -> Ok(4 * 1024 * 1024)
    Ok(0x30) -> Ok(8 * 1024 * 1024)
    Ok(0x40) -> Ok(16 * 1024 * 1024)
    Ok(0x50) -> Ok(32 * 1024 * 1024)
    Ok(0x60) -> Ok(64 * 1024 * 1024)
    Ok(0x70) -> Ok(128 * 1024 * 1024)
    Ok(_) -> Error(UnsupportedFlashSize)
    Error(error) -> Error(error)
  }
}

/// IDF / esptool flash-size name (e.g. `"16MB"`) to the header size nibble.
pub fn flash_size_id_for_name(name: String) -> Result(Int, Error) {
  case name {
    "1MB" -> Ok(0x00)
    "2MB" -> Ok(0x10)
    "4MB" -> Ok(0x20)
    "8MB" -> Ok(0x30)
    "16MB" -> Ok(0x40)
    "32MB" -> Ok(0x50)
    "64MB" -> Ok(0x60)
    "128MB" -> Ok(0x70)
    _ -> Error(UnsupportedFlashSize)
  }
}

/// Rewrite the flash-size nibble, keeping mode and frequency bits.
pub fn with_flash_size_name(
  image: BitArray,
  name: String,
) -> Result(BitArray, Error) {
  use size_id <- result.try(flash_size_id_for_name(name))
  case image {
    <<0xe9, segments, mode, size_frequency, rest:bits>> -> {
      let frequency = int.bitwise_and(size_frequency, 0x0f)
      let updated = int.bitwise_or(size_id, frequency)
      Ok(<<0xe9, segments, mode, updated, rest:bits>>)
    }
    _ -> Error(InvalidImageHeader)
  }
}

/// Byte length of an image bit array.
pub fn byte_size(image: BitArray) -> Int {
  bit_array.byte_size(image)
}
