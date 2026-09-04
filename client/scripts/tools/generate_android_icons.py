#!/usr/bin/env python3
"""Compatibility entry point for SmartBook launcher asset generation."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_smartbook_icon import main  # noqa: E402


if __name__ == "__main__":
    if "--apply" not in sys.argv:
        sys.argv.append("--apply")
    main()
