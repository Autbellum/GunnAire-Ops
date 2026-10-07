#!/usr/bin/env python3
"""Run the repository's native build verification pipeline."""

from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parent / "generated" / "omni_runner.py"), run_name="__main__")
