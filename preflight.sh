#!/usr/bin/env bash
# Preflight: ensure kubectl, helm (+plugins), helmfile, and k9s match pinned versions.
set -euo pipefail

# ---------------------------------------------------------------------------
# Required versions (built-in defaults; env fills in only when unset).
# usc-manifest.json next to this script replaces the matching tool pins.
# ---------------------------------------------------------------------------
REQUIRED_KUBECTL_CLIENT_VERSION="${REQUIRED_KUBECTL_CLIENT_VERSION:-v1.31.4}"
# Not enforced. Kustomize is embedded in the kubectl binary from the manifest.
REQUIRED_KUSTOMIZE_VERSION="${REQUIRED_KUSTOMIZE_VERSION:-v5.4.2}"
REQUIRED_KUBECTL_SERVER_VERSION="${REQUIRED_KUBECTL_SERVER_VERSION:-v1.30.14}"
REQUIRED_HELM_VERSION="${REQUIRED_HELM_VERSION:-v3.16.4}"
REQUIRED_HELM_VERSION_FULL="${REQUIRED_HELM_VERSION_FULL:-v3.16.4+g7877b45}"
REQUIRED_HELM_DIFF_VERSION="${REQUIRED_HELM_DIFF_VERSION:-3.9.13}"
REQUIRED_HELM_SECRETS_VERSION="${REQUIRED_HELM_SECRETS_VERSION:-4.6.2}"
REQUIRED_HELMFILE_VERSION="${REQUIRED_HELMFILE_VERSION:-0.169.1}"
REQUIRED_K9S_VERSION="${REQUIRED_K9S_VERSION:-0.51.0}"

# clientTools[].version -> the pins above. name and version are read from each
# tool object; key order and pretty-printing do not matter.
apply_usc_manifest_versions() {
  local manifest="$1"
  local pairs name version applied=0
  local helm_full_core=""

  [[ -f "$manifest" ]] || return 0

  if ! pairs="$(awk '
    function take_string(s) {
      if (after_key) {
        if (depth == 2 && key == "name") name = s
        if (depth == 2 && key == "version") ver = s
        if (name != "" && ver != "") {
          print name "\t" ver
          name = ""
          ver = ""
        }
        after_key = 0
      } else {
        key = s
      }
    }
    BEGIN {
      depth = 0; in_str = 0; esc = 0; token = ""
      after_key = 0; key = ""; name = ""; ver = ""
    }
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
        if (c == "{") { depth++; after_key = 0; continue }
        if (c == "}") {
          depth--
          after_key = 0
          if (depth < 2) { name = ""; ver = "" }
          continue
        }
        if (c == ":") { after_key = 1; continue }
        if (c == "," || c == "[") { after_key = 0; continue }
      }
    }
  ' "$manifest")"; then
    echo "ERROR: failed to read ${manifest}" >&2
    exit 1
  fi

  if [[ -z "$pairs" ]]; then
    echo "ERROR: ${manifest} contains no clientTools name/version pairs" >&2
    exit 1
  fi

  while IFS=$'\t' read -r name version; do
    [[ -z "$name" ]] && continue
    if [[ ! "$version" =~ ^[A-Za-z0-9._+-]+$ ]]; then
      echo "ERROR: refusing version '${version}' for '${name}' from ${manifest}" >&2
      exit 1
    fi
    case "$name" in
      kubectl)
        REQUIRED_KUBECTL_CLIENT_VERSION="v${version#v}"
        echo "usc-manifest.json: REQUIRED_KUBECTL_CLIENT_VERSION=${REQUIRED_KUBECTL_CLIENT_VERSION}"
        ;;
      helm)
        REQUIRED_HELM_VERSION="v${version#v}"
        helm_full_core="${REQUIRED_HELM_VERSION_FULL#v}"
        helm_full_core="${helm_full_core%%+*}"
        if [[ "${REQUIRED_HELM_VERSION#v}" != "$helm_full_core" ]]; then
          REQUIRED_HELM_VERSION_FULL="$REQUIRED_HELM_VERSION"
        fi
        echo "usc-manifest.json: REQUIRED_HELM_VERSION=${REQUIRED_HELM_VERSION}"
        ;;
      helm-diff)
        REQUIRED_HELM_DIFF_VERSION="${version#v}"
        echo "usc-manifest.json: REQUIRED_HELM_DIFF_VERSION=${REQUIRED_HELM_DIFF_VERSION}"
        ;;
      helm-secrets)
        REQUIRED_HELM_SECRETS_VERSION="${version#v}"
        echo "usc-manifest.json: REQUIRED_HELM_SECRETS_VERSION=${REQUIRED_HELM_SECRETS_VERSION}"
        ;;
      helmfile)
        REQUIRED_HELMFILE_VERSION="${version#v}"
        echo "usc-manifest.json: REQUIRED_HELMFILE_VERSION=${REQUIRED_HELMFILE_VERSION}"
        ;;
      k9s)
        REQUIRED_K9S_VERSION="${version#v}"
        echo "usc-manifest.json: REQUIRED_K9S_VERSION=${REQUIRED_K9S_VERSION}"
        ;;
      *)
        continue
        ;;
    esac
    applied=1
  done <<< "$pairs"

  if [[ "$applied" -eq 0 ]]; then
    echo "usc-manifest.json: no pinned tool versions matched; keeping built-in defaults."
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
apply_usc_manifest_versions "${SCRIPT_DIR}/usc-manifest.json"

# Install tags (leading "v" where upstream release tags use it)
KUBECTL_INSTALL_VERSION="${REQUIRED_KUBECTL_CLIENT_VERSION}"
HELM_INSTALL_VERSION="${REQUIRED_HELM_VERSION}"
HELM_DIFF_INSTALL_VERSION="v${REQUIRED_HELM_DIFF_VERSION#v}"
HELM_SECRETS_INSTALL_VERSION="v${REQUIRED_HELM_SECRETS_VERSION#v}"
HELMFILE_INSTALL_VERSION="${REQUIRED_HELMFILE_VERSION#v}"
K9S_INSTALL_VERSION="${REQUIRED_K9S_VERSION#v}"

