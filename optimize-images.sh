#!/bin/bash
# Fast image optimization for web/public/assets
# Converts PNG/JPG to WebP and AVIF, compresses originals
# Requires: cwebp, avifenc, pngquant, jpegoptim

# Configurable quality settings
PNG_QUALITY="${PNG_QUALITY:-90-100}"
JPEG_QUALITY="${JPEG_QUALITY:-95}"
WEBP_QUALITY="${WEBP_QUALITY:-95}"
AVIF_QUALITY="${AVIF_QUALITY:-95}"

# Source and destination directories
SRC_DIR="./web/imagery"   # Set your origin folder here or via env
DEST_DIR="./web/public/assets"

# Create destination directory if it doesn't exist
mkdir -p "$DEST_DIR"

# Function to copy directory structure
copy_structure() {
  find "$SRC_DIR" -type d | while read -r dir; do
    rel="${dir#$SRC_DIR}"
    mkdir -p "$DEST_DIR$rel"
  done
}
copy_structure

# Compress PNGs (high quality, save to DEST_DIR)
find "$SRC_DIR" -type f -name '*.png' | while read -r file; do
  rel="${file#$SRC_DIR}"
  pngquant --force --output "$DEST_DIR$rel" --quality=$PNG_QUALITY "$file"
  # If pngquant fails, copy original
  if [ ! -s "$DEST_DIR$rel" ]; then
    cp "$file" "$DEST_DIR$rel"
  fi
done

# Compress JPGs (high quality, save to DEST_DIR)
find "$SRC_DIR" -type f -name '*.jpg' | while read -r file; do
  rel="${file#$SRC_DIR}"
  cp "$file" "$DEST_DIR$rel"
  jpegoptim --max=$JPEG_QUALITY --strip-all "$DEST_DIR$rel"
  # If jpegoptim fails, original is already copied
  done
find "$SRC_DIR" -type f -name '*.jpeg' | while read -r file; do
  rel="${file#$SRC_DIR}"
  cp "$file" "$DEST_DIR$rel"
  jpegoptim --max=$JPEG_QUALITY --strip-all "$DEST_DIR$rel"
  # If jpegoptim fails, original is already copied
  done

# Convert PNG/JPG to WebP (high quality, save to DEST_DIR)
find "$SRC_DIR" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | while read -r file; do
  rel="${file#$SRC_DIR}"
  outwebp="$DEST_DIR${rel%.*}.webp"
  cwebp -q $WEBP_QUALITY "$file" -o "$outwebp"
  # If cwebp fails, skip
  done

# Convert PNG/JPG to AVIF (high quality, save to DEST_DIR)
find "$SRC_DIR" -type f \( -name '*.png' -o -name '*.jpg' -o -name '*.jpeg' \) | while read -r file; do
  rel="${file#$SRC_DIR}"
  outavif="$DEST_DIR${rel%.*}.avif"
  avifenc -q $AVIF_QUALITY "$file" "$outavif"
  # If avifenc fails, skip
  done

# Optimize SVGs (if svgo is installed, save to DEST_DIR)
if command -v svgo >/dev/null; then
  find "$SRC_DIR" -type f -name '*.svg' | while read -r file; do
    rel="${file#$SRC_DIR}"
    svgo -o "$DEST_DIR$rel" "$file"
  done
fi

echo "Image optimization complete!"
