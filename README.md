# ILIAS Helm Chart

This chart aims to provide a secure and simple deployment of ILIAS, keeping the values you need to set to a minimum.

Helm chart for deploying [ILIAS](https://www.ilias.de/) LMS on Kubernetes, including MariaDB, the ILIAS cron daemon, and optionally the ILIAS Java server (`ilserver`, for certificate/PDF generation).

## Installation

Pull the chart directly from the Codeberg package registry as an OCI artifact:

```bash
helm install ilias oci://codeberg.org/pwurbs/charts/ilias --version 1.0.0 \
  --namespace ilias --create-namespace \
  -f my-values.yaml
```

Available versions: [codeberg.org/pwurbs/-/packages](https://codeberg.org/pwurbs/-/packages).

## Configuration

Most important values in [`chart/values.yaml`](chart/values.yaml):

| Key | Description |
|-----|-------------|
| `ilias.httpPath` | Public URL, e.g. `https://ilias.example.com` — required, no default |
| `ilias.autoSetup` | `"0"` = setup/update block in the entrypoint is skipped (default). Only set to `"1"` temporarily for the initial install or a version update — see warning below. |
| `ingress.host` | Ingress hostname — required, no default |
| `storage.*.size` | PVC sizes for MariaDB data, `ilias-public`, `ilias-data` — review before going to production; the default `local-path` StorageClass doesn't support resizing an existing PVC |
| `secrets.existingSecret` | Name of an already existing secret in the cluster (see below); if empty, the chart creates the secret itself |

All other values (timezone, upload size, TLS secret name, resource requests/limits, image tags, ...) have workable defaults — see [`chart/values.yaml`](chart/values.yaml) for the full list and further explanations.

### Secrets

By default (`secrets.existingSecret` empty), the chart generates `ilias-root-password`, `ilias-db-password`, and `mariadb-root-password` itself on first install (`chart/templates/secret.yaml`, via Helm's `lookup` + `randAlphaNum`) and reuses the existing values on every subsequent `helm upgrade` — no cleartext password ever needs to be set as a value.
This matters beyond convenience: all three passwords are only ever consumed once, at the very first start. MariaDB only applies `MYSQL_ROOT_PASSWORD`/`MYSQL_PASSWORD` when initializing an empty data directory, and ILIAS only applies `ILIAS_ROOT_PASSWORD` (the admin account password) during the initial setup run — later starts read but ignore these. `ILIAS_DB_PASSWORD` is the exception: ILIAS reads it live on every start to connect to MariaDB, so a mismatch there breaks connectivity immediately, not just at setup.

Retrieve the generated admin password for the initial login:

```bash
kubectl -n ilias get secret <release-name>-secrets -o jsonpath='{.data.ilias-root-password}' | base64 -d; echo
```

Change it right after logging in — the Secret still holds it in plaintext afterwards, and the underlying `ILIAS_ROOT_PASSWORD` env var is, as explained above, ignored on every start after the first anyway, so changing it in ILIAS itself is free of side effects.

Note that `lookup` requires a live cluster connection — it works with `helm install`/`upgrade` and with Flux's `helm-controller`, but always generates fresh (throwaway) values when rendering offline, e.g. plain `helm template`.
This stability only holds while the Secret object itself survives: deleting it independently of the PVCs (or reinstalling on top of the same PVCs after a `helm uninstall`) makes the chart generate a new, mismatched password on the next deploy — so back it up together with the PVCs.

If you'd rather manage the Secret yourself outside of Helm (SOPS, External Secrets Operator, Sealed Secrets, ...), set `secrets.existingSecret` to its name and create it out of band.
The same drift risk described above applies here too — it's now on you to keep its values in sync with what's actually configured in MariaDB/ILIAS:

```bash
kubectl -n ilias create secret generic ilias-secrets \
  --from-literal=ilias-root-password="<...>" \
  --from-literal=ilias-db-password="<...>" \
  --from-literal=mariadb-root-password="<...>"
```

If your externally managed Secret uses different key names, point the chart at them via `secrets.existingSecretKeys.iliasRootPassword`/`iliasDbPassword`/`mariadbRootPassword` instead of renaming the keys — they default to `ilias-root-password`/`ilias-db-password`/`mariadb-root-password`.

### `autoSetup` — warning

With `autoSetup: "1"`, the container entrypoint checks on **every** start whether the `settings` table exists: if it's empty, a **fresh install** runs (risk if the DB is accidentally empty or misconnected); if ILIAS is already installed, `cli/setup.php update -y` runs automatically without manual confirmation. So keep it at `"0"` in normal operation, and only set it to `"1"` briefly for the initial install/update, then reset it.

## Components

| Pod | Description |
|-----|-------------|
| `ilias-mariadb` | MariaDB, version pinned via `images.mariadb.tag`, data in a PVC |
| `ilias` | ILIAS web server (Apache + PHP), mounts the `ilias-public` and `ilias-data` PVCs |
| `ilias-cron` | ILIAS cron daemon, shares volumes with `ilias` |
| `ilias-ilserver` | ILIAS Java server, only reachable internally (`ilias-ilserver:11111`), used for certificate/PDF generation. Optional — can be disabled via `ilserver.enabled` (default `true`) if certificate/PDF generation isn't needed. See below for configuring the ilserver connection. |

`ilias` and `ilias-cron` each have a `wait-for-db` init container that polls via `mariadb -e "SELECT 1"` until MariaDB is reachable before the actual container starts — avoids failed attempts when all pods start at the same time.

### Configuring the ilserver connection

Host/port for the ilserver can **not** be configured via the ILIAS admin UI (that form was removed in ILIAS 11) — they have to be set directly as rows in the `settings` table after the initial install:

```bash
mariadb -u "$MYSQL_USER" -p"$MYSQL_PASSWORD" "$MYSQL_DATABASE" -e "
  DELETE FROM settings WHERE module='common' AND keyword IN ('rpc_server_host','rpc_server_port');
  INSERT INTO settings (module, keyword, value) VALUES
    ('common','rpc_server_host','ilias-ilserver'),
    ('common','rpc_server_port','11111');
"
```

## Health check

ILIAS ships no built-in, lightweight health-check endpoint. The chart therefore mounts its own minimal [`chart/health/health.php`](chart/health/health.php) (returns `HTTP 200`, no DB access etc.) via a ConfigMap under `/health.php` in the `ilias` container, and uses it for the startup, readiness, and liveness probes.
You can use this endpoint as an availability check too.

## Branding

ILIAS's default skin has no values-driven way to swap the header logo or inject custom CSS — doing so otherwise means maintaining a custom image or patching files into a running container by hand. This chart provides that as an optional, values-only mechanism instead, without shipping any branding content of its own.

Custom branding (header icons + CSS override) is disabled by default — the chart itself ships no branding assets. Enable it purely via values:

| Key | Description |
|-----|-------------|
| `branding.enabled` | `false` (default) = no branding mechanism is rendered, original ILIAS icons/CSS stay unchanged |
| `branding.headerIconSvg` / `branding.headerIconResponsiveSvg` | Raw SVG content, replaces the ILIAS default header icons |
| `branding.css` | CSS appended to the ILIAS default `delos.css` |

With `enabled: true`, the `build-delos-css` init container builds the final CSS at pod startup: the original `delos.css` is extracted from the ILIAS image and merged with `branding.css` (the result lands in an `emptyDir`, which is then mounted as `delos.css`); the icons are mounted over the default icons via a ConfigMap rendered from the values above. Since the values are passed as regular Helm values, your own logos/CSS stay outside this public chart repo (e.g. in a private `HelmRelease`).

## Persistent Volumes

Container-internal UIDs matter when manually copying data into these volumes from outside the container.

| Volume | Used by → mountpoint | Container user (UID) | Default size |
|--------|-----------------------|----------------------|--------------|
| `mariadb-data` | `ilias-mariadb` → `/var/lib/mysql` | mysql (999) | 5Gi |
| `ilias-public` | `ilias`, `ilias-cron` → `/var/www/html/public/data`; `ilias-ilserver` (read-only) → `/app/data` | www-data (33) | 5Gi |
| `ilias-data` | `ilias`, `ilias-cron` → `/var/iliasdata/ilias`; `ilias-ilserver` (read-only) → `/app/iliasdata` | www-data (33) | 50Gi |

## License

[Apache License 2.0](LICENSE).
