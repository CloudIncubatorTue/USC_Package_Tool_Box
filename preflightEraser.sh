#!/usr/bin/env bash
# preflightEraser.sh — remove tools installed by preflight.sh. No sudo.
# Default: only paths listed in the install receipt.
# --reset: ignore the receipt and remove every client tool from the manifest
# from the preflight install directories, then delete the receipt.
set -euo pipefail

YES="${PREFLIGHT_ERASER_YES:-0}"
RESET="${PREFLIGHT_ERASER_RESET:-0}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
RECEIPT="${PREFLIGHT_RECEIPT:-${HOME}/.local/share/preflight/install-receipt.tsv}"
BIN_DIR="${PREFLIGHT_BIN_DIR:-${HOME}/.local/bin}"
PLUGIN_DIR="${PREFLIGHT_HELM_PLUGINS:-${HELM_PLUGINS:-${HOME}/.local/share/helm/plugins}}"
MANIFEST_PATH="${PREFLIGHT_MANIFEST:-${SCRIPT_DIR}/usc-manifest.json}"

for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    --reset) RESET=1 ;;
    -h|--help)
      cat <<EOF
Usage: ./preflightEraser.sh [--reset] [--yes|-y]

Default (receipt):
  Removes only the files and directories listed in:
    ${RECEIPT}
  Each row is: name, version, path, manifest-hash
  Binaries an operator placed themselves are not removed.
  If that receipt is missing or has no tool rows, the same removal as
  --reset runs for this user. Run the script as the user that ran preflight.sh,
  because the receipt and install directories are under \$HOME.

--reset:
  Ignores the receipt. Removes every client tool named in:
    ${MANIFEST_PATH}
  from the preflight install directories:
    binaries: ${BIN_DIR}/<name>
    helm plugins: ${PLUGIN_DIR}/<plugin>
  Plugin directories are chosen by exact manifest name, or by a plugin.yaml
  whose name is that tool (helm-diff matches a plugin named diff).
  Other files in those directories are left in place.
  curl, tar, gzip, and checksum tools are not removed.
  The receipt is deleted afterward so the record matches the empty install.

Does not use sudo.
Override paths with PREFLIGHT_RECEIPT, PREFLIGHT_BIN_DIR, PREFLIGHT_HELM_PLUGINS,
PREFLIGHT_MANIFEST.
Non-interactive: PREFLIGHT_ERASER_YES=1 or --yes
Reset without a flag: PREFLIGHT_ERASER_RESET=1
EOF
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument: ${arg} (try --help)" >&2
      exit 1
      ;;
  esac
done

if [[ -z "${HOME:-}" ]]; then
  echo "ERROR: HOME is not set" >&2
  exit 1
fi

safe_to_remove() {
  local path="$1"
  local protected p
  [[ "$path" == /* ]] || return 1
  [[ "$path" != *".."* ]] || return 1
  [[ "$path" != */ ]] || return 1
  protected=(
    "/"
    "/bin"
    "/lib"
    "/opt"
    "/usr"
    "/usr/bin"
    "/usr/local"
    "/usr/local/bin"
    "${HOME}"
    "${HOME}/.local"
    "${HOME}/.local/bin"
    "${HOME}/.local/share"
    "${HOME}/.local/share/helm"
    "${HOME}/.local/share/helm/plugins"
    "${HOME}/.local/share/preflight"
    "${BIN_DIR}"
    "${PLUGIN_DIR}"
  )
  for p in "${protected[@]}"; do
    [[ -n "$p" && "$path" == "$p" ]] && return 1
  done
  return 0
}

