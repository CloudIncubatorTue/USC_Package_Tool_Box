# preflight.sh

Ensures that `kubectl`, Helm (including plugins), `helmfile`, and `k9s` are present at the pinned versions. Missing or mismatched tools are downloaded from `usc-manifest.json` into a user-writable directory. Base tools are only checked; this script does not install OS packages and does not call `sudo`.

## Running

`preflight.sh` is a convenience tool maintained by Cloud Incubator GmbH. It is not an official component of the USC package. It supports USC manifest `schemaVersion` `1.0` only. That text is printed at start and by `--help`.

```bash
./preflight.sh
./preflight.sh --dry-run
./preflight.sh --manifest usc-manifest.json
./preflight.sh --bundle /tmp/usc-cli-bundle --manifest usc-manifest.json
```

`uname -s` must be Linux. The platform key is `<os>-<arch>` from `uname -s` and `uname -m` (`x86_64` becomes `amd64`, `aarch64` becomes `arm64`; any other machine name is kept). Each tool is looked up at `platforms["<os>-<arch>"]`. A missing key is an error for that tool. The script does not assume `amd64`.

`--dry-run` prints `DRY-RUN skip` or `DRY-RUN would install` for every `clientTools` entry and does not download, install, or write the receipt.

`--bundle <dir> --manifest <path>` runs on a connected machine. It downloads every artifact for this OS and architecture into `<dir>`, checks each file with the same `verify_download` path as an install (`checksums.sha512`, or `checksums.sha256` when `sha512sum` is absent), and exits on mismatch before that file is kept. It does not install binaries or plugins and does not write the receipt. It copies the manifest into `<dir>` under the same file name, then prints the directory to transfer and the command to run on the air-gapped host:

```bash
PREFLIGHT_ARTIFACT_DIR=<dir> PREFLIGHT_OFFLINE=1 ./preflight.sh --manifest <dir>/<manifest-file>
```

If the directory is copied to another path, use that path in both places.

On startup the script prints the distinct host from every `download.url` for this platform. When `curl` is available and `PREFLIGHT_OFFLINE` is not set, it also follows redirects (`curl -L`) and prints the distinct final host for each URL. That list is not hardcoded. A failed download, when offline mode is not already set, says both: set `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` if the host needs a proxy, and otherwise run `--bundle` on a connected machine and re-run here with `PREFLIGHT_ARTIFACT_DIR` and `PREFLIGHT_OFFLINE=1`. The same host list is printed again with that error.

Checked on 2026-10-04 with HEAD and redirects: `dl.k8s.io` and `get.helm.sh` stayed on those hosts. The GitHub release URLs for helm-diff, helm-secrets, helmfile, and k9s finished on `release-assets.githubusercontent.com`, not on `objects.githubusercontent.com`.

The script does not need root. Network access is required unless the tool is already at the pinned version, `PREFLIGHT_OFFLINE=1` is set with files in `PREFLIGHT_ARTIFACT_DIR`, or you are only running `--dry-run`. Downloads use `download.url` for the current platform and are checked against `checksums.sha512` (or `checksums.sha256` when `sha512sum` is not available). Before a download, free space must be at least `PREFLIGHT_MIN_TMP_MB` mebibytes (default 64). If `PREFLIGHT_ARTIFACT_DIR` contains a file named from the URL basename, that file is used instead of the network. `PREFLIGHT_OFFLINE=1` never uses the network.

Versions can be overridden before start via environment variables when `usc-manifest.json` is not beside the script (or does not name that tool):

```bash
REQUIRED_HELM_VERSION=v3.16.4 REQUIRED_HELMFILE_VERSION=0.169.1 REQUIRED_K9S_VERSION=0.51.0 ./preflight.sh
```

