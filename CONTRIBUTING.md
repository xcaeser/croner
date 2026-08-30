# Contributing to Croner

Thank you for considering a contribution to Croner!

## Getting started

1. Fork the repository and create your branch from `main`.
2. Keep changes focused and follow the existing Zig style.
3. Add or update focused tests for behavior changes.
4. Open a pull request with a concise description and verification steps.

## Development setup

```sh
zig fmt --check .
zig build test --summary all
zig build docs
```

The reusable API lives in the `libcron` module. The root-only `croner` CLI
owns configuration parsing and daemon control; keep those concerns out of the
library. Discuss significant API changes in an issue before opening a pull
request.
