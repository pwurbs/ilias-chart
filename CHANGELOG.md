# Changelog

## 1.1.1
- `ilias-cron`: completed Jobs are now cleaned up via `ttlSecondsAfterFinished`, keeping fast-completing Job Pods around for less time

## 1.1.0
- Restricted-PSA-compatible `securityContext` for all containers and init containers
- `ilias-cron` now deployed via Kubernetes `CronJob` resource

## 1.0.0
- Initial public release of the chart
