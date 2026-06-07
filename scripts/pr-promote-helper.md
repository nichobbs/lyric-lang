# PR Agent Promotion Helper

## Overview

This document describes how Claude agents should check and promote draft PRs when CI passes.

Since webhook events may not fire for successful CI runs, agents should actively poll the PR status instead of waiting for events.

## Agent Workflow

### 1. After Creating a Draft PR

```
create_pull_request(
  owner: "nichobbs",
  repo: "lyric-lang",
  title: "...",
  head: "branch-name",
  base: "main",
  draft: true
)
```

### 2. Subscribe to PR Activity

```
subscribe_pr_activity(
  owner: "nichobbs",
  repo: "lyric-lang",
  pullNumber: <PR_NUMBER>
)
```

This ensures the agent receives webhook events for review comments, CI changes, and other updates.

### 3. Check PR Status (Periodic Poll)

After CI should have completed (typically 5-10 minutes), check the PR status:

```
pull_request_read(
  method: "get_check_runs",
  owner: "nichobbs",
  repo: "lyric-lang",
  pullNumber: <PR_NUMBER>
)
```

This returns all check runs (CI jobs) for the PR's head commit.

### 4. Verify Ready to Promote

Check that:
- **All required checks passed**: Look for `conclusion: "success"` on all checks
- **PR is still in draft**: `pull_request_read(method: "get")` should show `draft: true`
- **No merge conflicts**: Check `mergeable_state` is not `"dirty"`

### 5. Promote to Ready

When all conditions are met:

```
update_pull_request(
  owner: "nichobbs",
  repo: "lyric-lang",
  pullNumber: <PR_NUMBER>,
  draft: false
)
```

This triggers:
1. PR transitions from draft to "ready for review"
2. `claude-review` workflow fires (was waiting for non-draft event)
3. Review analysis begins on validated code

### 6. Log the Action

Output clearly:
```
✓ PR #<N>: All CI checks passed, promoted to ready for review
```

## Implementation Details

### Check Run Status Structure

```javascript
{
  "check_runs": [
    {
      "name": "build-and-test",
      "conclusion": "success",  // success, failure, neutral, etc.
      "status": "completed"      // completed, in_progress, queued
    },
    // ... more checks
  ]
}
```

Only promote when:
- All checks have `status: "completed"`
- All checks have `conclusion: "success"`

### Error Handling

Handle these cases gracefully:

| Situation | Action |
|-----------|--------|
| Some checks still `in_progress` | Reschedule check (not ready yet) |
| A check has `conclusion: "failure"` | Skip promotion, log failure |
| PR already ready (not draft) | Log and skip (no-op) |
| Merge conflicts detected | Skip and note blocker |
| Permission error on promote | Log (may be fork PR) |

### Reschedule Logic

If checks are still in progress:
- Use `/loop` skill or similar to reschedule check in 30-60 seconds
- Don't busy-wait, yield control back
- Maximum retry count (e.g., 10 attempts over ~5 minutes)

## Example: Agent Pseudocode

```
function checkAndPromotePR(owner, repo, pr_number):
  
  // Step 1: Get current PR status
  pr = pull_request_read(method: "get")
  if not pr.draft:
    log("✓ PR already ready, skipping")
    return
  
  // Step 2: Check CI status
  checks = pull_request_read(method: "get_check_runs")
  completed = filter(checks, status == "completed")
  all_passed = all(completed, conclusion == "success")
  
  if len(completed) < len(checks):
    log("⏳ CI still running, will retry in 30s")
    reschedule_in(30_seconds)
    return
  
  if not all_passed:
    failures = filter(checks, conclusion != "success")
    log("✗ CI failed, skipping promotion")
    log_failures(failures)
    return
  
  // Step 3: Promote to ready
  try:
    update_pull_request(draft: false)
    log("✓ PR promoted to ready for review")
  catch 403:
    log("⚠ Permission denied (may be fork)")
  catch error:
    log("✗ Error promoting PR: " + error.message)
```

## Integration with Session

When an agent has an open PR:

1. **Immediately after push**: `subscribe_pr_activity`
2. **5-10 minutes later**: First check (CI should be starting/done)
3. **On each webhook event**: Re-check if promotion is now possible
4. **Periodically** (every 30-60s if in progress): Re-check status

The agent should not block on this check—it can continue with other work and handle promotion asynchronously.

## See Also

- `CLAUDE.md` - Full policy on draft PRs and agent promotion
- GitHub API docs - `mcp__github__pull_request_read`, `mcp__github__update_pull_request`
- PR subscription - `subscribe_pr_activity` for event-driven updates