# name and installTarget for each clientTools entry (depth-2 fields only).
parse_manifest_targets() {
  local manifest="$1"
  awk '
    function take_string(s) {
      if (after_key) {
        if (depth == 2) {
          if (key == "name") name = s
          else if (key == "installTarget") target = s
        }
        after_key = 0
        key = ""
      } else key = s
    }
    function emit() {
      if (name == "") return
      printf "%s\034%s\n", name, target
      name = ""
      target = ""
    }
    BEGIN { depth = 0; in_str = 0; esc = 0; token = ""; after_key = 0; key = "" }
    {
      n = length($0)
      for (i = 1; i <= n; i++) {
        c = substr($0, i, 1)
        if (in_str) {
          if (esc) { token = token c; esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { in_str = 0; take_string(token); token = ""; continue }
          token = token c
          continue
        }
        if (c == "\"") { in_str = 1; token = ""; continue }
        if (c == "{") { depth++; after_key = 0; key = ""; continue }
        if (c == "}") {
          if (depth == 2) emit()
          depth--
          continue
        }
        if (c == ":") { after_key = 1; continue }
        if (c == "," || c == "[") { after_key = 0; continue }
      }
    }
  ' "$manifest"
}

plugin_yaml_name() {
  local yaml="$1"
  awk -F: '/^[[:space:]]*name:/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$yaml"
}

# Collect absolute paths --reset will remove. One path per line.
collect_reset_paths() {
  local name target yaml pname short d
  local -a bin_names=() plugin_names=()
  if [[ -f "$MANIFEST_PATH" ]]; then
    while IFS=$'\034' read -r name target; do
      [[ -z "${name:-}" ]] && continue
      case "$target" in
        bin) bin_names+=("$name") ;;
        helm-plugin-dir) plugin_names+=("$name") ;;
      esac
    done < <(parse_manifest_targets "$MANIFEST_PATH")
  fi
  if [[ ${#bin_names[@]} -eq 0 && ${#plugin_names[@]} -eq 0 ]]; then
    echo "WARNING: no client tools read from ${MANIFEST_PATH}; using the built-in preflight tool list." >&2
    bin_names=(kubectl helm helmfile k9s)
    plugin_names=(helm-diff helm-secrets)
  fi
  for name in "${bin_names[@]}"; do
    printf '%s\n' "${BIN_DIR}/${name}"
  done
  if [[ -d "$PLUGIN_DIR" ]]; then
    local nullglob_was=0
    if shopt -q nullglob; then
      nullglob_was=1
    fi
    shopt -s nullglob
    for name in "${plugin_names[@]}"; do
      short="${name#helm-}"
      printf '%s\n' "${PLUGIN_DIR}/${name}"
      for yaml in "${PLUGIN_DIR}"/*/plugin.yaml; do
        pname="$(plugin_yaml_name "$yaml")"
        d="$(dirname "$yaml")"
        if [[ "$pname" == "$name" || "$pname" == "$short" || "helm-${pname}" == "$name" ]]; then
          printf '%s\n' "$d"
        fi
      done
    done
    if [[ "$nullglob_was" -eq 0 ]]; then
      shopt -u nullglob
    fi
  else
    for name in "${plugin_names[@]}"; do
      printf '%s\n' "${PLUGIN_DIR}/${name}"
    done
  fi
}

dedupe_paths() {
  local p seen=""
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    case $'\n'"${seen}"$'\n' in
      *$'\n'"${p}"$'\n'*) continue ;;
    esac
    seen="${seen}"$'\n'"${p}"
    printf '%s\n' "$p"
  done
}

confirm_or_abort() {
  local prompt="$1"
  echo
  if [[ "$YES" == "1" ]]; then
    return 0
  fi
  read -r -p "${prompt}" reply
  case "${reply}" in
    y|Y|yes|YES) ;;
    *)
      echo "Aborted."
      exit 0
      ;;
  esac
}

remove_path() {
  local path="$1"
  local label="${2:-}"
  if [[ -z "$path" ]]; then
    echo "ERROR: empty path" >&2
    return 1
  fi
  if ! safe_to_remove "$path"; then
    echo "ERROR: refusing to remove unsafe path: ${path}" >&2
    return 1
  fi
  if [[ -e "$path" || -L "$path" ]]; then
    if [[ -n "$label" ]]; then
      echo "Removing ${path} (${label})"
    else
      echo "Removing ${path}"
    fi
    rm -rf -- "$path"
  else
    echo "Already absent: ${path}"
  fi
}

run_receipt() {
  local -a rows=()
  local line name rest version path hash
  local -a removed=() failed=()
  if [[ ! -f "$RECEIPT" ]]; then
    echo "No receipt at ${RECEIPT}."
    echo "Removing the manifest client tools from ${BIN_DIR} and ${PLUGIN_DIR} for this user."
    echo "If preflight was run as another user, run this script as that user so HOME matches."
    run_reset
    return 0
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    rows+=("$line")
  done < "$RECEIPT"
  echo "=== preflight eraser ==="
  echo "Receipt: ${RECEIPT}"
  if [[ ${#rows[@]} -eq 0 ]]; then
    echo "Receipt at ${RECEIPT} has no tool rows."
    echo "Removing the manifest client tools from ${BIN_DIR} and ${PLUGIN_DIR} for this user."
    run_reset
    return 0
  fi
  echo "This will remove only these recorded paths:"
  for line in "${rows[@]}"; do
    printf '  %s\n' "$line"
  done
  echo
  echo "No sudo. Paths that are not in the receipt are left untouched."
  confirm_or_abort "Proceed with removal? [y/N] "
  for line in "${rows[@]}"; do
    name="${line%%$'\t'*}"
    rest="${line#*$'\t'}"
    version="${rest%%$'\t'*}"
    rest="${rest#*$'\t'}"
    path="${rest%%$'\t'*}"
    hash="${rest#*$'\t'}"
    if [[ -z "${path:-}" ]]; then
      echo "ERROR: receipt row missing path: ${line}" >&2
      failed+=("$line")
      continue
    fi
    if remove_path "$path" "${name} ${version}"; then
      removed+=("$path")
    else
      failed+=("$path")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: some removals failed: ${failed[*]}" >&2
    echo "Receipt left in place: ${RECEIPT}" >&2
    exit 1
  fi
  rm -f -- "$RECEIPT"
  echo
  echo "Removed ${#removed[@]} recorded path(s)."
  echo "Deleted receipt ${RECEIPT}."
  echo "Preflight eraser completed successfully."
}

run_reset() {
  local -a paths=() failed=() removed=()
  local path
  echo "=== preflight eraser (reset) ==="
  echo "Receipt ignored: ${RECEIPT}"
  echo "Manifest: ${MANIFEST_PATH}"
  echo "Binaries under: ${BIN_DIR}"
  echo "Helm plugins under: ${PLUGIN_DIR}"
  echo
  echo "This removes every manifest client tool from those directories and then deletes the receipt."
  echo "Other files in those directories stay. Base tools (curl, tar, gzip, checksums) stay. No sudo."
  while IFS= read -r path; do
    [[ -n "$path" ]] && paths+=("$path")
  done < <(collect_reset_paths | dedupe_paths)
  if [[ ${#paths[@]} -eq 0 ]]; then
    echo "No tool paths to remove."
  else
    echo "Paths:"
    for path in "${paths[@]}"; do
      printf '  %s\n' "$path"
    done
  fi
  confirm_or_abort "Reset the preflight install directories? [y/N] "
  for path in "${paths[@]:-}"; do
    [[ -n "$path" ]] || continue
    if remove_path "$path"; then
      removed+=("$path")
    else
      failed+=("$path")
    fi
  done
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "ERROR: some removals failed: ${failed[*]}" >&2
    echo "Receipt left in place: ${RECEIPT}" >&2
    exit 1
  fi
  if [[ -f "$RECEIPT" ]]; then
    rm -f -- "$RECEIPT"
    echo "Deleted receipt ${RECEIPT}."
  else
    echo "No receipt to delete at ${RECEIPT}."
  fi
  echo
  echo "Reset removed ${#removed[@]} path(s) from the preflight install directories."
  echo "Preflight eraser reset completed successfully."
}

if [[ "$RESET" == "1" ]]; then
  run_reset
else
  run_receipt
fi
