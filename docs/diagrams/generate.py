"""
Diagramas de arquitetura — gin-tattoo / aws-devops
Requer: d2 (https://d2lang.com) e layout ELK

Uso:
    python3 docs/diagrams/generate.py

Os arquivos .d2 são a fonte — edite-os diretamente para ajustar.
Este script apenas invoca o d2 para regenerar os SVGs.
"""

import subprocess
import sys

DIAGRAMS = [
    ("docs/diagrams/architecture.d2", "docs/diagrams/architecture.svg"),
    ("docs/diagrams/pipeline.d2",     "docs/diagrams/pipeline.svg"),
]

for src, out in DIAGRAMS:
    result = subprocess.run(
        ["d2", "--theme=201", "--layout=elk", src, out],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        print(f"✗ {src}: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    print(f"✓ {out}")
