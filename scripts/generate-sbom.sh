#!/usr/bin/env bash
# Generate CycloneDX SBOMs for backend (Python) and frontend (Node) and run
# dependency vulnerability scans. Run from the repo root:
#   bash scripts/generate-sbom.sh
#
# Outputs:
#   sbom/backend.cdx.json   - backend SBOM (CycloneDX)
#   sbom/frontend.cdx.json  - frontend SBOM (CycloneDX)
#   sbom/backend-audit.json - pip-audit results
#   sbom/frontend-audit.txt - npm audit results
set -euo pipefail

mkdir -p sbom

echo "==> Backend SBOM + audit (pip-audit)"
pip install -q pip-audit cyclonedx-py 2>/dev/null || true
pip-audit -r backend/requirements.txt --format cyclonedx-json -o sbom/backend.cdx.json || true
pip-audit -r backend/requirements.txt --format json -o sbom/backend-audit.json || true

echo "==> Frontend SBOM + audit (npm)"
cd frontend
npm install --no-audit --no-fund >/dev/null 2>&1 || true
npx @cyclonedx/cyclonedx-npm --output-file ../sbom/frontend.cdx.json || true
npm audit --json > ../sbom/frontend-audit.json || true
cd ..

echo "==> Done. SBOMs written to ./sbom"