# User-writable install locations. No sudo, no package manager.
BIN_DIR="${PREFLIGHT_BIN_DIR:-${HOME}/.local/bin}"
PLUGIN_DIR="${PREFLIGHT_HELM_PLUGINS:-${HELM_PLUGINS:-${HOME}/.local/share/helm/plugins}}"
RECEIPT="${PREFLIGHT_RECEIPT:-${HOME}/.local/share/preflight/install-receipt.tsv}"
MANIFEST_PATH="${PREFLIGHT_MANIFEST:-${SCRIPT_DIR}/usc-manifest.json}"
MANIFEST_HASH=""
WORK_DIR=""
PATH_HAD_BIN_DIR=0
PATH_BIN_FIRST=0
ORIGINAL_PATH="${PATH}"
HELM_PLUGINS_PRESET=0
if [[ -n "${HELM_PLUGINS:-}" ]]; then
  HELM_PLUGINS_PRESET=1
fi
declare -A TOOL_URL=()
declare -A TOOL_SHA256=()
declare -A TOOL_SHA512=()
declare -A TOOL_ARCHIVE=()
declare -A TOOL_MEMBER=()
declare -A TOOL_KIND=()
declare -A TOOL_TARGET=()
declare -A TOOL_MANIFEST_VERSION=()
TOOL_ORDER=()
SUPPORTED_SCHEMA_VERSION="1.0"
SCHEMA_VERSION=""
DRY_RUN=0
BUNDLE_DIR=""

# ---------------------------------------------------------------------------
# Architecture (downloads follow the manifest platform key)
# ---------------------------------------------------------------------------
ARCH=""
GOARCH=""
PLATFORM_KEY=""

need_cmd() { command -v "$1" >/dev/null 2>&1; }

# Prefer the copy this script installed. Fall back to whatever else is on PATH.
tool_bin() {
  local name="$1"
  if [[ -n "${BIN_DIR}" && -x "${BIN_DIR}/${name}" ]]; then
    printf '%s\n' "${BIN_DIR}/${name}"
  elif command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
  fi
}

require_linux() {
  local os
  os="$(uname -s)"
  if [[ "${os,,}" != "linux" ]]; then
    echo "ERROR: preflight.sh supports Linux only (uname -s reported ${os})." >&2
    exit 1
  fi
}

detect_arch() {
  local machine os
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  machine="$(uname -m)"
  case "$machine" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) ARCH="$(printf '%s' "$machine" | tr '[:upper:]' '[:lower:]')" ;;
  esac
  GOARCH="$ARCH"
  PLATFORM_KEY="${os}-${ARCH}"
}

# Presence only. This script never installs OS packages and never calls sudo.
require_base_tools() {
  local -a missing=()
  if ! need_cmd curl && ! need_cmd wget; then
    missing+=(curl-or-wget)
  fi
  need_cmd tar || missing+=(tar)
  need_cmd gzip || missing+=(gzip)
  if ! need_cmd sha256sum && ! need_cmd sha512sum; then
    missing+=(sha256sum-or-sha512sum)
  fi
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "ERROR: missing base tool(s): ${missing[*]}" >&2
    echo "Install them manually and re-run. preflight.sh does not use sudo or a package manager." >&2
    exit 1
  fi
}

manifest_file_hash() {
  local file="$1"
  if need_cmd sha256sum; then
    echo "sha256:$(sha256sum "$file" | awk '{print $1}')"
  else
    echo "sha512:$(sha512sum "$file" | awk '{print $1}')"
  fi
}

# name, kind, version, installTarget, archiveType, memberPath, url, sha256, sha512
# for PLATFORM_KEY. memberPath is empty when the manifest stores null.
parse_manifest_tools() {
  local manifest="$1"
  awk -v platform="$PLATFORM_KEY" '
    function take_string(s) {
      if (after_key) {
        if (depth == 1 && key == "schemaVersion") schemaver = s
        if (depth == 2 && !in_platform) {
          if (key == "name") name = s
          else if (key == "kind") kind = s
          else if (key == "version") ver = s
          else if (key == "installTarget") target = s
        }
        if (in_platform && objkey[depth] == "checksums") {
          if (key == "sha256") sha256 = s
          else if (key == "sha512") sha512 = s
        }
        if (in_platform && objkey[depth] == "download") {
          if (key == "url") url = s
          else if (key == "archiveType") archive = s
          else if (key == "memberPath") member = s
        }
        after_key = 0
        key = ""
      } else {
        key = s
      }
    }
    function take_literal(lit) {
      if (!after_key) return
      if (in_platform && objkey[depth] == "download" && key == "memberPath" && lit == "null") member = ""
      after_key = 0
      key = ""
    }
    function emit() {
      if (name == "") return
      printf "%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\034%s\n", name, kind, ver, target, archive, member, url, sha256, sha512
      name = kind = ver = target = archive = member = url = sha256 = sha512 = ""
    }
    BEGIN { depth = 0; in_str = 0; esc = 0; token = ""; after_key = 0; key = ""; in_platform = 0; platform_depth = 0; schemaver = "" }
    END { printf "SCHEMA\034%s\n", schemaver }
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
        if (c ~ /[A-Za-z]/) {
          lit = c
          while (i < n) {
            c2 = substr($0, i + 1, 1)
            if (c2 !~ /[A-Za-z]/) break
            lit = lit c2
            i++
          }
          take_literal(lit)
          continue
        }
        if (c == "{") {
          depth++
          objkey[depth] = key
          if (key == platform) { in_platform = 1; platform_depth = depth }
          after_key = 0
          key = ""
          continue
        }
        if (c == "}") {
          if (in_platform && depth == platform_depth) in_platform = 0
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

load_manifest_downloads() {
  local manifest="$MANIFEST_PATH"
  local name kind ver target archive member url sha256 sha512
  TOOL_ORDER=()
  SCHEMA_VERSION=""
  [[ -f "$manifest" ]] || return 0
  MANIFEST_HASH="$(manifest_file_hash "$manifest")"
  while IFS=$'\034' read -r name kind ver target archive member url sha256 sha512; do
    [[ -z "${name:-}" ]] && continue
    if [[ "$name" == "SCHEMA" ]]; then
      SCHEMA_VERSION="${kind:-}"
      continue
    fi
    if [[ -z "${TOOL_KIND[$name]+x}" ]]; then
      TOOL_ORDER+=("$name")
    fi
    TOOL_KIND["$name"]="$kind"
    TOOL_MANIFEST_VERSION["$name"]="$ver"
    TOOL_TARGET["$name"]="$target"
    TOOL_ARCHIVE["$name"]="$archive"
    TOOL_MEMBER["$name"]="$member"
    TOOL_URL["$name"]="$url"
    TOOL_SHA256["$name"]="$sha256"
    TOOL_SHA512["$name"]="$sha512"
  done < <(parse_manifest_tools "$manifest")
  if [[ -z "$SCHEMA_VERSION" ]]; then
    echo "ERROR: ${manifest} has no schemaVersion" >&2
    exit 1
  fi
  if [[ "$SCHEMA_VERSION" != "$SUPPORTED_SCHEMA_VERSION" ]]; then
    echo "ERROR: unsupported manifest schemaVersion '${SCHEMA_VERSION}' (this preflight supports ${SUPPORTED_SCHEMA_VERSION} only)." >&2
    exit 1
  fi
}

fetch_url() {
  local url="$1"
  local dest="$2"
  if need_cmd curl; then
    curl -fsSL -o "$dest" "$url"
  else
    wget -O "$dest" "$url"
  fi
}

url_basename() {
  local url="$1" base
  base="${url%%\?*}"
  base="${base##*/}"
  printf '%s\n' "$base"
}

url_host() {
  local url="$1" host
  host="$(printf '%s' "$url" | awk -F/ '{print $3}')"
  host="${host%%:*}"
  printf '%s\n' "$host"
}

probe_effective_url() {
  local url="$1" result code eff
  result="$(curl -sSIL --max-time 20 --max-redirs 10 -o /dev/null -w '%{http_code} %{url_effective}' "$url" 2>/dev/null || true)"
  code="${result%% *}"
  eff="${result#* }"
  if [[ -z "$code" || "$code" == "000" || -z "$eff" ]]; then
    result="$(curl -sSL --max-time 25 --max-redirs 10 --range 0-0 -o /dev/null -w '%{http_code} %{url_effective}' "$url" 2>/dev/null || true)"
    code="${result%% *}"
    eff="${result#* }"
  fi
  if [[ -z "$code" || "$code" == "000" || -z "$eff" ]]; then
    return 1
  fi
  printf '%s\n' "$eff"
}

print_required_hosts() {
  local name url host eff seen_manifest="" seen_effective=""
  echo "Hosts named in manifest download URLs:"
  for name in "${TOOL_ORDER[@]}"; do
    url="${TOOL_URL[$name]:-}"
    [[ -n "$url" ]] || continue
    host="$(url_host "$url")"
    [[ -n "$host" ]] || continue
    case $'\n'"${seen_manifest}"$'\n' in
      *$'\n'"${host}"$'\n'*) continue ;;
    esac
    seen_manifest="${seen_manifest}"$'\n'"${host}"
    echo "  ${host}"
  done
  if [[ "${PREFLIGHT_OFFLINE:-0}" == "1" ]]; then
    echo "Offline mode: redirect targets were not resolved."
    return 0
  fi
  if ! need_cmd curl; then
    echo "curl is not available, so redirect targets were not resolved."
    return 0
  fi
  echo "Effective hosts after redirects (from curl -L, not a hardcoded list):"
  for name in "${TOOL_ORDER[@]}"; do
    url="${TOOL_URL[$name]:-}"
    [[ -n "$url" ]] || continue
    if ! eff="$(probe_effective_url "$url")"; then
      echo "  (probe failed for $(url_host "$url"))"
      continue
    fi
    host="$(url_host "$eff")"
    [[ -n "$host" ]] || continue
    case $'\n'"${seen_effective}"$'\n' in
      *$'\n'"${host}"$'\n'*) continue ;;
    esac
    seen_effective="${seen_effective}"$'\n'"${host}"
    echo "  ${host}"
  done
}

