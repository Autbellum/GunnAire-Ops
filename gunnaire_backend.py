#!/usr/bin/env python3
"""Render-compatible launcher for the GunnAire backend and local-first AI routes.

The canonical business API remains in ``Backend/gunnaire_backend.py``. The
selected deployment entrypoint subclasses that handler only to add authenticated
local-AI status and assist routes. All other routes retain canonical behavior.
"""

from Backend.gunnaire_local_ai_backend import main


if __name__ == "__main__":
    main()
