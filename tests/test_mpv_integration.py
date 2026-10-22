from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
SERVER = FIXTURES / "redirect_hls_server.py"
PLAYLIST = FIXTURES / "redirect_hls.m3u"
CONTROLLER = FIXTURES / "integration_controller.lua"
QUIT_CONTROLLER = FIXTURES / "quit_controller.lua"
HOST = "127.0.0.1"
PORT = 18991


def find_mpv() -> Path:
    candidates = [ROOT.parent / "mpv.exe", ROOT.parent / "mpv"]
    path_mpv = shutil.which("mpv")
    if path_mpv:
        candidates.append(Path(path_mpv))
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise RuntimeError("mpv executable not found next to portable_config or on PATH")


def wait_for_server(process: subprocess.Popen[str]) -> None:
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if process.poll() is not None:
            _, stderr = process.communicate(timeout=1)
            raise RuntimeError(f"integration server exited early: {stderr.strip()}")
        try:
            with socket.create_connection((HOST, PORT), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("integration server did not become ready")


def assert_mpv_ok(completed: subprocess.CompletedProcess[str], label: str) -> None:
    if (
        completed.returncode != 0
        or "Lua error" in completed.stdout
        or "script-opts: unknown key" in completed.stdout
    ):
        tail = "\n".join(completed.stdout.splitlines()[-40:])
        raise RuntimeError(f"{label} failed ({completed.returncode}):\n{tail}")


def main() -> int:
    mpv = find_mpv()
    server = subprocess.Popen(
        [sys.executable, str(SERVER)],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    )

    server_stdout = ""
    server_stderr = ""
    try:
        wait_for_server(server)
        with tempfile.TemporaryDirectory(prefix="mpv-iptv-integration-") as config_dir:
            config_path = Path(config_dir)
            (config_path / "cache").mkdir()
            shutil.copytree(ROOT / "scripts" / "epg", config_path / "scripts" / "epg")
            (config_path / "script-opts").mkdir()
            shutil.copy2(ROOT / "script-opts" / "epg.conf", config_path / "script-opts" / "epg.conf")
            env = os.environ.copy()
            common_options = [
                f"--config-dir={config_dir}",
                "--no-ytdl",
                "--idle=yes",
                "--force-window=no",
                "--vo=null",
                "--ao=null",
                "--terminal=yes",
            ]

            empty_completed = subprocess.run(
                [str(mpv), f"--script={QUIT_CONTROLLER}", *common_options],
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=6,
                check=False,
            )
            assert_mpv_ok(empty_completed, "mpv empty-start integration run")

            command = [
                str(mpv),
                str(PLAYLIST),
                f"--script={CONTROLLER}",
                "--script-opts=epg-iptv_retry_count=0,epg-iptv_retry_delay=0.1,epg-iptv_network_timeout=3",
                *common_options,
            ]
            completed = subprocess.run(
                command,
                cwd=ROOT,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                encoding="utf-8",
                errors="replace",
                timeout=12,
                check=False,
            )
            assert_mpv_ok(completed, "mpv redirect/HLS integration run")
    finally:
        if server.poll() is None:
            server.terminate()
        try:
            server_stdout, server_stderr = server.communicate(timeout=3)
        except subprocess.TimeoutExpired:
            server.kill()
            server_stdout, server_stderr = server.communicate(timeout=3)

    records = []
    for line in server_stdout.splitlines():
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "path" in record:
            records.append(record)

    required_paths = ("/start", "/master.m3u8", "/segment.ts")
    missing = [
        path
        for path in required_paths
        if not any(record.get("path") == path and record.get("headers_ok") for record in records)
    ]
    if missing:
        summary = [
            {"path": record.get("path"), "headers_ok": record.get("headers_ok")}
            for record in records
        ]
        raise RuntimeError(
            "source headers were not propagated to all redirect/HLS requests; "
            f"missing={missing}, records={summary}, server_stderr={server_stderr.strip()}"
        )

    invalid = [
        {"path": record.get("path"), "headers_ok": record.get("headers_ok")}
        for record in records
        if not record.get("headers_ok")
    ]
    if invalid:
        raise RuntimeError(
            "mpv emitted requests outside the descriptor-controlled IPTV chain; "
            f"invalid={invalid}, server_stderr={server_stderr.strip()}"
        )

    print(
        "PASS mpv integration: local M3U intercepted before native expansion; "
        "302 -> HLS manifest -> TS segment all inherited source headers"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
