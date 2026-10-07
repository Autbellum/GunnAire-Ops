#!/usr/bin/env python3
"""Run the repository's simulator launch telemetry analyzer."""

from pathlib import Path
import runpy

runpy.run_path(str(Path(__file__).resolve().parent / "generated" / "telemetry_agent.py"), run_name="__main__")
