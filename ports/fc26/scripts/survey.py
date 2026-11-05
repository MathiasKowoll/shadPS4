#!/usr/bin/env python3

import argparse
import hashlib
import json
import os
import struct
import sys
from pathlib import Path


PORT_DIR = Path(__file__).resolve().parent.parent
PROFILE_PATH = PORT_DIR / "profile.json"


def parse_sfo(path: Path) -> dict[str, object]:
    data = path.read_bytes()
    if len(data) < 20:
        raise ValueError("param.sfo is too small")
    magic, _version, key_start, data_start, count = struct.unpack_from("<4s4I", data)
    if magic != b"\x00PSF":
        raise ValueError("param.sfo has an invalid magic value")

    values: dict[str, object] = {}
    for index in range(count):
        entry_offset = 20 + index * 16
        if entry_offset + 16 > len(data):
            raise ValueError("param.sfo entry table is truncated")
        key_offset, value_format, value_length, _max_length, value_offset = struct.unpack_from(
            "<HHIII", data, entry_offset
        )
        key_position = key_start + key_offset
        key_end = data.find(b"\0", key_position)
        if key_end < 0:
            raise ValueError("param.sfo key table is malformed")
        key = data[key_position:key_end].decode("utf-8", errors="replace")
        value_position = data_start + value_offset
        value = data[value_position : value_position + value_length]
        if value_format == 0x0404 and len(value) >= 4:
            values[key] = struct.unpack_from("<I", value)[0]
        else:
            values[key] = value.rstrip(b"\0").decode("utf-8", errors="replace")
    return values


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(4 * 1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def survey(game_dir: Path, verify_hashes: bool) -> tuple[dict[str, object], list[str]]:
    profile = json.loads(PROFILE_PATH.read_text(encoding="utf-8"))
    problems: list[str] = []
    sfo_path = game_dir / "sce_sys" / "param.sfo"
    try:
        sfo = parse_sfo(sfo_path)
    except (OSError, ValueError) as error:
        sfo = {}
        problems.append(f"cannot read {sfo_path}: {error}")

    title_id = str(sfo.get("TITLE_ID", ""))
    app_version = str(sfo.get("APP_VER", ""))
    if title_id != profile["title_id"]:
        problems.append(f"TITLE_ID is {title_id or 'missing'}, expected {profile['title_id']}")
    if app_version != profile["app_version"]:
        problems.append(
            f"APP_VER is {app_version or 'missing'}, expected {profile['app_version']}"
        )

    file_results: dict[str, object] = {}
    for relative_name, expected in profile["files"].items():
        path = game_dir / relative_name
        result: dict[str, object] = {"exists": path.is_file()}
        if not path.is_file():
            problems.append(f"required file is missing: {relative_name}")
        else:
            size = path.stat().st_size
            result["size"] = size
            if size != expected["size"]:
                problems.append(
                    f"size mismatch for {relative_name}: {size}, expected {expected['size']}"
                )
            if verify_hashes:
                digest = sha256(path)
                result["sha256"] = digest
                if digest != expected["sha256"]:
                    problems.append(f"SHA-256 mismatch for {relative_name}")
        file_results[relative_name] = result

    total_size = 0
    file_count = 0
    for root, _directories, names in os.walk(game_dir):
        for name in names:
            try:
                total_size += (Path(root) / name).stat().st_size
                file_count += 1
            except OSError:
                continue

    report: dict[str, object] = {
        "profile": str(PROFILE_PATH),
        "game_dir": str(game_dir),
        "title_id": title_id,
        "app_version": app_version,
        "title": sfo.get("TITLE", ""),
        "system_version": sfo.get("SYSTEM_VER", ""),
        "file_count": file_count,
        "total_size": total_size,
        "hashes_verified": verify_hashes,
        "critical_files": file_results,
        "valid": not problems,
        "problems": problems,
    }
    return report, problems


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate the supported FC26 PS4 build")
    parser.add_argument("game_dir", type=Path)
    parser.add_argument("--verify-hashes", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    game_dir = args.game_dir.expanduser().resolve()
    report, problems = survey(game_dir, args.verify_hashes)
    rendered = json.dumps(report, indent=2, ensure_ascii=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")

    if problems:
        for problem in problems:
            print(f"STOP: {problem}", file=sys.stderr)
        return 1
    mode = "identity, sizes, and SHA-256" if args.verify_hashes else "identity and sizes"
    print(f"FC26 profile verified: {mode}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