print_network_hint() {
  if [[ "${PREFLIGHT_OFFLINE:-0}" == "1" ]]; then
    return 0
  fi
  echo "If this host needs a proxy, set HTTPS_PROXY, HTTP_PROXY, and NO_PROXY." >&2
  echo "If this host has no internet access at all, on a connected machine run:" >&2
  echo "  ./preflight.sh --bundle <dir> --manifest ${MANIFEST_PATH}" >&2
  echo "Copy <dir> to this host, then run:" >&2
  echo "  PREFLIGHT_ARTIFACT_DIR=<dir> PREFLIGHT_OFFLINE=1 ./preflight.sh --manifest <dir>/$(basename "$MANIFEST_PATH")" >&2
  print_required_hosts >&2 || true
}

require_disk_space() {
  local dir="$1"
  local need="${PREFLIGHT_MIN_TMP_MB:-64}"
  local probe="$dir" avail
  if [[ ! -d "$probe" ]]; then
    probe="$(dirname "$probe")"
  fi
  [[ -d "$probe" ]] || probe="${TMPDIR:-/tmp}"
  avail="$(df -Pk "$probe" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024}')"
  if [[ -z "$avail" ]]; then
    echo "WARNING: could not measure free space on ${probe}" >&2
    return 0
  fi
  if (( avail < need )); then
    echo "ERROR: ${probe} has ${avail} MiB free; need at least ${need} MiB (PREFLIGHT_MIN_TMP_MB)." >&2
    exit 1
  fi
}

acquire_url() {
  local url="$1" dest="$2" name="$3"
  local base dir
  base="$(url_basename "$url")"
  dir="${PREFLIGHT_ARTIFACT_DIR:-}"
  if [[ -n "$dir" && -f "${dir}/${base}" ]]; then
    echo "Using local artifact ${dir}/${base} for ${name}"
    cp -f "${dir}/${base}" "$dest"
    return 0
  fi
  if [[ "${PREFLIGHT_OFFLINE:-0}" == "1" ]]; then
    echo "ERROR: PREFLIGHT_OFFLINE=1 and ${dir:-PREFLIGHT_ARTIFACT_DIR}/${base} is missing for ${name}" >&2
    exit 1
  fi
  if ! fetch_url "$url" "$dest"; then
    echo "ERROR: failed to download ${name} from ${url}" >&2
    print_network_hint
    return 1
  fi
}

verify_download() {
  local name="$1"
  local file="$2"
  local sha256="${TOOL_SHA256[$name]:-}"
  local sha512="${TOOL_SHA512[$name]:-}"
  if [[ -n "$sha512" ]] && need_cmd sha512sum; then
    if ! printf '%s  %s\n' "$sha512" "$file" | sha512sum --check --status; then
      echo "ERROR: sha512 mismatch for ${name} (manifest ${MANIFEST_PATH})" >&2
      exit 1
    fi
    echo "sha512 OK: ${name}"
    return 0
  fi
  if [[ -n "$sha256" ]] && need_cmd sha256sum; then
    if ! printf '%s  %s\n' "$sha256" "$file" | sha256sum --check --status; then
      echo "ERROR: sha256 mismatch for ${name} (manifest ${MANIFEST_PATH})" >&2
      exit 1
    fi
    echo "sha256 OK: ${name}"
    return 0
  fi
  echo "ERROR: no usable manifest checksum for ${name}. Need sha512sum for checksums.sha512 or sha256sum for checksums.sha256." >&2
  exit 1
}

