import gleam/bit_array
import gleam/crypto
import gleam/string
import gleeunit
import gleeunit/should
import orbital/internal/partition.{
  type Partition, DuplicatePartition, Expansion, InvalidPartitionTable,
  InvalidPartitionType, Partition, PartitionExceedsFlash, PartitionNotFound,
  PartitionNotLast,
}

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn main_avm_offset_skips_earlier_partitions_test() {
  let table =
    build_partition_table([
      partition("boot.avm", 0x01, 0x00, 0x1f0000, 0),
      partition("main.avm", 0x01, 0x00, 0x2b8000, 0),
    ])

  partition.main_avm_offset(table)
  |> should.equal(Ok(0x2b8000))
}

pub fn main_avm_offset_is_missing_when_the_table_has_no_app_slot_test() {
  let table =
    build_partition_table([partition("boot.avm", 0x01, 0x00, 0x1f0000, 0)])

  partition.main_avm_offset(table)
  |> should.equal(Error(Nil))
}

pub fn hex_address_formats_the_badge_slot_test() {
  partition.hex_address(0x2b8000)
  |> should.equal("0x2b8000")
}

pub fn expected_table_layout_constants_test() {
  partition.expected_table_offset()
  |> should.equal(0x8000)

  partition.expected_table_size()
  |> should.equal(0xC00)
}

pub fn expand_partition_grows_final_main_avm_test() {
  let table =
    build_partition_table([
      partition("nvs", 0x01, 0x02, 0x9000, 0x4000),
      partition("phy_init", 0x01, 0x01, 0xf000, 0x1000),
      partition("factory", 0x00, 0x00, 0x10000, 0x1f0000),
      partition("boot.avm", 0x01, 0x60, 0x200000, 0x50000),
      partition("main.avm", 0x01, 0x60, 0x250000, 0x100000),
    ])

  let assert Ok(Expansion(
    changed: True,
    partition: Partition(size: 0x100000, ..),
    updated_partition: Partition(offset: 0x250000, size: 0xdb0000, ..),
    partition_table:,
  )) = partition.expand_partition(table, "main.avm", 0x1000000)

  bit_array.byte_size(partition_table)
  |> should.equal(0xC00)

  let assert Ok(partitions) = partition.parse(partition_table)
  let assert Ok(main) =
    list_find(partitions, fn(entry: Partition) { entry.name == "main.avm" })
  main.offset |> should.equal(0x250000)
  main.size |> should.equal(0xdb0000)
}

pub fn expand_partition_supports_8mb_and_32mb_flash_test() {
  let table =
    build_partition_table([
      partition("factory", 0x00, 0x00, 0x10000, 0x1f0000),
      partition("boot.avm", 0x01, 0x60, 0x200000, 0x50000),
      partition("main.avm", 0x01, 0x60, 0x250000, 0x100000),
    ])

  let assert Ok(Expansion(updated_partition: Partition(size: size_8mb, ..), ..)) =
    partition.expand_partition(table, "main.avm", 0x800000)
  size_8mb |> should.equal(0x5b0000)

  let assert Ok(Expansion(updated_partition: Partition(size: size_32mb, ..), ..)) =
    partition.expand_partition(table, "main.avm", 0x2000000)
  size_32mb |> should.equal(0x1db0000)
}

pub fn expand_partition_reports_already_expanded_without_change_test() {
  let table =
    build_partition_table([
      partition("main.avm", 0x01, 0x60, 0x250000, 0xdb0000),
    ])

  let assert Ok(Expansion(changed: False, partition_table:, ..)) =
    partition.expand_partition(table, "main.avm", 0x1000000)

  partition_table |> should.equal(table)
}

pub fn expand_partition_refuses_partition_following_main_test() {
  let table =
    build_partition_table([
      partition("main.avm", 0x01, 0x60, 0x250000, 0x100000),
      partition("storage", 0x01, 0x40, 0x350000, 0x100000),
    ])

  partition.expand_partition(table, "main.avm", 0x1000000)
  |> should.equal(Error(PartitionNotLast(name: "main.avm", next: "storage")))
}

