Helm chart for the ILIAS LMS (ILIAS, MariaDB, cron job, optional Java server `ilserver`), built for
the Kubernetes Restricted Pod Security Standard. Published as OCI chart
`oci://codeberg.org/pwurbs/charts/ilias` and listed on Artifact Hub.

## Docs
- Components, values, secrets, security measures → chart/README.md (ships with the package)
- Release history → CHANGELOG.md

## Every functional change
A change to values, templates or behaviour is done only with all four of these, in the same change:
1. `version` in chart/Chart.yaml bumped — the patch digit, also for new opt-in features.
2. CHANGELOG.md: a new `## <version>` section at the top, one line per change.
3. chart/Chart.yaml `annotations.artifacthub.io/changes`: replaced with this release's entries only
   (`kind: added|changed|fixed|removed`) — Artifact Hub shows it as the current version's changelog.
4. chart/values.schema.json: a block for every new or changed values.yaml key, in the structure of
   the existing sections (`type`, `default`, `description` per leaf).

Docs-only changes need none of this. The install examples use `--version <chart-version>` and need
no update.

## Artifact Hub metadata
Artifact Hub does not read chart/artifacthub-repo.yml from the chart package: for OCI repositories
it reads a separate artifact tagged `artifacthub.io`. After changing the file, push it once:
```bash
oras push codeberg.org/pwurbs/charts/ilias:artifacthub.io \
  --config /dev/null:application/vnd.cncf.artifacthub.config.v1+yaml \
  chart/artifacthub-repo.yml:application/vnd.cncf.artifacthub.repository-metadata.layer.v1.yaml
```
A release without changes to this file doesn't need it.