install_user_file() {
  local src="$1"
  local dest="$2"
  mkdir -p "$(dirname "$dest")"
  cp -f "$src" "$dest"
  chmod 0755 "$dest"
}

# Upsert one tool this run actually installed. Other receipt rows stay.
# Path of a tool that already lives in the preflight install directories.
# A match elsewhere on PATH is not returned, so the receipt does not claim it.
managed_install_path() {
  local name="$1"
  local kind="${TOOL_KIND[$name]:-}"
  local target="${TOOL_TARGET[$name]:-}"
  local yaml pname
  if [[ "$kind" == "helm-plugin" || "$target" == "helm-plugin-dir" ]]; then
    [[ -d "$PLUGIN_DIR" ]] || return 1
    if [[ -f "${PLUGIN_DIR}/${name}/plugin.yaml" ]]; then
      printf '%s\n' "${PLUGIN_DIR}/${name}"
      return 0
    fi
    local nullglob_was=0
    if shopt -q nullglob; then
      nullglob_was=1
    fi
    shopt -s nullglob
    for yaml in "${PLUGIN_DIR}"/*/plugin.yaml; do
      pname="$(awk -F: '/^[[:space:]]*name:/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$yaml")"
      if [[ "$pname" == "$name" || "$pname" == "${name#helm-}" || "helm-${pname}" == "$name" ]]; then
        printf '%s\n' "$(dirname "$yaml")"
        if [[ "$nullglob_was" -eq 0 ]]; then
          shopt -u nullglob
        fi
        return 0
      fi
    done
    if [[ "$nullglob_was" -eq 0 ]]; then
      shopt -u nullglob
    fi
    return 1
  fi
  if [[ -x "${BIN_DIR}/${name}" ]]; then
    printf '%s\n' "${BIN_DIR}/${name}"
    return 0
  fi
  return 1
}

record_installed() {
  local name="$1"
  local version="$2"
  local path="$3"
  local tmp line first
  if [[ -z "${MANIFEST_HASH}" ]]; then
    echo "ERROR: refusing to record ${name} without a manifest hash" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$RECEIPT")"
  tmp="$(mktemp "${TMPDIR:-/tmp}/preflight-receipt.XXXXXX")"
  {
    echo "# preflight-receipt 1"
    echo "# manifest ${MANIFEST_PATH}"
    if [[ -f "$RECEIPT" ]]; then
      while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        first="${line%%$'\t'*}"
        [[ "$first" == "$name" ]] && continue
        printf '%s\n' "$line"
      done < "$RECEIPT"
    fi
    printf '%s\t%s\t%s\t%s\n' "$name" "$version" "$path" "$MANIFEST_HASH"
  } > "$tmp"
  mv -f "$tmp" "$RECEIPT"
}

install_plugin_tree() {
  local name="$1"
  local archive="$2"
  local stage dest top count
  stage="${WORK_DIR}/plugin-${name}"
  rm -rf "$stage"
  mkdir -p "$stage"
  tar -xzf "$archive" -C "$stage"
  if [[ -f "${stage}/plugin.yaml" ]]; then
    dest="${PLUGIN_DIR}/${name}"
  else
    count="$(find "$stage" -mindepth 1 -maxdepth 1 -type d | wc -l)"
    top="$(find "$stage" -mindepth 1 -maxdepth 1 -type d -print -quit)"
    if [[ "$count" -eq 1 && -n "$top" && -f "${top}/plugin.yaml" ]]; then
      dest="${PLUGIN_DIR}/$(basename "$top")"
    else
      echo "ERROR: ${name} archive has no single plugin directory with plugin.yaml" >&2
      exit 1
    fi
  fi
  case "$dest" in
    "${PLUGIN_DIR}"/*) ;;
    *)
      echo "ERROR: refusing plugin destination ${dest}" >&2
      exit 1
      ;;
  esac
  if [[ "$(dirname "$dest")" != "$PLUGIN_DIR" ]]; then
    echo "ERROR: refusing plugin destination ${dest}" >&2
    exit 1
  fi
  mkdir -p "$PLUGIN_DIR"
  rm -rf "$dest"
  mkdir -p "$dest"
  if [[ -f "${stage}/plugin.yaml" ]]; then
    cp -a "${stage}/." "$dest/"
  else
    cp -a "${top}/." "$dest/"
  fi
  record_installed "$name" "${TOOL_MANIFEST_VERSION[$name]}" "$dest"
  echo "Installed ${name} plugin at ${dest}"
}

# Place one downloaded artifact. Layout comes from the manifest fields
# kind, download.archiveType, download.memberPath, and installTarget.
# kind helm-plugin always has memberPath null: the whole archive is the plugin.
install_from_manifest() {
  local name="$1"
  local url="${TOOL_URL[$name]:-}"
  local kind="${TOOL_KIND[$name]:-}"
  local archive_type="${TOOL_ARCHIVE[$name]:-}"
  local member="${TOOL_MEMBER[$name]:-}"
  local target="${TOOL_TARGET[$name]:-}"
  local archive extracted
  if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "ERROR: ${MANIFEST_PATH} not found; refusing to download ${name} without the manifest" >&2
    exit 1
  fi
  if [[ -z "$url" ]]; then
    echo "ERROR: ${MANIFEST_PATH} has no ${PLATFORM_KEY} download for ${name}" >&2
    exit 1
  fi
  mkdir -p "$WORK_DIR"
  archive="${WORK_DIR}/${name}.download"
  echo "Downloading ${name} from ${url}"
  require_disk_space "$WORK_DIR"
  if ! acquire_url "$url" "$archive" "$name"; then
    exit 1
  fi
  if [[ ! -s "$archive" ]]; then
    echo "ERROR: empty download for ${name}: ${url}" >&2
    print_network_hint
    exit 1
  fi
  verify_download "$name" "$archive"
  if [[ "$kind" == "helm-plugin" || "$target" == "helm-plugin-dir" ]]; then
    if [[ "$archive_type" != "tar.gz" ]]; then
      echo "ERROR: helm plugin ${name} archiveType is '${archive_type}', expected tar.gz" >&2
      exit 1
    fi
    install_plugin_tree "$name" "$archive"
  elif [[ "$target" == "bin" ]]; then
    case "$archive_type" in
      raw-binary)
        install_user_file "$archive" "${BIN_DIR}/${name}"
        record_installed "$name" "${TOOL_MANIFEST_VERSION[$name]}" "${BIN_DIR}/${name}"
        echo "Installed ${name} at ${BIN_DIR}/${name}"
        ;;
      tar.gz)
        if [[ -z "$member" ]]; then
          echo "ERROR: ${name} tar.gz has no download.memberPath" >&2
          exit 1
        fi
        if ! tar -xzf "$archive" -C "$WORK_DIR" "$member"; then
          echo "ERROR: failed to extract ${member} from ${name}" >&2
          exit 1
        fi
        extracted="${WORK_DIR}/${member}"
        if [[ ! -f "$extracted" ]]; then
          echo "ERROR: ${extracted} missing after extract" >&2
          exit 1
        fi
        install_user_file "$extracted" "${BIN_DIR}/${name}"
        record_installed "$name" "${TOOL_MANIFEST_VERSION[$name]}" "${BIN_DIR}/${name}"
        echo "Installed ${name} at ${BIN_DIR}/${name}"
        ;;
      *)
        echo "ERROR: unsupported archiveType '${archive_type}' for ${name}" >&2
        exit 1
        ;;
    esac
  else
    echo "ERROR: unsupported installTarget '${target}' for ${name} (kind ${kind})" >&2
    exit 1
  fi
  hash -r || true
}

# First executable named $1 on the PATH from before this script prepended BIN_DIR.
# $2, when set, skips a path that is the same file (the local install).
# Walk the path directly. `command -v` returns bash's remembered command and hides
# the preinstalled binary once this script has run the local one.
first_on_original_path() {
  local name="$1" exclude="${2:-}" rest dir cand
  rest="${ORIGINAL_PATH}"
  while [[ -n "$rest" ]]; do
    dir="${rest%%:*}"
    if [[ "$rest" == *:* ]]; then
      rest="${rest#*:}"
    else
      rest=""
    fi
    [[ -n "$dir" ]] || continue
    cand="${dir}/${name}"
    [[ -x "$cand" && ! -d "$cand" ]] || continue
    if [[ -n "$exclude" ]] && same_path "$cand" "$exclude"; then
      continue
    fi
    printf '%s\n' "$cand"
    return 0
  done
}

same_path() {
  local a="$1" b="$2" ra rb
  [[ -n "$a" && -n "$b" ]] || return 1
  if [[ "$a" == "$b" ]]; then
    return 0
  fi
  if need_cmd readlink; then
    ra="$(readlink -f "$a" 2>/dev/null || printf '%s' "$a")"
    rb="$(readlink -f "$b" 2>/dev/null || printf '%s' "$b")"
    [[ "$ra" == "$rb" ]]
    return
  fi
  return 1
}

print_path_hint() {
  local name kind target local_bin shell_bin other_bin plugin_path
  local -a need_path=() still_global=() local_ok=() plugin_lines=()
  echo
  echo "WARNING: your current shell does not keep the PATH change from this script."
  echo "Tools:"
  for name in "${TOOL_ORDER[@]}"; do
    kind="${TOOL_KIND[$name]:-}"
    target="${TOOL_TARGET[$name]:-}"
    if [[ "$kind" == "helm-plugin" || "$target" == "helm-plugin-dir" ]]; then
      plugin_path="$(managed_install_path "$name" || true)"
      if [[ -n "$plugin_path" ]]; then
        plugin_lines+=("${name} is installed locally at ${plugin_path}")
      else
        plugin_lines+=("${name} is not in ${PLUGIN_DIR}")
      fi
      continue
    fi
    local_bin="${BIN_DIR}/${name}"
    shell_bin="$(first_on_original_path "$name")"
    other_bin=""
    if [[ -x "$local_bin" ]]; then
      other_bin="$(first_on_original_path "$name" "$local_bin")"
    fi
    if [[ -x "$local_bin" && -n "$other_bin" ]]; then
      # A preinstalled binary remains on PATH. Amazon Linux already puts
      # ~/.local/bin first, so a fresh lookup sees the local file, while the
      # shell that started this script still runs the binary it remembered.
      need_path+=("${name}  local: ${local_bin}")
      if [[ -n "$shell_bin" ]] && ! same_path "$shell_bin" "$local_bin"; then
        need_path+=("$(printf '    shell still runs the global binary: %s' "$shell_bin")")
      else
        need_path+=("$(printf '    shell still runs the preinstalled binary: %s' "$other_bin")")
        need_path+=("    ${BIN_DIR} is already on PATH; run hash -r so this shell drops the remembered command")
      fi
    elif [[ -x "$local_bin" ]] && same_path "$shell_bin" "$local_bin"; then
      local_ok+=("${name}  shell already runs ${shell_bin}")
    elif [[ -x "$local_bin" ]]; then
      need_path+=("${name}  local: ${local_bin}")
      need_path+=("    shell has no ${name} command until PATH is updated")
    elif [[ -n "$shell_bin" ]]; then
      still_global+=("${name}  ${shell_bin}")
    else
      still_global+=("${name}  not installed locally and not on PATH")
    fi
  done
  if [[ ${#need_path[@]} -gt 0 ]]; then
    echo
    echo "Installed locally, but this shell does not run them yet:"
    local line
    for line in "${need_path[@]}"; do
      echo "  ${line}"
    done
  fi
  if [[ ${#still_global[@]} -gt 0 ]]; then
    echo
    echo "Still taken from the global installation (no copy in ${BIN_DIR}):"
    local line
    for line in "${still_global[@]}"; do
      echo "  ${line}"
    done
  fi
  if [[ ${#local_ok[@]} -gt 0 ]]; then
    echo
    echo "Already used from the local install:"
    local line
    for line in "${local_ok[@]}"; do
      echo "  ${line}"
    done
  fi
  if [[ ${#plugin_lines[@]} -gt 0 ]]; then
    echo
    echo "Helm plugins:"
    local line
    for line in "${plugin_lines[@]}"; do
      echo "  ${line}"
    done
  fi
  if [[ ${#need_path[@]} -eq 0 && "$HELM_PLUGINS_PRESET" -eq 1 ]]; then
    return 0
  fi
  echo
  echo "Run these commands in the current shell:"
  echo
  if [[ ${#need_path[@]} -gt 0 ]]; then
    echo "  export PATH=\"${BIN_DIR}:\$PATH\""
    echo "  hash -r"
  fi
  if [[ "$HELM_PLUGINS_PRESET" -eq 0 ]]; then
    echo "  export HELM_PLUGINS=\"${PLUGIN_DIR}\""
  fi
  echo
  echo "Add the export lines to ~/.bashrc so new login shells keep them:"
  if [[ ${#need_path[@]} -gt 0 ]]; then
    echo "  printf '%s\\n' 'export PATH=\"${BIN_DIR}:\$PATH\"' >> ~/.bashrc"
  fi
  if [[ "$HELM_PLUGINS_PRESET" -eq 0 ]]; then
    echo "  printf '%s\\n' 'export HELM_PLUGINS=\"${PLUGIN_DIR}\"' >> ~/.bashrc"
  fi
}

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------
normalize_v() {
  local v="${1:-}"
  v="${v#v}"
  echo "$v"
}

versions_equal() {
  local a b
  a="$(normalize_v "$1")"
  b="$(normalize_v "$2")"
  [[ "$a" == "$b" ]]
}

# Strip build metadata (+g....) for loose compare when needed
version_core() {
  local v
  v="$(normalize_v "$1")"
  echo "${v%%+*}"
}

get_kubectl_client_version() {
  local bin
  bin="$(tool_bin kubectl)"
  [[ -n "$bin" ]] || return 1
  "$bin" version --client=true -o yaml 2>/dev/null \
    | awk '/^[[:space:]]*gitVersion:/ {print $2; exit}' \
    || "$bin" version --client 2>/dev/null \
    | awk -F': ' '/Client Version/ {print $2; exit}'
}

get_kustomize_version() {
  # kubectl embeds kustomize; reported by `kubectl version --client`
  local bin
  bin="$(tool_bin kubectl)"
  [[ -n "$bin" ]] || return 1
  "$bin" version --client=true -o yaml 2>/dev/null \
    | awk '/kustomizeVersion:/ {print $2; exit}' \
    || "$bin" version --client 2>/dev/null \
    | awk -F': ' '/Kustomize Version/ {print $2; exit}'
}

get_kubectl_server_version() {
  kubectl version -o yaml 2>/dev/null \
    | awk '/serverVersion:/{f=1; next} f && /gitVersion:/{print $2; exit}' \
    || kubectl version 2>/dev/null \
    | awk -F': ' '/Server Version/ {print $2; exit}'
}

get_helm_version() {
  # e.g. version.BuildInfo{Version:"v3.16.4", GitCommit:"7877b45", ...}
  local bin
  bin="$(tool_bin helm)"
  [[ -n "$bin" ]] || return 1
  "$bin" version --short 2>/dev/null | awk '{print $1}' | sed 's/,*$//'
}

get_helm_version_full() {
  local ver commit bin
  bin="$(tool_bin helm)"
  [[ -n "$bin" ]] || return 1
  ver="$("$bin" version --template='{{.Version}}' 2>/dev/null || true)"
  commit="$("$bin" version --template='{{.GitCommit}}' 2>/dev/null || true)"
  if [[ -n "$ver" && -n "$commit" ]]; then
    # short commit like upstream display (+g7877b45)
    local short="${commit:0:7}"
    echo "${ver}+g${short}"
  else
    get_helm_version
  fi
}

get_helm_plugin_version() {
  local name="$1"
  local bin yaml pname pver
  bin="$(tool_bin helm || true)"
  if [[ -n "$bin" ]]; then
    pver="$("$bin" plugin list 2>/dev/null | awk -v n="$name" 'NR>1 && $1==n {print $2; exit}' || true)"
    if [[ -n "$pver" ]]; then
      printf '%s\n' "$pver"
      return 0
    fi
  fi
  [[ -d "${PLUGIN_DIR}" ]] || return 1
  local nullglob_was=0
  if shopt -q nullglob; then
    nullglob_was=1
  fi
  shopt -s nullglob
  for yaml in "${PLUGIN_DIR}"/*/plugin.yaml; do
    pname="$(awk -F: '/^[[:space:]]*name:/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$yaml")"
    if [[ "$pname" == "$name" || "$pname" == "${name#helm-}" || "helm-${pname}" == "$name" ]]; then
      awk -F: '/^[[:space:]]*version:/ {gsub(/["'\''[:space:]]/, "", $2); print $2; exit}' "$yaml"
      if [[ "$nullglob_was" -eq 0 ]]; then
        shopt -u nullglob
      fi
      return 0
    fi
  done
  if [[ "$nullglob_was" -eq 0 ]]; then
    shopt -u nullglob
  fi
  return 1
}

