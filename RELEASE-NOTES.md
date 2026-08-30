# Release Notes

## v0.1.0 (Initial Release)

Cron scheduling for Zig, in-process or from a single `croner.json`.

- Parse and evaluate familiar five-field cron expressions.
- Schedule callbacks or direct child processes with `libcron`.
- Control timezones, overlap behavior, and cancellation.
- Manage command jobs with `setup`, `start`, `stop`, `list`, `reload`, and `logs`.
- Validate configurations with the published [JSON Schema](https://xcaeser.github.io/croner/croner.schema.json).

The CLI supports macOS and Linux and schedules jobs in UTC.

`libcron` has no runtime dependencies.
