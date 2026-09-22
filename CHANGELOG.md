# Changelog

## 1.1.3
- `secret.yaml`: fixed Flux drift-correction failing after a manual credential rotation

## 1.1.2
- `cron.user`/`cron.clientId` values added — `run-jobs` login and client ID are now configurable instead of hardcoded to `root`/`default`

## 1.1.1
- `ilias-cron`: `successfulJobsHistoryLimit`/`failedJobsHistoryLimit` reduced from 3 to 1

## 1.1.0
- Restricted-PSA-compatible `securityContext` for all containers and init containers
- `ilias-cron` now deployed via Kubernetes `CronJob` resource

## 1.0.0
- Initial public release of the chart