When `usc-manifest.json` is in the same directory as `preflight.sh`, it replaces the matching pins. See [Versions from `usc-manifest.json`](#versions-from-usc-manifestjson).

## Flow

1. **Check** — Linux, then `curl` or `wget`, `tar`, `gzip`, and `sha256sum` or `sha512sum`. If one is missing, exit with a manual-install message.  
2. **Detect** — Platform key `<os>-<arch>` from `uname`. Do not assume `amd64`.  
3. **Ensure** — `ensure_tool` runs once per `clientTools` entry. A tool already at that version is skipped. Anything else is downloaded from that platform's `download.url`. `--dry-run` only prints the decision. A new tool is a new manifest entry, not a new function in `preflight.sh`.  
4. **Verify** — Check kubectl server version (only if the cluster is reachable); print all versions at the end.  

## Prerequisites and install locations

No package manager is used. `apt`, `dnf`, `yum`, `zypper`, and `snap` are not called. `sudo` is not called.

| Need | Behavior when missing |
| --- | --- |
| `curl` or `wget` | Exit. Install one manually. `curl` is used when both exist. |
| `tar` and `gzip` | Exit. Required to unpack `tar.gz` artifacts. |
| `sha512sum` or `sha256sum` | Exit. `sha512` from the manifest is preferred when `sha512sum` is present. |

| Destination | Default | Override |
| --- | --- | --- |
| Binaries | `$HOME/.local/bin` | `PREFLIGHT_BIN_DIR` |
| Helm plugins | `$HOME/.local/share/helm/plugins` | `PREFLIGHT_HELM_PLUGINS` (or a pre-set `HELM_PLUGINS`) |
| Receipt | `$HOME/.local/share/preflight/install-receipt.tsv` | `PREFLIGHT_RECEIPT` |
| Manifest | `usc-manifest.json` next to `preflight.sh` | `PREFLIGHT_MANIFEST` |

The new binaries are not picked up by the shell that started `preflight.sh`. The script prepends `$HOME/.local/bin` only for its own process. The last lines of the run are a warning that lists, for each manifest tool:

- installed locally, but this shell still runs a global or preinstalled binary (or has no command for it yet). A second copy anywhere on `PATH` counts, including the `kubectl` Amazon Linux already installed. `$HOME/.local/bin` is often already first in `~/.bashrc`, so a fresh lookup sees the local file while the current shell still runs the binary it remembered. That tool is not reported as already local.
- still taken from the global installation, because there is no copy in `$HOME/.local/bin`
- already used from the local install, and no other copy of that command is on `PATH`
- Helm plugins under `$HOME/.local/share/helm/plugins`

When a local binary is hidden by an older one, or `HELM_PLUGINS` is unset, those last lines also print:

```bash
export PATH="$HOME/.local/bin:$PATH"
hash -r
export HELM_PLUGINS="$HOME/.local/share/helm/plugins"
printf '%s\n' 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc
printf '%s\n' 'export HELM_PLUGINS="$HOME/.local/share/helm/plugins"' >> ~/.bashrc
```

`hash -r` drops the shell's remembered location of `kubectl` and the other tools. That step is required on Amazon Linux even when `$HOME/.local/bin` is already on `PATH`, because the shell keeps the preinstalled `kubectl` until the remembered command is cleared. The two `printf` lines make later login shells keep the same `PATH`. If `HELM_PLUGINS` was already set, that export is omitted. Without the `PATH` change, an older `kubectl` earlier on `PATH` stays the one you run.

`install_from_manifest` is the only installer. It uses `kind`, `download.archiveType`, `download.memberPath`, and `installTarget`. `kind` `helm-plugin` (`installTarget` `helm-plugin-dir`) has `memberPath` null and the whole archive is extracted into the plugins directory, including `plugin.yaml` and the plugin's own files. `installTarget` `bin` with `archiveType` `raw-binary` copies the file; `tar.gz` extracts only `memberPath`. The digest is compared to `checksums.sha512` or `checksums.sha256` from that same platform object. A mismatch exits before the file is installed. There is no second request for a checksum file.

## Required versions (defaults)

| Environment variable | Default | Check / installation |
| --- | --- | --- |
| `REQUIRED_KUBECTL_CLIENT_VERSION` | `v1.31.4` | kubectl client; reinstall on mismatch |
| `REQUIRED_KUSTOMIZE_VERSION` | `v5.4.2` | not enforced; Kustomize is whatever the installed kubectl embeds |
| `REQUIRED_KUBECTL_SERVER_VERSION` | `v1.30.14` | API server; only if cluster is reachable |
| `REQUIRED_HELM_VERSION` | `v3.16.4` | Helm (core version without build metadata) |
| `REQUIRED_HELM_VERSION_FULL` | `v3.16.4+g7877b45` | Display / target value including Git commit |
| `REQUIRED_HELM_DIFF_VERSION` | `3.9.13` | Helm plugin `diff` |
| `REQUIRED_HELM_SECRETS_VERSION` | `4.6.2` | Helm plugin `secrets` |
| `REQUIRED_HELMFILE_VERSION` | `0.169.1` | helmfile |
| `REQUIRED_K9S_VERSION` | `0.51.0` | k9s |

Built-in defaults apply when `usc-manifest.json` is absent. When that file is present, matching tools take their `version` from it (see below), including over an already exported variable. Pins the manifest does not name — `REQUIRED_KUSTOMIZE_VERSION`, `REQUIRED_KUBECTL_SERVER_VERSION`, and `REQUIRED_HELM_VERSION_FULL` while the Helm core version is unchanged — still use the environment when it is set, otherwise the default.

## Checked / installed components

| Component | Behavior |
| --- | --- |
| **kubectl (Client)** | Check version; on mismatch download the manifest `raw-binary` into `$HOME/.local/bin/kubectl` |
| **Kustomize** | Version from `kubectl version --client`; expects the version bundled with the pinned kubectl |
| **kubectl (Server)** | Only if `kubectl cluster-info` succeeds; otherwise skip with a notice, not an error |
| **Helm** | Compare core version; install the manifest `tar.gz` member into `$HOME/.local/bin/helm` |
| **helm-diff** | Plugin archive from the manifest, extracted under `$HOME/.local/share/helm/plugins` |
| **helm-secrets** | Same as helm-diff |
| **helmfile** | Manifest `tar.gz` member → `$HOME/.local/bin/helmfile`; version via `helmfile version -o short` |
| **k9s** | Manifest `tar.gz` member → `$HOME/.local/bin/k9s`; version via parsing `Version:` from `k9s version` |

### k9s

**k9s** is a terminal UI for Kubernetes clusters (from [derailed/k9s](https://github.com/derailed/k9s)). Preflight pins it via `REQUIRED_K9S_VERSION` (default `0.51.0`) so operators get a consistent interactive tool next to kubectl, Helm, and helmfile.

It is included for **day-2 ops convenience** on this USC stack: browse pods, namespaces, and other resources; tail logs; and scan events without leaving the terminal—complementing the declarative deploy/upgrade path rather than replacing it.

## Versions from `usc-manifest.json`

`preflight.sh` looks for `usc-manifest.json` in its own directory before it derives install tags. If the file is missing, the built-in defaults above stay. If it is present, each `clientTools` entry replaces the pin for that tool. The file follows USC manifest schema 1.0 (`https://usc.schemas.services.usu.com/usc-manifest-1.0.schema.json`): `clientTools[].name` selects the variable, `clientTools[].version` supplies the value.

The script stores the version in the form the rest of `preflight.sh` already uses. A leading `v` in the manifest is kept or added for kubectl and Helm (their download URLs require it) and removed for the Helm plugins, helmfile, and k9s (those install tags add `v` themselves).

| `clientTools[].name` | Variable | Stored form | Shipped manifest |
| --- | --- | --- | --- |
| `kubectl` | `REQUIRED_KUBECTL_CLIENT_VERSION` | leading `v` | `v1.35.6` |
| `helm` | `REQUIRED_HELM_VERSION` | leading `v` | `v3.16.4` (manifest field is `3.16.4`) |
| `helm-diff` | `REQUIRED_HELM_DIFF_VERSION` | no leading `v` | `3.9.13` (manifest field is `v3.9.13`) |
| `helm-secrets` | `REQUIRED_HELM_SECRETS_VERSION` | no leading `v` | `4.6.2` (manifest field is `v4.6.2`) |
| `helmfile` | `REQUIRED_HELMFILE_VERSION` | no leading `v` | `0.169.1` |
| `k9s` | `REQUIRED_K9S_VERSION` | no leading `v` | `0.51.0` |

`REQUIRED_HELM_VERSION_FULL` stays at its built-in value when that value's core version (the part before `+`) equals the manifest Helm version. The shipped manifest keeps `v3.16.4+g7877b45`. If the manifest Helm core differs, `REQUIRED_HELM_VERSION_FULL` becomes the `v`-prefixed manifest version, without a git commit — the manifest has no commit field.

`REQUIRED_KUSTOMIZE_VERSION` is not a client tool and is not enforced. kubectl `v1.35.6` from the shipped manifest embeds Kustomize `v5.7.1`. Reinstalling that same kubectl cannot change the embedded version, so a mismatch with the old `v5.4.2` default does not fail the run. `REQUIRED_KUBECTL_SERVER_VERSION` is still checked when the cluster is reachable.

A version that is empty or contains characters other than letters, digits, `.`, `_`, `+`, and `-` stops `preflight.sh` before any install. A manifest with no `name`/`version` pairs does the same. Names other than the six in the table do not change version pins. When a tool must be installed, its bytes come from that tool's `platforms["linux-<arch>"].download` and are checked against that object's `checksums`. An already-correct binary on `PATH` is left in place and is not written to the receipt.

## Install receipt

`preflight.sh` writes `$HOME/.local/share/preflight/install-receipt.tsv` for every manifest tool that lives in the preflight install directories. That includes a tool installed in this run and a tool that was already there at the right version. A matching binary that lives somewhere else on `PATH` is not recorded.

```text
name<TAB>version<TAB>path<TAB>manifest-hash
```

`manifest-hash` is `sha256:<hex>` of the manifest file (`sha512:<hex>` when only `sha512sum` exists). A later run replaces the row for the same name and keeps the other rows. The directory is created when the first row is written. `helm/` and `k9s/` under `.local/share` are tool data directories, not the receipt.

`preflightEraser.sh` reads that file and deletes only those paths. It refuses `/`, `$HOME`, `$HOME/.local/bin`, the Helm plugins directory itself, and any path that is relative or contains `..`. It does not call `sudo` and does not search by tool name. After every recorded path is removed, it deletes the receipt. `PREFLIGHT_ERASER_YES=1` or `--yes` skips the confirmation prompt.

If the receipt is missing or has no tool rows, the script does not stop. It removes the manifest client tools from this user's install directories, the same as `--reset`, and asks before deleting. The receipt is stored under `$HOME`, so the script must be run as the same user that ran `preflight.sh`.

### Reset without the receipt

```bash
./preflightEraser.sh --reset
```

`--reset` (or `PREFLIGHT_ERASER_RESET=1`) does not use the receipt to choose paths. It reads `clientTools` from `usc-manifest.json` (`PREFLIGHT_MANIFEST`) and removes each tool from the preflight install directories:

- `installTarget` `bin` → `$HOME/.local/bin/<name>` (`PREFLIGHT_BIN_DIR`)
- `installTarget` `helm-plugin-dir` → the plugin directory under `$HOME/.local/share/helm/plugins` (`PREFLIGHT_HELM_PLUGINS`) whose `plugin.yaml` name is the manifest name, or that name without a leading `helm-` (`helm-diff` removes a plugin named `diff`)

Other files in those directories stay, including tools the operator copied there. Binaries outside those directories stay, including a `kubectl` already on the system `PATH`. `curl`, `tar`, `gzip`, and the checksum tools stay. If the manifest cannot be read, the built-in list is used: `kubectl`, `helm`, `helmfile`, `k9s`, `helm-diff`, and `helm-secrets`.

After the tool paths are removed, `--reset` deletes the receipt so the record matches an empty preflight install. The same path-safety checks apply. `--yes` skips the confirmation prompt.

## Important notes

- **Server check is conditional:** Without a reachable cluster, the server version check is skipped (no exit error). With a cluster and a mismatch: abort with an error.
- **Architecture:** Only `x86_64`/`amd64` and `aarch64`/`arm64`.
- **No root and no package manager:** Missing `curl`/`wget`, `tar`, `gzip`, or checksum tools must be installed by the operator.
- **User install path:** New binaries go to `$HOME/.local/bin`. A compatible tool already on `PATH` is not replaced and is not recorded.
- Source of truth for behavior: `preflight.sh`. When `usc-manifest.json` is present, it supplies the six tool pins in the chapter above; otherwise the built-in defaults in `preflight.sh` apply.
