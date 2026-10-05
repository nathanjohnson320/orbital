//// GitHub listing, download, and `firmware_images/` cache for `install`.
////
//// Uses `gleam_httpc` + `gleam_json` + `gleam_crypto` + `simplifile`. Zip
//// member extraction is the only Erlang shell-out (`zip` stdlib).

import filepath
import gleam/bit_array
import gleam/crypto
import gleam/dynamic/decode
import gleam/http/request
import gleam/httpc
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import orbital/internal/firmware.{
  type Error, type Image, type Source, Atomvm, Build, Cache, CustomRepo, Factory,
  Image, Img, LocalSource, Network, Nightly, ReleaseNotFound, UnknownImage, Zip,
}
import orbital/internal/firmware_bundle
import simplifile

const atomvm_releases = "https://api.github.com/repos/atomvm/atomvm/releases"

const factory_releases = "https://api.github.com/repos/atomvm/atomvm-esp32-firmware-factory/releases"

const cache_dir_name = "firmware_images"

const build_images_dir = "_build/atomvm_images"

const page_size = 10

const user_agent = "orbital-firmware/1.0 (+https://github.com/nathanjohnson320/orbital)"

pub type Section {
  Section(kind: String, title: String, images: List(Image))
}

/// Render `--list-images` text (AtomVM + factory + optional repo + local).
pub fn list_images_text(
  repo: Option(String),
  filter: Option(List(String)),
  header: List(String),
) -> Result(String, Error) {
  let sources = case repo {
    Some(repo) -> [Atomvm, Factory, CustomRepo(repo)]
    None -> [Atomvm, Factory]
  }
  let #(sections, header) = case fetch_listing(sources) {
    Ok(sections) -> #(sections, header)
    Error(error) -> #(
      [],
      list.append(header, [
        "Warning: "
          <> firmware.error_message(error)
          <> ". Only local images are listed.",
      ]),
    )
  }
  let sections = list.append(sections, [local_section()])
  Ok(render_list(sections, filter, header))
}

/// Update parts for an image: FLASH.txt bundle parts when zip, else sliced img.
pub fn update_parts(
  image: Image,
  flash_offset: Int,
) -> Result(firmware.UpdateParts, Error) {
  case image.kind, image.path {
    Zip, Some(path) -> {
      use bundle <- result.try(verify_zip(path, image.stamp))
      firmware_bundle.bundle_update_parts(bundle)
    }
    _, _ -> {
      use path <- result.try(firmware.image_path(image))
      use img_bytes <- result.try(
        simplifile.read_bits(path)
        |> result.map_error(fn(_) {
          firmware.FileError("Could not read firmware image at " <> path)
        }),
      )
      firmware_bundle.slice_image(img_bytes, flash_offset)
    }
  }
}

/// Resolve a local path (`.img` or `.zip`) onto disk metadata.
pub fn ensure_path(path: String) -> Result(Image, Error) {
  case simplifile.is_file(path) {
    Ok(True) ->
      case string.ends_with(path, ".zip") {
        True -> extract_local_bundle(path)
        False ->
          Ok(
            Image(
              ..firmware.local_image(path),
              source: Some(LocalSource),
              size: file_size(path),
            ),
          )
      }
    _ -> Error(firmware.FileError("Image file not found: " <> path))
  }
}

/// Download (or reuse cache for) a release Elixir image for `chip`.
pub fn ensure_release(
  chip: String,
  version: Option(String),
  repo: Option(String),
) -> Result(Image, Error) {
  let source = case repo {
    Some(repo) -> CustomRepo(repo)
    None -> Atomvm
  }
  case source, version {
    Atomvm, Some(version) ->
      case find_cached("AtomVM-" <> chip <> "-elixir-" <> version, source) {
        [image, ..] -> Ok(image)
        [] -> download_release(source, chip, Some(version))
      }
    _, _ -> download_release(source, chip, version)
  }
}

