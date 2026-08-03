#!/usr/bin/env bash
# Render a Mermaid (.mmd) file to SVG using mmdc + nix-shell chromium.
# Usage: scripts/render-mermaid.sh input.mmd output.svg [width_px] [config.json]
#
# Why nix-shell? The puppeteer-bundled Chrome needs libnspr4/libnss3
# which aren't installed on this host (no sudo). nix-shell -p chromium
# pulls the binary with bundled libs, no system changes.
#
# Why a config file? The %%{init}%% directive in .mmd files gets
# overridden by the default base-theme CSS in some mmdc versions;
# passing an explicit config file via --configFile is more reliable.
#
# Width handling:
#   mmdc auto-sizes the SVG viewBox to fit content. If left alone, a
#   wide horizontal diagram produces a viewBox like 4602x762, which
#   when displayed at width=900 in HTML shrinks text to ~20% of
#   intended size (16px -> 3.9px).
#
#   To keep text readable when the SVG is shown at column-width, we
#   constrain the puppeteer page width via --width. The resulting SVG
#   has a smaller viewBox (text rendered at the configured size), and
#   displaying it at the same column width preserves readability.
#
#   Rule: width_px is BOTH the puppeteer page width AND the recommended
#   display width in HTML (use <img width="$width">).
#
# Defaults:
#   config.json = docs/diagrams/mermaid-config.json
#   width       = 1200  (a wide page renders text at the configured
#                        fontSize, then <img width="1200"> shows it
#                        at native size on GitHub's column)
#
# This script is non-fatal: it exits 1 with a clear message if anything
# fails. It is NOT part of the cloud loop (scan→deploy→verify→drift→
# agent); it is only used by docs authoring.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "usage: $0 input.mmd output.svg [width_px] [config.json]" >&2
  exit 64
fi

INPUT="$1"
OUTPUT="$2"
WIDTH="${3:-1200}"
CONFIG="${4:-$REPO_ROOT/docs/diagrams/mermaid-config.json}"

if [[ ! -f "$INPUT" ]]; then
  echo "render-mermaid: input not found: $INPUT" >&2
  exit 66
fi

if [[ ! -f "$CONFIG" ]]; then
  echo "render-mermaid: config not found: $CONFIG" >&2
  exit 67
fi

# Sanity: ensure the .mmd file starts with a mermaid fence (or is a
# raw mermaid definition that mmdc accepts as input).
if head -1 "$INPUT" | grep -qE '^```(mermaid)?$'; then
  TMP="$(mktemp --suffix=.mmd)"
  awk '/^```(mermaid)?$/{next} /^```$/{next} {print}' "$INPUT" > "$TMP"
  CLEAN_INPUT="$TMP"
  cleanup() { rm -f "$TMP" "$PUPPETEER_CFG"; }
  trap cleanup EXIT
else
  CLEAN_INPUT="$INPUT"
  cleanup() { rm -f "$PUPPETEER_CFG"; }
  trap cleanup EXIT
fi

# Puppeteer config: use the nix chromium binary
PUPPETEER_CFG="$(mktemp --suffix=.json)"

CHROMIUM_BIN="$(find /nix/store -maxdepth 4 -name chromium -type f -executable 2>/dev/null | head -1 || true)"
if [[ -z "$CHROMIUM_BIN" ]]; then
  echo "render-mermaid: chromium not found in /nix/store; run 'nix-shell -p chromium --run true' first" >&2
  exit 69
fi

cat > "$PUPPETEER_CFG" <<EOF
{
  "executablePath": "$CHROMIUM_BIN",
  "args": ["--no-sandbox", "--disable-dev-shm-usage"],
  "viewport": {
    "width": ${WIDTH},
    "height": 2000,
    "deviceScaleFactor": 1
  }
}
EOF

# Render at the configured width so the SVG's viewBox is bounded.
# Height is not meaningful for our use; mmdc measures content height.
mmdc \
  --input "$CLEAN_INPUT" \
  --output "$OUTPUT" \
  --width "$WIDTH" \
  --height 2000 \
  --configFile "$CONFIG" \
  --puppeteerConfigFile "$PUPPETEER_CFG" \
  --quiet \
  --backgroundColor transparent

# Post-process: inject CSS overrides for edge stroke and arrow markers.
# mmdc's default edge stroke is 1px and markers are 8x8px — both become
# invisible when the SVG is displayed at GitHub column width (~900px
# vs native viewBox 1200-1700px scales everything down ~60%).
#
# Our overrides:
#   .edge-thickness-normal   stroke-width: 2.5px (was 1px)
#   .edge-thickness-thick    stroke-width: 4px    (was 3.5px)
#   .edgePath .path          stroke-width: 2.5px (the actual edge lines)
#   .flowchart-link          stroke-width: 2.5px
#   marker                   markerWidth: 18, markerHeight: 18 (was 8)
#   marker path             fill: #0a0a0a, stroke: #0a0a0a (black arrows)
#
# Insert these as a new <style> block right before </svg>. The
# !important markers ensure they win against any default CSS.
python3 - "$OUTPUT" <<'PYEOF'
import re
import sys
output = sys.argv[1]
with open(output, 'r') as f:
    svg = f.read()
marker_css = (
    '<style>'
    '#my-svg .edge-thickness-normal{stroke-width:2.5px !important;}'
    '#my-svg .edge-thickness-thick{stroke-width:4px !important;}'
    '#my-svg .edgePath .path{stroke-width:2.5px !important;}'
    '#my-svg .flowchart-link{stroke-width:2.5px !important;}'
    '#my-svg marker{markerWidth:18px !important;markerHeight:18px !important;}'
    '#my-svg marker path{fill:#0a0a0a !important;stroke:#0a0a0a !important;}'
    '#my-svg .arrowMarkerPath{fill:#0a0a0a !important;stroke:#0a0a0a !important;stroke-width:1.5 !important;}'
    '</style>'
)
new_svg = re.sub(r'(</svg>)', marker_css + r'\1', svg, count=1)
if new_svg == svg:
    print('render-mermaid: WARNING: did not find </svg> in output, marker CSS not injected', file=sys.stderr)
with open(output, 'w') as f:
    f.write(new_svg)
PYEOF

if [[ ! -s "$OUTPUT" ]]; then
  echo "render-mermaid: output empty or missing: $OUTPUT" >&2
  exit 70
fi

# Sanity: SVG should mention mermaid in the metadata
if ! grep -q '<svg' "$OUTPUT"; then
  echo "render-mermaid: output is not an SVG: $OUTPUT" >&2
  exit 71
fi

# Report
SIZE=$(wc -c < "$OUTPUT")
VIEWBOX=$(grep -oE 'viewBox="[^"]*"' "$OUTPUT" | head -1)
echo "render-mermaid: wrote $OUTPUT"
echo "                  ${SIZE} bytes, width ${WIDTH}px, viewBox=${VIEWBOX}"
