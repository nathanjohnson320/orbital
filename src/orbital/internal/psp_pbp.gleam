//// Patch `PARAM.SFO` `TITLE` inside a PSP `EBOOT.PBP`.
////
//// The XMB / PPSSPP game-list label comes from PBP segment 0 (`PARAM.SFO`)
//// key `TITLE`, not from the `PSP/GAME/<folder>` name. AtomVM still loads
//// `ms0:/PSP/GAME/ATOMVM/app.avm`; only the display title is rewritten here.

import filepath
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/result
import gleam/string
import simplifile

const pbp_header_size = 40

const sfo_header_size = 20

const sfo_index_entry_size = 16

pub type Error {
  InvalidPbp
  InvalidSfo
  TitleKeyMissing
  EmptyTitle
  CannotRead(path: String, reason: simplifile.FileError)
  CannotWrite(path: String, reason: simplifile.FileError)
}

/// Outcome of rewriting `TITLE` (possibly truncated to the SFO value slot).
pub type PatchResult {
  PatchResult(title: String, truncated: Bool, max_len: Int)
}

pub fn error_message(error: Error) -> String {
  case error {
    InvalidPbp -> "The EBOOT.PBP file is not a valid PBP archive."
    InvalidSfo -> "The PARAM.SFO inside EBOOT.PBP is invalid."
    TitleKeyMissing -> "PARAM.SFO has no TITLE key to patch."
    EmptyTitle -> "PBP title must not be empty."
    CannotRead(path:, ..) -> "I couldn't read '" <> path <> "'."
    CannotWrite(path:, ..) -> "I couldn't write '" <> path <> "'."
  }
}

/// Read the current `TITLE` string from a PBP (NUL-terminated value, without NUL).
pub fn read_title(pbp: BitArray) -> Result(String, Error) {
  use sfo <- result.try(param_sfo(pbp))
  use entry <- result.try(find_title_entry(sfo))
  use value <- result.try(slice_sfo(
    sfo,
    entry.data_table_offset + entry.data_offset,
    entry.data_len,
  ))
  Ok(c_string(value))
}

/// Rewrite `TITLE` in a PBP bit array.
///
/// When `title` (+ NUL) fits in the existing `param_data_max_len` slot, the
/// value is patched in place and the used-length field is updated. Oversized
/// titles are truncated to `max_len - 1` bytes with `truncated: True`.
pub fn with_title(
  pbp: BitArray,
  title: String,
) -> Result(#(BitArray, PatchResult), Error) {
  use prepared <- result.try(prepare_title(title))
  use #(sfo_start, sfo) <- result.try(param_sfo_slice(pbp))
  use #(sfo2, patch) <- result.try(sfo_with_title(sfo, prepared))
  use pbp2 <- result.try(replace_range(pbp, sfo_start, sfo2))
  Ok(#(pbp2, patch))
}

/// Read `path`, patch `TITLE`, and write the file back.
pub fn set_title_file(
  path: String,
  title: String,
) -> Result(PatchResult, Error) {
  use pbp <- result.try(
    simplifile.read_bits(path)
    |> result.map_error(fn(reason) { CannotRead(path:, reason:) }),
  )
  use #(pbp2, patch) <- result.try(with_title(pbp, title))
  use Nil <- result.try(
    simplifile.write_bits(to: path, bits: pbp2)
    |> result.map_error(fn(reason) { CannotWrite(path:, reason:) }),
  )
  Ok(patch)
}

/// Patch `EBOOT.PBP` under `game_path` and print the title that was written.
pub fn set_game_eboot_title(
  game_path: String,
  title: String,
) -> Result(PatchResult, Error) {
  let eboot = filepath.join(game_path, "EBOOT.PBP")
  use patch <- result.try(set_title_file(eboot, title))
  io.println("PBP TITLE → " <> patch.title)
  case patch.truncated {
    False -> Nil
    True ->
      io.println(
        "Warning: title truncated to "
        <> int.to_string(patch.max_len - 1)
        <> " bytes to fit PARAM.SFO TITLE slot.",
      )
  }
  Ok(patch)
}

// --- PBP / SFO parsing -------------------------------------------------------

type SfoEntry {
  SfoEntry(
    key: String,
    /// Absolute byte offset of this 16-byte index row inside the SFO.
    index_offset: Int,
    data_fmt: Int,
    data_len: Int,
    data_max_len: Int,
    data_offset: Int,
    data_table_offset: Int,
  )
}

fn prepare_title(title: String) -> Result(String, Error) {
  case string.trim(title) {
    "" -> Error(EmptyTitle)
    trimmed -> Ok(trimmed)
  }
}

fn param_sfo(pbp: BitArray) -> Result(BitArray, Error) {
  use #(_, sfo) <- result.try(param_sfo_slice(pbp))
  Ok(sfo)
}

fn param_sfo_slice(pbp: BitArray) -> Result(#(Int, BitArray), Error) {
  case pbp {
    <<0, 80, 66, 80, _version:size(32)-little, offsets:bytes-size(32), _:bits>> -> {
      use sfo_start <- result.try(u32_at(offsets, 0))
      use next <- result.try(next_segment_offset(offsets, sfo_start, pbp))
      case next >= sfo_start {
        False -> Error(InvalidPbp)
        True -> {
          let size = next - sfo_start
          use sfo <- result.try(
            bit_array.slice(pbp, sfo_start, size)
            |> result.replace_error(InvalidPbp),
          )
          Ok(#(sfo_start, sfo))
        }
      }
    }
    _ -> Error(InvalidPbp)
  }
}

fn next_segment_offset(
  offsets: BitArray,
  sfo_start: Int,
  pbp: BitArray,
) -> Result(Int, Error) {
  use values <- result.try(read_u32_list(offsets, 8, []))
  let later =
    values
    |> list.filter(fn(offset) { offset > sfo_start })
    |> list.sort(int.compare)
  case later {
    [next, ..] -> Ok(next)
    [] -> Ok(bit_array.byte_size(pbp))
  }
}

fn sfo_with_title(
  sfo: BitArray,
  title: String,
) -> Result(#(BitArray, PatchResult), Error) {
  use entry <- result.try(find_title_entry(sfo))
  case entry.data_max_len < 1 {
    True -> Error(InvalidSfo)
    False -> {
      let #(title_bytes, truncated) = fit_title_bytes(title, entry.data_max_len)
      let used_len = bit_array.byte_size(title_bytes) + 1
      let padding = entry.data_max_len - used_len
      let value =
        bit_array.concat([
          title_bytes,
          <<0>>,
          bit_array.concat(list.repeat(<<0>>, padding)),
        ])
      use sfo1 <- result.try(replace_range(
        sfo,
        entry.data_table_offset + entry.data_offset,
        value,
      ))
      // Update used-length (data_len) at index_offset + 4.
      use sfo2 <- result.try(
        replace_range(sfo1, entry.index_offset + 4, <<used_len:size(32)-little>>),
      )
      let written = case bit_array.to_string(title_bytes) {
        Ok(text) -> text
        Error(Nil) -> title
      }
      Ok(#(
        sfo2,
        PatchResult(title: written, truncated:, max_len: entry.data_max_len),
      ))
    }
  }
}

fn fit_title_bytes(title: String, max_len: Int) -> #(BitArray, Bool) {
  let limit = max_len - 1
  let full = bit_array.from_string(title)
  case bit_array.byte_size(full) <= limit {
    True -> #(full, False)
    False -> #(truncate_utf8(title, limit), True)
  }
}

