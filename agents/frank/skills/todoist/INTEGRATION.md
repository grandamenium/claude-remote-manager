# Todoist Integration

## API Configuration

- **Base URL:** https://api.todoist.com/api/v1/
- **Auth:** Bearer token from `.env` as `TODOIST_API_TOKEN`
- **Version:** API v1

## Projects

| Project | ID | Purpose |
|---------|----|---------|
| Clearworks | 6f7vp9GfP7xXhVfj | Business operations and client work |
| Josh Personal | 6fCVMRhWm3pPhr5p | Personal tasks and life management |
| Logic TCG | 6fCVMQxCj2CRpgV8 | TCG/hobby projects (RRK, card games, etc) |
| Frank CoS | 6gG222cVh8qc5JCV | Agent fleet management and autonomous tasks |

## Write-Through Protocol

When Josh tells you ANYTHING actionable:

1. **Write to active-tasks.md FIRST**
2. **Route by category:**
   - Personal items → `tasks/personal/active.md` + Todoist Josh Personal
   - Business items → `tasks/clearworks/active.md` + Todoist Clearworks
   - Decisions/corrections → save to `~/.claude/projects/.../memory/` files
3. **THEN respond** with confirmation

**Never save task-only. Always:** Write file FIRST, then Todoist, then acknowledge.

## Task Commands

| Pattern | Action |
|---------|--------|
| "add [X] to tasks" / "task: [X]" / "remember to [X]" | Write to active-tasks.md + Todoist, confirm |
| "what's open" / "task status" | Send Urgent + Waiting On sections from active-tasks |
| "orders" | Send tasks/personal/active.md Orders section |
| "milestones" / "what's due this week" | Filter active-tasks.md Milestones to current week |
| "mark [X] done" / "[X] is done" | Check off + complete in Todoist, confirm |
| "status of [project]" | Summarize project status in 3-5 lines from active-tasks |
| "catch me up" | Daily note + active-tasks.md changes since last briefing |

## Confirmation Pattern

**Always confirm with exact wording:**
- Add: "Added to tasks: [exact text]"
- Complete: "Marked done: [exact text]"
- Move: "Moved to [section]: [exact text]"

Never silently succeed. Josh should see exactly what was added/changed.

## Todoist API Usage

```bash
# Create task
curl -X POST "https://api.todoist.com/api/v1/tasks" \
  -H "Authorization: Bearer $TODOIST_API_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"content":"Task name","project_id":"PROJECT_ID","priority":4}'

# List tasks
curl "https://api.todoist.com/api/v1/tasks?project_id=PROJECT_ID" \
  -H "Authorization: Bearer $TODOIST_API_TOKEN"

# Complete task
curl -X POST "https://api.todoist.com/api/v1/tasks/{task_id}/close" \
  -H "Authorization: Bearer $TODOIST_API_TOKEN"
```
