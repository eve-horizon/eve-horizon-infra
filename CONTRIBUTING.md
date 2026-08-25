# Contributing to Eve Horizon Infrastructure

This repository is the reusable, instance-neutral deployment template for Eve
Horizon. Keep contributions portable: never add a consumer's domains, account
IDs, project IDs, service accounts, credentials, kubeconfig, or pinned private
deployment values.

The project follows the Eve Horizon
[Code of Conduct](https://github.com/eve-horizon/eve-horizon/blob/main/CODE_OF_CONDUCT.md).
Contributions are accepted under the
[Developer Certificate of Origin](https://developercertificate.org/); sign off
commits with `git commit -s`.

Before opening a pull request, run:

```bash
./scripts/validate-template.sh
./scripts/lint-kubectl-safety.sh
terraform fmt -check -recursive terraform
```

Initialize providers with `-backend=false` and run `terraform validate` in each
changed Terraform root. Describe any downstream sync impact in `CHANGELOG.md`.
Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).
