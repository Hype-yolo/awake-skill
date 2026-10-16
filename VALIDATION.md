# Validation

Initial release validation (2026-10-16):

- SKILL.md frontmatter and packaging: skill-creator validator passed.
- macOS: shell syntax passed; 19 isolated mock behavior tests passed.
- Windows: native Windows PowerShell 5.1 mock lifecycle tests passed on GitHub Actions, covering initial activation, deadline replacement, expiry/reboot decisions, durable preparation, rollback and failed-restoration retry. The first run exposed a null-string interop bug in atomic file replacement; this was fixed and the full suite passed.
- Public tree reviewed for personal paths, device names, account configuration, credentials and private infrastructure. Git history is independent from the personal source.

Neither controller was installed on the development Mac during packaging. Real privileged installation, actual scheduled recovery and physical lid-close behavior are not claimed as verified. Windows mock tests do not touch real power plans or Task Scheduler. See platform references for hardware acceptance steps and recovery limitations.
