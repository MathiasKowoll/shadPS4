#!/usr/bin/env python3

from __future__ import annotations

import argparse
import collections
import datetime
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import zipfile


TITLE_ID = "CUSA52342"
DEFAULT_DATA_DIR = pathlib.Path("/Volumes/CrucialX8/Emulation/Ps4/FC26/port-data")
DEFAULT_BUILD_DIR = pathlib.Path("/Volumes/CrucialX8/Emulation/Ps4/FC26/port-build")


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_value(repo: pathlib.Path, *arguments: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *arguments],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def atomic_json(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.")
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(value, stream, indent=2, sort_keys=True)
            stream.write("\n")
        os.replace(temporary_name, path)
    except BaseException:
        pathlib.Path(temporary_name).unlink(missing_ok=True)
        raise


def inspect_archive(path: pathlib.Path) -> dict:
    with zipfile.ZipFile(path) as archive:
        corrupt_entry = archive.testzip()
        if corrupt_entry is not None:
            raise RuntimeError(f"cache archive contains a corrupt entry: {corrupt_entry}")
        names = archive.namelist()
        counts = collections.Counter(pathlib.PurePosixPath(name).suffix.lstrip(".") for name in names)
        profile = archive.read("profile.bin")
    return {
        "entries": len(names),
        "entry_counts": dict(sorted(counts.items())),
        "profile_sha256": hashlib.sha256(profile).hexdigest(),
    }


def cache_path(data_dir: pathlib.Path) -> pathlib.Path:
    return data_dir / "user" / "cache" / f"{TITLE_ID}.zip"


def atomic_copy(source: pathlib.Path, destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        dir=destination.parent, prefix=f".{destination.name}."
    )
    os.close(descriptor)
    temporary = pathlib.Path(temporary_name)
    try:
        shutil.copy2(source, temporary)
        os.replace(temporary, destination)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


def prepare(data_dir: pathlib.Path) -> int:
    source = cache_path(data_dir)
    if not source.is_file():
        print(f"No shader cache exists yet: {source}")
        return 0

    try:
        details = inspect_archive(source)
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        digest = sha256(source)
        partial = data_dir / "shader-cache" / "partial" / f"{digest}.partial.zip"
        if not partial.exists():
            atomic_copy(source, partial)
        print(f"Preserved incomplete shader cache: {partial}")

        latest_path = data_dir / "shader-cache" / "latest.json"
        if not latest_path.is_file():
            raise RuntimeError(
                f"active shader cache is invalid and no valid snapshot is available: {error}"
            ) from error
        latest = json.loads(latest_path.read_text(encoding="utf-8"))
        archive_name = latest["cache"]["archive"]
        snapshot = data_dir / "shader-cache" / "snapshots" / archive_name
        restored_details = inspect_archive(snapshot)
        atomic_copy(snapshot, source)
        print(
            f"Restored shader cache {latest['cache']['sha256'][:12]}: "
            f"{restored_details['entry_counts'].get('spv', 0)} shaders, "
            f"{restored_details['entry_counts'].get('key', 0)} pipelines"
        )
        return 0

    print(
        f"Shader cache is valid: {details['entry_counts'].get('spv', 0)} shaders, "
        f"{details['entry_counts'].get('key', 0)} pipelines"
    )
    return 0


def status(data_dir: pathlib.Path) -> int:
    source = cache_path(data_dir)
    if not source.is_file():
        print(f"No shader cache exists yet: {source}")
        return 0
    print(f"Cache: {source}")
    print(f"Size: {source.stat().st_size} bytes")
    latest = data_dir / "shader-cache" / "latest.json"
    try:
        details = inspect_archive(source)
    except (OSError, RuntimeError, zipfile.BadZipFile) as error:
        print(f"Active cache is being written or is incomplete: {error}")
        if latest.is_file():
            manifest = json.loads(latest.read_text(encoding="utf-8"))
            cache = manifest["cache"]
            print(
                f"Latest valid snapshot: {cache['sha256']} "
                f"({cache['entry_counts'].get('spv', 0)} shaders, "
                f"{cache['entry_counts'].get('key', 0)} pipelines)"
            )
        else:
            print("Latest valid snapshot: none")
        return 0

    digest = sha256(source)
    print(f"SHA-256: {digest}")
    print(f"Entries: {details['entries']} {details['entry_counts']}")
    print(f"Latest preserved snapshot: {latest if latest.is_file() else 'none'}")
    return 0


def snapshot(
    repo: pathlib.Path,
    data_dir: pathlib.Path,
    build_dir: pathlib.Path,
    label: str,
    exit_code: int | None,
    if_present: bool,
) -> int:
    source = cache_path(data_dir)
    if not source.is_file():
        if if_present:
            return 0
        raise FileNotFoundError(f"shader cache does not exist: {source}")

    snapshots = data_dir / "shader-cache" / "snapshots"
    snapshots.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(dir=snapshots, prefix=".cache.", suffix=".zip")
    os.close(descriptor)
    temporary = pathlib.Path(temporary_name)
    try:
        shutil.copy2(source, temporary)
        details = inspect_archive(temporary)
        digest = sha256(temporary)
        archive_path = snapshots / f"{digest}.zip"
        if archive_path.exists():
            temporary.unlink()
        else:
            os.replace(temporary, archive_path)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise

    profile_path = repo / "ports" / "fc26" / "profile.json"
    game_profile = json.loads(profile_path.read_text(encoding="utf-8"))
    dirty = bool(git_value(repo, "status", "--porcelain"))
    driver_repo = repo / "externals" / "mesa-kosmickrisp"
    manifest = {
        "captured_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "label": label,
        "run_exit_code": exit_code,
        "cache": {
            "archive": archive_path.name,
            "sha256": digest,
            "size": archive_path.stat().st_size,
            **details,
        },
        "game": {
            "title_id": game_profile["title_id"],
            "app_version": game_profile["app_version"],
            "eboot_sha256": game_profile["files"]["eboot.bin"]["sha256"],
        },
        "runtime": {
            "shadps4_commit": git_value(repo, "rev-parse", "HEAD"),
            "shadps4_dirty": dirty,
            "kosmickrisp_commit": git_value(driver_repo, "rev-parse", "HEAD"),
            "binary": str(build_dir / "shadps4"),
        },
    }
    manifest_path = snapshots / f"{digest}.json"
    if not manifest_path.exists():
        atomic_json(manifest_path, manifest)
    atomic_json(data_dir / "shader-cache" / "latest.json", manifest)
    print(
        f"Preserved shader cache {digest[:12]}: "
        f"{details['entry_counts'].get('spv', 0)} shaders, "
        f"{details['entry_counts'].get('key', 0)} pipelines"
    )
    print(f"Snapshot: {archive_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect and preserve the FC26 shader cache")
    parser.add_argument("--data-dir", type=pathlib.Path, default=DEFAULT_DATA_DIR)
    parser.add_argument("--build-dir", type=pathlib.Path, default=DEFAULT_BUILD_DIR)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("status")
    subparsers.add_parser("prepare")
    snapshot_parser = subparsers.add_parser("snapshot")
    snapshot_parser.add_argument("--label", default="manual")
    snapshot_parser.add_argument("--exit-code", type=int)
    snapshot_parser.add_argument("--if-present", action="store_true")
    arguments = parser.parse_args()

    repo = pathlib.Path(__file__).resolve().parents[3]
    if arguments.command == "status":
        return status(arguments.data_dir)
    if arguments.command == "prepare":
        return prepare(arguments.data_dir)
    return snapshot(
        repo,
        arguments.data_dir,
        arguments.build_dir,
        arguments.label,
        arguments.exit_code,
        arguments.if_present,
    )


if __name__ == "__main__":
    raise SystemExit(main())
