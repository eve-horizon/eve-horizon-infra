# Security Policy

## Reporting a Vulnerability

Please **do not** open public GitHub issues for security vulnerabilities.

Report them privately via **[GitHub Private Vulnerability Reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)**
(the "Report a vulnerability" button on the repository's **Security** tab), or by
email to **security.com**.

Please include:

- A description of the issue and its impact.
- Steps to reproduce (proof-of-concept if available).
- Affected versions / components.

We aim to acknowledge reports within **5 business days** and to provide a
remediation timeline after triage.

## Scope

This repository is the **infrastructure template** for self-hosting Eve Horizon
(Kubernetes manifests, Terraform modules, and the `eve-infra` operational CLI).
Of particular interest:

- Manifests or Terraform that would provision insecure defaults.
- Leaked credentials, account identifiers, or instance-specific state in the
  template (it is meant to be generic — values like hostnames, ARNs, bucket
  names, and IPs should be placeholders, not real infrastructure).
- Privilege-escalation paths in the deploy workflows or `eve-infra` CLI.

For vulnerabilities in the Eve Horizon platform itself, report against the
`eve-horizon` repository.
