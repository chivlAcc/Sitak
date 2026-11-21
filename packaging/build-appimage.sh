#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ARCH="$(uname -m)"
[[ "$ARCH" == x86_64 ]] || { echo "Only x86_64 AppImages are configured (found $ARCH)." >&2; exit 1; }

for cmd in meson ninja cmake pkg-config curl unzip python3 7za readelf ldd; do
  command -v "$cmd" >/dev/null || { echo "Missing build command: $cmd" >&2; exit 1; }
done
for dep in glib-2.0 gio-2.0 gtk+-3.0 gtksourceview-4 gsl lcms2 fftw3f cfitsio cairo opencv4 libraw libtiff-4 libjpeg libpng exiv2; do
  pkg-config --exists "$dep" || { echo "Missing $dep development files; see the Ubuntu dependency list in README.md." >&2; exit 1; }
done

# Extract the exact Siril 1.4.5 release archive. Clean checkouts fetch the
# immutable release tag from the official Siril GitLab project automatically.
SIRIL_SRC="$ROOT/upstream/siril-1.4.5"
if [[ ! -f "$SIRIL_SRC/meson.build" ]]; then
  SIRIL_ARCHIVE="$ROOT/siril-1.4.5.zip"
  if [[ ! -f "$SIRIL_ARCHIVE" ]]; then
    SIRIL_ARCHIVE="$ROOT/.cache/siril-1.4.5.zip"
    mkdir -p "$ROOT/.cache"
    echo "Downloading official Siril 1.4.5 source archive..."
    curl --fail --location --retry 3 \
      "https://gitlab.com/free-astro/siril/-/archive/1.4.5/siril-1.4.5.zip" \
      --output "$SIRIL_ARCHIVE"
  fi
  mkdir -p "$ROOT/upstream"
  unzip -q -n "$SIRIL_ARCHIVE" -d "$ROOT/upstream"
fi

# The provided source ZIP omits Git submodule contents. Fetch the matching
# pinned dependencies used to build this release, so builds do not float.
fetch_pinned() {
  local url="$1" commit="$2" dest="$3"
  if [[ ! -f "$dest/CMakeLists.txt" && ! -f "$dest/meson.build" ]]; then
    rm -rf "$dest"
    mkdir -p "$dest"
    git -C "$dest" init -q
    git -C "$dest" remote add origin "$url"
    git -C "$dest" fetch -q --depth=1 origin "$commit"
    git -C "$dest" checkout -q FETCH_HEAD
  fi
}
command -v git >/dev/null || { echo "Git is required to fetch Siril's missing submodules." >&2; exit 1; }
fetch_pinned https://github.com/CarVac/librtprocess.git 9a858270acb2096e2e403d932760ee688fcac425 "$SIRIL_SRC/subprojects/librtprocess"
fetch_pinned https://github.com/ibireme/yyjson.git 9ddba001a4ea88e93b46932e5c5b87b222e19a5f "$SIRIL_SRC/subprojects/yyjson"

SIRIL_BUILD="$ROOT/.cache/siril-build"
if [[ -f "$SIRIL_BUILD/meson-private/coredata.dat" ]]; then
  meson setup --reconfigure "$SIRIL_BUILD" "$SIRIL_SRC" --buildtype=release \
    -Dopenmp=true -Dlibraw=true -Dlibtiff=true -Dlibjpeg=true -Dlibpng=true \
    -Dlibcurl=false -Dlibgit2=false -DlibXISF=false -Dffms2=false \
    -Dffmpeg=false -Dlibheif=false -Dlibjxl=false -Dcriterion=false
else
  meson setup "$SIRIL_BUILD" "$SIRIL_SRC" --buildtype=release \
    -Dopenmp=true -Dlibraw=true -Dlibtiff=true -Dlibjpeg=true -Dlibpng=true \
    -Dlibcurl=false -Dlibgit2=false -DlibXISF=false -Dffms2=false \
    -Dffmpeg=false -Dlibheif=false -Dlibjxl=false -Dcriterion=false
fi
ninja -C "$SIRIL_BUILD" -j"$(nproc)" src/siril-cli

