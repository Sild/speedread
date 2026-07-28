# Contributing to SpeedRead

Thank you for helping improve SpeedRead. Bug reports, focused feature proposals,
documentation fixes, accessibility improvements, and tested code changes are
welcome.

## Before you start

- Search existing issues and pull requests.
- Open an issue before a large product, architecture, dependency, or storage
  change.
- Do not attach copyrighted publications, Apple account details, signing
  material, device identifiers, or other personal data.
- Report vulnerabilities privately according to [SECURITY.md](SECURITY.md).

## Development setup

SpeedRead requires macOS, Xcode 26.6, and an iOS simulator runtime. Bootstrap
the pinned command-line tools and generate the project:

```sh
make bootstrap
make generate
```

`project.yml` is the source of truth for `SpeedRead.xcodeproj`. Project
generation must not leave an unreviewed diff.

## Making a change

Keep changes focused and follow the architecture, concurrency, data, testing,
and accessibility rules in [AGENTS.md](AGENTS.md). Add deterministic tests for
project-owned behavior and failure paths. Do not add analytics, advertising,
accounts, or a custom backend.

Use the narrowest relevant checks while developing. Before opening a pull
request, run:

```sh
make format-check
make lint
make test
make project-check
```

Project or release-surface changes should also run `make archive-check`.
Physical devices, signing credentials, and App Store access are not required
for contributions.

## Pull requests

Explain the behavior change, link relevant issues, and list the exact validation
that ran. Include screenshots for visual changes and describe accessibility
effects. By contributing, you agree that your contribution is licensed under
the repository's [Apache License 2.0](LICENSE).
