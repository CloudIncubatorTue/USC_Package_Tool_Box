# Preflight changelog

## User-local install, no sudo, no package manager

**When:** 2026-10-04 10:26:38 UTC

**Request:** Remove `sudo` and package-manager installation. Drop `detect_package_manager`, `pkg_install`, `install_deps`, and every `sudo` call. Install into a user-writable directory (`$HOME/.local/bin`, `$HOME/.local/share/helm/plugins`) and print a `PATH` hint when that directory is not already on `PATH`. For `curl`/`wget`, `tar`, and `sha256sum`/`sha512sum`, only check that the command exists and exit with a manual-install message. Download kubectl, Helm, helmfile, k9s, and the Helm plugins from the USC manifest instead of installing them with the OS package manager.

**How it was solved:**

- Deleted `detect_package_manager`, `pkg_install`, `install_deps`, `install_deps_via_snap_fallback`, and `try_snap_install`. `preflight.sh` and `preflightEraser.sh` contain no `sudo` invocation. `apt-get`, `dnf`, `yum`, `zypper`, and `snap` are not called.
- `require_base_tools` runs before any download. It requires `curl` or `wget`, `tar`, `gzip` (needed to unpack `tar.gz`), and `sha256sum` or `sha512sum`. A missing command prints the name and exits. Nothing is installed to satisfy that check.
- `detect_arch` still maps `x86_64`/`amd64` and `aarch64`/`arm64` to `linux-amd64` or `linux-arm64`. That key selects `clientTools[].platforms` in `usc-manifest.json` (override the file with `PREFLIGHT_MANIFEST`).
- For each tool that fails its existing version check, `install_from_manifest` downloads `download.url` with `curl` (or `wget` if `curl` is absent). It does not build the URL from a version string and it does not fetch a separate checksum file.
- The expected digest is `checksums.sha512` when `sha512sum` is on `PATH`, otherwise `checksums.sha256`. `sha512sum --check` / `sha256sum --check` must succeed. A mismatch prints an error and exits before the file is copied into place.
- `archiveType` `raw-binary` is copied to `$HOME/.local/bin/<name>` (`PREFLIGHT_BIN_DIR`). `tar.gz` with `download.memberPath` extracts that member to the same directory (Helm's `linux-amd64/helm`, helmfile's `helmfile`, k9s's `k9s`). `installTarget` `helm-plugin-dir` with `memberPath` null extracts the whole archive under `$HOME/.local/share/helm/plugins` (`PREFLIGHT_HELM_PLUGINS`, or a `HELM_PLUGINS` value that was already set). `helm plugin install` from GitHub is no longer used.
- The current process prepends the bin directory to `PATH` and, when `HELM_PLUGINS` was unset, exports the plugin directory. If the bin directory was not on `PATH` at start, the script prints `export PATH="$HOME/.local/bin:$PATH"`. If `HELM_PLUGINS` was unset, it prints that export as well.
- Version checks prefer `$HOME/.local/bin/<tool>` when that file exists, then any other copy on `PATH`. A copy that is already the required version is left where it is and is not recorded. `mkdir` of the destination must succeed without root; otherwise the script exits and tells the operator to set `PREFLIGHT_BIN_DIR`.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md`.

---

## Receipt-only cleanup

**When:** 2026-10-04 10:26:38 UTC

**Request:** Cleanup must remove only what this run installed. Write a receipt at install time with path, version, and manifest hash for each tool actually installed. `preflightEraser.sh` must read that receipt instead of matching plausible paths or names, so it does not delete a binary merely because `command -v` resolves to `/usr/local/bin/<name>`, and it does not wildcard plugin directories whose names contain `diff` or `secrets`.

**How it was solved:**

- `record_installed` writes `$HOME/.local/share/preflight/install-receipt.tsv` (`PREFLIGHT_RECEIPT`). It runs only after a checksum-verified file or plugin directory has been placed. A skipped tool (already the right version) does not get a row.
- Each data row is `name<TAB>version<TAB>absolute-path<TAB>manifest-hash`. `version` is the manifest `clientTools[].version` (`v1.35.6`, `3.16.4`, `v3.9.13`, …). `manifest-hash` is `sha256:<hex>` of the manifest file, or `sha512:<hex>` when only `sha512sum` exists. Reinstalling the same name replaces that row and leaves the other rows in place.
- `preflightEraser.sh` reads only that file. For each row it deletes that exact path with `rm -rf` and no `sudo`. It does not call `command -v`, does not look in `/usr/local/bin`, and does not search for directories by substring.
- Before deletion it refuses a path that is relative, contains `..`, or is exactly `/`, `/usr`, `/usr/local`, `/usr/local/bin`, `$HOME`, `$HOME/.local`, `$HOME/.local/bin`, or the Helm plugins directory itself. A refused path leaves the receipt on disk and exits non-zero.
- When every recorded path is removed or already absent, the script deletes the receipt. `--yes` or `PREFLIGHT_ERASER_YES=1` skips the confirmation prompt. A missing receipt exits 0 and removes nothing.

**Status:** addressed in `preflight.sh` and `preflightEraser.sh`. Documented in `preflight.md`.

---

## Reset install directories without the receipt

**When:** 2026-10-04 10:48:51 UTC

**Request:** Add a `preflightEraser.sh` option that ignores the receipt and removes all of the preflight packages, so the environment can be put back to a base level.

**How it was solved:**

- New flag `--reset`, also enabled by `PREFLIGHT_ERASER_RESET=1`. The default mode is unchanged: it still deletes only receipt rows.
- `--reset` does not read receipt rows to decide what to delete. It reads `clientTools[].name` and `installTarget` from `usc-manifest.json` (`PREFLIGHT_MANIFEST`, otherwise the file next to the script).
- `installTarget` `bin` removes `$PREFLIGHT_BIN_DIR/<name>` (default `$HOME/.local/bin/<name>`). `installTarget` `helm-plugin-dir` removes the plugin directory under `$PREFLIGHT_HELM_PLUGINS` (default `$HOME/.local/share/helm/plugins`) when that directory's `plugin.yaml` name equals the manifest name, or equals that name with a leading `helm-` stripped (`helm-diff` → plugin `diff`). The directory named exactly as the manifest tool is removed as well.
- Files in those directories that are not manifest client tools are left in place. Tools outside those directories are left in place, so a distro `kubectl` on `PATH` is not removed. `curl`, `tar`, `gzip`, and checksum commands are not removed.
- If the manifest is missing or has no `name`/`installTarget` pairs, the built-in list is `kubectl`, `helm`, `helmfile`, `k9s`, `helm-diff`, and `helm-secrets`.
- The same `safe_to_remove` checks apply (`/`, `$HOME`, the bin directory itself, the plugins directory itself, relative paths, `..`). A refused path exits non-zero and leaves the receipt on disk.
- When every selected path is removed or already absent, the receipt file is deleted so a later default eraser run does not try to clean an install that reset already cleared. `--yes` or `PREFLIGHT_ERASER_YES=1` skips the confirmation prompt.

**Status:** addressed in `preflightEraser.sh`. Documented in `preflight.md` under **Reset without the receipt**.

---

## Checksums come from the manifest

**When:** 2026-10-04 10:26:38 UTC (same change as the user-local install; recorded here on its own).

**Request:** Stop fetching a second checksum file from the same host as the artifact. Read `checksums.sha256` and `checksums.sha512` from the platform object in `usc-manifest.json`. Prefer sha512. sha256 is enough when sha512 cannot be checked. Download the artifact, compare it to that digest, and exit on mismatch.

**How it was solved:**

- `parse_manifest_tools` reads `checksums.sha256` and `checksums.sha512` from `platforms["linux-<arch>"]` into `TOOL_SHA256` and `TOOL_SHA512`. No checksum URL is requested.
- `install_kubectl`, `install_helm`, `install_helmfile`, `install_k9s`, and the Helm plugins `helm-diff` and `helm-secrets` all install through `install_from_manifest`. That function downloads the artifact once, then calls `verify_download` before any file is copied into `$HOME/.local/bin` or the Helm plugins directory.
- `verify_download` uses `checksums.sha512` with `sha512sum --check` when that command exists and the manifest field is non-empty. Otherwise it uses `checksums.sha256` with `sha256sum --check`. A mismatch prints `ERROR: sha512 mismatch` or `ERROR: sha256 mismatch` and exits 1. If neither digest can be checked, it exits 1 as well.
- The check is the digest in the manifest against the downloaded bytes. It does not trust a checksum file published next to the artifact.

**Status:** addressed in `preflight.sh` (`verify_download`). Documented in `preflight.md`.

---

## One manifest-driven ensure step

**When:** 2026-10-04 11:12:04 UTC

**Request:** Keep the existing behavior that skips an install when the tool is already at a compatible version, but replace the per-tool `ensure_*` functions with one function driven by the manifest. Adding a tool must be a manifest change, not a script change.

**How it was solved:**

- Removed `install_kubectl`, `ensure_kubectl`, `install_helm`, `ensure_helm`, `ensure_helm_plugin`, `ensure_helm_plugins`, `install_helmfile`, `ensure_helmfile`, `install_k9s`, and `ensure_k9s`.
- `load_manifest_downloads` records `clientTools` order in `TOOL_ORDER`. `ensure_manifest_tools` calls `ensure_tool` once per name.
- `ensure_tool` reads that tool's `version`, `kind`, and `download.url` from the manifest. `installed_version` reads the copy already on disk: kubectl, Helm, helmfile, and k9s keep their existing parsers (including the k9s raw-output fallback); a Helm plugin matches `plugin.yaml` name `diff` to manifest name `helm-diff`; any other binary is accepted when its version command prints the same version number.
- Comparison ignores a leading `v` and Helm build metadata (`v3.16.4+g…` matches `3.16.4`). A match prints `OK` and does not download. A mismatch or a missing tool calls `install_from_manifest`, then checks the version again and exits if the reported version is still different.
- The kubectl server check and the embedded Kustomize check stay after the loop. They are not `clientTools` entries, so they are not part of the install loop.

**Status:** addressed in `preflight.sh` (`ensure_tool`). Documented in `preflight.md`.

---

## One download and extract function

**When:** 2026-10-04 11:13:37 UTC

**Request:** Replace `install_kubectl`, `install_helm`, `install_helmfile`, `install_k9s`, `install_helm_plugin_diff`, and `install_helm_plugin_secrets` with one function. The layout must come from `kind`, `download.archiveType`, `download.memberPath`, and `installTarget`. For `kind` `helm-plugin`, `memberPath` is null: extract the whole archive into the plugins directory, because a plugin needs `plugin.yaml` and its own files, not one extracted member.

**How it was solved:**

- There is no per-tool install function. `ensure_tool` calls `install_from_manifest` for every `clientTools` name that is missing or at the wrong version.
- `install_from_manifest` reads `TOOL_KIND`, `TOOL_ARCHIVE`, `TOOL_MEMBER`, and `TOOL_TARGET`, which were filled from `kind`, `download.archiveType`, `download.memberPath`, and `installTarget`.
- `kind` `helm-plugin` or `installTarget` `helm-plugin-dir` requires `archiveType` `tar.gz` and calls `install_plugin_tree`. That extracts the whole archive. A top-level `plugin.yaml` lands in `$HOME/.local/share/helm/plugins/<name>/`. A single top-level directory that contains `plugin.yaml` (the `diff/` directory inside helm-diff) is copied with all of its files, including `bin/`. `memberPath` null is not treated as "extract one file".
- `installTarget` `bin` and `archiveType` `raw-binary` copies the downloaded file to `$HOME/.local/bin/<name>`. `archiveType` `tar.gz` extracts only `download.memberPath` (Helm's `linux-amd64/helm`, helmfile's `helmfile`, k9s's `k9s`) and installs that file. Other archive types and install targets exit with an error.
- The checksum check still runs before either copy.

**Status:** addressed in `preflight.sh` (`install_from_manifest`). Documented in `preflight.md`.

---

## Linux, platform key, disk space, and offline artifacts

**When:** 2026-10-04 11:17:28 UTC

**Request:** Before installing, require Linux. Build the platform key `<os>-<arch>` from `uname -s` and `uname -m`, and fail that tool when `platforms` has no such key, instead of assuming `amd64`. Keep disk-space checks and `PREFLIGHT_ARTIFACT_DIR` / offline handling on the generic downloader.

**How it was solved:**

- `require_linux` exits unless `uname -s` is `Linux`.
- `detect_arch` no longer aborts on an unknown machine name. `x86_64` and `amd64` become `amd64`. `aarch64` and `arm64` become `arm64`. Any other `uname -m` is lowercased and kept. The key is `<lowercased uname -s>-<arch>`, for example `linux-amd64`.
- `ensure_tool` errors with `no <platform> download for <name>` when that tool's `platforms` object has no entry. It does not substitute `linux-amd64`.
- `require_disk_space` runs before each download. Free space is `df -Pk` in mebibytes. The minimum is `PREFLIGHT_MIN_TMP_MB`, default 64. Below that, the script exits.
- `acquire_url` copies `PREFLIGHT_ARTIFACT_DIR/<url basename>` when that file exists. `PREFLIGHT_OFFLINE=1` exits if the local file is missing and does not call curl or wget. Otherwise the manifest `download.url` is fetched. Checksum verification is unchanged.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md`.

---

## Support boundary

**When:** 2026-10-04 11:17:28 UTC

**Request:** On start and in `--help`, state that this is a convenience tool maintained by Cloud Incubator GmbH, not an official component of the USC package, and name the manifest schema version it supports.

**How it was solved:**

- `print_support_boundary` prints that text and `Supported USC manifest schemaVersion: 1.0`. `main` prints it before any install. `--help` prints it and then the usage.
- `load_manifest_downloads` rejects a missing `schemaVersion` and any value other than `1.0`.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md`.

---

## Dry run

**When:** 2026-10-04 11:17:28 UTC

**Request:** Add `--dry-run` so an operator can see what would be downloaded, installed, or skipped without writing state files.

**How it was solved:**

- `--dry-run` sets `DRY_RUN=1`. `ensure_tool` prints `DRY-RUN skip <name>` when the installed version matches, or `DRY-RUN would install <name> <version>` plus the manifest URL when it does not. It does not call `install_from_manifest`.
- The dry-run path does not create `$HOME/.local/bin`, the Helm plugins directory, the work directory, or the receipt. A kustomize mismatch prints that kubectl would be reinstalled and does not download it. The live server-version check is not run.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md`.

---

## Air-gapped bundle

**When:** 2026-10-04 11:26:46 UTC

**Request:** Add `--bundle <dir> --manifest <path>` for a connected machine. Download every artifact for the current OS and architecture into `<dir>`, verify each with the existing checksum check, do not install, copy the manifest into `<dir>`, and print the exact offline command to run after the directory is transferred.

**How it was solved:**

- `--bundle` and `--bundle=<dir>` set `BUNDLE_DIR`. After the Linux check, platform key, and manifest load, `run_bundle` runs and `main` returns. It does not create `$HOME/.local/bin`, does not extract plugins, and does not write the receipt.
- For each `clientTools` entry, `acquire_url` fetches `download.url` into a temporary file and `verify_download` checks `checksums.sha512` or `checksums.sha256`. A mismatch exits before `cp` into `<dir>`, so a bad download is not the file that gets carried. The kept name is the URL basename, which is what `PREFLIGHT_ARTIFACT_DIR` already looks up. Two tools that share that basename are an error.
- A tool with no `platforms["<os>-<arch>"]` entry fails that tool, same as install. `PREFLIGHT_OFFLINE=1` is rejected for `--bundle`, because this step is the connected download.
- The manifest is copied to `<dir>/$(basename of the manifest path)`. The script prints that absolute directory and:

  `PREFLIGHT_ARTIFACT_DIR=<dir> PREFLIGHT_OFFLINE=1 ./preflight.sh --manifest <dir>/<manifest-file>`

- `--dry-run --bundle <dir>` lists the downloads and the manifest copy and does not create `<dir>`.

**Status:** addressed in `preflight.sh` (`run_bundle`). Documented in `preflight.md`.

---

## Network failure hint and derived host allowlist

**When:** 2026-10-04 11:33:00 UTC

**Request:** When a download fails and `PREFLIGHT_OFFLINE` is not already set, do not mention only a proxy. Tell the operator to set `HTTPS_PROXY`, `HTTP_PROXY`, and `NO_PROXY` if the host needs a proxy, and to use `--bundle` on a connected machine and re-run with `PREFLIGHT_ARTIFACT_DIR` and `PREFLIGHT_OFFLINE=1` if the host has no internet. Also print the distinct hosts this run must reach, taken from the manifest URLs, plus the final host after redirects. Do not hardcode a CDN name. Check `dl.k8s.io` and `get.helm.sh` the same way and record what was observed.

**How it was solved:**

- `print_network_hint` runs from `acquire_url` when `curl` or `wget` fails and `PREFLIGHT_OFFLINE` is not `1`. It prints both the proxy variables and the `--bundle` plus `PREFLIGHT_ARTIFACT_DIR` / `PREFLIGHT_OFFLINE=1` command. If offline mode is already set, that hint is not printed; the existing missing-artifact error stands.
- `print_required_hosts` runs after the manifest is loaded, and again inside the failure hint. It prints each distinct host from `download.url` for the current platform. With `curl` and without offline mode, `probe_effective_url` uses `curl -sSIL -o /dev/null -w '%{http_code} %{url_effective}'` and, if that does not return a usable URL, a one-byte ranged GET with redirects. The distinct final hosts are printed. A failed probe is reported for that URL and does not abort the run. Offline mode and a host without `curl` print the manifest hosts only.
- No CDN hostname is written in the script.

**Observed on 2026-10-04** with HEAD and redirects against the shipped `usc-manifest.json` (`linux-amd64`):

| Tool | Manifest host | Effective host |
| --- | --- | --- |
| kubectl | `dl.k8s.io` | `dl.k8s.io` |
| helm | `get.helm.sh` | `get.helm.sh` |
| helm-diff, helm-secrets, helmfile, k9s | `github.com` | `release-assets.githubusercontent.com` |

`dl.k8s.io` and `get.helm.sh` did not change host on this check. The GitHub release URLs did not land on `objects.githubusercontent.com`.

**Status:** addressed in `preflight.sh` (`print_network_hint`, `print_required_hosts`). Documented in `preflight.md`.

---

## Do not fail on the embedded Kustomize version

**When:** 2026-10-04 11:49:39 UTC

**Request:** Installing kubectl `v1.35.6` from `usc-manifest.json` succeeded, then the run exited with `kustomize still 'v5.7.1' after kubectl install` because `REQUIRED_KUSTOMIZE_VERSION` is still `v5.4.2`.

**How it was solved:**

- kubectl `v1.35.6` embeds Kustomize `v5.7.1`. `check_kustomize_via_kubectl` downloaded that same kubectl again and then exited, which cannot change the embedded version.
- The check now prints the Kustomize version reported by the installed kubectl and returns. It does not reinstall kubectl and it does not exit.
- `REQUIRED_KUSTOMIZE_VERSION` remains set for compatibility and is not used as a pass/fail pin. The kubectl client version from the manifest is still enforced by `ensure_tool`.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md` and `AGENTS.md`.

---

## Eraser continues when the receipt is missing

**When:** 2026-10-04 12:00:21 UTC

**Request:** `./preflightEraser.sh` printed `No receipt at /home/ec2-user/.local/share/preflight/install-receipt.tsv` and stopped, so the tools already installed under that user's `$HOME/.local` were left in place.

**How it was solved:**

- A missing receipt, or a receipt with no tool rows, no longer exits. The script tells the operator it is removing the manifest client tools from this user's `$HOME/.local/bin` and Helm plugin directory, then runs the same removal as `--reset` and asks for confirmation.
- The receipt and the install directories are under `$HOME`. The eraser must be run as the same user that ran `preflight.sh`. A run as `ec2-user` does not see `/home/admin/.local`.
- Files in those directories that are not manifest client tools are still left alone.

**Status:** addressed in `preflightEraser.sh`. Documented in `preflight.md` and `AGENTS.md`.

---

## Write the receipt when tools are already installed

**When:** 2026-10-04 12:02:41 UTC

**Request:** `preflight.sh` did not create `$HOME/.local/share/preflight/`. `~/.local/share` contained only `helm/` and `k9s/`, so `preflightEraser.sh` found no receipt.

**How it was solved:**

- The receipt was written only when this run copied a new file. Tools already at the manifest version were skipped and never recorded, so the `preflight` directory was never created. `helm/` and `k9s/` under `.local/share` are data directories those programs create; they are not the receipt.
- On a matching version, `ensure_tool` now calls `managed_install_path`. If the binary is `$HOME/.local/bin/<name>` or the plugin directory is under `$HOME/.local/share/helm/plugins`, that path is upserted into `install-receipt.tsv`. `record_installed` creates `$HOME/.local/share/preflight` at that point.
- A matching binary that lives somewhere else on `PATH` is still not recorded.

**Status:** addressed in `preflight.sh`. Documented in `preflight.md` and `AGENTS.md`.

---

## Warn that the current shell still has the old PATH

**When:** 2026-10-04 12:16:35 UTC

**Request:** Newly installed binaries are not picked up by the shell that started `preflight.sh`. The run must warn and print the commands that put `$HOME/.local/bin` first on `PATH`.

**How it was solved:**

- `preflight.sh` prepends the install directory only inside its own process. That change disappears when the script exits, so an older `kubectl` earlier on `PATH` remains the one the operator runs.
- Unless `$HOME/.local/bin` (`PREFLIGHT_BIN_DIR`) is already the first `PATH` entry, the end of a real run and of `--dry-run` prints a warning and these commands: `export PATH="<bin>:$PATH"`, `hash -r`, and `export HELM_PLUGINS="<plugin dir>"` when `HELM_PLUGINS` was not already set.
- It also prints `printf` lines that append those exports to `~/.bashrc`. The script does not edit `~/.bashrc` itself.

**Status:** addressed in `preflight.sh` (`print_path_hint`). Documented in `preflight.md` and `AGENTS.md`.

---

## PATH warning is the last message and names each tool

**When:** 2026-10-04 12:22:28 UTC

**Request:** Put the shell warning at the very end. List which tools were installed locally but are not yet the command this shell runs, and which tools are still taken from the global installation.

**How it was solved:**

- `print_path_hint` now runs after `Preflight completed successfully.` and after `Dry run completed.` Nothing is printed after it.
- For each binary in the manifest it compares `$HOME/.local/bin/<name>` with `command -v` on the `PATH` from before the script prepended its own directory. Local file present and the shell command is different or missing: listed under "Installed locally, but this shell does not run them yet", including the global path. No local file but a command on `PATH`: listed under "Still taken from the global installation". Same file: "Already used from the local install".
- Helm plugins are listed with their directory under `$HOME/.local/share/helm/plugins`.
- The `export PATH`, `hash -r`, `export HELM_PLUGINS`, and `~/.bashrc` lines are printed only when a local binary is still hidden or `HELM_PLUGINS` was not set.

**Status:** addressed in `preflight.sh` (`print_path_hint`). Documented in `preflight.md`.

---

## PATH warning keeps a preinstalled kubectl in the global list

**When:** 2026-10-04 12:28:00 UTC

**Request:** On Amazon Linux, `kubectl` is preinstalled and the current shell still runs that binary. The warning reported it under "Already used from the local install" because `$HOME/.local/bin` is already on `PATH`.

**How it was solved:**

- The shell command is found by walking the `PATH` from before this script prepends its directory. `command -v` is not used; bash returns the command this process remembered after it ran the local binary.
- A local file is "already used" only when that file is the only executable of that name on `PATH`. If another copy exists, including a preinstalled `kubectl` later on `PATH`, the tool is listed under "Installed locally, but this shell does not run them yet" with that preinstalled path. `hash -r` is required even when `$HOME/.local/bin` is already first.

**Status:** addressed in `preflight.sh` (`first_on_original_path`, `print_path_hint`). Documented in `preflight.md` and `AGENTS.md`.
