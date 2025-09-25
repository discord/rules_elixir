"""Simple hex.pm utilities for rules_mix.

This provides basic functionality to fetch hex packages without complex
dependency resolution - that's handled by external tooling.
"""

def hex_archive_url(package_name, version):
    """Generate the hex.pm archive URL for a package."""
    return "https://repo.hex.pm/tarballs/{}-{}.tar".format(package_name, version)