/// Resolve a published image name (or custom-repo basename) and cache it.
pub fn ensure_name(
  name: String,
  repo: Option(String),
) -> Result(Image, Error) {
  let parsed = firmware.parse_name(name)
  let wanted = case parsed {
    Ok(image) -> string.lowercase(image.name)
    Error(_) -> string.lowercase(stem_name(name))
  }
  case repo {
    None -> {
      let source = case parsed {
        Ok(Image(channel: Nightly, ..)) -> Factory
        _ -> Atomvm
      }
      let version = case parsed {
        Ok(Image(version:, ..)) -> version
        Error(_) -> None
      }
      case fetch_release(source, version) {
        Ok(release) -> {
          let images = release_images(release, source)
          case list.find(images, fn(i) { string.lowercase(i.name) == wanted }) {
            Ok(image) -> ensure_cached(image)
            Error(Nil) ->
              case find_cached(wanted, source) {
                [image, ..] -> Ok(image)
                [] -> Error(UnknownImage(name))
              }
          }
        }
        Error(error) ->
          case find_cached(wanted, source) {
            [image, ..] -> Ok(image)
            [] -> Error(error)
          }
      }
    }
    Some(repo) -> {
      let source = CustomRepo(repo)
      use releases <- result.try(fetch_json_list(releases_url(source, ListPage)))
      let found =
        list.flat_map(releases, fn(release) {
          case release_draft(release) {
            True -> []
            False ->
              list.filter(release_images(release, source), fn(i) {
                string.lowercase(i.name) == wanted
              })
          }
        })
      case found {
        [image, ..] -> ensure_cached(image)
        [] ->
          case find_cached(wanted, source) {
            [image, ..] -> Ok(image)
            [] -> Error(UnknownImage(name))
          }
      }
    }
  }
}

// --- Listing -----------------------------------------------------------------

fn fetch_listing(sources: List(Source)) -> Result(List(Section), Error) {
  list.try_fold(over: sources, from: [], with: fn(acc, source) {
    use releases <- result.try(fetch_json_list(releases_url(source, ListPage)))
    Ok(list.append(acc, listing_sections(source, releases)))
  })
}

fn listing_sections(source: Source, releases: List(Release)) -> List(Section) {
  case source {
    Atomvm -> {
      let classified = classify_releases(releases)
      let stable = case classified.stable {
        Some(release) -> [
          Section(
            kind: "stable",
            title: "Stable release "
              <> release.tag_name
              <> " ("
              <> option.unwrap(release.published_at, "?")
              <> ")",
            images: release_images(release, Atomvm),
          ),
        ]
        None -> []
      }
      let prereleases =
        list.map(classified.prereleases, fn(release) {
          Section(
            kind: "prerelease",
            title: "Prerelease "
              <> release.tag_name
              <> " ("
              <> option.unwrap(release.published_at, "?")
              <> ")",
            images: release_images(release, Atomvm),
          )
        })
      list.append(stable, prereleases)
    }
    Factory -> [
      Section(
        kind: "nightly",
        title: "Nightly builds (atomvm-esp32-firmware-factory)",
        images: list.flat_map(releases, fn(release) {
          case release.draft {
            True -> []
            False -> release_images(release, Factory)
          }
        }),
      ),
    ]
    CustomRepo(repo) ->
      list.filter_map(releases, fn(release) {
        case release.draft {
          True -> Error(Nil)
          False ->
            Ok(Section(
              kind: "custom",
              title: "Custom builds ("
                <> repo
                <> "), release "
                <> release.tag_name
                <> " ("
                <> option.unwrap(release.published_at, "?")
                <> ")",
              images: release_images(release, source),
            ))
        }
      })
    _ -> []
  }
}

fn local_section() -> Section {
  Section(kind: "local", title: "Local images", images: local_images())
}

fn local_images() -> List(Image) {
  let root = cache_dir()
  let subdirs = case simplifile.read_directory(root) {
    Ok(entries) ->
      list.filter_map(list.sort(entries, string.compare), fn(entry) {
        let path = filepath.join(root, entry)
        case simplifile.is_directory(path) {
          Ok(True) -> Ok(path)
          _ -> Error(Nil)
        }
      })
    Error(_) -> []
  }
  let cached =
    list.flat_map([root, ..subdirs], fn(dir) {
      files_in(dir, relative_to_cwd(dir), Cache)
    })
    |> without_extracted
  list.append(cached, files_in(build_images_dir, build_images_dir, Build))
}

