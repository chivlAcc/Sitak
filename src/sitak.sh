#!/usr/bin/env bash
set -Eeuo pipefail

# Sitak — astrophotography preprocessing using the Siril command-line engine.
# Copyright (C) 2026 chivl
# SPDX-License-Identifier: GPL-3.0-only
# This program comes with ABSOLUTELY NO WARRANTY. See LICENSE for details.
SITAK_VERSION="2.0.0"
EXIT_OK=0
EXIT_INPUT=1
EXIT_REGISTRATION=2
EXIT_IO=3
JSON=0
CLEAN_TEMP=0
NO_COMPRESS=0
TIFF_MODE=0
TIFF_DEFLATE=0
BATCH=0
RECURSIVE=0
SIGMA="3.0"
SESSION_ARG=""
OUTPUT_ARG=""
OUTPUT_EXPLICIT=0

usage() {
  cat <<'EOF'
Sitak 2.0.0 — astrophotography preprocessing using Siril 1.4.5

Usage:
  sitak [session-folder|frames.7z] [-o output-file] [OPTIONS]
  sitak --batch [parent-folder] [-o output-file] [OPTIONS]

If no input is given, Sitak uses the current folder. If -o is omitted,
Sitak writes finalstacked.fit.fz in the current folder (or finalstacked.tif with
--tiff/--tiff-deflate).
A session may contain lights/light, darks/dark, flats/flat, biases/bias,
or offsets folders. An unclassified collection of images is treated as lights.
A .7z archive may contain those folders or one unclassified lights collection.

Options:
  -o, --output FILE  Output path: .fit.fz, .fit/.fits, or .tif/.tiff
  --tiff             Use uncompressed 32-bit TIFF (default: ./finalstacked.tif)
  --tiff-deflate     Use 32-bit TIFF with lossless Deflate compression
  --batch            Process projects below the input folder, or current folder
  --recursive        With --batch, search nested folders for projects
  --sigma FLOAT      Final stack sigma threshold (default 3.0)
  --no-compress      Write uncompressed FITS; default name becomes .fits
  --clean-temp       Remove run intermediates after success
  --json             Emit newline-delimited JSON status and stage events
  --version          Show Sitak version
  -h, --help         Show this help

In batch mode outputs go in the output folder, with each project name prefixed
(e.g. Orion_finalstacked.fit.fz). Original frames and archives are not changed.
EOF
}

json_quote() {
  local value="$1"
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '"%s"' "$value"
}
json_error() {
  local stage="$1" message="$2" code="$3"
  if (( JSON )); then
    printf '{"stage":'; json_quote "$stage"
    printf ',"message":'; json_quote "$message"
    printf ',"progress":1.0,"code":%d}\n' "$code"
  else
    printf 'Sitak: %s: %s\n' "$stage" "$message" >&2
  fi
}
fail() { json_error "$1" "$2" "$3"; exit "$3"; }

valid_sigma() {
  [[ "$1" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)([eE][+-]?[0-9]+)?$ ]] || return 1
  awk -v x="$1" 'BEGIN { exit !(x > 0 && x <= 20) }'
}

is_image_name() {
  case "${1,,}" in
    *.fit|*.fits|*.fts|*.dng|*.cr2|*.cr3|*.nef|*.arw|*.raf|*.rw2|*.orf|*.pef|*.srw|*.3fr|*.iiq|*.kdc|*.dcr|*.mos|*.raw) return 0 ;;
    *) return 1 ;;
  esac
}

is_sitak_output() {
  local path="$1" base="${1##*/}" manifest
  case "${base,,}" in
    finalstacked*|*_finalstacked*|sitak_master*) return 0 ;;
  esac
  manifest="$(dirname -- "$path")/.sitak_outputs"
  [[ -f "$manifest" ]] && grep -Fqx -- "$base" "$manifest"
}

folder_category() {
  local name="${1,,}"
  name="${name//[^a-z0-9]/}"
  case "$name" in
    light|lights|lightframe|lightframes|science|target) printf lights ;;
    dark|darks|darkframe|darkframes) printf darks ;;
    flat|flats|flatframe|flatframes) printf flats ;;
    bias|biases|biasframe|biasframes|offset|offsets) printf biases ;;
    *) return 1 ;;
  esac
}

