"""AtomVM firmware listing and download used by `orbital install`.

Talks to the GitHub Releases API (stdlib urllib only — no extra deps) and
caches images under `firmware_images/` at the project root, matching
ExAtomVM's layout and naming.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

ATOMVM_RELEASES = "https://api.github.com/repos/atomvm/atomvm/releases"
FACTORY_RELEASES = (
    "https://api.github.com/repos/atomvm/atomvm-esp32-firmware-factory/releases"
)
CACHE_DIR = "firmware_images"
BUILD_IMAGES_DIR = "_build/atomvm_images"
PAGE_SIZE = 10

CHIP_RE = re.compile(r"^esp32([a-z]\d+)?(_[a-z0-9]+)*$")
STABLE_RE = re.compile(r"^v\d+\.\d+\.\d+$")
VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+(-[0-9A-Za-z.]+)*$")
CHANNEL_RE = re.compile(r"^nightly(-[0-9A-Za-z.]+)+$")
USER_AGENT = "orbital-firmware/1.0 (+https://github.com/nathanjohnson320/orbital)"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="firmware.py")
    sub = parser.add_subparsers(dest="command", required=True)

    listing = sub.add_parser("list-images")
    listing.add_argument("--chip")
    listing.add_argument("--repo")
    listing.add_argument("--connected-chips", default="")

    ensure = sub.add_parser("ensure")
    ensure.add_argument("--mode", required=True, choices=["release", "name", "path"])
    ensure.add_argument("--chip")
    ensure.add_argument("--version")
    ensure.add_argument("--name")
    ensure.add_argument("--path")
    ensure.add_argument("--repo")

    args = parser.parse_args(argv)
    try:
        if args.command == "list-images":
            text = list_images(
                chip=args.chip,
                repo=args.repo,
                connected_chips=[
                    c for c in args.connected_chips.split(",") if c.strip()
                ],
            )
            sys.stdout.write(text)
            if not text.endswith("\n"):
                sys.stdout.write("\n")
            return 0
        if args.command == "ensure":
            image = ensure_image(
                mode=args.mode,
                chip=args.chip,
                version=args.version,
                name=args.name,
                path=args.path,
                repo=args.repo,
            )
            return emit(image)
    except FirmwareError as error:
        print(str(error), file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001
        print(f"firmware helper error: {error}", file=sys.stderr)
        return 1
    return 1


def emit(payload: object) -> int:
    json.dump(payload, sys.stdout, separators=(",", ":"))
    sys.stdout.write("\n")
    return 0


class FirmwareError(RuntimeError):
    pass


def list_images(
    chip: str | None,
    repo: str | None,
    connected_chips: list[str],
) -> str:
    header: list[str] = []
    filter_chips: list[str] | None
    if chip == "all":
        filter_chips = None
    elif chip:
        filter_chips = [chip]
    elif connected_chips:
        filter_chips = connected_chips
        header.extend(f"Connected chip filter: {c}" for c in connected_chips)
    else:
        filter_chips = None
        header.append("No chip filter; listing every image.")

    sources: list[object] = ["atomvm", "factory"]
    if repo:
        sources.append(("repo", repo))

    sections: list[dict] = []
    warning = None
    try:
        for source in sources:
            sections.extend(listing_sections(source, fetch_json(releases_url(source, "list"))))
    except FirmwareError as error:
        warning = f"Warning: {error}. Only local images are listed."
        sections = []

    if warning:
        header.append(warning)
    sections.append(local_section())
    return render_list(sections, filter_chips, header)


def ensure_image(
    mode: str,
    chip: str | None,
    version: str | None,
    name: str | None,
    path: str | None,
    repo: str | None,
) -> dict:
    source = ("repo", repo) if repo else None
    if mode == "path":
        if not path:
            raise FirmwareError("--path is required for mode=path")
        return ensure_path(path)
    if mode == "release":
        if not chip:
            raise FirmwareError("--chip is required to download a release image")
        return ensure_release(chip, version, source or "atomvm")
    if mode == "name":
        if not name:
            raise FirmwareError("--name is required for mode=name")
        return ensure_name(name, source)
    raise FirmwareError(f"unknown mode {mode}")


def ensure_path(path: str) -> dict:
    p = Path(path)
    if not p.is_file():
        raise FirmwareError(f"Image file not found: {path}")
    if p.suffix == ".zip":
        return extract_local_bundle(p)
    image = local_image_dict(str(p))
    image["path"] = str(p)
    return image


def ensure_release(chip: str, version: str | None, source: object) -> dict:
    if source == "atomvm" and version:
        cached = find_cached(f"AtomVM-{chip}-elixir-{version}", source)
        if cached:
            return cached[0]

    release = fetch_release(source, version)
    images = release_images(release, source)
    selected = select_release_image(images, release["tag_name"], chip)
    return ensure_cached(selected)


def ensure_name(name: str, source: object | None) -> dict:
    parsed = parse_name(name)
    wanted = (parsed["name"] if parsed else parse_stem(name)).lower()

    if source is None:
        channel = parsed["channel"] if parsed else "stable"
        resolved_source: object = "factory" if channel == "nightly" else "atomvm"
        version = parsed["version"] if parsed else None
        try:
            release = fetch_release(resolved_source, version)
            images = release_images(release, resolved_source)
            found = [i for i in images if i["name"].lower() == wanted]
            if found:
                return ensure_cached(found[0])
        except FirmwareError:
            pass
        cached = find_cached(wanted, resolved_source)
        if cached:
            return cached[0]
        raise FirmwareError(
            f"Unknown image '{name}'. List them with --list-images."
        )

    releases = fetch_json(releases_url(source, "list"))
    for release in releases:
        if release.get("draft"):
            continue
        for image in release_images(release, source):
            if image["name"].lower() == wanted:
                return ensure_cached(image)
    cached = find_cached(wanted, source)
    if cached:
        return cached[0]
    raise FirmwareError(f"Unknown image '{name}' in {source[1]}.")


def extract_local_bundle(path: Path) -> dict:
    data = path.read_bytes()
    bundle = verify_bundle(data, path.name, None)
    image = local_image_dict(str(path.with_suffix(".img")))
    image["kind"] = "zip"
    image["file"] = path.name
    image["path"] = str(path)
    image["stamp"] = bundle.get("stamp") or image.get("stamp")
    image["chip"] = image.get("chip") or bundle["flash"].get("chip")
    image["base_chip"] = (image["chip"] or "").split("_")[0] or None
    image["flash_offset"] = bundle["flash"].get("flash_offset")
    cache_name = cached_file_name(image)
    img_name = cache_name.rsplit(".", 1)[0] + ".img" if image.get("stamp") else path.with_suffix(".img").name
    img_path = Path(cache_dir()) / img_name
    if not img_path.exists():
        write_atomically(img_path, bundle["image"])
    image["img_path"] = str(img_path)
    return image


# --- GitHub -----------------------------------------------------------------


def fetch_release(source: object, tag: str | None) -> dict:
    if isinstance(source, tuple) and source[0] == "repo" and tag is None:
        try:
            return fetch_json(releases_url(source, None))
        except FirmwareError:
            releases = [
                r for r in fetch_json(releases_url(source, "list")) if not r.get("draft")
            ]
            if not releases:
                raise FirmwareError(f"No releases found for {source[1]}")
            return releases[0]
    try:
        return fetch_json(releases_url(source, tag))
    except FirmwareError as error:
        if "404" in str(error):
            raise FirmwareError(
                f"Release not found: {tag or 'latest'} ({source_label(source)})"
            ) from error
        raise


def releases_url(source: object, tag: str | None | str) -> str:
    base = releases_base(source)
    if tag == "list":
        return f"{base}?per_page={PAGE_SIZE}"
    if tag is None:
        return f"{base}/latest"
    return f"{base}/tags/{urllib.parse.quote(tag, safe='')}"


def releases_base(source: object) -> str:
    if source == "atomvm":
        return ATOMVM_RELEASES
    if source == "factory":
        return FACTORY_RELEASES
    if isinstance(source, tuple) and source[0] == "repo":
        return f"https://api.github.com/repos/{source[1]}/releases"
    raise FirmwareError(f"Unknown source {source}")


def source_label(source: object) -> str:
    if source == "atomvm":
        return "atomvm/AtomVM"
    if source == "factory":
        return "atomvm/atomvm-esp32-firmware-factory"
    if isinstance(source, tuple):
        return source[1]
    return str(source)


def fetch_json(url: str):
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/vnd.github+json", "User-Agent": USER_AGENT},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return json.load(response)
    except urllib.error.HTTPError as error:
        raise FirmwareError(f"HTTP {error.code} for {url}") from error
    except urllib.error.URLError as error:
        raise FirmwareError(f"Network error for {url}: {error.reason}") from error


def fetch_binary(url: str) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise FirmwareError(f"HTTP {error.code} downloading {url}") from error
    except urllib.error.URLError as error:
        raise FirmwareError(f"Network error downloading {url}: {error.reason}") from error


# --- Listing ----------------------------------------------------------------


def listing_sections(source: object, releases: list) -> list[dict]:
    if source == "atomvm":
        classified = classify_releases(releases)
        out = []
        if classified["stable"]:
            release = classified["stable"]
            out.append(
                {
                    "kind": "stable",
                    "title": f"Stable release {release['tag_name']} ({date(release.get('published_at'))})",
                    "images": release_images(release, "atomvm"),
                }
            )
        for release in classified["prereleases"]:
            out.append(
                {
                    "kind": "prerelease",
                    "title": f"Prerelease {release['tag_name']} ({date(release.get('published_at'))})",
                    "images": release_images(release, "atomvm"),
                }
            )
        return out
    if source == "factory":
        images = []
        for release in releases:
            if release.get("draft"):
                continue
            images.extend(release_images(release, "factory"))
        return [
            {
                "kind": "nightly",
                "title": "Nightly builds (atomvm-esp32-firmware-factory)",
                "images": images,
            }
        ]
    # custom repo
    assert isinstance(source, tuple)
    repo = source[1]
    sections = []
    for release in releases:
        if release.get("draft"):
            continue
        sections.append(
            {
                "kind": "custom",
                "title": f"Custom builds ({repo}), release {release['tag_name']} ({date(release.get('published_at'))})",
                "images": release_images(release, source),
            }
        )
    return sections


def classify_releases(releases: list) -> dict:
    live = [r for r in releases if not r.get("draft")]
    prereleases = []
    for release in live:
        if release.get("prerelease"):
            prereleases.append(release)
        else:
            return {"stable": release, "prereleases": prereleases}
    return {"stable": None, "prereleases": prereleases}


def local_section() -> dict:
    return {"kind": "local", "title": "Local images", "images": local_images()}


def local_images() -> list[dict]:
    root = Path(cache_dir())
    dirs = [root]
    if root.is_dir():
        dirs.extend(sorted(p for p in root.iterdir() if p.is_dir()))
    cached = []
    for directory in dirs:
        shown = str(directory.relative_to(Path.cwd())) if directory.is_absolute() else str(directory)
        try:
            shown = str(directory.relative_to(Path.cwd()))
        except ValueError:
            shown = str(directory)
        cached.extend(files_in(directory, shown, "cache"))
    cached = without_extracted(cached)
    return cached + files_in(Path(BUILD_IMAGES_DIR), BUILD_IMAGES_DIR, "build")


def files_in(directory: Path, shown_as: str, source: str) -> list[dict]:
    if not directory.is_dir():
        return []
    out = []
    for file in sorted(directory.iterdir()):
        if file.suffix not in {".img", ".zip"}:
            continue
        image = local_image_dict(file.name)
        image.update(
            {
                "source": source,
                "path": str(Path(shown_as) / file.name),
                "size": file.stat().st_size,
            }
        )
        out.append(image)
    return out


def without_extracted(images: list[dict]) -> list[dict]:
    bundles = {(i["name"], i.get("stamp")) for i in images if i.get("kind") == "zip"}
    return [
        i
        for i in images
        if not (i.get("kind") == "img" and (i["name"], i.get("stamp")) in bundles)
    ]


def render_list(sections: list[dict], filter_chips: list[str] | None, header: list[str]) -> str:
    hidden = 0
    shown = []
    for section in sections:
        kept = []
        for image in section["images"]:
            if listed(image, filter_chips):
                kept.append(image)
            else:
                hidden += 1
        shown.append({**section, "images": kept})

    body: list[str] = []
    for section in shown:
        if not section["images"]:
            continue
        width = max(len(label(section, image)) for image in section["images"])
        body.append(section["title"])
        for image in section["images"]:
            body.append(
                "  "
                + label(section, image).ljust(width)
                + "  "
                + flavor(image).ljust(11)
                + "  "
                + format_size(image.get("size"))
            )
        body.append("")

    intro = header[:]
    if filter_chips:
        intro.append(
            "Showing images for "
            + ", ".join(filter_chips)
            + "; pass --chip all to list every image."
        )
    if intro:
        intro.append("")
    hidden_line = [f"{hidden} images for other chips not shown.", ""] if hidden else []
    footer = [
        "Install with:",
        "  gleam run -m orbital install --image <name or path>",
        "  gleam run -m orbital install --version <tag>        the Elixir image of a release",
        "Older releases: https://github.com/atomvm/AtomVM/releases",
    ]
    return "\n".join(intro + body + hidden_line + footer)


def listed(image: dict, chips: list[str] | None) -> bool:
    if chips is None:
        return True
    chip = image.get("base_chip") or image.get("chip")
    return chip is None or chip in chips or image.get("chip") in chips


def label(section: dict, image: dict) -> str:
    if section["kind"] == "local":
        return image.get("path") or image.get("file") or image["name"]
    if not image.get("chip"):
        return image.get("file") or image["name"]
    return image["name"]


def flavor(image: dict) -> str:
    if image.get("elixir") is True:
        return "Elixir"
    if image.get("elixir") is False:
        return "Erlang only"
    return "unknown"


def format_size(size: int | None) -> str:
    if not size:
        return ""
    if size < 1024:
        return f"{size} B"
    if size < 1024 * 1024:
        return f"{size / 1024:.1f} KB"
    return f"{size / (1024 * 1024):.1f} MB"


# --- Images -----------------------------------------------------------------


def release_images(release: dict, source: object) -> list[dict]:
    assets = release.get("assets") or []
    sidecars = {
        a["name"][: -len(".sha256")]: a["browser_download_url"]
        for a in assets
        if a["name"].endswith(".sha256")
    }
    out = []
    for asset in assets:
        name = asset["name"]
        if not (name.endswith(".img") or name.endswith(".zip")):
            continue
        image = asset_image(name, release["tag_name"], source)
        if image is None:
            continue
        image.update(
            {
                "source": source_key(source),
                "tag": release["tag_name"],
                "url": asset["browser_download_url"],
                "size": asset.get("size"),
                "published_at": date(release.get("published_at")),
                "sha256": digest_from_asset(asset),
                "sha256_url": sidecars.get(name),
                "stamp": image.get("stamp")
                or rolling_stamp(image, release, asset),
            }
        )
        if release.get("prerelease") and image["channel"] == "stable":
            image["channel"] = "prerelease"
        out.append(image)
    return out


def asset_image(name: str, tag: str, source: object) -> dict | None:
    parsed = parse_name(name)
    if isinstance(source, tuple) and source[0] == "repo":
        if parsed:
            if parsed["version"] is None:
                parsed["version"] = tag
            parsed["channel"] = "custom"
            return parsed
        image = local_image_dict(name)
        image["version"] = tag
        image["channel"] = "custom"
        return image
    return parsed


def select_release_image(images: list[dict], tag: str, chip: str) -> dict:
    wanted = f"AtomVM-{chip}-elixir-{tag}"
    for image in images:
        if image["name"] == wanted or (
            image.get("chip") == chip
            and image.get("elixir") is True
            and image.get("version") == tag
        ):
            return image
    # fall back to any elixir image for chip
    for image in images:
        if image.get("base_chip") == chip and image.get("elixir") is True:
            return image
    for image in images:
        if image.get("base_chip") == chip:
            return image
    raise FirmwareError(
        f"No firmware image for chip '{chip}' in release {tag}."
    )


def ensure_cached(image: dict) -> dict:
    directory = Path(cache_dir_for(image.get("source")))
    directory.mkdir(parents=True, exist_ok=True)
    file_name = cached_file_name(image)
    path = directory / file_name
    if path.exists():
        image = dict(image)
        image["path"] = str(path)
        if image.get("kind") == "zip":
            img_path = path.with_suffix(".img")
            if not img_path.exists():
                bundle = verify_bundle(path.read_bytes(), path.name, image.get("stamp"))
                write_atomically(img_path, bundle["image"])
                image["flash_offset"] = bundle["flash"].get("flash_offset")
            image["img_path"] = str(img_path)
        print(f"Using cached {path}", file=sys.stderr)
        return image

    print(f"Downloading {image.get('file') or image['name']}…", file=sys.stderr)
    data, status = download_verified(image)
    write_atomically(path, data)
    image = dict(image)
    image["path"] = str(path)
    if image.get("kind") == "zip":
        bundle = verify_bundle(data, path.name, image.get("stamp"))
        img_path = path.with_suffix(".img")
        write_atomically(img_path, bundle["image"])
        image["img_path"] = str(img_path)
        image["flash_offset"] = bundle["flash"].get("flash_offset")
    if status == "unverified":
        print("Warning: could not verify sha256 for this download.", file=sys.stderr)
    return image


def download_verified(image: dict) -> tuple[bytes, str]:
    url = image.get("url")
    if not url:
        raise FirmwareError(f"Image {image['name']} has no download URL.")
    data = fetch_binary(url)
    size = image.get("size")
    if isinstance(size, int) and len(data) != size:
        raise FirmwareError(
            f"Size mismatch for {image.get('file')}: expected {size}, got {len(data)}"
        )
    expected = image.get("sha256")
    if not expected and image.get("sha256_url"):
        text = fetch_binary(image["sha256_url"]).decode("utf-8", errors="replace")
        for hex_digest, name in parse_sha256_lines(text):
            if name == image.get("file"):
                expected = hex_digest
                break
    if not expected:
        return data, "unverified"
    actual = hashlib.sha256(data).hexdigest()
    if actual.lower() != expected.lower():
        raise FirmwareError(
            f"Digest mismatch for {image.get('file')}: expected {expected}, got {actual}"
        )
    return data, "verified"


def parse_sha256_lines(text: str) -> list[tuple[str, str]]:
    out = []
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and re.fullmatch(r"[0-9a-fA-F]{64}", parts[0]):
            out.append((parts[0], parts[1].lstrip("*")))
    return out


def digest_from_asset(asset: dict) -> str | None:
    digest = asset.get("digest")
    if isinstance(digest, str) and digest.startswith("sha256:"):
        return digest.split(":", 1)[1]
    return None


def find_cached(name: str, source: object) -> list[dict]:
    directory = Path(cache_dir_for(source))
    if not directory.is_dir():
        return []
    wanted = name.lower()
    out = []
    for file in sorted(directory.iterdir(), reverse=True):
        if file.suffix not in {".img", ".zip"}:
            continue
        image = local_image_dict(file.name)
        if image["name"].lower() == wanted or file.name.lower().startswith(wanted):
            image["path"] = str(file)
            if image["kind"] == "zip":
                img = file.with_suffix(".img")
                if img.exists():
                    image["img_path"] = str(img)
            out.append(image)
    return out


def cached_file_name(image: dict) -> str:
    stamp = image.get("stamp")
    if stamp and "+" in stamp:
        suffix = stamp.split("+", 1)[1]
        kind = image.get("kind") or "img"
        return f"{image['name']}+{suffix}.{kind}"
    return image.get("file") or f"{image['name']}.img"


def cache_dir() -> str:
    return str(Path.cwd() / CACHE_DIR)


def cache_dir_for(source: object | None) -> str:
    if isinstance(source, str) and source.startswith("repo:"):
        repo = source.split(":", 1)[1]
        return str(Path(cache_dir()) / repo.replace("/", "-"))
    if isinstance(source, tuple) and source[0] == "repo":
        return str(Path(cache_dir()) / source[1].replace("/", "-"))
    return cache_dir()


def source_key(source: object) -> str:
    if isinstance(source, tuple):
        return f"repo:{source[1]}"
    return str(source)


def write_atomically(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


# --- Naming -----------------------------------------------------------------


def parse_name(name_or_path: str) -> dict | None:
    file = Path(name_or_path).name
    stem, kind = split_extension(file)
    parts = stem.split("-")
    if len(parts) < 2:
        return None
    atomvm, chip, *rest = parts
    if atomvm.lower() != "atomvm" or not CHIP_RE.match(chip):
        return None
    flavor: list[str] = []
    version_tokens: list[str] = []
    for token in rest:
        if not version_tokens and not version_token(token):
            flavor.append(token)
        else:
            version_tokens.append(token)
    try:
        version, stamp = parse_version(version_tokens)
    except ValueError:
        return None
    name = stem.split("+", 1)[0]
    return {
        "name": name,
        "file": file if kind else None,
        "kind": kind,
        "chip": chip,
        "base_chip": chip.split("_", 1)[0],
        "elixir": "elixir" in flavor,
        "features": [f for f in flavor if f != "elixir"],
        "version": version,
        "channel": channel(version),
        "stamp": stamp,
        "path": None,
        "img_path": None,
        "flash_offset": None,
    }


def local_image_dict(path_or_file: str) -> dict:
    parsed = parse_name(path_or_file)
    if parsed:
        parsed["channel"] = "local"
        return parsed
    file = Path(path_or_file).name
    stem, kind = split_extension(file)
    return {
        "name": stem,
        "file": file,
        "kind": kind or "img",
        "chip": None,
        "base_chip": None,
        "elixir": None,
        "features": [],
        "version": None,
        "channel": "local",
        "stamp": None,
        "path": None,
        "img_path": None,
        "flash_offset": None,
    }


def split_extension(file: str) -> tuple[str, str | None]:
    if file.endswith(".img"):
        return file[: -len(".img")], "img"
    if file.endswith(".zip"):
        return file[: -len(".zip")], "zip"
    return file, None


def parse_stem(name: str) -> str:
    stem, _kind = split_extension(Path(name).name)
    return stem.split("+", 1)[0]


def version_token(token: str) -> bool:
    return token == "nightly" or bool(re.match(r"^v\d", token))


def parse_version(tokens: list[str]) -> tuple[str | None, str | None]:
    if not tokens:
        return None, None
    joined = "-".join(tokens)
    if "+" in joined:
        version, suffix = joined.split("+", 1)
        stamp = f"{version}+{suffix}"
    else:
        version, stamp = joined, None
    if VERSION_RE.match(version) or CHANNEL_RE.match(version):
        return version, stamp
    raise ValueError("bad version")


def channel(version: str | None) -> str:
    if version is None:
        return "local"
    if version.startswith("nightly"):
        return "nightly"
    if STABLE_RE.match(version):
        return "stable"
    return "prerelease"


def rolling_stamp(image: dict, release: dict, asset: dict) -> str | None:
    tag = release.get("tag_name") or ""
    if re.match(r"^v\d", tag):
        return None
    if image.get("kind") == "zip":
        return stamp_from_body(release.get("body") or "")
    updated = date(asset.get("updated_at"))
    if updated:
        return f"{image.get('version') or tag}+{updated.replace('-', '')}"
    return None


def stamp_from_body(body: str) -> str | None:
    match = re.search(r"Build stamp: `([^`]+)`", body)
    return match.group(1) if match else None


def date(value: str | None) -> str | None:
    if isinstance(value, str) and len(value) >= 10:
        return value[:10]
    return None


# --- Zip bundles ------------------------------------------------------------


def verify_bundle(data: bytes, file_name: str, expected_stamp: str | None) -> dict:
    try:
        with zipfile.ZipFile(io_bytes(data)) as zf:
            names = zf.namelist()
            img_names = [n for n in names if n.endswith(".img") and "/" not in n.rstrip("/")]
            if len(img_names) != 1:
                # also accept nested single img
                img_names = [n for n in names if n.endswith(".img")]
            if len(img_names) != 1:
                raise FirmwareError(f"{file_name}: expected exactly one .img member")
            img_name = img_names[0]
            image = zf.read(img_name)
            flash = {"chip": None, "flash_offset": None, "parts": []}
            stamp = expected_stamp
            if "FLASH.txt" in names:
                flash = parse_flash_txt(zf.read("FLASH.txt").decode("utf-8", errors="replace"))
            if "sdkconfig" in names:
                stamp = stamp or stamp_from_sdkconfig(
                    zf.read("sdkconfig").decode("utf-8", errors="replace")
                )
            parts = {}
            for part in flash.get("parts") or []:
                part_name = part["name"]
                if part_name in names:
                    parts[part_name] = zf.read(part_name)
            return {
                "image": image,
                "stamp": stamp,
                "flash": flash,
                "parts": parts,
                "stem": Path(file_name).stem,
            }
    except zipfile.BadZipFile as error:
        raise FirmwareError(f"{file_name}: not a valid zip bundle") from error


def io_bytes(data: bytes):
    import io

    return io.BytesIO(data)


def parse_flash_txt(text: str) -> dict:
    chip = None
    flash_offset = None
    parts = []
    in_contents = False
    for line in text.splitlines():
        if line.startswith("Chip:"):
            chip = line.split(":", 1)[1].strip().lower()
        elif line.startswith("Flash offset:"):
            flash_offset = int(line.split(":", 1)[1].strip(), 0)
        elif line.strip() == "Contents":
            in_contents = True
            continue
        elif in_contents:
            if re.match(r"^[-=]+$", line.strip()) or not line.strip():
                if parts and not line.strip():
                    break
                continue
            match = re.match(r"\s*(0x[0-9a-fA-F]+)\s+(\S+)", line)
            if match:
                parts.append(
                    {"offset": int(match.group(1), 0), "name": match.group(2)}
                )
            elif line and not line.startswith(" "):
                break
    return {"chip": chip, "flash_offset": flash_offset, "parts": parts}


def stamp_from_sdkconfig(text: str) -> str | None:
    match = re.search(r'CONFIG_APP_PROJECT_VER="([^"]+)"', text)
    return match.group(1) if match else None


if __name__ == "__main__":
    raise SystemExit(main())
