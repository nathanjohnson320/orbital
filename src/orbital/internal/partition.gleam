//// ESP-IDF partition table parsing and `main.avm` expansion.
////
//// Pure helpers for later `expand` / flash commands. Each entry is 32 bytes:
//// magic `0x50AA`, type, subtype, little-endian offset and size, a 16-byte
//// name, and flags. An MD5 marker (`0xEBEB`…) checksums the preceding segment;
//// `0xFFFF…` ends the table.

import gleam/bit_array
import gleam/crypto
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

const entry_size = 32

const data_partition_type = 0x01

const table_size = 0xC00

/// A parsed ESP-IDF partition entry.
pub type Partition {
  Partition(
    name: String,
    type_: Int,
    subtype: Int,
    offset: Int,
    size: Int,
    flags: Int,
    /// Byte offset of this 32-byte entry inside the partition table blob.
    entry_offset: Int,
  )
}

/// Result of expanding `main.avm` (or another final data partition) to the end
/// of flash.
pub type Expansion {
  Expansion(
    changed: Bool,
    partition: Partition,
    updated_partition: Partition,
    partition_table: BitArray,
  )
}

pub type Error {
  InvalidPartitionTable
  CorruptPartitionData
  PartitionNotFound(String)
  DuplicatePartition(String)
  InvalidPartitionType(String)
  PartitionNotLast(name: String, next: String)
  PartitionExceedsFlash(String)
  OverlappingPartitions(first: String, second: String)
  InvalidFlashSize
}

/// Address of the `main.avm` partition in an ESP-IDF partition table.
///
/// Kept for the flash command: returns only the offset, or `Error(Nil)` when
/// the slot is missing or the table cannot be parsed.
pub fn main_avm_offset(table: BitArray) -> Result(Int, Nil) {
  case find_data_partition(table, "main.avm") {
    Ok(Partition(offset:, ..)) -> Ok(offset)
    Error(_) -> Error(Nil)
  }
}

pub fn hex_address(value: Int) -> String {
  "0x" <> hex_digits(value)
}

/// Parse every partition entry from a table blob.
pub fn parse(table: BitArray) -> Result(List(Partition), Error) {
  use #(_, partitions) <- result.try(parse_records(table))
  Ok(partitions)
}

/// Find a data partition by name (any subtype).
pub fn find_data_partition(
  table: BitArray,
  name: String,
) -> Result(Partition, Error) {
  use #(_, partitions) <- result.try(parse_records(table))
  use partition <- result.try(find_named(partitions, name))
  use Nil <- result.try(validate_data_partition(partition))
  Ok(partition)
}

/// Expand a final data partition so it fills flash through `flash_size`.
///
/// Updates the partition size field and regenerates MD5 markers. Other
/// offsets and the erased tail are preserved.
pub fn expand_partition(
  table: BitArray,
  name: String,
  flash_size: Int,
) -> Result(Expansion, Error) {
  use #(records, partitions) <- result.try(parse_records(table))
  use partition <- result.try(find_named(partitions, name))
  use Nil <- result.try(validate_partition(partition, partitions, flash_size))
  let new_size = flash_size - partition.offset
  let updated_partition = Partition(..partition, size: new_size)
  let partition_table = rebuild(records, partition.entry_offset, new_size)
  Ok(Expansion(
    changed: new_size != partition.size,
    partition:,
    updated_partition:,
    partition_table:,
  ))
}

// --- Parsing -----------------------------------------------------------------

type Record {
  PartitionRecord(partition: Partition, entry: BitArray)
  Md5Record(entry: BitArray)
  TailRecord(remaining: BitArray)
}

fn parse_records(
  table: BitArray,
) -> Result(#(List(Record), List(Partition)), Error) {
  case bit_array.byte_size(table) % entry_size {
    0 -> parse_records_loop(table, 0, [], [], [])
    _ -> Error(InvalidPartitionTable)
  }
}

fn parse_records_loop(
  remaining: BitArray,
  entry_offset: Int,
  segment: List(BitArray),
  records: List(Record),
  partitions: List(Partition),
) -> Result(#(List(Record), List(Partition)), Error) {
  case remaining {
    <<>> -> Error(InvalidPartitionTable)

    <<entry:bytes-size(entry_size), rest:bits>> -> {
      case is_erased(entry) {
        True ->
          Ok(#(
            list.reverse([TailRecord(remaining), ..records]),
            list.reverse(partitions),
          ))

        False ->
          case is_md5(entry) {
            True -> {
              use Nil <- result.try(verify_md5(entry, segment))
              parse_records_loop(
                rest,
                entry_offset + entry_size,
                [],
                [Md5Record(entry), ..records],
                partitions,
              )
            }

            False -> {
              use partition <- result.try(parse_partition(entry, entry_offset))
              parse_records_loop(
                rest,
                entry_offset + entry_size,
                [entry, ..segment],
                [PartitionRecord(partition:, entry:), ..records],
                [partition, ..partitions],
              )
            }
          }
      }
    }

    _ -> Error(InvalidPartitionTable)
  }
}

fn parse_partition(
  entry: BitArray,
  entry_offset: Int,
) -> Result(Partition, Error) {
  case entry {
    <<
      0xaa,
      0x50,
      type_:8,
      subtype:8,
      offset:size(32)-little,
      size:size(32)-little,
      label:bytes-size(16),
      flags:size(32)-little,
    >> ->
      Ok(Partition(
        name: label_name(label),
        type_:,
        subtype:,
        offset:,
        size:,
        flags:,
        entry_offset:,
      ))
    _ -> Error(CorruptPartitionData)
  }
}

fn is_erased(entry: BitArray) -> Bool {
  entry == bit_array.concat(list.repeat(<<0xff>>, entry_size))
}