# A path is a project if it directly contains image files or exposure folders.
is_project_dir() {
  local root="$1" child base
  [[ -d "$root" ]] || return 1
  while IFS= read -r -d '' child; do
    base="$(basename -- "$child")"
    if folder_category "$base" >/dev/null 2>&1; then return 0; fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  while IFS= read -r -d '' child; do
    if is_image_name "$child" && ! is_sitak_output "$child"; then return 0; fi
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type f -print0 2>/dev/null)
  return 1
}

valid_sigma_or_fail() {
  valid_sigma "$1" || fail input "--sigma must be a number greater than 0 and no more than 20" "$EXIT_INPUT"
}

process_one() (
  set -Eeuo pipefail
  local INPUT="$1" OUTPUT_REQUEST="$2" OUTPUT_COMPRESS=1 SESSION="" WORK_ROOT WORK EXTRACT_DIR LOG
  local OUT_DIR_ARG OUT_BASE OUT_DIR OUTPUT OUTPUT_FORMAT SIRIL_CLI SCRIPT SIRIL_CONFIG
  local LIGHT_COUNT=0 DARK_COUNT=0 FLAT_COUNT=0 BIAS_COUNT=0 CFA=0
  local FRAME_COUNT=0 CALIBRATE ENGINE_RC RESULT STAGED

  OUT_DIR_ARG="$(dirname -- "$OUTPUT_REQUEST")"
  OUT_BASE="$(basename -- "$OUTPUT_REQUEST")"
  case "${OUT_BASE,,}" in
    *.fit.fz|*.fits.fz) OUTPUT_FORMAT=fits; OUTPUT_COMPRESS=1 ;;
    *.fit|*.fits) OUTPUT_FORMAT=fits; OUTPUT_COMPRESS=0 ;;
    *.tif|*.tiff) OUTPUT_FORMAT=tiff; OUTPUT_COMPRESS=1 ;;
    *) fail input "Output filename must end in .fit.fz, .fits.fz, .fit, .fits, .tif, or .tiff" "$EXIT_INPUT" ;;
  esac
  if (( TIFF_MODE )) && [[ "$OUTPUT_FORMAT" != tiff ]]; then
    fail input "--tiff/--tiff-deflate requires a .tif or .tiff output filename" "$EXIT_INPUT"
  fi
  if (( TIFF_DEFLATE )) && [[ "$OUTPUT_FORMAT" != tiff ]]; then
    fail input "--tiff-deflate can only be used with a .tif or .tiff output" "$EXIT_INPUT"
  fi
  if (( NO_COMPRESS )) && [[ "$OUTPUT_FORMAT" == tiff ]]; then
    fail input "TIFF is uncompressed by default; omit --no-compress or use --tiff-deflate" "$EXIT_INPUT"
  fi
  if (( NO_COMPRESS && OUTPUT_COMPRESS )); then
    fail input "--no-compress requires an output name ending in .fit or .fits" "$EXIT_INPUT"
  fi
  mkdir -p -- "$OUT_DIR_ARG" 2>/dev/null || fail io "Cannot create output directory: $OUT_DIR_ARG" "$EXIT_IO"
  OUT_DIR="$(cd "$OUT_DIR_ARG" && pwd -P)"
  OUTPUT="$OUT_DIR/$OUT_BASE"
  [[ ! -e "$OUTPUT" ]] || fail io "Output already exists; choose another name or move it first: $OUTPUT" "$EXIT_IO"

  WORK_ROOT="$(pwd -P)/.sitak_work"
  mkdir -p -- "$WORK_ROOT" 2>/dev/null || fail io "Cannot create workspace in the current directory: $WORK_ROOT" "$EXIT_IO"
  WORK="$(mktemp -d "$WORK_ROOT/run-$(date -u +%Y%m%dT%H%M%SZ)-XXXXXX")" || fail io "Cannot create a private Sitak workspace" "$EXIT_IO"
  chmod 700 "$WORK" || fail io "Cannot secure the Sitak workspace" "$EXIT_IO"
  mkdir -p "$WORK"/{input_lights,input_darks,input_flats,input_biases,process,masters}
  LOG="$WORK/siril.log"
  trap 'printf "Sitak stopped. Work files were kept at: %s\\n" "$WORK" >&2; exit 130' INT TERM HUP

  if [[ -d "$INPUT" ]]; then
    SESSION="$(cd "$INPUT" && pwd -P)"
  elif [[ -f "$INPUT" && "${INPUT,,}" == *.7z ]]; then
    command -v 7za >/dev/null 2>&1 || fail setup "The 7z extractor is missing from this Sitak package" "$EXIT_IO"
    EXTRACT_DIR="$WORK/archive-input"
    mkdir -p "$EXTRACT_DIR" || fail io "Cannot create archive extraction folder" "$EXIT_IO"
    local ARCHIVE_LIST="$WORK/archive-list.txt" ARCHIVE_BYTES AVAILABLE_BYTES
    if ! LC_ALL=C 7za l -slt -- "$INPUT" >"$ARCHIVE_LIST" 2>&1; then
      fail input "Could not read this .7z archive. Check that it is intact; password-protected archives are not supported." "$EXIT_INPUT"
    fi
    if grep -Eq '^Encrypted = \+' "$ARCHIVE_LIST"; then
      fail input "This .7z archive is encrypted. Password-protected archives are not supported." "$EXIT_INPUT"
    fi
    if awk '
      /^----------$/ { entries=1; next }
      entries && /^Path = / {
        path=substr($0,8)
        if (path ~ /^\// || path ~ /^[A-Za-z]:/) bad=1
        n=split(path,p,"/"); for(i=1;i<=n;i++) if(p[i]=="..") bad=1
      }
      END { exit !bad }
    ' "$ARCHIVE_LIST"; then
      fail input "This .7z archive contains an unsafe absolute or parent-traversal path; extraction was stopped." "$EXIT_INPUT"
    fi
    ARCHIVE_BYTES="$(awk -F' = ' '/^Size = [0-9]+$/ { total += $2 } END { printf "%.0f", total }' "$ARCHIVE_LIST")"
    AVAILABLE_BYTES="$(df -Pk "$EXTRACT_DIR" | awk 'NR==2 { printf "%.0f", $4 * 1024 }')"
    [[ "$ARCHIVE_BYTES" =~ ^[0-9]+$ && "$AVAILABLE_BYTES" =~ ^[0-9]+$ ]] || fail io "Could not check available disk space before extracting the archive" "$EXIT_IO"
    (( ARCHIVE_BYTES + 104857600 <= AVAILABLE_BYTES )) || fail io "Not enough free disk space to safely extract this archive. It needs about $(( (ARCHIVE_BYTES + 1073741823) / 1073741824 )) GiB; free up space or choose a disk with more room." "$EXIT_IO"
    if ! LC_ALL=C 7za t -bd -- "$INPUT" >"$WORK/archive-test.log" 2>&1; then
      fail input "The .7z archive failed its integrity test. Check the file or download it again." "$EXIT_INPUT"
    fi
    if ! LC_ALL=C 7za x -y -bd "-o$EXTRACT_DIR" -- "$INPUT" </dev/null >"$LOG" 2>&1; then
      if (( ! JSON )); then tail -n 15 "$LOG" >&2 || true; fi
      fail input "Could not extract this .7z archive. Check that it is intact and not password-protected; details are in $LOG" "$EXIT_INPUT"
    fi
    SESSION="$EXTRACT_DIR"
  else
    fail input "Input must be a readable session folder or a .7z archive: $INPUT" "$EXIT_INPUT"
  fi

  if [[ -n "${SITAK_SIRIL_CLI:-}" ]]; then
    SIRIL_CLI="$SITAK_SIRIL_CLI"
  else
    local SCRIPT_DIR PREFIX
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
    PREFIX="$(cd "$SCRIPT_DIR/.." && pwd -P)"
    if [[ -x "$PREFIX/lib/sitak/siril-cli" ]]; then
      SIRIL_CLI="$PREFIX/lib/sitak/siril-cli"
    elif [[ -x "$PREFIX/.cache/siril-build/src/siril-cli" ]]; then
      SIRIL_CLI="$PREFIX/.cache/siril-build/src/siril-cli"
    elif command -v siril-cli >/dev/null 2>&1; then
      SIRIL_CLI="$(command -v siril-cli)"
    else
      fail setup "Siril 1.4.5 CLI engine not found. Use the Sitak AppImage or set SITAK_SIRIL_CLI to its location." "$EXIT_IO"
    fi
  fi
  [[ -x "$SIRIL_CLI" ]] || fail setup "Siril CLI is not executable: $SIRIL_CLI" "$EXIT_IO"

  # Sort all supported frames, find their nearest named exposure folder, and
  # treat otherwise-unclassified images as lights (useful for lights-only sets).
  collect_frames() {
    local desired="$1" destination="$2" prefix="$3" required="$4"
    local -a files=()
    local file relative component category i=0 ext link
    while IFS= read -r -d '' file; do
      relative="${file#"$SESSION"/}"
      category=""
      IFS='/' read -r -a components <<< "$relative"
      for component in "${components[@]::${#components[@]}-1}"; do
        if category="$(folder_category "$component" 2>/dev/null)"; then :; else category=""; fi
      done
      [[ -n "$category" ]] || category=lights
      [[ "$category" == "$desired" ]] && ! is_sitak_output "$file" && files+=("$file")
    done < <(find "$SESSION" -path "$WORK_ROOT" -prune -o -type f \
      \( -iname '*.fit' -o -iname '*.fits' -o -iname '*.fts' \
      -o -iname '*.dng' -o -iname '*.cr2' -o -iname '*.cr3' -o -iname '*.nef' \
      -o -iname '*.arw' -o -iname '*.raf' -o -iname '*.rw2' -o -iname '*.orf' \
      -o -iname '*.pef' -o -iname '*.srw' -o -iname '*.3fr' -o -iname '*.iiq' \
      -o -iname '*.kdc' -o -iname '*.dcr' -o -iname '*.mos' -o -iname '*.raw' \) \
      -print0 | sort -z)
    if (( ${#files[@]} == 0 )); then
      if (( required )); then fail input "No supported light images were found. Add lights/ or light/ folders, or put lights-only images in the session root." "$EXIT_INPUT"; fi
      FRAME_COUNT=0
      return 0
    fi
    for file in "${files[@]}"; do
      ((i+=1))
      ext="${file##*.}"
      printf -v link '%s/%s%05d.%s' "$destination" "$prefix" "$i" "$ext"
      ln -s -- "$file" "$link" || fail io "Cannot stage input image: $file" "$EXIT_IO"
    done
    FRAME_COUNT="${#files[@]}"
  }
  collect_frames lights "$WORK/input_lights" light 1; LIGHT_COUNT="$FRAME_COUNT"
  collect_frames darks "$WORK/input_darks" dark 0; DARK_COUNT="$FRAME_COUNT"
  collect_frames flats "$WORK/input_flats" flat 0; FLAT_COUNT="$FRAME_COUNT"
  collect_frames biases "$WORK/input_biases" bias 0; BIAS_COUNT="$FRAME_COUNT"
  (( LIGHT_COUNT > 0 )) || fail input "No usable light frames found" "$EXIT_INPUT"

  if find "$WORK/input_lights" -maxdepth 1 -type l \
    \( -iname '*.dng' -o -iname '*.cr2' -o -iname '*.cr3' -o -iname '*.nef' \
    -o -iname '*.arw' -o -iname '*.raf' -o -iname '*.rw2' -o -iname '*.orf' \
    -o -iname '*.pef' -o -iname '*.srw' -o -iname '*.3fr' -o -iname '*.iiq' \
    -o -iname '*.kdc' -o -iname '*.dcr' -o -iname '*.mos' -o -iname '*.raw' \) \
    -print -quit | grep -q .; then CFA=1; fi
  if (( ! CFA )); then
    while IFS= read -r -d '' fits_path; do
      if head -c 65536 -- "$fits_path" | LC_ALL=C grep -aEiq '^BAYERPAT[[:space:]]*='; then CFA=1; break; fi
    done < <(find "$WORK/input_lights" -maxdepth 1 -type l \
      \( -iname '*.fit' -o -iname '*.fits' -o -iname '*.fts' \) -print0 | sort -z)
  fi

  SCRIPT="$WORK/sitak_pipeline.ssf"
  SIRIL_CONFIG="$WORK/siril.ini"
  cat > "$SIRIL_CONFIG" <<'SIRIL_CONFIG'
[core]
extension=.fit
check_updates=false
[debayer]
use_bayer_header=true
interpolation=8
[gui_registration]
interpolation=4
clamping=true
SIRIL_CONFIG
  {
    printf 'requires 1.4.5\nsetmem 0.75\n'
    if (( OUTPUT_COMPRESS )); then printf 'setcompress 1 -type=rice 16\n'; else printf 'setcompress 0\n'; fi
    if (( BIAS_COUNT > 0 )); then
      cat <<'SIRIL_BIAS'
cd input_biases
convert bias -out=../process
cd ../process
stack bias rej winsorized 3 3 -nonorm -out=../masters/master_bias
cd ..
SIRIL_BIAS
    fi
    if (( DARK_COUNT > 0 )); then
      cat <<'SIRIL_DARK'
cd input_darks
convert dark -out=../process
cd ../process
stack dark rej winsorized 3 3 -nonorm -out=../masters/master_dark
cd ..
SIRIL_DARK
    fi
    if (( FLAT_COUNT > 0 )); then
      cat <<'SIRIL_FLAT_CONVERT'
cd input_flats
convert flat -out=../process
cd ../process
SIRIL_FLAT_CONVERT
      if (( DARK_COUNT > 0 )); then
        printf 'calibrate flat -dark=../masters/master_dark -cc=dark\n'
      elif (( BIAS_COUNT > 0 )); then
        printf 'calibrate flat -bias=../masters/master_bias\n'
      fi
      cat <<'SIRIL_FLAT_STACK'
stack pp_flat rej winsorized 3 3 -norm=mul -out=../masters/master_flat
cd ..
SIRIL_FLAT_STACK
    fi
    cat <<'SIRIL_LIGHTS'
cd input_lights
convert light -out=../process
cd ../process
SIRIL_LIGHTS
    CALIBRATE='calibrate light'
    if (( DARK_COUNT > 0 )); then CALIBRATE+=" -dark=../masters/master_dark -cc=dark"; fi
    if (( BIAS_COUNT > 0 && DARK_COUNT == 0 )); then CALIBRATE+=" -bias=../masters/master_bias"; fi
    if (( FLAT_COUNT > 0 )); then CALIBRATE+=" -flat=../masters/master_flat"; fi
    if (( CFA )); then CALIBRATE+=" -cfa -equalize_cfa -debayer"; fi
    printf '%s\n' "$CALIBRATE"
    printf 'register pp_light\n'
    printf 'stack r_pp_light rej winsorized %s %s -norm=addscale -output_norm -rgb_equal -32b -out=Sitak_master\n' "$SIGMA" "$SIGMA"
    if [[ "$OUTPUT_FORMAT" == tiff ]]; then
      if (( OUTPUT_COMPRESS )); then printf 'load Sitak_master.fit.fz\n'; else printf 'load Sitak_master.fit\n'; fi
      if (( TIFF_DEFLATE )); then printf 'savetif32 Sitak_export -deflate\n'; else printf 'savetif32 Sitak_export\n'; fi
    fi
    printf 'close\n'
  } > "$SCRIPT"

  if (( JSON )); then
    printf '{"stage":"pipeline","progress":0.02,"lights":%s,"darks":%s,"flats":%s,"biases":%s,"output":' "$LIGHT_COUNT" "$DARK_COUNT" "$FLAT_COUNT" "$BIAS_COUNT"
    json_quote "$OUTPUT"
    printf '}\n'
    printf '{"stage":"siril","progress":0.05}\n'
  fi
  if (( JSON )); then
    set +e
    LC_ALL=C "$SIRIL_CLI" --directory "$WORK" --initfile "$SIRIL_CONFIG" --script "$SCRIPT" 2>&1 | tee "$LOG" | awk -v master_stacks="$(( (BIAS_COUNT > 0) + (DARK_COUNT > 0) + (FLAT_COUNT > 0) ))" '
      function emit(stage, progress) { if (!seen[stage]++) { printf "{\"stage\":\"%s\",\"event\":\"started\",\"progress\":%.2f}\n", stage, progress; fflush() } }
      { line=tolower($0); if (line ~ /running command: convert/) emit("convert",0.10); if (line ~ /running command: calibrate/) emit("calibrate",0.30); if (line ~ /running command: register/) emit("register",0.60); if (line ~ /running command: stack/) { stack_commands++; if (stack_commands > master_stacks) emit("integrate",0.85) } }
    '
    ENGINE_RC=${PIPESTATUS[0]}
    set -e
  else
    set +e
    LC_ALL=C "$SIRIL_CLI" --directory "$WORK" --initfile "$SIRIL_CONFIG" --script "$SCRIPT" 2>&1 | tee "$LOG" >&2
    ENGINE_RC=${PIPESTATUS[0]}
    set -e
  fi
  if (( ENGINE_RC != 0 )); then
    if grep -Eiq 'registration.*(fail|error)|not enough stars|no stars|asterism' "$LOG"; then
      fail registration "Siril could not register the light frames. Check that they contain enough matching stars and have compatible fields of view. See $LOG" "$EXIT_REGISTRATION"
    elif grep -Eiq 'convert.*(fail|error)|unsupported.*format|could not open|no images|not found' "$LOG"; then
      fail input "Siril could not read or convert one or more input frames. Check formats and folder contents. See $LOG" "$EXIT_INPUT"
    else
      fail processing "Siril processing failed (engine exit code $ENGINE_RC). See $LOG" "$EXIT_IO"
    fi
  fi

  if [[ "$OUTPUT_FORMAT" == tiff ]]; then
    RESULT="$WORK/process/Sitak_export.tif"
  elif (( OUTPUT_COMPRESS )); then RESULT="$WORK/process/Sitak_master.fit.fz"
  else RESULT="$WORK/process/Sitak_master.fit"; fi
  [[ -s "$RESULT" ]] || { if [[ "$OUTPUT_FORMAT" != tiff ]]; then if (( OUTPUT_COMPRESS )); then RESULT="$WORK/process/Sitak_master.fits.fz"; else RESULT="$WORK/process/Sitak_master.fits"; fi; fi; }
  [[ -s "$RESULT" ]] || fail processing "Siril finished without creating the expected final image. Keep the workspace for diagnosis: $WORK" "$EXIT_IO"
  STAGED="$OUT_DIR/.${OUT_BASE}.sitak-tmp-$$"
  cp -- "$RESULT" "$STAGED" || fail io "Could not copy the final image to $OUT_DIR" "$EXIT_IO"
  if ! mv --no-clobber -- "$STAGED" "$OUTPUT"; then rm -f -- "$STAGED"; fail io "Could not safely move the output into place: $OUTPUT" "$EXIT_IO"; fi
  [[ ! -e "$STAGED" ]] || { rm -f -- "$STAGED"; fail io "Output path already existed and was not overwritten" "$EXIT_IO"; }
  printf '%s\n' "$OUT_BASE" >> "$OUT_DIR/.sitak_outputs" 2>/dev/null || true
  if (( CLEAN_TEMP )); then rm -rf -- "$WORK"; fi
  trap - INT TERM HUP
  if (( JSON )); then
    printf '{"stage":"complete","progress":1.0,"output":'; json_quote "$OUTPUT"
    printf ',"code":0}\n'
  else
    printf 'Sitak complete: %s\n' "$OUTPUT"
    printf 'Processed %s light(s), %s dark(s), %s flat(s), and %s bias frame(s).\n' "$LIGHT_COUNT" "$DARK_COUNT" "$FLAT_COUNT" "$BIAS_COUNT"
    if (( ! CLEAN_TEMP )); then printf 'Intermediate work files: %s\n' "$WORK"; fi
  fi
  exit "$EXIT_OK"
)

is_archive() { [[ -f "$1" && "${1,,}" == *.7z ]]; }

run_batch() {
  local root="$1" output="$2" output_dir output_base input name safe candidate rc final_rc=0 count=0
  local -a candidates=()
  output_dir="$(dirname -- "$output")"
  output_base="$(basename -- "$output")"
  mkdir -p -- "$output_dir" || fail io "Cannot create batch output folder: $output_dir" "$EXIT_IO"

  discover() {
    local dir="$1" child base
    local -a nested_projects=()
    while IFS= read -r -d '' child; do
      base="$(basename -- "$child")"
      if folder_category "$base" >/dev/null 2>&1; then candidates+=("$dir"); return; fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    while IFS= read -r -d '' child; do
      base="$(basename -- "$child")"
      [[ "$base" == .* || "$base" == .sitak_work ]] && continue
      if [[ -d "$child" ]]; then
        if is_project_dir "$child"; then nested_projects+=("$child")
        elif (( RECURSIVE )); then nested_projects+=("$child")
        fi
      elif is_archive "$child"; then candidates+=("$child")
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0 | sort -z)
    if (( ${#nested_projects[@]} > 0 )); then
      for child in "${nested_projects[@]}"; do
        if is_project_dir "$child"; then candidates+=("$child"); else discover "$child"; fi
      done
      return
    fi
    if is_project_dir "$dir"; then candidates+=("$dir"); return; fi
  }

  if is_archive "$root"; then candidates+=("$root")
  elif [[ -d "$root" ]]; then discover "$(cd "$root" && pwd -P)"
  else fail input "Batch input must be a folder or a .7z archive: $root" "$EXIT_INPUT"
  fi
  (( ${#candidates[@]} > 0 )) || fail input "No projects found. Put each project in its own folder (with lights/ and optional calibration folders), or use --recursive for nested folders." "$EXIT_INPUT"

  for candidate in "${candidates[@]}"; do
    name="$(basename -- "$candidate")"
    name="${name%.7z}"
    safe="${name//[^A-Za-z0-9._-]/_}"
    [[ -n "$safe" ]] || safe="project"
    final_output="$output_dir/${safe}_${output_base}"
    if (( JSON )); then printf '{"stage":"batch_project","event":"started","project":'; json_quote "$name"; printf '}\n'; fi
    set +e
    process_one "$candidate" "$final_output"
    rc=$?
    set -e
    ((count+=1))
    if (( rc != 0 )); then final_rc=$rc; fi
  done
  if (( JSON )); then printf '{"stage":"batch_complete","progress":1.0,"projects":%d,"code":%d}\n' "$count" "$final_rc"
  else printf 'Batch finished: %d project(s) processed; results are in %s\n' "$count" "$(cd "$output_dir" && pwd -P)"
  fi
  return "$final_rc"
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -V|--version) printf 'Sitak %s\n' "$SITAK_VERSION"; exit 0 ;;
    --json) JSON=1 ;;
    --clean-temp) CLEAN_TEMP=1 ;;
    --no-compress) NO_COMPRESS=1 ;;
    --tiff) TIFF_MODE=1 ;;
    --tiff-deflate) TIFF_MODE=1; TIFF_DEFLATE=1 ;;
    --batch) BATCH=1 ;;
    --recursive) RECURSIVE=1 ;;
    --sigma)
      shift; (($#)) || fail input "--sigma needs a number between 0 and 20" "$EXIT_INPUT"
      valid_sigma "$1" || fail input "--sigma must be a number greater than 0 and no more than 20" "$EXIT_INPUT"
      SIGMA="$1" ;;
    -o|--output)
      shift; (($#)) || fail input "-o/--output requires a filename" "$EXIT_INPUT"
      [[ -z "$OUTPUT_ARG" ]] || fail input "Specify output only once" "$EXIT_INPUT"
      OUTPUT_ARG="$1"; OUTPUT_EXPLICIT=1 ;;
    --*) fail input "Unknown option: $1" "$EXIT_INPUT" ;;
    -*) fail input "Unknown option: $1" "$EXIT_INPUT" ;;
    *) [[ -z "$SESSION_ARG" ]] || fail input "Specify only one input folder or archive" "$EXIT_INPUT"; SESSION_ARG="$1" ;;
  esac
  shift
done
(( ! RECURSIVE || BATCH )) || fail input "--recursive must be used with --batch" "$EXIT_INPUT"
[[ -n "$SESSION_ARG" ]] || SESSION_ARG="$(pwd -P)"
if [[ -z "$OUTPUT_ARG" ]]; then
  if (( TIFF_MODE )); then OUTPUT_ARG="finalstacked.tif"
  elif (( NO_COMPRESS )); then OUTPUT_ARG="finalstacked.fits"
  else OUTPUT_ARG="finalstacked.fit.fz"; fi
fi
case "${OUTPUT_ARG,,}" in *.tif|*.tiff) : ;; *) (( ! TIFF_MODE )) || fail input "--tiff/--tiff-deflate requires a .tif or .tiff output filename" "$EXIT_INPUT" ;; esac
if (( NO_COMPRESS )) && [[ "${OUTPUT_ARG,,}" == *.fz ]]; then
  fail input "--no-compress requires an output name ending in .fit or .fits" "$EXIT_INPUT"
fi
if (( BATCH )); then
  run_batch "$SESSION_ARG" "$OUTPUT_ARG"
else
  process_one "$SESSION_ARG" "$OUTPUT_ARG"
fi