/// Drop graphemes from the end until the UTF-8 encoding fits `limit` bytes.
fn truncate_utf8(title: String, limit: Int) -> BitArray {
  truncate_utf8_loop(title, limit)
}

fn truncate_utf8_loop(title: String, limit: Int) -> BitArray {
  let bytes = bit_array.from_string(title)
  case bit_array.byte_size(bytes) <= limit {
    True -> bytes
    False ->
      case string.drop_end(title, 1) {
        "" -> <<>>
        shorter -> truncate_utf8_loop(shorter, limit)
      }
  }
}

fn find_title_entry(sfo: BitArray) -> Result(SfoEntry, Error) {
  use entries <- result.try(parse_sfo_entries(sfo))
  list.find(entries, fn(entry) { entry.key == "TITLE" })
  |> result.replace_error(TitleKeyMissing)
}

fn parse_sfo_entries(sfo: BitArray) -> Result(List(SfoEntry), Error) {
  case sfo {
    <<
      0,
      80,
      83,
      70,
      _version:size(32)-little,
      key_table:size(32)-little,
      data_table:size(32)-little,
      count:size(32)-little,
      rest:bits,
    >> -> {
      use Nil <- result.try(case count >= 0 && key_table >= sfo_header_size {
        True -> Ok(Nil)
        False -> Error(InvalidSfo)
      })
      parse_index_rows(rest, 0, count, key_table, data_table, sfo, [])
    }
    _ -> Error(InvalidSfo)
  }
}

fn parse_index_rows(
  after_header: BitArray,
  index: Int,
  count: Int,
  key_table: Int,
  data_table: Int,
  sfo: BitArray,
  acc: List(SfoEntry),
) -> Result(List(SfoEntry), Error) {
  case index >= count {
    True -> Ok(list.reverse(acc))
    False -> {
      let row_offset = index * sfo_index_entry_size
      use row <- result.try(
        bit_array.slice(after_header, row_offset, sfo_index_entry_size)
        |> result.replace_error(InvalidSfo),
      )
      case row {
        <<
          key_off:size(16)-little,
          data_fmt:size(16)-little,
          data_len:size(32)-little,
          data_max_len:size(32)-little,
          data_offset:size(32)-little,
        >> -> {
          use key <- result.try(read_key(sfo, key_table + key_off))
          let entry =
            SfoEntry(
              key:,
              index_offset: sfo_header_size + row_offset,
              data_fmt:,
              data_len:,
              data_max_len:,
              data_offset:,
              data_table_offset: data_table,
            )
          parse_index_rows(
            after_header,
            index + 1,
            count,
            key_table,
            data_table,
            sfo,
            [entry, ..acc],
          )
        }
        _ -> Error(InvalidSfo)
      }
    }
  }
}

