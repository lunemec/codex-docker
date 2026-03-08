# Task Breakdown: Clawpocalypse Ops Thread Agent

## Epic A — Contract & Policy

### A1. Define action contract
- **Deliverable:** `specs/clawpocalypse-agent-control-thread/action-schema.md`
- **Actions:** `status`, `add`, `stop`, `restart`, `remount`
- **Fields:** `claw`, `new_mount_path`, `service_name`, `confirm`, `dry_run`
- **DoD:** schema examples for success/failure + validation rules.

### A2. Define mount policy config
- **Deliverable:** `specs/clawpocalypse-agent-control-thread/mount-policy.md`
- Include allowlist prefixes + denylist absolute paths.
- **DoD:** policy can be evaluated non-interactively by script.

---

## Epic B — Toolbelt Implementation

### B1. Create ops script
- **Target file:** `scripts/claw_ops.sh`
- Subcommands:
  - `status <claw|all>`
  - `stop <claw>`
  - `restart <claw>`
  - `remount <claw> <host_path> [--dry-run]`
  - `add <claw> --from-template <profile> [--mount <path>]`
- **DoD:** deterministic stdout/stderr + non-zero exit on failed policy/validation.

### B2. Add compose patch generator
- **Target file:** `scripts/lib/claw_compose_patch.sh`
- Generates/updates `docker-compose.override.yml` instead of editing base compose.
- **DoD:** preserves unrelated services; idempotent output.

### B3. Add safety checks
- **Target files:**
  - `scripts/lib/claw_policy.sh`
  - `scripts/claw_ops.sh`
- Checks:
  - path exists,
  - path readable,
  - path allowed by policy,
  - service/claw known.
- **DoD:** blocked actions return clear reason text.

### B4. Backup + rollback helper
- **Target file:** `scripts/lib/claw_rollback.sh`
- Creates timestamped backups and emits rollback command.
- **DoD:** tested restore for remount and add flows.

### B5. Verification tests
- **Target files:**
  - `scripts/verify_claw_ops_contract.sh`
  - fixture files under `specs/clawpocalypse-agent-control-thread/fixtures/`
- **DoD:** tests cover happy path + policy violation + invalid claw.

---

## Epic C — Clawpocalypse Wiring

### C1. Add ops docs/runbook
- **Target file:** `/workspace/clawpocalypse/specs/agent-control-thread/runbook.md`
- Include examples and incident rollback path.
- **DoD:** operator can perform all v1 actions from documented commands.

### C2. Add ops-thread prompt profile
- **Target location:** `configs/toolbelt/agents/` (new profile for ops thread agent)
- Constrain behavior to action contract + no arbitrary shell.
- **DoD:** prompt explicitly refuses out-of-policy operations.

### C3. Add thread spawn recipe
- **Target file:** `/workspace/clawpocalypse/specs/agent-control-thread/thread-bootstrap.md`
- Include `sessions_spawn` payload template (`runtime: acp`, `thread: true`, `mode: session`, explicit `agentId`).
- **DoD:** one copy-paste recipe creates the persistent ops thread session.

---

## Epic D — E2E Validation

### D1. Dry-run remount of `claw-general`
- Show policy pass + compose diff + no apply.
- **DoD:** dry-run output includes exact apply command.

### D2. Apply remount of `claw-general`
- Stop/recreate target service, verify healthy startup logs.
- **DoD:** `docker compose ps` healthy and OpenClaw reachable.

### D3. Rollback drill
- Revert to previous mount using generated rollback command.
- **DoD:** restored mount path and healthy service.

---

## Suggested Execution Order
1. A1 → A2
2. B1 + B3 (minimal working control path)
3. B2 + B4
4. C1 + C2 + C3
5. B5 + D1 + D2 + D3

## Notes
- Keep v1 intentionally narrow: only lifecycle + remount operations.
- Prefer explicit service names (`claw-general`, etc.) over free-form inputs.
- Ship with dry-run default for remount until confidence is high.