fn is_md5(entry: BitArray) -> Bool {
  case entry {
    <<
      0xeb,
      0xeb,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      0xff,
      _:bytes-size(16),
    >> -> True
    _ -> False
  }
}

fn verify_md5(entry: BitArray, segment: List(BitArray)) -> Result(Nil, Error) {
  case entry {
    <<0xeb, 0xeb, _:bytes-size(14), digest:bytes-size(16)>> ->
      case digest == segment_digest(segment) {
        True -> Ok(Nil)
        False -> Error(InvalidPartitionTable)
      }
    _ -> Error(InvalidPartitionTable)
  }
}

fn segment_digest(segment: List(BitArray)) -> BitArray {
  segment
  |> list.reverse
  |> bit_array.concat
  |> crypto.hash(crypto.Md5, _)
}

fn find_named(
  partitions: List(Partition),
  name: String,
) -> Result(Partition, Error) {
  case list.filter(partitions, fn(p) { p.name == name }) {
    [partition] -> Ok(partition)
    [] -> Error(PartitionNotFound(name))
    _ -> Error(DuplicatePartition(name))
  }
}

// --- Validation --------------------------------------------------------------

fn validate_partition(
  partition: Partition,
  partitions: List(Partition),
  flash_size: Int,
) -> Result(Nil, Error) {
  use Nil <- result.try(validate_data_partition(partition))
  use Nil <- result.try(validate_flash_size(flash_size))
  use Nil <- result.try(validate_layout(partitions, flash_size))
  use Nil <- result.try(validate_last_partition(partition, partitions))
  validate_expansion(partition, flash_size)
}

fn validate_data_partition(partition: Partition) -> Result(Nil, Error) {
  case partition.type_ == data_partition_type {
    True -> Ok(Nil)
    False -> Error(InvalidPartitionType(partition.name))
  }
}

fn validate_flash_size(flash_size: Int) -> Result(Nil, Error) {
  case flash_size > 0 && flash_size <= 0xFFFFFFFF {
    True -> Ok(Nil)
    False -> Error(InvalidFlashSize)
  }
}

fn validate_layout(
  partitions: List(Partition),
  flash_size: Int,
) -> Result(Nil, Error) {
  let sorted =
    list.sort(partitions, by: fn(a, b) { int.compare(a.offset, b.offset) })
  validate_layout_loop(sorted, flash_size, None)
}

fn validate_layout_loop(
  partitions: List(Partition),
  flash_size: Int,
  previous: Option(Partition),
) -> Result(Nil, Error) {
  case partitions {
    [] -> Ok(Nil)
    [partition, ..rest] -> {
      let partition_end = partition.offset + partition.size
      case partition_end > flash_size {
        True -> Error(PartitionExceedsFlash(partition.name))
        False ->
          case overlaps_previous(previous, partition) {
            True -> {
              let assert Some(prev) = previous
              Error(OverlappingPartitions(prev.name, partition.name))
            }
            False -> validate_layout_loop(rest, flash_size, Some(partition))
          }
      }
    }
  }
}

fn overlaps_previous(previous: Option(Partition), partition: Partition) -> Bool {
  case previous {
    Some(prev) -> prev.offset + prev.size > partition.offset
    None -> False
  }
}

fn validate_last_partition(
  partition: Partition,
  partitions: List(Partition),
) -> Result(Nil, Error) {
  case list.find(partitions, fn(p) { p.offset > partition.offset }) {
    Ok(next) -> Error(PartitionNotLast(partition.name, next.name))
    Error(Nil) -> Ok(Nil)
  }
}

fn validate_expansion(
  partition: Partition,
  flash_size: Int,
) -> Result(Nil, Error) {
  let current_end = partition.offset + partition.size
  case partition.offset >= flash_size || current_end > flash_size {
    True -> Error(PartitionExceedsFlash(partition.name))
    False -> Ok(Nil)
  }
}

// --- Rebuild -----------------------------------------------------------------

fn rebuild(
  records: List(Record),
  target_entry_offset: Int,
  new_size: Int,
) -> BitArray {
  let #(_, chunks) =
    list.map_fold(over: records, from: [], with: fn(segment, record) {
      case record {
        PartitionRecord(partition:, entry:) ->
          case partition.entry_offset == target_entry_offset {
            True -> {
              let updated = update_size(entry, new_size)
              #([updated, ..segment], updated)
            }
            False -> #([entry, ..segment], entry)
          }
        Md5Record(_) -> #([], md5_marker(segment))
        TailRecord(remaining:) -> #(segment, remaining)
      }
    })
  bit_array.concat(chunks)
}

fn update_size(entry: BitArray, new_size: Int) -> BitArray {
  let assert <<prefix:bytes-size(8), _:size(32)-little, suffix:bits>> = entry
  <<prefix:bits, new_size:size(32)-little, suffix:bits>>
}

fn md5_marker(segment: List(BitArray)) -> BitArray {
  <<
    0xeb,
    0xeb,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    segment_digest(segment):bits,
  >>
}

fn label_name(label: BitArray) -> String {
  case label {
    <<0, _:bits>> -> ""
    <<byte, rest:bits>> -> {
      let char = case bit_array.to_string(<<byte>>) {
        Ok(text) -> text
        Error(_) -> ""
      }
      char <> label_name(rest)
    }
    _ -> ""
  }
}

fn hex_digits(value: Int) -> String {
  let assert Ok(nibble) = int.remainder(value, 16)
  let rest = value / 16
  let digit = string.slice("0123456789abcdef", nibble, 1)
  case rest {
    0 -> digit
    _ -> hex_digits(rest) <> digit
  }
}

/// Expected on-device partition table size used by AtomVM layouts.
pub fn expected_table_size() -> Int {
  table_size
}
