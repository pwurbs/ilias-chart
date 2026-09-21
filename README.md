# ILIAS Helm Chart

Helm chart for deploying [ILIAS](https://www.ilias.de/) LMS on Kubernetes, including MariaDB, ILIAS's scheduled job queue, and optionally the ILIAS Java server (`ilserver`, for certificate generation).

This chart aims to provide a secure and simple deployment of ILIAS, keeping the values you need to set to a minimum. 

One of the main goals of this chart is to run it under the Kubernetes [Restricted Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted). 
The upstream `srsolutions/ilias` image, however, was built with root in mind — it runs as root by default and its entrypoint assumes it throughout. Getting it to run under Restricted PSA anyway means compensating for a few weaknesses in the underlying app and image design with a number of targeted workarounds across the chart. See [Security](#security) below for the full list.

## Installation

Pull the chart directly from the chart package registry as an OCI artifact:

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

Change it right after logging in — the Secret still holds it in plaintext afterwards, and the underlying `ILIAS_ROOT_PASSWORD` env var is, as explained above, ignored on every start after the first anyway, so changing it in ILIAS itself is strongly recommended and free of side effects.

Note that `lookup` requires a live cluster connection — it works with `helm install`/`upgrade` and with Flux's `helm-controller`, but always generates fresh (throwaway) values when rendering offline, e.g. plain `helm template`.
This stability only holds while the Secret object itself survives: deleting it independently of the PVCs (or reinstalling on top of the same PVCs after a `helm uninstall`) makes the chart generate a new, mismatched password on the next deploy — so back it up together with the PVCs.

If you'd rather manage the Secret yourself outside of Helm (SOPS, External Secrets Operator, Sealed Secrets, ...), set `secrets.existingSecret` to its name and create it out of band.

```bash
kubectl -n ilias create secret generic ilias-secrets \
  --from-literal=ilias-root-password="<...>" \
  --from-literal=ilias-db-password="<...>" \
  --from-literal=mariadb-root-password="<...>"
```

If your externally managed Secret uses different key names, point the chart at them via `secrets.existingSecretKeys.iliasRootPassword`/`iliasDbPassword`/`mariadbRootPassword` instead of renaming the keys — they default to `ilias-root-password`/`ilias-db-password`/`mariadb-root-password`.

The same drift risk described above applies here too — it's now on you to keep its values in sync with what's actually configured in MariaDB/ILIAS.

### Cron technical user

`ilias-cron` runs `cli/cron.php run-jobs <user> <client_id>` (`cron.user`/`cron.clientId` in
`values.yaml`, defaulting to `root`/`default` — the built-in superadmin, for out-of-the-box
compatibility). ILIAS requires the cron `<user>` to have `auth_mode=local` and `active=1` — the same
requirement a normal web login has — but needs no RBAC role/permissions: ILIAS's Cron component
contract forbids cron job implementations from relying on permissions, and this holds up in
ILIAS's own core cron jobs (mail notifications, certificates, StudyProgramme progress, ...), which
operate through repository classes that bypass the RBAC layer entirely regardless of which user
runs them.

**Recommended hardening (opt-in, not the chart default):** point `cron.user` at a dedicated,
permission-less account instead of `root`. Because `auth_mode=local`+`active=1` makes an account
reachable through the normal web login form, using `root` for cron permanently forces the
superadmin account to stay locally-authenticatable and active — you can't deactivate it or move it
to SSO-only without breaking cron. A dedicated account limits what a compromised password can
reach, and since cron doesn't check RBAC, a low-privilege role (e.g. the built-in Guest role) works
just as well as any other. This is a per-deployment decision, not a chart default, because it
requires manually creating that account first:

### `autoSetup` — hint

With `autoSetup: "1"`, the container entrypoint checks on **every** start whether the `settings` table exists: if it's empty, a **fresh install** runs (risk if the DB is accidentally empty or misconnected); if ILIAS is already installed, `cli/setup.php update -y` runs automatically without manual confirmation. So keep it at `"0"` in normal operation, and only set it to `"1"` briefly for the initial install/update, then reset it.

## Components

| Pod | Description |
|-----|-------------|
| `ilias-mariadb` | MariaDB, version pinned via `images.mariadb.tag`, data in a PVC |
| `ilias` | ILIAS web server (Apache + PHP), mounts the `ilias-public` and `ilias-data` PVCs |
| `ilias-cron` | Kubernetes `CronJob` that runs ILIAS's job queue directly — sharing volumes with `ilias` |
| `ilias-ilserver` | ILIAS Java server, only reachable internally (`ilias-ilserver:11111`), used for certificate generation. Optional — can be disabled via `ilserver.enabled`. See below for configuring the ilserver connection. |

`ilias` has a `wait-for-db` init container that polls via `mariadb -e "SELECT 1"` until MariaDB is reachable before the actual container starts — avoids failed attempts when all pods start at the same time.

## Security Measures

To satisfy the restrictions of the Kubernetes [Restricted Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted) — the following measures are required.

Every container and init container sets an explicit, non-root `securityContext`:

```yaml
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
privileged: false
readOnlyRootFilesystem: false
runAsNonRoot: true
runAsUser: 33    # or 999 for mariadb itself
runAsGroup: 33   # (matches www-data/mysql, see "Persistent Volumes" below)
seccompProfile:
  type: RuntimeDefault
```

In short:

- **Port 80** (`ilias`): a pod-level sysctl (`net.ipv4.ip_unprivileged_port_start: "80"`) lets `www-data` bind it directly. No root and no added `NET_BIND_SERVICE` capability is required. Only port 80 itself is unlocked, ports 1–79 stay privileged.
- **Two root-owned config files** the entrypoint writes on every start (`/etc/cron.d/ilias`, `/usr/local/etc/php/conf.d/ilias.ini`) are redirected via `subPath` onto a small `emptyDir`, pre-created as real files by an init container's `touch` — a `subPath` target that doesn't already exist in the volume would otherwise be created as a directory by kubelet, not a file, breaking the entrypoint's write. Applies to both `ilias` and `ilias-cron`.
- **`su www-data` inside the vendor entrypoint** (used for the install/update step) is neutralized by shadowing `su` with a shell function for that one shell session: since the container already *is* `www-data`, source and target user are identical, but the real `su` still goes through PAM, which needs a root caller or a password `www-data` (a service account) doesn't have. The function just execs the given command directly; the entrypoint itself — and all its install/update/config-generation logic — stays completely unmodified.
- **`ilias-cron`** runs as a real Kubernetes `CronJob` instead of a long-running container with the image's own `cron` daemon, which fundamentally requires root (reads root-owned `/etc/cron.d`, `setuid`s to run jobs). Its container still needs the image entrypoint to run first (it writes `ilias.ini.php`, without which `cli/cron.php` can't even boot) — so it uses `args`, not a `command` override, plus its own copy of the DB/HTTP env vars and the same `/etc/cron.d`/`conf.d` `emptyDir` fix as `ilias`.
- **`ilserver`**: its own entrypoint rewrites `/app/ilias.ini.php`/`/app/ilServer.properties` on every start (same `emptyDir` + init-container-`touch` fix as above for those two files) and needs a writable Lucene index directory (`/var/lucenedata/ilias`) — that one's a plain `emptyDir` mounted as a whole directory, no `subPath` involved, so no pre-creation is needed there.
- **`wait-for-db`** (in `ilias`) uses the ilias image rather than the mariadb image — both bundle the `mariadb` CLI client, but this way the init container runs as the same UID as `ilias` itself, so the files it pre-creates need no special group permissions to be writable by the main container afterwards.
- **`mariadb`**: the official image already supports running non-root out of the box (it detects a non-root UID and skips its root-only setup path) — just needed the `securityContext`, nothing else.

`readOnlyRootFilesystem` is left `false` (not required by the Restricted standard) because the vendor entrypoint writes several config files directly to the container's root filesystem at every start. Most of the `emptyDir` mounts this would need already exist (added above for the non-root fixes); what's still missing is a handful of other paths — `/var/www/html/ilias.ini.php` itself, Apache's own runtime directories (`/var/run/apache2`, `/tmp`), MariaDB's `/run/mysqld`/`/tmp`. Treated as a separate, optional hardening step, not needed for Restricted PSA compliance.

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

[Apache License 2.0](LICENSE)
