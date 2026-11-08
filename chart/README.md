# ILIAS Helm Chart

Helm chart for deploying [ILIAS](https://www.ilias.de/) LMS on Kubernetes, including MariaDB, ILIAS's scheduled job queue, and optionally the ILIAS Java server (`ilserver`, for certificate generation).

This chart aims to provide a secure and simple deployment of ILIAS, keeping the values you need to set to a minimum. 

One of the main goals of this chart is to run it under the Kubernetes [Restricted Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted). 
The upstream `srsolutions/ilias` image, however, was built with root in mind — it runs as root by default and its entrypoint assumes it throughout. Getting it to run under Restricted PSA anyway means compensating for a few weaknesses in the underlying app and image design with a number of targeted workarounds across the chart. See [Security Measures](#security-measures) below for the full list.

## Installation

Pull the chart directly from the chart package registry as an OCI artifact:

```bash
helm install ilias oci://codeberg.org/pwurbs/charts/ilias --version <chart-version> \
  --namespace ilias --create-namespace \
  -f my-values.yaml
```

Available versions: [codeberg.org/pwurbs/-/packages](https://codeberg.org/pwurbs/-/packages).

## Components

| Pod | Description |
|-----|-------------|
| `ilias-mariadb` | MariaDB, version pinned via `images.mariadb.tag`, data in a PVC |
| `ilias` | ILIAS web server (Apache + PHP), mounts the `ilias-public` and `ilias-data` PVCs |
| `ilias-cron` | Kubernetes `CronJob` that runs ILIAS's job queue directly — sharing volumes with `ilias` |
| `ilias-ilserver` | ILIAS Java server, only reachable internally (`ilias-ilserver:11111`), used for certificate generation. Optional — can be disabled via `ilserver.enabled`. See below for configuring the ilserver connection. |

`ilias`, `ilias-cron` and `ilias-ilserver` share the `ilias-public` and `ilias-data` volumes (ReadWriteOnce) and therefore always run on the same node, enforced by a required pod affinity. The first of them may start on any node, the others follow it.

`ilias` has a `wait-for-db` init container that polls via `mariadb -e "SELECT 1"` until MariaDB is reachable before the actual container starts — avoids failed attempts when all pods start at the same time.

## Configuration

Most important values in [`values.yaml`](values.yaml):

| Key | Description |
|-----|-------------|
| `ilias.httpPath` | Public URL, e.g. `https://ilias.example.com` — required, no default |
| `ilias.autoSetup` | `"0"` = setup/update block in the entrypoint is skipped (default). Only set to `"1"` temporarily for the initial install or a version update — see warning below. |
| `ingress.host` | Ingress hostname — required, no default |
| `storage.*.size` | PVC sizes for MariaDB data, `ilias-public`, `ilias-data` — review before going to production; the default `local-path` StorageClass doesn't support resizing an existing PVC |
| `secrets.existingSecret` | Name of an already existing secret in the cluster (see below); if empty, the chart creates the secret itself |

All other values (timezone, upload size, TLS secret name, resource requests/limits, image tags, ...) have workable defaults — see [`values.yaml`](values.yaml) for the full list and further explanations.

### Secrets

By default (`secrets.existingSecret` empty), the chart generates `ilias-root-password`, `ilias-db-password`, and `mariadb-root-password` itself on first install — no cleartext password ever needs to be set as a value. On every subsequent render, it carries the live values through unchanged. So, as long as nothing rotated them out of band, the rendered Secret is byte-identical to the live one, and the Secret stays a normal, permanent part of every release's manifest. Exception: rendering offline (plain `helm template`, no cluster) always generates fresh, throwaway values instead.
If the Secret already exists but is missing one of the three keys, the chart refuses to render rather than mint a replacement that would no longer match the live MariaDB/ILIAS credentials — see Rotation below for how that can happen and how to recover.

`ilias-root-password` and `mariadb-root-password` are only ever consumed once, at the very first start: MariaDB only applies `MYSQL_ROOT_PASSWORD` when initializing an empty data directory, and ILIAS only applies `ILIAS_ROOT_PASSWORD` (the admin account password) during the initial setup run — later starts read but ignore these. `ilias-db-password` is different: MariaDB applies its `MYSQL_PASSWORD` copy the same first-start-only way, but ILIAS reads its `ILIAS_DB_PASSWORD` copy of the same value live on every start to connect to MariaDB — so a mismatch there breaks connectivity immediately, not just at setup.

Retrieve the generated admin password for the initial login:

```bash
kubectl -n ilias get secret <release-name>-secrets -o jsonpath='{.data.ilias-root-password}' | base64 -d; echo
```
It's also logged in the Ilias container. 

Change it right after logging in the first time in the ILIAS UI — the Secret keeps holding the initial password, which from that point on is no longer relevant.

The secret gets a `helm.sh/resource-policy: keep` annotation as a protection against unintended chart uninstall. Back it up together with the PVCs, though: losing the Secret independently (e.g. reinstalling on top of existing PVCs after a `helm uninstall`) generates a new, mismatched password.

If you'd rather manage the Secret yourself outside of Helm (SOPS, External Secrets Operator, Sealed Secrets, ...), set `secrets.existingSecret` to its name and create it out of band. If your externally managed Secret uses different key names, point the chart at them via `secrets.existingSecretKeys.iliasRootPassword`/`iliasDbPassword`/`mariadbRootPassword`.

#### Password Rotation

Rotating a password means changing it at the source (MariaDB/ILIAS) and in the Secret together, then restarting `ilias`.

If using Flux with `driftDetection: mode: enabled`, then add this to the HelmRelease once, before your first rotation, or step 2 below can race Flux's own drift correction:

```yaml
spec:
  driftDetection:
    mode: enabled
    ignore:
      - paths: ["/data"]
        target:
          kind: Secret
          name: ilias-secrets   # <release-name>-secrets
```

```bash
# 1) Set up: namespace, Secret name, the MariaDB pod (for step 2), and the new password.
NS=ilias; SECRET=ilias-secrets; POD=$(kubectl -n $NS get pod -l app=ilias-mariadb -o jsonpath='{.items[0].metadata.name}')
NEW=$(openssl rand -hex 24)

# 2) Change it at the source. Rotates ilias-db-password. To rotate
#    mariadb-root-password instead, replace the ALTER USER line below with:
#      ALTER USER 'root'@'%' IDENTIFIED BY '$NEW';
#      ALTER USER 'root'@'localhost' IDENTIFIED BY '$NEW';
kubectl exec -i -n "$NS" "$POD" -- sh -c 'mariadb -uroot -p"$MARIADB_ROOT_PASSWORD"' <<EOF
ALTER USER 'ilias'@'%' IDENTIFIED BY '$NEW';
EOF

# 3) Patch the Secret to match (use key mariadb-root-password instead, if that's
#    the one you rotated in step 2).
kubectl patch secret "$SECRET" -n "$NS" --type merge \
  -p "{\"stringData\":{\"ilias-db-password\":\"$NEW\"}}"

# 4) Restart ilias so it picks up the new value. Rotated mariadb-root-password
#    instead? Restart deployment/ilias-mariadb too — its own healthcheck probes
#    read that same password from their env, which is just as stale otherwise.
kubectl rollout restart deployment/ilias -n "$NS"

# 5) Flux only: capture the new value into a release now instead of waiting for the
#    next regular reconcile.
flux reconcile hr ilias -n "$NS" --force

unset NEW
```

Don't do a `helm rollback` to a revision from before a rotation — its Secret still holds the password you just replaced.

### Cron technical user

`ilias-cron` runs `cli/cron.php run-jobs <user> <client_id>`, defaulting to `root`/`default` — the built-in superadmin.

But the user account should be chosen carefully, because some preconditions must be
fulfilled and it directly affects the security posture of your installation.

The account must use the `ILIAS Auth` authentication mode (local auth) and must
be active. This is enforced by ILIAS's underlying authentication chain for any
CLI-executed account. Its password, however, is never actually checked.
Also, cron jobs must not rely on any specific permissions — so the cron account only needs a low-privileged role.

So, we recommend to create a dedicated cron-user (instead of using root), assign a low-privileged role and set this account name in the chart values.

### autoSetup

With `autoSetup: "1"`, the container entrypoint checks on **every** start whether the `settings` table exists: if it's empty, a **fresh install** runs (risk if the DB is accidentally empty or misconnected); if ILIAS is already installed, `cli/setup.php update -y` runs automatically without manual confirmation. So keep it at `"0"` in normal operation, and only set it to `"1"` briefly for the initial install/update, then reset it.

### Branding

ILIAS's default skin has no values-driven way to swap the header logo or inject custom CSS — doing so otherwise means maintaining a custom image or patching files into a running container by hand. This chart provides that as an optional, values-only mechanism instead, without shipping any branding content of its own.

Custom branding (header icons + CSS override) is disabled by default — the chart itself ships no branding assets. Enable it purely via values:

| Key | Description |
|-----|-------------|
| `branding.enabled` | `false` (default) = no branding mechanism is rendered, original ILIAS icons/CSS stay unchanged |
| `branding.headerIconSvg` / `branding.headerIconResponsiveSvg` | Raw SVG content, replaces the ILIAS default header icons |
| `branding.css` | CSS appended to the ILIAS default `delos.css` |

With `enabled: true`, the `build-delos-css` init container builds the final CSS at pod startup: the original `delos.css` is extracted from the ILIAS image and merged with `branding.css` (the result lands in an `emptyDir`, which is then mounted as `delos.css`); the icons are mounted over the default icons via a ConfigMap rendered from the values above. Since the values are passed as regular Helm values, your own logos/CSS stay outside this public chart repo (e.g. in a private `HelmRelease`).

### Reverse Proxy Client IP

ILIAS reads `$_SERVER['REMOTE_ADDR']` directly wherever it logs or checks the client IP and has no `X-Forwarded-For` support of its own — and the vendor image's Apache doesn't rewrite it either. Behind a reverse proxy (e.g. Traefik/an Ingress controller), that means ILIAS always sees the proxy's own pod IP instead of the real client IP — even if the proxy sets `X-Forwarded-For` correctly.

This chart can fix that via Apache's `mod_remoteip`, which rewrites `REMOTE_ADDR` from `X-Forwarded-For` before PHP sees it. `trustedIPs` are configured as `RemoteIPInternalProxy` so the directive walks the full proxy chain, stopping at the first hop outside `trustedIPs`, so a client still can't spoof its own `X-Forwarded-For`.

The feature is disabled by default; see `reverseProxy` in `values.yaml` for the keys. When enabling it, set `trustedIPs` to a sensible value. Take into account that any device within this list should be trustworthy.

### Persistent Volumes

Container-internal UIDs matter when manually copying data into these volumes from outside the container.

Every pod sets `fsGroup` to its container's group (33 or 999) with `fsGroupChangePolicy: OnRootMismatch`, so the volumes are writable even when a new volume belongs to root, as with most block storage. If the top directory of a volume has a different group, for example on an existing `local-path` volume, kubelet changes the group of all files on it once at the next start.

| Volume | Used by → mountpoint | Container user (UID) | Default size |
|--------|-----------------------|----------------------|--------------|
| `mariadb-data` | `ilias-mariadb` → `/var/lib/mysql` | mysql (999) | 5Gi |
| `ilias-public` | `ilias`, `ilias-cron` → `/var/www/html/public/data`; `ilias-ilserver` (read-only) → `/app/data` | www-data (33) | 5Gi |
| `ilias-data` | `ilias`, `ilias-cron` → `/var/iliasdata/ilias`; `ilias-ilserver` (read-only) → `/app/iliasdata` | www-data (33) | 50Gi |

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
runAsGroup: 33   # (matches www-data/mysql, see "Persistent Volumes" above)
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

**Optional user namespace:** `hostUsers: false` runs all pods in their own Linux user namespace — the container UIDs (33, 999) map to unprivileged, pod-unique UIDs on the node, which limits the impact of a container escape. Existing data on the PVCs stays accessible (idmapped mounts), and the UIDs in [Persistent Volumes](#persistent-volumes) remain the ones to use when copying data in. Not part of the Restricted standard, so opt-in: requires Kubernetes 1.33+, Linux kernel 6.3+ and a recent container runtime (containerd 2.x or CRI-O, runc 1.2+ or crun); pods fail to start on nodes without support.

`readOnlyRootFilesystem` is left `false` (not required by the Restricted standard) because the vendor entrypoint writes several config files directly to the container's root filesystem at every start. Most of the `emptyDir` mounts this would need already exist (added above for the non-root fixes); what's still missing is a handful of other paths — `/var/www/html/ilias.ini.php` itself, Apache's own runtime directories (`/var/run/apache2`, `/tmp`), MariaDB's `/run/mysqld`/`/tmp`. Treated as a separate, optional hardening step, not needed for Restricted PSA compliance.

## Configuring the ilserver connection

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

ILIAS ships no built-in, lightweight health-check endpoint. The chart therefore mounts its own minimal [`health/health.php`](health/health.php) (returns `HTTP 200`, no DB access etc.) via a ConfigMap under `/health.php` in the `ilias` container, and uses it for the startup, readiness, and liveness probes.
You can use this endpoint as an availability check too.

## License

[Apache License 2.0](../LICENSE)
