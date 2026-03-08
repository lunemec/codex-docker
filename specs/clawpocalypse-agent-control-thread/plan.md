# Plan (Toolbelt-side): Ops Control Surface for Clawpocalypse

## Objective
Implement a safe automation surface in toolbelt so an Ops thread agent can manage claw lifecycle and remounts without manual compose editing.

## Deliverables
- `scripts/claw_ops.sh` (public command surface)
- `scripts/lib/claw_policy.sh` (mount/path policy)
- `scripts/lib/claw_compose_patch.sh` (override generation)
- `scripts/lib/claw_rollback.sh` (backup/restore helpers)
- `scripts/verify_claw_ops_contract.sh` (contract tests)

## Phases
1. **Contract first:** action schema + policy docs.
2. **MVP commands:** status/stop/restart/remount --dry-run.
3. **Mutation path:** apply remount/add + backup+rollback.
4. **Hardening:** tests + deterministic output + docs.

## Success Criteria
- Ops agent can invoke one script with structured args.
- Unsafe mount requests are blocked pre-apply.
- Every mutating action emits rollback instructions.