get_helmfile_version() {
  # Default output is multi-line "pretty" box art (Version on a later line).
  # -o short prints "0.169.1" first; an upgrade notice may follow — take line 1 only.
  local bin
  bin="$(tool_bin helmfile)"
  [[ -n "$bin" ]] || return 1
  "$bin" version -o short 2>/dev/null \
    | awk 'NR==1 { gsub(/\r/,""); print $1; exit }'
}

# Strip ANSI CSI / color sequences from CLI output (k9s colors "Version:" etc.).
strip_ansi() {
  # shellcheck disable=SC2001
  sed $'s/\x1B\\[[0-9;]*[a-zA-Z]//g'
}

get_k9s_version() {
  # k9s prints ASCII art then a colored line like:
  #   ESC[36mVersion:ESC[0m    v0.51.0
  # Color codes sit BETWEEN "Version:" and the number, so parsers that require
  # "Version:" immediately followed by whitespace+version fail unless ANSI is
  # stripped first. --short is uncolored but uses "Version" without a colon.
  local raw ver bin
  bin="$(tool_bin k9s || true)"
  [[ -n "$bin" ]] || return 1
  raw="$("$bin" version 2>&1 || true)"
  raw="$(printf '%s' "$raw" | strip_ansi | tr -d '\r')"

  ver="$(printf '%s\n' "$raw" \
    | grep -iE 'Version[[:space:]]*:?' \
    | head -n1 \
    | grep -oE 'v?[0-9]+(\.[0-9]+)+' \
    | head -n1 || true)"
  ver="${ver#v}"

  if [[ -z "$ver" ]]; then
    # Last resort: first semver-like token in the whole blob
    ver="$(printf '%s\n' "$raw" | grep -oE 'v?[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
    ver="${ver#v}"
  fi

  [[ -n "$ver" ]] && echo "$ver"
}