fn read_key(sfo: BitArray, offset: Int) -> Result(String, Error) {
  use tail <- result.try(
    bit_array.slice(sfo, offset, bit_array.byte_size(sfo) - offset)
    |> result.replace_error(InvalidSfo),
  )
  Ok(c_string(tail))
}

fn c_string(bytes: BitArray) -> String {
  case take_until_nul(bytes, <<>>) {
    <<>> -> ""
    raw ->
      case bit_array.to_string(raw) {
        Ok(text) -> text
        Error(Nil) -> ""
      }
  }
}

fn take_until_nul(bytes: BitArray, acc: BitArray) -> BitArray {
  case bytes {
    <<>> -> acc
    <<0, _:bits>> -> acc
    <<byte, rest:bits>> -> take_until_nul(rest, bit_array.append(acc, <<byte>>))
    _ -> acc
  }
}

fn slice_sfo(sfo: BitArray, start: Int, size: Int) -> Result(BitArray, Error) {
  bit_array.slice(sfo, start, size)
  |> result.replace_error(InvalidSfo)
}

fn replace_range(
  data: BitArray,
  start: Int,
  replacement: BitArray,
) -> Result(BitArray, Error) {
  let size = bit_array.byte_size(replacement)
  let total = bit_array.byte_size(data)
  case start < 0 || start + size > total {
    True -> Error(InvalidSfo)
    False -> {
      use prefix <- result.try(
        bit_array.slice(data, 0, start)
        |> result.replace_error(InvalidSfo),
      )
      use suffix <- result.try(
        bit_array.slice(data, start + size, total - start - size)
        |> result.replace_error(InvalidSfo),
      )
      Ok(bit_array.concat([prefix, replacement, suffix]))
    }
  }
}

fn u32_at(data: BitArray, index: Int) -> Result(Int, Error) {
  use word <- result.try(
    bit_array.slice(data, index * 4, 4)
    |> result.replace_error(InvalidPbp),
  )
  case word {
    <<value:size(32)-little>> -> Ok(value)
    _ -> Error(InvalidPbp)
  }
}

fn read_u32_list(
  data: BitArray,
  count: Int,
  acc: List(Int),
) -> Result(List(Int), Error) {
  case list.length(acc) >= count {
    True -> Ok(list.reverse(acc))
    False -> {
      use value <- result.try(u32_at(data, list.length(acc)))
      read_u32_list(data, count, [value, ..acc])
    }
  }
}

/// Build a tiny PBP with a PARAM.SFO `TITLE` slot for unit tests.
pub fn test_fixture_pbp(title: String, title_max_len: Int) -> BitArray {
  let sfo = test_fixture_sfo(title, title_max_len)
  let sfo_start = pbp_header_size
  let sfo_end = sfo_start + bit_array.byte_size(sfo)
  let icon = <<"PNG":utf8>>
  let file_end = sfo_end + bit_array.byte_size(icon)
  let header = <<
    0,
    80,
    66,
    80,
    0x00010000:size(32)-little,
    sfo_start:size(32)-little,
    sfo_end:size(32)-little,
    file_end:size(32)-little,
    file_end:size(32)-little,
    file_end:size(32)-little,
    file_end:size(32)-little,
    file_end:size(32)-little,
    file_end:size(32)-little,
  >>
  bit_array.concat([header, sfo, icon])
}

fn test_fixture_sfo(title: String, title_max_len: Int) -> BitArray {
  let title_key = <<"TITLE":utf8, 0>>
  let category_key = <<"CATEGORY":utf8, 0>>
  let title_val = bit_array.from_string(title)
  let title_used = bit_array.byte_size(title_val) + 1
  let title_padded =
    bit_array.concat([
      title_val,
      <<0>>,
      bit_array.concat(list.repeat(<<0>>, title_max_len - title_used)),
    ])
  let category_val = <<"MG":utf8, 0, 0>>
  let key_blob = bit_array.concat([title_key, category_key])
  let key_pad = { 4 - { bit_array.byte_size(key_blob) % 4 } } % 4
  let key_blob =
    bit_array.concat([key_blob, bit_array.concat(list.repeat(<<0>>, key_pad))])
  let count = 2
  let key_table = sfo_header_size + count * sfo_index_entry_size
  let data_table = key_table + bit_array.byte_size(key_blob)
  let index = <<
    0:size(16)-little,
    0x0004:size(16)-little,
    title_used:size(32)-little,
    title_max_len:size(32)-little,
    0:size(32)-little,
    bit_array.byte_size(title_key):size(16)-little,
    0x0004:size(16)-little,
    3:size(32)-little,
    4:size(32)-little,
    title_max_len:size(32)-little,
  >>
  let header = <<
    0,
    80,
    83,
    70,
    0x00000101:size(32)-little,
    key_table:size(32)-little,
    data_table:size(32)-little,
    count:size(32)-little,
  >>
  bit_array.concat([
    header,
    index,
    key_blob,
    title_padded,
    category_val,
  ])
}
