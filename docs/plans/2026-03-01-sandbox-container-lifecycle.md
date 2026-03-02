# Plan: Sandbox Container Lifecycle Control

Status: Proposed

## Goal
Make `sb` manage long-lived sandbox containers predictably so stale and outdated containers do not accumulate, while preserving the current per-directory reuse model.

## Problems
1. Containers are persistent by design (`--restart unless-stopped`), so they pile up unless the operator cleans them up manually.
2. Rebuilding `agent-sandbox:persistent` does not tell existing containers that they are now outdated.
3. `sb sandbox prune` only removes stopped containers. It does not help with running containers created from old images.
4. A directory can be left with a valid label mapping but an invalid runtime shape, which forces ad hoc cleanup.

## Proposal

### 1. Stamp each container with the image it was created from
When `sb` creates a container, add a label:

- `agent-sandbox.image-id=<docker image id>`

This gives `sb` a stable way to distinguish:

- current container on current image
- current container on old image
- malformed container missing expected metadata

### 2. Reconcile lifecycle on every `sb <dir>`
When `sb` resolves the container for a directory:

1. If no container exists, create one.
2. If a container exists but its runtime settings are stale, recreate it.
3. If a container exists but its `agent-sandbox.image-id` differs from the current image ID, recreate it.
4. Otherwise, reuse it.

This keeps the common path automatic. Operators should not need to remember to manually clean a container after every rebuild.

### 3. Add explicit bulk cleanup for outdated containers
Add:

- `sb sandbox rm --outdated`

Behavior:

- remove any sandbox container whose `agent-sandbox.image-id` does not match the current `agent-sandbox:persistent` image
- leave current-image containers alone
- work for both running and stopped containers

This solves a different problem from `--stopped`.

### 4. Keep stopped-container cleanup separate
Retain:

- `sb sandbox prune`
- `sb sandbox rm --stopped`

These commands remain useful for dead containers, but they should not be overloaded to mean "outdated image".

### 5. Surface lifecycle state in status/list output
Extend inspection-oriented commands so stale state is visible:

- `sb <dir> --status` should report whether the container is current or outdated
- `sb sandbox ls` can optionally show image freshness in a later iteration

This is not required for the first implementation, but it would make the system easier to trust.

## Implementation Steps
1. Add helper(s) in `sb` to read the current image ID and read container label values.
2. Label new containers with `agent-sandbox.image-id`.
3. Extend `container_runtime_needs_refresh` or equivalent startup reconciliation to also treat mismatched image IDs as outdated.
4. Add `sb sandbox rm --outdated`.
5. Update help text.
6. Add integration coverage for:
   - recreate on outdated image ID
   - bulk remove outdated containers

## Validation
1. Start a sandbox for a test directory and record its container name and image label.
2. Rebuild the image.
3. Run `sb <dir> --start`.
4. Verify the previous container is replaced by a new one using the rebuilt image ID.
5. Create multiple containers from different image generations and verify `sb sandbox rm --outdated` removes only the older-generation containers.

## Acceptance Criteria
1. A sandbox started before an image rebuild is automatically refreshed on the next `sb <dir>`.
2. Operators can remove old-generation containers in bulk without touching current ones.
3. Stopped-container cleanup and outdated-image cleanup remain separate commands with clear semantics.
