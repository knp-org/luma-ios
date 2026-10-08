"""Generate icon variants from the user-provided logo. No demo music is bundled."""
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
subprocess.run(["swift", str(root / "Scripts/generate_logo_assets.swift")], cwd=root, check=True)
