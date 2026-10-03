#!/usr/bin/env sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
vendor="$root/bridge/assets/vendor"
mkdir -p "$vendor"

cd "$root"
npm ci --ignore-scripts
npm run build:widgets

# Keep the MIME renderer on the same plotly.js release shipped by the current
# Plotly Python package.  FigureWidget embeds this bundle separately; matching
# the two avoids subtle incompatibilities between regular MIME output and
# widget output.
curl -fsSL https://cdn.plot.ly/plotly-3.7.0.min.js -o "$vendor/plotly.min.js"
curl -fsSL https://cdn.jsdelivr.net/npm/dompurify@3.2.6/dist/purify.min.js -o "$vendor/purify.min.js"
curl -fsSL https://cdn.jsdelivr.net/npm/marked@16.2.1/lib/marked.umd.js -o "$vendor/marked.min.js"
curl -fsSL https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js -o "$vendor/katex.min.js"
curl -fsSL https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css -o "$vendor/katex.min.css"

mkdir -p "$vendor/fonts"
for name in \
  KaTeX_AMS-Regular KaTeX_Caligraphic-Bold KaTeX_Caligraphic-Regular \
  KaTeX_Fraktur-Bold KaTeX_Fraktur-Regular KaTeX_Main-Bold \
  KaTeX_Main-BoldItalic KaTeX_Main-Italic KaTeX_Main-Regular \
  KaTeX_Math-BoldItalic KaTeX_Math-Italic KaTeX_SansSerif-Bold \
  KaTeX_SansSerif-Italic KaTeX_SansSerif-Regular KaTeX_Script-Regular \
  KaTeX_Size1-Regular KaTeX_Size2-Regular KaTeX_Size3-Regular \
  KaTeX_Size4-Regular KaTeX_Typewriter-Regular
do
  curl -fsSL "https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/fonts/$name.woff2" -o "$vendor/fonts/$name.woff2"
done
