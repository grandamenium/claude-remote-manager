# Briefing Schedule (All Times PST)

## Core Briefings

| Briefing | Time | Cron | Content |
|----------|------|------|---------|
| Morning Brief | 8:00 AM | 3 8 * * * | Focus areas, calendar, email triage, dev status, action items |
| Midday Sync | 12:00 PM | 4 12 * * * | Done since morning, high-signal emails, next up, blockers. 5-7 bullets max. |
| Evening Wrap | 5:00 PM | 2 17 * * * | Wins, comms summary, open threads, tomorrow's priority |
| Weekly Review | Fri 6:00 PM | 3 18 * * 5 | What worked, metrics, what broke, money moves, lessons |
| Weekly Prep | Sat 2:00 PM | 7 14 * * 6 | North star, calendar, finances, projects, what's off |

## Additional Scheduled Tasks

| Task | Day/Time | Cron | What |
|------|----------|------|------|
| Email Triage | Weekdays 7 AM | 15 7 * * 1-5 | Categorize unread, draft replies |
| Action Items | Weekdays 4 PM | 30 16 * * 1-5 | Check open items, flag overdue (check sent folder first!) |
| Outreach Check | Mon/Wed/Fri 10 AM | 45 10 * * 1,3,5 | Sales prospects only — cross-ref client folders + Gmail before flagging |
| Client Health | Wednesday 9 AM | 0 9 * * 3 | Flag >14 days no contact |
| Pipeline Review | Thursday 3 PM | 15 15 * * 4 | Sales pipeline status |
| Forgot Anything | Friday 11 AM | 30 11 * * 5 | Scan week for dropped threads |
| Stale Check | Sunday 10 AM | 0 10 * * 0 | Knowledge curation |

## Data Sources for All Briefings

Before EVERY briefing, pull fresh:
- **Gmail:** Unread since last briefing (use `after:YYYY-MM-DD` in query)
- **Google Calendar:** All events for the day + upcoming week
- **Git activity:** `git log --oneline -20` across:
  - ~/code/clearpath
  - ~/code/lifecycle-killer
  - ~/code/nonprofit-hub
  - ~/code/knowledge-sync
- **Daily notes:** ~/code/knowledge-sync/daily/$(date +%Y-%m-%d).md
- **Memory files:** ~/.claude/projects/*/memory/*.md (focus on soul.md, feedback_*.md, project_*.md)
- **State file:** ~/code/knowledge-sync/cc/sessions/frank-state.json (pending_tasks, blockers)
- **Active tasks:** ~/code/knowledge-sync/tasks/clearworks/active.md + tasks/personal/active.md
