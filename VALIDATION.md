# Validation

Initial release validation (2026-10-16):

- SKILL.md frontmatter and packaging: skill-creator validator passed.
- macOS: shell syntax passed; 19 isolated mock behavior tests passed.
- Windows: native Windows PowerShell 5.1 mock lifecycle tests passed on GitHub Actions, covering initial activation, deadline replacement, expiry/reboot decisions, durable preparation, rollback and failed-restoration retry. The first run exposed a null-string interop bug in atomic file replacement; this was fixed and the full suite passed.
- Public tree reviewed for personal paths, device names, account configuration, credentials and private infrastructure. Git history is independent from the personal source.

Neither controller was installed on the development Mac during packaging. Real privileged installation, actual scheduled recovery and physical lid-close behavior are not claimed as verified. Windows mock tests do not touch real power plans or Task Scheduler. See platform references for hardware acceptance steps and recovery limitations.

## First-run setup update (2026-10-16)

- Adds versioned per-user network preferences, explicit setup/configure routing and reuse on subsequent starts. User preferences never enter the public repository.
- macOS config: 6 isolated filesystem tests passed (missing state without writes, Unicode/shell-like SSIDs as data, mode replacement, invalid input preservation, corrupt/future schema preservation, symlink rejection). Existing 19 controller tests and shell syntax checks passed.
- Skill packaging validator passed. Windows configuration tests and the existing mocked controller lifecycle suite passed on native PowerShell 5.1 CI. Both macOS and Windows jobs passed: https://github.com/Hype-yolo/awake-skill/actions/runs/38867693491 .
- No live Wi-Fi switching, privileged installer, Windows UAC, physical lid-close or end-to-end recovery test was performed for this update. Windows still requires elevated power operations; saved preferences do not create passwordless privileges. macOS configuration requires Python 3.
- Configuration writes use temporary files and atomic replacement. They are user preferences, not privileged command inputs; network actions remain host-tool operations with connection readback.

Independent scenario review covered first setup with a supplied hotspot and duration, returning invocation, standard-user Windows setup, status without preferences, corrupted preferences, and a temporary network override. The Windows command examples and corrupt-file recovery instructions were corrected from that review. This was a workflow review, not a live hardware test.
