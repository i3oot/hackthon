#!/usr/bin/env bash
set -euo pipefail

# Accept multiple possible environment variable names passed by the devcontainer feature system.
# Common names: additionalComponents (JSON option), ADDITIONALCOMPONENTS (legacy), ADDITIONAL_COMPONENTS
# Prefer explicit env var if set; otherwise fallback.
ADDITIONAL_COMPONENTS_RAW="${ADDITIONALCOMPONENTS:-${ADDITIONAL_COMPONENTS:-${additionalComponents:-}}}"

# Determine the non-root user that should own the SDK installation.
TARGET_USER="${USERNAME:-${_REMOTE_USER:-vscode}}"
if ! id "$TARGET_USER" >/dev/null 2>&1; then
  TARGET_USER=$(id -un)
fi

TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6 || true)
if [[ -z "$TARGET_HOME" ]]; then
  TARGET_HOME="$HOME"
fi

run_as_target_user() {
  if [[ $EUID -eq 0 && "$TARGET_USER" != "root" ]]; then
    runuser -u "$TARGET_USER" -- "$@"
  else
    "$@"
  fi
}

trim() {
  local value="$1"
  # shellcheck disable=SC2001
  value="$(echo "$value" | sed -e 's/^\s*//' -e 's/\s*$//')"
  printf '%s' "$value"
}

if ! command -v gcloud >/dev/null 2>&1; then
  echo "gcloud CLI not found, installing..."

  # Ensure prerequisites are installed (curl, tar)
  if [[ $EUID -eq 0 ]]; then
    apt-get update -y && apt-get install -y curl tar gzip ca-certificates || { echo "Failed to install prerequisites" >&2; exit 1; }
  else
    # Try to proceed assuming required tools may already be available; warn otherwise
    for cmd in curl tar gzip; do
      if ! command -v $cmd >/dev/null 2>&1; then
        echo "Required command '$cmd' not found; aborting." >&2
        exit 1
      fi
    done
  fi

  # Choose installation directory. Install into the non-root user's home when running as root so the tooling is
  # immediately available without sudo.
  if [[ $EUID -eq 0 ]]; then
    INSTALL_DIR="${TARGET_HOME}/google-cloud-sdk"
  else
    INSTALL_DIR="${HOME}/google-cloud-sdk"
  fi

  # Clean up any previous partial downloads in working dir
  TMP_TAR="google-cloud-cli-linux-x86_64.tar.gz"
  if [[ -f "$TMP_TAR" ]]; then
    rm -f "$TMP_TAR"
  fi

  # Download and unpack into a temporary directory, then run the installer to chosen prefix
  curl -fsSL -o "$TMP_TAR" https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-cli-linux-x86_64.tar.gz
  mkdir -p /tmp/gcloud-install
  tar -xf "$TMP_TAR" -C /tmp/gcloud-install
  rm -f "$TMP_TAR"

  # The extracted folder name may vary; find the extracted sdk dir
  SDK_SRC_DIR=$(find /tmp/gcloud-install -maxdepth 1 -type d -name "google-cloud-sdk*" -print -quit)
  if [[ -z "$SDK_SRC_DIR" ]]; then
    # If not found, maybe the archive extracted into /tmp/gcloud-install/google-cloud-sdk
    SDK_SRC_DIR="/tmp/gcloud-install/google-cloud-sdk"
  fi

  echo "Running Google Cloud SDK installer to '$INSTALL_DIR'"
  if [[ $EUID -eq 0 ]]; then
    rm -rf "$INSTALL_DIR"
    mkdir -p "$(dirname "$INSTALL_DIR")"
    mv "$SDK_SRC_DIR" "$INSTALL_DIR" || { echo "Failed to move SDK to $INSTALL_DIR" >&2; exit 1; }
    chown -R "$TARGET_USER":"$TARGET_USER" "$INSTALL_DIR"
    run_as_target_user "${INSTALL_DIR}/install.sh" --quiet --usage-reporting false --path-update false || { echo "gcloud installer failed" >&2; exit 1; }
  else
    "$SDK_SRC_DIR/install.sh" --quiet --usage-reporting false --path-update false || { echo "gcloud installer failed" >&2; exit 1; }
  fi

  # Clean extracted temp
  rm -rf /tmp/gcloud-install

  # Ensure bin is on PATH for this session
  if [[ -x "$INSTALL_DIR/bin/gcloud" ]]; then
    export PATH="$INSTALL_DIR/bin:$PATH"
    echo "Added $INSTALL_DIR/bin to PATH for this session."
  fi

  # If the install updated global paths (when run as root) try to rehash
  if command -v hash >/dev/null 2>&1; then
    hash -r || true
  fi

  if [[ $EUID -eq 0 ]]; then
    PROFILE_SNIPPET="/etc/profile.d/google-cloud-sdk.sh"
    cat <<EOF >"$PROFILE_SNIPPET"
if [ -d "$INSTALL_DIR/bin" ]; then
  case ":\$PATH:" in
    *:"$INSTALL_DIR/bin":*) ;;
    *) PATH="$INSTALL_DIR/bin:\$PATH" ;;
  esac
fi
EOF
    chmod 0644 "$PROFILE_SNIPPET"
  fi
fi

declare -a requested_components=()

if [[ -n "$ADDITIONAL_COMPONENTS_RAW" ]]; then
  IFS=',' read -ra extras <<< "$ADDITIONAL_COMPONENTS_RAW"
  for entry in "${extras[@]}"; do
    local_trimmed="$(trim "$entry")"
    if [[ -n "$local_trimmed" ]]; then
      requested_components+=("$local_trimmed")
    fi
  done
fi

if [[ ${#requested_components[@]} -eq 0 ]]; then
  echo "No Google Cloud components requested; skipping installation."
  exit 0
fi

# Build a set of components that are already installed to avoid redundant installs.
declare -A installed_set=()
GCLOUD_BIN="${INSTALL_DIR:-${HOME}/google-cloud-sdk}/bin/gcloud"
if [[ ! -x "$GCLOUD_BIN" ]]; then
  GCLOUD_BIN=$(command -v gcloud || true)
fi

if [[ -z "$GCLOUD_BIN" ]]; then
  echo "gcloud binary not found after installation; aborting." >&2
  exit 1
fi

if mapfile -t local_components < <(run_as_target_user "$GCLOUD_BIN" components list --only-local-state --format='value(id)' 2>/dev/null); then
  for comp in "${local_components[@]}"; do
    installed_set["$comp"]=1
  done
else
  echo "Warning: Unable to read currently installed components; proceeding to install requested components."
fi

declare -a to_install=()
for comp in "${requested_components[@]}"; do
  if [[ -n "${installed_set[$comp]:-}" ]]; then
    echo "Component '$comp' already installed; skipping."
  else
    to_install+=("$comp")
  fi
done

if [[ ${#to_install[@]} -eq 0 ]]; then
  echo "All requested Google Cloud components already installed."
  exit 0
fi

echo "Installing Google Cloud components: ${to_install[*]}"
CLOUDSDK_CORE_DISABLE_PROMPTS=1 run_as_target_user "$GCLOUD_BIN" components install --quiet "${to_install[@]}"

echo "Google Cloud components installation complete."
