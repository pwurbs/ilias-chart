# ILIAS Helm Chart

Helm chart for deploying [ILIAS](https://www.ilias.de/) Learning Management System on Kubernetes, including MariaDB, ILIAS's scheduled job queue, and optionally the ILIAS Java server (`ilserver`, for certificate generation). Built to run under the Kubernetes [Restricted Pod Security Standard](https://kubernetes.io/docs/concepts/security/pod-security-standards/#restricted).

```bash
helm install ilias oci://codeberg.org/pwurbs/charts/ilias --version 1.0.0 \
  --namespace ilias --create-namespace \
  -f my-values.yaml
```

See the [chart documentation](chart/README.md) for configuration, secrets management, security measures, and everything else.

Available chart versions: [codeberg.org/pwurbs/-/packages](https://codeberg.org/pwurbs/-/packages).

## License

[Apache License 2.0](LICENSE)
