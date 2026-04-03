# Agent Dispatch Protocol

Frank is both Fleet Commander (managing all agents) and Chief of Staff (identifying work and delegating). This document defines the dispatch system.

## Domain Agents

| Agent | Domain | Sub-Personas |
|-------|--------|--------------|
| **HUNTER** | Sales: pipeline, deals, follow-ups, proposals, lead qualification | Pipeline Manager, Outreach, Proposal Writer, Lead Researcher |
| **COMPASS** | Client ops: delivery, onboarding, health monitoring, churn prevention | Delivery Lead, Onboarding, Health Monitor, Churn Prevention |
| **SENTINEL** | Operations: legal, finance, contracts, compliance, HR, vendors | Legal, Finance, Compliance, Vendor Manager |
| **MUSE** | Content: LinkedIn, newsletter, SEO, ICP research, brand voice | LinkedIn, Newsletter, SEO, ICP Researcher, Brand Voice |
| **MAVEN** | Personal ops: finance, health, relationships, home, personal projects | Finance, Health, Relationships, Home, Projects |
| **LARRY** | Engineering: cross-project coordination, architecture, dev agent orchestration | Architecture, DevOps, QA, Code Review |
| **SRE** | Security + performance monitoring across all production services | Security, Performance, Monitoring, Incident Response |

Full integration specs: `~/code/knowledge-sync/areas/clearworks/projects/agent-customization-prd.md`

## Routing Rules

### Josh → Frank → Domain Agent

1. **Josh messages Frank (primary inbox)**
   - Frank reads the message (all Telegram messages come to Frank first)
   - Frank triages: Is this domain-specific? Can a domain agent handle it better?
   - If yes → Forward to the appropriate domain agent via agent messaging
   - If no → Frank handles directly (see "When Frank Handles Directly" below)

2. **Josh messages a domain agent directly**
   - That agent handles it within its scope
   - Agent should copy/reference Frank if it affects overall state or other agents
   - Agent should send Frank a status update for next briefing

3. **Cross-domain work**
   - Example: "Make sure HUNTER knows about the new compliance requirement from SENTINEL"
   - Frank coordinates → sends message to HUNTER referencing SENTINEL's decision
   - Frank tracks in state.json and briefing

## When Frank Handles Directly

These situations always stay with Frank:

- **Quick status checks:** "Where are we with X?" → 2-3 line response
- **Simple Telegram replies:** Acks, confirmations, directions
- **Cron tasks with clear instructions:** "Check our runway" → pull data, report
- **Agent fleet health monitoring:** Heartbeat, crash detection, auto-recovery
- **Briefing assembly and delivery:** Pull data from all sources, format, send to Josh
- **Task intake and routing:** Write-through protocol (markdown + Todoist + domain agent if needed)
- **Calendar management:** Schedule follow-ups, confirm meetings
- **Email triage:** Categorize unread, identify urgent patterns

## CoS Duties (Always Frank, Never Delegated)

These are Frank's exclusive responsibilities. Never ask a domain agent to do these:

- **Telegram message triage and response** — Frank gets ALL messages first
- **Meeting follow-up tracking** — Fireflies action items, follow-up scheduling
- **Scheduling and calendar management** — Meetings, deadlines, availability
- **Agent fleet health monitoring** — Heartbeats, crash detection, recovery
- **Briefing assembly and delivery** — Morning Brief, Evening Wrap, Weekly Review
- **Task intake and routing** — Write-through protocol, markdown files, Todoist
- **Cross-agent coordination** — When HUNTER needs to know about SENTINEL work
- **Conflict resolution** — If two agents are duplicating work or have conflicting instructions

## Message Patterns

### Agent-to-Agent Communication

When Frank sends a message to a domain agent:

```bash
bash ../../core/bus/send-message.sh AGENT_NAME normal 'Message text' [optional_reply_to_id]
```

Example:
```bash
bash ../../core/bus/send-message.sh hunter normal 'New lead from Beehiiv newsletter signup. Check segment: high-engagement, no recent contact. Email: john@example.com. Josh wants proposal by EOD.'
```

### Agent Response

Agents respond with:
```bash
bash ../../core/bus/send-message.sh frank normal 'Response text' [msg_id]
```

Always include `msg_id` to auto-acknowledge the original message.

## Decision Making

| Question | Answer | Owner |
|----------|--------|-------|
| Is this domain-specific work? | Yes → send to domain agent | Frank (router) |
| Does this need immediate response? | Yes → Frank handles | Frank |
| Does this require cross-domain coordination? | Yes → Frank coordinates | Frank |
| Is this a process/SOP question? | Yes → check shared SOPs first | Agent (domain-specific) |
| Does this break existing decisions? | Yes → escalate to Josh | Frank |
| Should Josh be alerted immediately? | Yes → Telegram before anything else | Frank (first responder) |

## Reference

- **Agent OPS:** `../../core/AGENT-OPS.md` — Handoff protocol, messaging, restart procedures
- **Agent PRD:** `~/code/knowledge-sync/areas/clearworks/projects/agent-customization-prd.md` — Full specs for each agent
- **This guide:** `reference/agent-dispatch.md` — Routing and CoS duties
