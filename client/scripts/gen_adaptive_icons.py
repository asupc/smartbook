#!/usr/bin/env python3
"""Compatibility entry point for the active SmartBook adaptive icon assets."""

import sys

from generate_smartbook_icon import main


if __name__ == "__main__":
    if "--apply" not in sys.argv:
        sys.argv.append("--apply")
    main()
