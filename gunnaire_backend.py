#!/usr/bin/env python3
"""Render-compatible launcher for the canonical GunnAire backend.

Keep all service implementation in ``Backend/gunnaire_backend.py``. Render's
existing start command runs this root file, so importing the canonical module
here prevents the deployed API from drifting behind the implementation tested
with the Xcode application.
"""

from Backend.gunnaire_backend import main


if __name__ == "__main__":
    main()