check_kustomize_via_kubectl() {
  local kustomize
  if ! tool_bin kubectl >/dev/null; then
    return 0
  fi
  kustomize="$(get_kustomize_version || true)"
  if [[ -z "${kustomize:-}" ]]; then
    echo "kustomize (via kubectl): not reported"
    return 0
  fi
  echo "kustomize (via kubectl): ${kustomize} (embedded in this kubectl; not a separate pin)"
}

check_kubectl_server() {
  local server
  if ! need_cmd kubectl; then
    return 0
  fi
  if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "kubectl server: cluster not reachable — skip server version check (expected ${REQUIRED_KUBECTL_SERVER_VERSION})"
    return 0
  fi
  server="$(get_kubectl_server_version || true)"
  if versions_equal "${server:-}" "$REQUIRED_KUBECTL_SERVER_VERSION"; then
    echo "kubectl server OK: ${server}"
  else
    echo "ERROR: kubectl server version mismatch (have: ${server:-none}, need: ${REQUIRED_KUBECTL_SERVER_VERSION})"
    exit 1
  fi
}

# One ensure step for every clientTools entry. A new tool is a manifest edit.
k9s_raw_mentions_required() {
  local need raw bin
  need="$(normalize_v "${1:-}")"
  [[ -n "$need" ]] || return 1
  bin="$(tool_bin k9s || true)"
  [[ -n "$bin" ]] || return 1
  raw="$("$bin" version 2>&1 || true)"
  raw="$(printf '%s' "$raw" | strip_ansi)"
  printf '%s' "$raw" | grep -qE "v?${need}([^0-9]|$)"
}

