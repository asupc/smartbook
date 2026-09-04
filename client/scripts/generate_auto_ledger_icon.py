#!/usr/bin/env python3
"""Compatibility entry point for the 智记 SmartBook icon generator."""

import sys

from generate_smartbook_icon import main


if __name__ == "__main__":
    if "--apply" not in sys.argv:
        sys.argv.append("--apply")
    main()