if [[ -f "$ROOT/build/meson-private/coredata.dat" ]]; then meson setup --reconfigure "$ROOT/build" "$ROOT" --prefix=/usr --buildtype=release
else meson setup "$ROOT/build" "$ROOT" --prefix=/usr --buildtype=release
fi
meson compile -C "$ROOT/build"
APPDIR="$ROOT/AppDir"
rm -rf "$APPDIR"
DESTDIR="$APPDIR" meson install -C "$ROOT/build"
mkdir -p "$APPDIR/usr/lib/sitak"
install -m 0755 "$SIRIL_BUILD/src/siril-cli" "$APPDIR/usr/lib/sitak/siril-cli"
mkdir -p "$APPDIR/usr/bin"
SEVEN_ZIP="$(readlink -f "$(command -v 7za)")"
if [[ ! -x "$SEVEN_ZIP" ]] || ! readelf -h "$SEVEN_ZIP" >/dev/null 2>&1; then
  SEVEN_ZIP="/usr/lib/7zip/7za"
fi
[[ -x "$SEVEN_ZIP" ]] && readelf -h "$SEVEN_ZIP" >/dev/null 2>&1 || {
  echo "Could not locate the 7za ELF executable (expected /usr/lib/7zip/7za)." >&2
  exit 1
}
install -m 0755 "$SEVEN_ZIP" "$APPDIR/usr/bin/7za"
install -m 0644 "$ROOT/packaging/sitak.desktop" "$APPDIR/sitak.desktop"
python3 "$ROOT/packaging/make_icon.py" "$APPDIR/sitak.png"
mkdir -p "$APPDIR/usr/share/metainfo"
install -m 0644 "$ROOT/packaging/sitak.appdata.xml" "$APPDIR/usr/share/metainfo/sitak.appdata.xml"
install -m 0644 "$ROOT/LICENSE" "$APPDIR/LICENSE"
SOURCE_DIR="$APPDIR/usr/share/sitak/source"
mkdir -p "$SOURCE_DIR"
tar -czf "$SOURCE_DIR/sitak-corresponding-source.tar.gz" --exclude-vcs \
  -C "$ROOT" src/sitak.sh meson.build README.md LICENSE packaging .github/workflows/build.yml upstream/siril-1.4.5
cat > "$SOURCE_DIR/DEPENDENCIES.txt" <<'EOF'
Sitak 2.0.0 is authored by chivl and licensed GPL-3.0-only.
The executable bundles the Siril 1.4.5 CLI engine. Siril's upstream project states GPL version 3 or later (GPL-3.0-or-later).
Siril upstream repository: https://gitlab.com/free-astro/siril (release source is also included in this archive).
librtprocess commit: 9a858270acb2096e2e403d932760ee688fcac425
yyjson commit: 9ddba001a4ea88e93b46932e5c5b87b222e19a5f
The AppImage also bundles runtime shared libraries; consult each component's license and copyright notices before redistribution.
EOF

TOOL="$ROOT/.cache/linuxdeploy-x86_64.AppImage"
if [[ ! -x "$TOOL" ]]; then
  curl --fail --location --retry 3 \
    https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage \
    --output "$TOOL"
  chmod +x "$TOOL"
fi
CUSTOM_APPRUN="$ROOT/.cache/sitak-AppRun"
install -m 0755 "$ROOT/packaging/AppRun" "$CUSTOM_APPRUN"
(
  cd "$ROOT"
  APPIMAGE_EXTRACT_AND_RUN=1 ARCH=x86_64 "$TOOL" \
    --appdir "$APPDIR" \
    --executable "$APPDIR/usr/lib/sitak/siril-cli" \
    --executable "$APPDIR/usr/bin/7za" \
    --custom-apprun "$CUSTOM_APPRUN" \
    --desktop-file "$APPDIR/sitak.desktop" \
    --icon-file "$APPDIR/sitak.png" \
    --output appimage
)
for binary in "$APPDIR/usr/lib/sitak/siril-cli" "$APPDIR/usr/bin/7za"; do
  missing="$(LD_LIBRARY_PATH="$APPDIR/usr/lib:$APPDIR/usr/lib/x86_64-linux-gnu" ldd "$binary" | grep 'not found' || true)"
  [[ -z "$missing" ]] || { echo "Unresolved runtime library for $binary:" >&2; echo "$missing" >&2; exit 1; }
done
GENERATED="$(find "$ROOT" -maxdepth 1 -type f -name '*.AppImage' ! -name 'linuxdeploy*' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)"
[[ -n "$GENERATED" ]] || { echo "AppImage creation did not produce an output file." >&2; exit 1; }
[[ "$GENERATED" == "$ROOT/Sitak-x86_64.AppImage" ]] || mv -f "$GENERATED" "$ROOT/Sitak-x86_64.AppImage"
echo "Created $ROOT/Sitak-x86_64.AppImage"