generic_semver() {
  local bin="$1" out ver args
  [[ -n "$bin" && -x "$bin" ]] || return 1
  for args in "version --client" "version -o short" "version --short" "--version" "version"; do
    if need_cmd timeout; then
      # shellcheck disable=SC2086
      out="$(timeout 8 "$bin" $args 2>/dev/null || true)"
    else
      # shellcheck disable=SC2086
      out="$("$bin" $args 2>/dev/null || true)"
    fi
    ver="$(printf '%s\n' "$out" | grep -oE 'v?[0-9]+(\.[0-9]+){1,3}' | head -n1 || true)"
    if [[ -n "$ver" ]]; then
      printf '%s\n' "$ver"
      return 0
    fi
  done
  return 1
}

installed_version() {
  local name="$1"
  local kind="${TOOL_KIND[$name]:-}"
  local target="${TOOL_TARGET[$name]:-}"
  local need="${TOOL_MANIFEST_VERSION[$name]:-}"
  if [[ "$kind" == "helm-plugin" || "$target" == "helm-plugin-dir" ]]; then
    get_helm_plugin_version "$name" && return 0
    return 1
  fi
  case "$name" in
    kubectl) get_kubectl_client_version ;;
    helm) get_helm_version ;;
    helmfile) get_helmfile_version ;;
    k9s)
      if get_k9s_version; then
        return 0
      fi
      if k9s_raw_mentions_required "$need"; then
        normalize_v "$need"
        return 0
      fi
      return 1
      ;;
    *) generic_semver "$(tool_bin "$name" || true)" ;;
  esac
}

versions_compatible() {
  local have="$1" need="$2"
  [[ -n "$have" && "$(version_core "$have")" == "$(version_core "$need")" ]]
}

ensure_tool() {
  local name="$1"
  local ver="${TOOL_MANIFEST_VERSION[$name]:-}"
  local url="${TOOL_URL[$name]:-}"
  local have="" managed=""
  if [[ -z "$url" ]]; then
    echo "ERROR: ${MANIFEST_PATH} has no ${PLATFORM_KEY} download for ${name}" >&2
    exit 1
  fi
  have="$(installed_version "$name" || true)"
  if versions_compatible "${have:-}" "$ver"; then
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN skip ${name}: ${have} matches ${ver}"
    else
      echo "OK ${name}: ${have} matches ${ver}"
      managed="$(managed_install_path "$name" || true)"
      if [[ -n "$managed" ]]; then
        record_installed "$name" "$ver" "$managed"
        echo "Recorded ${managed} in ${RECEIPT}"
      fi
    fi
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN would install ${name} ${ver} (have: ${have:-none})"
    echo "  ${url}"
    return 0
  fi
  if [[ -n "${have:-}" ]]; then
    echo "${name} mismatch (have: ${have}, need: ${ver})"
  else
    echo "${name} not found — installing ${ver}"
  fi
  install_from_manifest "$name"
  have="$(installed_version "$name" || true)"
  if [[ -n "${have:-}" ]] && ! versions_compatible "${have}" "$ver"; then
    echo "ERROR: ${name} version still wrong (have: ${have}, need: ${ver})" >&2
    echo "       binary: $(tool_bin "$name" 2>/dev/null || echo missing)" >&2
    exit 1
  fi
  if [[ -z "${have:-}" ]]; then
    echo "Installed ${name} ${ver} (checksum verified; version command produced no comparable number)."
  else
    echo "Installed ${name}: ${have}"
  fi
}

run_bundle() {
  local name url base dest manifest_copy archive
  local -a seen=()
  if [[ "${PREFLIGHT_OFFLINE:-0}" == "1" ]]; then
    echo "ERROR: --bundle fetches artifacts. Do not set PREFLIGHT_OFFLINE=1 on the connected machine." >&2
    exit 1
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN bundle into ${BUNDLE_DIR}"
  else
    mkdir -p "$BUNDLE_DIR"
    BUNDLE_DIR="$(cd -- "$BUNDLE_DIR" && pwd)"
    require_disk_space "$BUNDLE_DIR"
    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
    trap 'rm -rf "${WORK_DIR:-}"' EXIT
  fi
  for name in "${TOOL_ORDER[@]}"; do
    url="${TOOL_URL[$name]:-}"
    if [[ -z "$url" ]]; then
      echo "ERROR: ${MANIFEST_PATH} has no ${PLATFORM_KEY} download for ${name}" >&2
      exit 1
    fi
    base="$(url_basename "$url")"
    local already=0 s
    for s in "${seen[@]:-}"; do
      if [[ "$s" == "$base" ]]; then
        already=1
        break
      fi
    done
    if [[ "$already" == "1" ]]; then
      echo "ERROR: two tools share the artifact file name ${base}" >&2
      exit 1
    fi
    seen+=("$base")
    dest="${BUNDLE_DIR}/${base}"
    if [[ "$DRY_RUN" == "1" ]]; then
      echo "DRY-RUN download ${name} -> ${dest}"
      echo "  ${url}"
      continue
    fi
    archive="${WORK_DIR}/${name}.download"
    echo "Bundling ${name} -> ${dest}"
    if ! acquire_url "$url" "$archive" "$name"; then
      exit 1
    fi
    if [[ ! -s "$archive" ]]; then
      echo "ERROR: empty download for ${name}: ${url}" >&2
      exit 1
    fi
    verify_download "$name" "$archive"
    cp -f "$archive" "$dest"
  done
  manifest_copy="${BUNDLE_DIR}/$(basename "$MANIFEST_PATH")"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "DRY-RUN copy manifest to ${manifest_copy}"
  else
    cp -f "$MANIFEST_PATH" "$manifest_copy"
    echo "Copied manifest to ${manifest_copy}"
  fi
  echo
  echo "Transfer this directory to the air-gapped host:"
  echo "  ${BUNDLE_DIR}"
  echo "If the directory is placed at a different path, use that path in both places below."
  echo "On that host, from the directory that contains preflight.sh, run:"
  echo "  PREFLIGHT_ARTIFACT_DIR=${BUNDLE_DIR} PREFLIGHT_OFFLINE=1 ./preflight.sh --manifest ${manifest_copy}"
}