pub fn expand_partition_refuses_table_beyond_flash_test() {
  let table =
    build_partition_table([
      partition("factory", 0x00, 0x00, 0x10000, 0xf0000),
      partition("main.avm", 0x01, 0x60, 0x100000, 0x400000),
    ])

  partition.expand_partition(table, "main.avm", 0x400000)
  |> should.equal(Error(PartitionExceedsFlash("main.avm")))
}

pub fn expand_partition_refuses_corrupt_checksum_test() {
  let table =
    build_partition_table([
      partition("main.avm", 0x01, 0x60, 0x250000, 0x100000),
    ])
  let assert <<head:bytes-size(48), _digest_byte, rest:bits>> = table
  let corrupt = <<head:bits, 0, rest:bits>>

  partition.expand_partition(corrupt, "main.avm", 0x1000000)
  |> should.equal(Error(InvalidPartitionTable))
}

pub fn find_data_partition_by_name_test() {
  let table =
    build_partition_table([
      partition("nvs", 0x01, 0x02, 0x9000, 0x6000),
      partition("phy_init", 0x01, 0x01, 0xf000, 0x1000),
      partition("factory", 0x00, 0x00, 0x10000, 0x170000),
      partition("boot.avm", 0x01, 0x01, 0x180000, 0x180000),
      partition("main.avm", 0x01, 0x01, 0x300000, 0x100000),
    ])

  let assert Ok(Partition(
    name: "main.avm",
    offset: 0x300000,
    size: 0x100000,
    type_: 0x01,
    ..,
  )) = partition.find_data_partition(table, "main.avm")

  let assert Ok(Partition(offset: 0x180000, ..)) =
    partition.find_data_partition(table, "boot.avm")

  partition.find_data_partition(table, "app_b")
  |> should.equal(Error(PartitionNotFound("app_b")))

  partition.find_data_partition(table, "factory")
  |> should.equal(Error(InvalidPartitionType("factory")))
}

pub fn find_data_partition_in_erased_table_test() {
  let erased = bit_array.concat(list_repeat(<<0xff>>, 0xC00))

  partition.find_data_partition(erased, "main.avm")
  |> should.equal(Error(PartitionNotFound("main.avm")))
}

pub fn find_data_partition_refuses_duplicates_test() {
  let table =
    build_partition_table([
      partition("main.avm", 0x01, 0x01, 0x250000, 0x100000),
      partition("main.avm", 0x01, 0x01, 0x350000, 0x100000),
    ])

  partition.find_data_partition(table, "main.avm")
  |> should.equal(Error(DuplicatePartition("main.avm")))
}

fn build_partition_table(entries: List(BitArray)) -> BitArray {
  let data = bit_array.concat(entries)
  let md5_entry = <<
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
    crypto.hash(crypto.Md5, data):bits,
  >>
  let used = bit_array.byte_size(data) + bit_array.byte_size(md5_entry)
  let padding = list_repeat(<<0xff>>, 0xC00 - used)
  bit_array.concat([data, md5_entry, ..padding])
}

fn partition(
  name: String,
  type_: Int,
  subtype: Int,
  offset: Int,
  size: Int,
) -> BitArray {
  let padding = 16 - string.byte_size(name)
  <<
    0xaa,
    0x50,
    type_:8,
    subtype:8,
    offset:size(32)-little,
    size:size(32)-little,
    name:utf8,
    0:size(padding)-unit(8),
    0:size(32)-little,
  >>
}

fn list_repeat(value: BitArray, times: Int) -> List(BitArray) {
  case times {
    0 -> []
    _ -> [value, ..list_repeat(value, times - 1)]
  }
}

fn list_find(items: List(a), predicate: fn(a) -> Bool) -> Result(a, Nil) {
  case items {
    [] -> Error(Nil)
    [first, ..rest] ->
      case predicate(first) {
        True -> Ok(first)
        False -> list_find(rest, predicate)
      }
  }
}
