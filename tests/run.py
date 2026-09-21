"""Run the portable suites, optionally including the macOS native pipeline."""

import argparse
import importlib.util
import json
import os
import platform
import shutil
import signal
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def run(command, env):
    process = subprocess.Popen(command, cwd=ROOT, env=env, start_new_session=True)
    try:
        code = process.wait(timeout=90)
    except subprocess.TimeoutExpired:
        print("FAIL: test exceeded 90 seconds", flush=True)
        code = 1
    finally:
        # A failed suite must not leave its own renderer children running.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    if code:
        raise SystemExit(code)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", action="store_true", help="also test the compiled macOS helper")
    args = parser.parse_args()
    nvim = os.environ.get("NVIM", "nvim")
    for executable in [nvim, "pdfinfo", "pdftoppm", "pdftotext"]:
        if not shutil.which(executable):
            parser.error(f"required executable is missing: {executable}")
    helper = ROOT / ".build/pdfpreview-native"
    if args.native:
        if platform.system() != "Darwin" or not helper.is_file():
            parser.error("native checks require macOS and make native")
        for module in ["PIL", "numpy"]:
            if importlib.util.find_spec(module) is None:
                parser.error("install pixel-test dependencies: python3 -m pip install -r tests/requirements.txt")
    with tempfile.TemporaryDirectory(prefix="pdfpreview-tests-") as temporary:
        env = dict(
            os.environ,
            NVIM_LOG_FILE=str(Path(temporary) / "nvim.log"),
            PDFPREVIEW_TEST_NATIVE="1" if args.native else "0",
        )
        lua = [nvim, "--headless", "-u", "NONE", "-i", "NONE", "-l"]
        suites = ["core", "reader", "surface", "selection", "translate"]
        if args.native:
            suites.extend(["native", "pdfkit"])
        for suite in suites:
            print(f"Running {suite}", flush=True)
            run(lua + [f"tests/{suite}.lua"], env)
        if args.native:
            info = subprocess.run(
                [str(helper), str(ROOT / "tests/sample.pdf")],
                input='{"id":1,"action":"info"}\n',
                text=True,
                capture_output=True,
                check=True,
                timeout=15,
            )
            ui_api = subprocess.run(
                [
                    nvim,
                    "--headless",
                    "-u",
                    "NONE",
                    "-i",
                    "NONE",
                    "--cmd",
                    "lua io.stdout:write(vim.api.nvim_ui_send and '1' or '0')",
                    "+qa",
                ],
                env=env,
                capture_output=True,
                text=True,
                check=True,
                timeout=15,
            )
            if json.loads(info.stdout)["surface"] and ui_api.stdout == "1":
                print("Running ui", flush=True)
                run(lua + ["tests/ui.lua"], env)
            else:
                print("SKIP: embedded surface UI needs Neovim 0.12+ and a unified-memory Metal device", flush=True)
            print("Running pixels", flush=True)
            run([sys.executable, "tests/pixels.py"], env)
    print("All selected suites passed", flush=True)


if __name__ == "__main__":
    main()