ensure_manifest_tools() {
  local name
  if [[ ${#TOOL_ORDER[@]} -eq 0 ]]; then
    echo "ERROR: ${MANIFEST_PATH} has no clientTools to install." >&2
    exit 1
  fi
  for name in "${TOOL_ORDER[@]}"; do
    ensure_tool "$name"
  done
}

print_versions() {
  echo
  echo "=== Installed / verified versions ==="
  echo "Required pins:"
  echo "  kubectl client : ${REQUIRED_KUBECTL_CLIENT_VERSION}"
  echo "  kustomize      : $(get_kustomize_version 2>/dev/null || echo 'embedded in kubectl')"
  echo "  kubectl server : ${REQUIRED_KUBECTL_SERVER_VERSION}"
  echo "  helm           : ${REQUIRED_HELM_VERSION_FULL}"
  echo "  helm-diff      : ${REQUIRED_HELM_DIFF_VERSION}"
  echo "  helm-secrets   : ${REQUIRED_HELM_SECRETS_VERSION}"
  echo "  helmfile       : ${REQUIRED_HELMFILE_VERSION}"
  echo "  k9s            : ${REQUIRED_K9S_VERSION}"
  echo
  kubectl version --client=true 2>/dev/null || kubectl version --client
  if kubectl cluster-info >/dev/null 2>&1; then
    kubectl version 2>/dev/null | grep -E 'Server Version' || true
  fi
  helm version
  helm plugin list
  helmfile version
  k9s version
}

print_support_boundary() {
  cat <<EOF
preflight.sh is a convenience tool maintained by Cloud Incubator GmbH.
It is not an official component of the USC package.
Supported USC manifest schemaVersion: ${SUPPORTED_SCHEMA_VERSION}
EOF
}

usage() {
  print_support_boundary
  cat <<EOF

Usage: ./preflight.sh [--dry-run] [--manifest <path>]
       ./preflight.sh --bundle <dir> --manifest <path> [--dry-run]

--dry-run           Print what would be skipped or installed. Do not download or write.
--manifest <path>   USC manifest (default: usc-manifest.json next to this script,
                    or PREFLIGHT_MANIFEST). schemaVersion must be ${SUPPORTED_SCHEMA_VERSION}.
--bundle <dir>      Download and verify every artifact for this OS/arch into <dir>,
                    copy the manifest there, and print the air-gapped follow-up command.
                    Does not install.

PREFLIGHT_ARTIFACT_DIR   Use a local file named from the URL basename instead of downloading.
PREFLIGHT_OFFLINE=1      Never use the network.
PREFLIGHT_MIN_TMP_MB     Minimum free MiB before a download (default 64).
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --bundle)
        [[ $# -ge 2 ]] || { echo "ERROR: --bundle requires a directory" >&2; exit 2; }
        BUNDLE_DIR="$2"
        shift 2
        ;;
      --bundle=*)
        BUNDLE_DIR="${1#*=}"
        [[ -n "$BUNDLE_DIR" ]] || { echo "ERROR: --bundle requires a directory" >&2; exit 2; }
        shift
        ;;
      --manifest)
        [[ $# -ge 2 ]] || { echo "ERROR: --manifest requires a path" >&2; exit 2; }
        MANIFEST_PATH="$2"
        shift 2
        ;;
      --manifest=*)
        MANIFEST_PATH="${1#*=}"
        shift
        ;;
      *)
        echo "ERROR: unknown argument: $1 (try --help)" >&2
        exit 2
        ;;
    esac
  done
}

main() {
  parse_args "$@"
  print_support_boundary
  echo
  if [[ -z "${HOME:-}" ]]; then
    echo "ERROR: HOME is not set" >&2
    exit 1
  fi
  require_linux
  detect_arch
  require_base_tools
  load_manifest_downloads
  echo "Platform ${PLATFORM_KEY}. Manifest schemaVersion ${SCHEMA_VERSION}."
  print_required_hosts
  echo
  case "$PATH" in
    "${BIN_DIR}"|"${BIN_DIR}:"*) PATH_BIN_FIRST=1 ;;
  esac
  case ":${PATH}:" in
    *":${BIN_DIR}:"*) PATH_HAD_BIN_DIR=1 ;;
  esac
  if [[ -n "$BUNDLE_DIR" ]]; then
    run_bundle
    echo
    echo "Bundle completed."
    return 0
  fi
  export PATH="${BIN_DIR}:${PATH}"
  if [[ "$HELM_PLUGINS_PRESET" -eq 0 ]]; then
    export HELM_PLUGINS="$PLUGIN_DIR"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "Dry run. Nothing will be downloaded or written."
    ensure_manifest_tools
    check_kustomize_via_kubectl
    echo
    echo "Dry run completed."
    print_path_hint
    return 0
  fi
  if ! mkdir -p "$BIN_DIR" "$PLUGIN_DIR"; then
    echo "ERROR: cannot create ${BIN_DIR} or ${PLUGIN_DIR}. Set PREFLIGHT_BIN_DIR to a user-writable directory. This script does not use sudo." >&2
    exit 1
  fi
  WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/preflight.XXXXXX")"
  trap 'rm -rf "$WORK_DIR"' EXIT
  echo "Binaries: ${BIN_DIR}. Helm plugins: ${PLUGIN_DIR}. No sudo."
  ensure_manifest_tools
  check_kustomize_via_kubectl
  check_kubectl_server
  print_versions
  echo
  echo "Preflight completed successfully."
  print_path_hint
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
