#!/bin/sh
# Builds the upload package for custom hosting (e.g. Hostinger public_html),
# where the POS must answer at the domain root as index.html.
set -e
OUT="${1:-dist}"
rm -rf "$OUT" && mkdir -p "$OUT"

# POS becomes the site's front page
sed 's|href="pos.webmanifest"|href="manifest.json"|' pos.html > "$OUT/index.html"

# same manifest, but rooted at the domain instead of /pos.html
sed 's|"start_url": "pos.html"|"start_url": "./"|' pos.webmanifest > "$OUT/manifest.json"

cp sw.js icon-192.png icon-512.png icon-maskable.png "$OUT/"

cd "$OUT"
rm -f ../mugi-pos.zip
if command -v zip >/dev/null 2>&1; then
  zip -qr ../mugi-pos.zip .
else
  python3 - <<'PY'
import zipfile, os
z = zipfile.ZipFile('../mugi-pos.zip', 'w', zipfile.ZIP_DEFLATED)
for f in sorted(os.listdir('.')):
    z.write(f, f)
z.close()
PY
fi
cd ..
echo "built $OUT/ and mugi-pos.zip"