fn files_in(directory: String, shown_as: String, source: Source) -> List(Image) {
  case simplifile.read_directory(directory) {
    Ok(entries) ->
      list.filter_map(list.sort(entries, string.compare), fn(file) {
        case string.ends_with(file, ".img") || string.ends_with(file, ".zip") {
          False -> Error(Nil)
          True -> {
            let path = filepath.join(directory, file)
            let shown = filepath.join(shown_as, file)
            Ok(
              Image(
                ..firmware.local_image(path),
                path: Some(shown),
                source: Some(source),
                size: file_size(path),
              ),
            )
          }
        }
      })
    Error(_) -> []
  }
}

fn without_extracted(images: List(Image)) -> List(Image) {
  let bundles =
    list.filter_map(images, fn(image) {
      case image.kind {
        Zip -> Ok(#(image.name, image.stamp))
        Img -> Error(Nil)
      }
    })
  list.filter(images, fn(image) {
    case image.kind {
      Img -> !list.contains(bundles, #(image.name, image.stamp))
      Zip -> True
    }
  })
}

fn render_list(
  sections: List(Section),
  filter: Option(List(String)),
  header: List(String),
) -> String {
  let published =
    list.flat_map(sections, fn(section) {
      case section.kind {
        "nightly" ->
          list.map(section.images, fn(image) { #(image.name, image.stamp) })
        _ -> []
      }
    })
  let #(hidden, shown) =
    list.map_fold(over: sections, from: 0, with: fn(hidden, section) {
      let #(kept, dropped) =
        list.partition(section.images, fn(image) { listed(image, filter) })
      #(hidden + list.length(dropped), Section(..section, images: kept))
    })
  let body =
    list.flat_map(shown, fn(section) {
      case section.images {
        [] -> []
        images -> {
          let width =
            images
            |> list.map(fn(i) { string.length(label(section, i)) })
            |> list.fold(0, int.max)
          let rows =
            list.flat_map(images, fn(image) {
              row(section, image, width, published)
            })
          list.flatten([[section.title], rows, [""]])
        }
      }
    })
  let intro = case filter {
    Some(chips) ->
      list.append(header, [
        "Showing images for "
          <> string.join(chips, with: ", ")
          <> "; pass --chip all to list every image.",
      ])
    None -> header
  }
  let intro = case intro {
    [] -> []
    _ -> list.append(intro, [""])
  }
  let hidden_line = case hidden > 0 {
    True -> [int.to_string(hidden) <> " images for other chips not shown.", ""]
    False -> []
  }
  let footer = [
    "Install with:",
    "  gleam run -m orbital install --image <name or path>",
    "  gleam run -m orbital install --version <tag>        the Elixir image of a release",
    "Older releases: https://github.com/atomvm/AtomVM/releases",
  ]
  string.join(list.flatten([intro, body, hidden_line, footer]), with: "\n")
}

fn row(
  section: Section,
  image: Image,
  width: Int,
  published: List(#(String, Option(String))),
) -> List(String) {
  let first =
    "  "
    <> string.pad_end(label(section, image), to: width, with: " ")
    <> "  "
    <> string.pad_end(flavor(image), to: 11, with: " ")
    <> "  "
    <> firmware_bundle.format_size(image.size)
    <> note(section, image, published)
  case section.kind {
    "nightly" -> {
      let features = case image.features {
        [] -> ""
        features -> ", features: " <> string.join(features, with: ", ")
      }
      [
        first,
        "    build "
          <> option.unwrap(image.stamp, "unknown")
          <> " ("
          <> option.unwrap(image.published_at, "?")
          <> ")"
          <> features,
      ]
    }
    _ -> [first]
  }
}

fn note(
  section: Section,
  image: Image,
  published: List(#(String, Option(String))),
) -> String {
  case section.kind, image.source, image.channel {
    "local", Some(Build), _ -> "  built under _build/atomvm_images"
    "local", _, Nightly ->
      case image.stamp {
        Some(_) ->
          case
            list.contains(published, #(image.name, image.stamp))
            || published == []
          {
            True -> "  cached"
            False -> "  cached, no longer published"
          }
        None -> "  cached"
      }
    "local", _, _ -> "  cached"
    "custom", _, _ ->
      case image.chip {
        None -> "  install by name with --repo"
        Some(_) -> ""
      }
    _, _, _ -> ""
  }
}

fn listed(image: Image, filter: Option(List(String))) -> Bool {
  case filter {
    None -> True
    Some(chips) ->
      case firmware.image_chip(image), image.chip {
        None, _ -> True
        Some(chip), Some(variant) ->
          list.contains(chips, chip) || list.contains(chips, variant)
        Some(chip), None -> list.contains(chips, chip)
      }
  }
}

fn label(section: Section, image: Image) -> String {
  case section.kind {
    "local" -> option.unwrap(image.path, option.unwrap(image.file, image.name))
    _ ->
      case image.chip {
        None -> option.unwrap(image.file, image.name)
        Some(_) -> image.name
      }
  }
}

fn flavor(image: Image) -> String {
  case image.elixir {
    Some(True) -> "Elixir"
    Some(False) -> "Erlang only"
    None -> "unknown"
  }
}

// --- Releases / download -----------------------------------------------------

type Page {
  Latest
  ListPage
  Tag(String)
}

type Release {
  Release(
    tag_name: String,
    draft: Bool,
    prerelease: Bool,
    published_at: Option(String),
    body: Option(String),
    assets: List(Asset),
  )
}

type Asset {
  Asset(
    name: String,
    url: String,
    size: Option(Int),
    digest: Option(String),
    updated_at: Option(String),
  )
}

type Classified {
  Classified(stable: Option(Release), prereleases: List(Release))
}

fn download_release(
  source: Source,
  chip: String,
  version: Option(String),
) -> Result(Image, Error) {
  use release <- result.try(fetch_release(source, version))
  let images = release_images(release, source)
  use image <- result.try(
    firmware.select_release_image(images, release.tag_name, chip),
  )
  ensure_cached(image)
}

fn fetch_release(
  source: Source,
  tag: Option(String),
) -> Result(Release, Error) {
  case source, tag {
    CustomRepo(_), None ->
      case fetch_json_release(releases_url(source, Latest)) {
        Ok(release) -> Ok(release)
        Error(_) -> {
          use releases <- result.try(fetch_json_list(releases_url(source, ListPage)))
          case list.filter(releases, fn(r) { !r.draft }) {
            [release, ..] -> Ok(release)
            [] -> Error(ReleaseNotFound("latest"))
          }
        }
      }
    _, None -> fetch_json_release(releases_url(source, Latest))
    _, Some(tag) ->
      case fetch_json_release(releases_url(source, Tag(tag))) {
        Ok(release) -> Ok(release)
        Error(Network(reason)) ->
          case string.contains(reason, "404") {
            True -> Error(ReleaseNotFound(tag))
            False -> Error(Network(reason))
          }
        Error(other) -> Error(other)
      }
  }
}

fn releases_url(source: Source, page: Page) -> String {
  let base = case source {
    Atomvm -> atomvm_releases
    Factory -> factory_releases
    CustomRepo(repo) -> "https://api.github.com/repos/" <> repo <> "/releases"
    _ -> atomvm_releases
  }
  case page {
    ListPage -> base <> "?per_page=" <> int.to_string(page_size)
    Latest -> base <> "/latest"
    Tag(tag) -> base <> "/tags/" <> uri.percent_encode(tag)
  }
}

fn classify_releases(releases: List(Release)) -> Classified {
  let live = list.filter(releases, fn(r) { !r.draft })
  classify_loop(live, [])
}

fn classify_loop(
  releases: List(Release),
  prereleases: List(Release),
) -> Classified {
  case releases {
    [] -> Classified(stable: None, prereleases:)
    [release, ..rest] ->
      case release.prerelease {
        True -> classify_loop(rest, list.append(prereleases, [release]))
        False -> Classified(stable: Some(release), prereleases:)
      }
  }
}

fn release_images(release: Release, source: Source) -> List(Image) {
  let sidecars =
    list.filter_map(release.assets, fn(asset) {
      case string.ends_with(asset.name, ".sha256") {
        True ->
          Ok(#(string.drop_end(asset.name, 7), asset.url))
        False -> Error(Nil)
      }
    })
  list.filter_map(release.assets, fn(asset) {
    case string.ends_with(asset.name, ".img") || string.ends_with(asset.name, ".zip") {
      False -> Error(Nil)
      True ->
        case asset_image(asset.name, release.tag_name, source) {
          None -> Error(Nil)
          Some(image) -> {
            let channel = case image.channel, release.prerelease {
              firmware.Stable, True -> firmware.Prerelease
              channel, _ -> channel
            }
            Ok(
              Image(
                ..image,
                channel:,
                source: Some(source),
                tag: Some(release.tag_name),
                url: Some(asset.url),
                size: asset.size,
                published_at: release.published_at,
                sha256: digest_from_asset(asset),
                sha256_url: sidecar_url(sidecars, asset.name),
                stamp: case image.stamp {
                  Some(stamp) -> Some(stamp)
                  None -> rolling_stamp(image, release, asset)
                },
              ),
            )
          }
        }
    }
  })
}

fn asset_image(name: String, tag: String, source: Source) -> Option(Image) {
  case source {
    CustomRepo(_) ->
      case firmware.parse_name(name) {
        Ok(Image(version: None, ..) as image) ->
          Some(Image(..image, version: Some(tag), channel: firmware.Custom))
        Ok(image) -> Some(image)
        Error(_) ->
          Some(
            Image(
              ..firmware.local_image(name),
              version: Some(tag),
              channel: firmware.Custom,
              path: None,
            ),
          )
      }
    _ ->
      case firmware.parse_name(name) {
        Ok(image) -> Some(image)
        Error(_) -> None
      }
  }
}

fn ensure_cached(image: Image) -> Result(Image, Error) {
  let directory = cache_dir_for(image.source)
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(_) {
      firmware.FileError("Could not create " <> directory)
    }),
  )
  let file_name = cached_file_name(image)
  let path = filepath.join(directory, file_name)
  case simplifile.is_file(path) {
    Ok(True) -> {
      io.println("Using cached " <> path)
      finish_cached(Image(..image, path: Some(path)), path)
    }
    _ -> {
      io.println(
        "Downloading " <> option.unwrap(image.file, image.name) <> "…",
      )
      use #(data, status) <- result.try(download_verified(image))
      use Nil <- result.try(write_atomically(path, data))
      case status {
        "unverified" ->
          io.println("Warning: could not verify sha256 for this download.")
        _ -> Nil
      }
      print_gitignore_hint()
      finish_cached(Image(..image, path: Some(path)), path)
    }
  }
}

fn print_gitignore_hint() -> Nil {
  let gitignore = case simplifile.read(".gitignore") {
    Ok(text) -> Some(text)
    Error(_) -> None
  }
  case firmware.gitignore_hint(gitignore) {
    Some(hint) -> {
      io.println("")
      io.println(hint)
    }
    None -> Nil
  }
}

fn finish_cached(image: Image, path: String) -> Result(Image, Error) {
  case image.kind {
    Img -> Ok(image)
    Zip -> {
      use bundle <- result.try(verify_zip(path, image.stamp))
      let img_path = string_replace_end(path, ".zip", ".img")
      case simplifile.is_file(img_path) {
        Ok(True) -> Nil
        _ -> {
          let _ = write_atomically(img_path, bundle.image)
          Nil
        }
      }
      Ok(with_bundle(image, path, bundle, img_path))
    }
  }
}

fn with_bundle(
  image: Image,
  path: String,
  bundle: firmware.VerifiedBundle,
  img_path: String,
) -> Image {
  Image(
    ..image,
    path: Some(path),
    img_path: Some(img_path),
    stamp: case image.stamp {
      Some(stamp) -> Some(stamp)
      None -> bundle.stamp
    },
    flash_offset: Some(bundle.flash.flash_offset),
    chip: case image.chip {
      Some(chip) -> Some(chip)
      None -> Some(bundle.flash.chip)
    },
    base_chip: case image.base_chip {
      Some(chip) -> Some(chip)
      None -> Some(base_chip_token(bundle.flash.chip))
    },
  )
}

fn extract_local_bundle(path: String) -> Result(Image, Error) {
  use bundle <- result.try(verify_zip(path, None))
  let image =
    Image(
      ..firmware.local_image(path),
      kind: Zip,
      file: Some(basename(path)),
      path: Some(path),
      stamp: bundle.stamp,
      chip: Some(bundle.flash.chip),
      base_chip: Some(base_chip_token(bundle.flash.chip)),
      flash_offset: Some(bundle.flash.flash_offset),
      source: Some(LocalSource),
    )
  let directory = cache_dir()
  use Nil <- result.try(
    simplifile.create_directory_all(directory)
    |> result.map_error(fn(_) {
      firmware.FileError("Could not create " <> directory)
    }),
  )
  let cached_name = cached_file_name(Image(..image, kind: Zip))
  let cached_zip = filepath.join(directory, cached_name)
  let img_path = string_replace_end(cached_zip, ".zip", ".img")
  use Nil <- result.try(case simplifile.is_file(cached_zip) {
    Ok(True) -> Ok(Nil)
    _ ->
      simplifile.read_bits(path)
      |> result.map_error(fn(_) {
        firmware.FileError("Could not read " <> path)
      })
      |> result.try(fn(data) { write_atomically(cached_zip, data) })
  })
  use Nil <- result.try(write_atomically(img_path, bundle.image))
  Ok(with_bundle(image, cached_zip, bundle, img_path))
}

fn base_chip_token(chip: String) -> String {
  case string.split_once(chip, on: "_") {
    Ok(#(before, _)) -> before
    Error(_) -> chip
  }
}

fn verify_zip(
  path: String,
  expected_stamp: Option(String),
) -> Result(firmware.VerifiedBundle, Error) {
  use names <- result.try(zip_list_ffi(path) |> map_zip_error)
  use members <- result.try(
    list.try_map(names, fn(name) {
      use data <- result.try(zip_get_ffi(path, name) |> map_zip_error)
      Ok(#(name, data))
    }),
  )
  firmware_bundle.verify_bundle_members(members, basename(path), expected_stamp)
}

fn download_verified(image: Image) -> Result(#(BitArray, String), Error) {
  use url <- result.try(case image.url {
    Some(url) -> Ok(url)
    None -> Error(Network("Image " <> image.name <> " has no download URL."))
  })
  use data <- result.try(fetch_binary(url))
  let actual_size = bit_array.byte_size(data)
  use Nil <- result.try(case image.size {
    Some(size) ->
      case size == actual_size {
        True -> Ok(Nil)
        False ->
          Error(Network(
            "Size mismatch for "
            <> option.unwrap(image.file, image.name)
            <> ": expected "
            <> int.to_string(size)
            <> ", got "
            <> int.to_string(actual_size),
          ))
      }
    None -> Ok(Nil)
  })
  use expected <- result.try(expected_sha256(image))
  case expected {
    None -> Ok(#(data, "unverified"))
    Some(hex) -> {
      let actual = string.lowercase(bit_array.base16_encode(crypto.hash(crypto.Sha256, data)))
      case actual == string.lowercase(hex) {
        True -> Ok(#(data, "verified"))
        False ->
          Error(Network(
            "Digest mismatch for "
            <> option.unwrap(image.file, image.name)
            <> ": expected "
            <> hex
            <> ", got "
            <> actual,
          ))
      }
    }
  }
}

fn expected_sha256(image: Image) -> Result(Option(String), Error) {
  case image.sha256 {
    Some(hex) -> Ok(Some(hex))
    None ->
      case image.sha256_url {
        Some(url) -> {
          use bytes <- result.try(fetch_binary(url))
          case bit_array.to_string(bytes) {
            Error(_) -> Ok(None)
            Ok(text) -> {
              let lines = parse_sha256_lines(text)
              case
                list.find(lines, fn(pair) {
                  pair.1 == option.unwrap(image.file, "")
                })
              {
                Ok(#(hex, _)) -> Ok(Some(hex))
                Error(Nil) -> Ok(None)
              }
            }
          }
        }
        None -> Ok(None)
      }
  }
}

fn parse_sha256_lines(text: String) -> List(#(String, String)) {
  list.filter_map(string.split(text, on: "\n"), fn(line) {
    case string.split(string.trim(line), on: " ") {
      [hex, name, ..] ->
        case string.length(hex) == 64 {
          True -> Ok(#(hex, string.trim_start(name) |> string.trim_start |> strip_star))
          False -> Error(Nil)
        }
      _ -> Error(Nil)
    }
  })
}

fn strip_star(name: String) -> String {
  case string.starts_with(name, "*") {
    True -> string.drop_start(name, 1)
    False -> name
  }
}

fn digest_from_asset(asset: Asset) -> Option(String) {
  case asset.digest {
    Some("sha256:" <> hex) -> Some(hex)
    _ -> None
  }
}

fn sidecar_url(sidecars: List(#(String, String)), name: String) -> Option(String) {
  case list.key_find(sidecars, name) {
    Ok(url) -> Some(url)
    Error(_) -> None
  }
}

fn rolling_stamp(
  image: Image,
  release: Release,
  asset: Asset,
) -> Option(String) {
  case string.starts_with(release.tag_name, "v") && digit_after_v_tag(release.tag_name) {
    True -> None
    False ->
      case image.kind {
        Zip -> stamp_from_body(option.unwrap(release.body, ""))
        Img ->
          case date_only(asset.updated_at) {
            Some(day) ->
              Some(
                option.unwrap(image.version, release.tag_name)
                <> "+"
                <> string.replace(day, each: "-", with: ""),
              )
            None -> None
          }
      }
  }
}

fn digit_after_v_tag(tag: String) -> Bool {
  case string.drop_start(tag, 1) |> string.first {
    Ok(char) -> string.contains("0123456789", char)
    Error(_) -> False
  }
}

fn stamp_from_body(body: String) -> Option(String) {
  case string.split_once(body, on: "Build stamp: `") {
    Ok(#(_, rest)) ->
      case string.split_once(rest, on: "`") {
        Ok(#(stamp, _)) -> Some(stamp)
        Error(_) -> None
      }
    Error(_) -> None
  }
}

fn find_cached(name: String, source: Source) -> List(Image) {
  let directory = cache_dir_for(Some(source))
  case simplifile.read_directory(directory) {
    Error(_) -> []
    Ok(files) ->
      list.filter_map(list.reverse(list.sort(files, string.compare)), fn(file) {
        case string.ends_with(file, ".img") || string.ends_with(file, ".zip") {
          False -> Error(Nil)
          True -> {
            let image = firmware.local_image(filepath.join(directory, file))
            let wanted = string.lowercase(name)
            case
              string.lowercase(image.name) == wanted
              || string.starts_with(string.lowercase(file), wanted)
            {
              False -> Error(Nil)
              True -> {
                let path = filepath.join(directory, file)
                let img_path = case image.kind {
                  Zip -> {
                    let candidate = string_replace_end(path, ".zip", ".img")
                    case simplifile.is_file(candidate) {
                      Ok(True) -> Some(candidate)
                      _ -> None
                    }
                  }
                  Img -> None
                }
                Ok(
                  Image(
                    ..image,
                    path: Some(path),
                    img_path:,
                    source: Some(Cache),
                    size: file_size(path),
                  ),
                )
              }
            }
          }
        }
      })
  }
}

fn cached_file_name(image: Image) -> String {
  case image.stamp {
    Some(stamp) ->
      case string.split_once(stamp, on: "+") {
        Ok(#(_, suffix)) -> {
          let kind = case image.kind {
            Zip -> "zip"
            Img -> "img"
          }
          image.name <> "+" <> suffix <> "." <> kind
        }
        Error(_) -> option.unwrap(image.file, image.name <> ".img")
      }
    None -> option.unwrap(image.file, image.name <> ".img")
  }
}

fn cache_dir() -> String {
  cache_dir_name
}

fn cache_dir_for(source: Option(Source)) -> String {
  case source {
    Some(CustomRepo(repo)) ->
      filepath.join(cache_dir(), string.replace(repo, each: "/", with: "-"))
    _ -> cache_dir()
  }
}

fn write_atomically(path: String, data: BitArray) -> Result(Nil, Error) {
  let part = path <> ".part"
  use Nil <- result.try(
    simplifile.write_bits(to: part, bits: data)
    |> result.map_error(fn(_) { firmware.FileError("Could not write " <> part) }),
  )
  simplifile.rename(at: part, to: path)
  |> result.map_error(fn(_) { firmware.FileError("Could not finalize " <> path) })
}

// --- HTTP / JSON -------------------------------------------------------------

fn fetch_json_release(url: String) -> Result(Release, Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, release_decoder()) {
    Ok(release) -> Ok(release)
    Error(_) -> Error(Network("Invalid GitHub release JSON from " <> url))
  }
}

fn fetch_json_list(url: String) -> Result(List(Release), Error) {
  use body <- result.try(fetch_text(url))
  case json.parse(body, decode.list(release_decoder())) {
    Ok(releases) -> Ok(releases)
    Error(_) -> Error(Network("Invalid GitHub releases JSON from " <> url))
  }
}

fn fetch_text(url: String) -> Result(String, Error) {
  use bytes <- result.try(fetch_binary(url))
  bit_array.to_string(bytes)
  |> result.map_error(fn(_) { Network("Non-UTF8 response from " <> url) })
}

fn fetch_binary(url: String) -> Result(BitArray, Error) {
  use req <- result.try(
    request.to(url)
    |> result.map_error(fn(_) { Network("Invalid URL: " <> url) }),
  )
  let req =
    req
    |> request.set_header("user-agent", user_agent)
    |> request.set_header("accept", "application/vnd.github+json")
    |> request.set_body(<<>>)
  let config =
    httpc.configure()
    |> httpc.follow_redirects(True)
    |> httpc.timeout(120_000)
  case httpc.dispatch_bits(config, req) {
    Ok(response) if response.status >= 200 && response.status < 300 ->
      Ok(response.body)
    Ok(response) ->
      Error(Network(
        "HTTP " <> int.to_string(response.status) <> " for " <> url,
      ))
    Error(httpc.FailedToConnect(..)) ->
      Error(Network("Network error for " <> url))
    Error(httpc.ResponseTimeout) ->
      Error(Network("Timed out fetching " <> url))
    Error(httpc.InvalidUtf8Response) ->
      Error(Network("Invalid response from " <> url))
  }
}

fn release_decoder() -> decode.Decoder(Release) {
  use tag_name <- decode.field("tag_name", decode.string)
  use draft <- decode.optional_field("draft", False, decode.bool)
  use prerelease <- decode.optional_field("prerelease", False, decode.bool)
  use published_at <- decode.optional_field(
    "published_at",
    None,
    decode.optional(decode.string),
  )
  use body <- decode.optional_field("body", None, decode.optional(decode.string))
  use assets <- decode.optional_field("assets", [], decode.list(asset_decoder()))
  decode.success(Release(
    tag_name:,
    draft:,
    prerelease:,
    published_at: option.map(published_at, date_prefix),
    body:,
    assets:,
  ))
}

fn asset_decoder() -> decode.Decoder(Asset) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("browser_download_url", decode.string)
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  use digest <- decode.optional_field(
    "digest",
    None,
    decode.optional(decode.string),
  )
  use updated_at <- decode.optional_field(
    "updated_at",
    None,
    decode.optional(decode.string),
  )
  decode.success(Asset(name:, url:, size:, digest:, updated_at:))
}

fn release_draft(release: Release) -> Bool {
  release.draft
}

fn date_prefix(value: String) -> String {
  case string.length(value) >= 10 {
    True -> string.slice(value, at_index: 0, length: 10)
    False -> value
  }
}

fn date_only(value: Option(String)) -> Option(String) {
  option.map(value, date_prefix)
}

// --- Helpers -----------------------------------------------------------------

fn file_size(path: String) -> Option(Int) {
  case simplifile.file_info(path) {
    Ok(info) -> Some(info.size)
    Error(_) -> None
  }
}

fn relative_to_cwd(path: String) -> String {
  case string.starts_with(path, "./") {
    True -> string.drop_start(path, 2)
    False -> path
  }
}

fn basename(path: String) -> String {
  case string.split(path, on: "/") {
    [] -> path
    parts -> {
      let assert Ok(last) = list.last(parts)
      last
    }
  }
}

fn stem_name(name: String) -> String {
  let file = basename(name)
  case string.ends_with(file, ".img") || string.ends_with(file, ".zip") {
    True -> string.drop_end(file, 4)
    False -> file
  }
}

fn map_zip_error(result: Result(a, String)) -> Result(a, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error(reason) -> Error(firmware.BadImage(reason))
  }
}

fn string_replace_end(text: String, suffix: String, with with: String) -> String {
  case string.ends_with(text, suffix) {
    True -> string.drop_end(text, string.length(suffix)) <> with
    False -> text
  }
}

@external(erlang, "orbital_ffi", "zip_list")
fn zip_list_ffi(path: String) -> Result(List(String), String)

@external(erlang, "orbital_ffi", "zip_get")
fn zip_get_ffi(path: String, member: String) -> Result(BitArray, String)
