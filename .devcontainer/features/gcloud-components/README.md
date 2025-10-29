# gcloud-components devcontainer feature

Installs the Google Cloud SDK if missing and optionally installs additional components.

Options
- `additionalComponents` (string): comma-separated list of components to install. Example: `cloud-run-proxy, beta`

Usage (in `.devcontainer/devcontainer.json`):

```json
"features": {
  "ghcr.io/devcontainers/features/docker-in-docker:2": {},
  "./features/gcloud-components": {
    "additionalComponents": "cloud-run-proxy"
  }
}
```

Note: the feature installs the SDK into the non-root user's home when run as root and will attempt to set PATH for the session. If you need different install behavior, edit `install.sh`.
