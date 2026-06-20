# Security Policy

MacActivity handles local system metrics and cleanup actions. Security and
privacy-sensitive reports should be handled privately.

## Supported Versions

Until MacActivity has a stable public release line, security fixes target the
current `main` branch and the latest published release or prerelease artifact.

Older prerelease artifacts are supported only when the issue still reproduces on
current `main` or the latest available artifact.

## Reporting a Vulnerability

Do not open a public issue with exploit details, private data, crash logs that
contain sensitive paths, or proof-of-concept code.

Preferred reporting path:

1. Use GitHub private vulnerability reporting if it is enabled for this
   repository.
2. If private vulnerability reporting is not enabled, open a minimal public issue
   asking for a private maintainer contact. Do not include technical details in
   that issue.

Include:

- Affected version, commit, or artifact.
- macOS version and hardware architecture.
- Clear reproduction steps.
- Expected and actual security impact.
- Whether the issue involves cleanup deletion scope, launch-at-login behavior,
  local file access, system metrics, app signing, or release artifacts.

## Disclosure

Maintainers should acknowledge reports before public discussion, reproduce the
issue, decide severity, and prepare a fix or mitigation before publishing
detailed vulnerability information.
