# Agent Guardrails Reference

Frank manages the guardrail system for all Clearworks agents via the Clearpath API (`X-Api-Key` auth).

## Kill Switches

**Pause an agent** (Josh says "pause clearpath-dev" or "stop clearpath-dev"):
```bash
# 1. Write local kill-switch file (fast-checker stops message injection immediately)
mkdir -p ~/.claude-remote/default/agents/clearpath-dev
echo "paused by Frank on Josh's request" > ~/.claude-remote/default/agents/clearpath-dev/kill-switch

# 2. Record in Clearpath DB
curl -s -X POST https://clearpath-production-c86d.up.railway.app/api/guardrails/controls \
  -H "X-Api-Key: $CLEARPATH_API_KEY" -H "Content-Type: application/json" \
  -d '{"agentName":"clearpath-dev","enabled":false,"reason":"paused by Josh","updatedBy":"frank"}'

# 3. Confirm to Josh
bash ../../core/bus/send-telegram.sh $CHAT_ID "clearpath-dev is paused."
```

**Resume an agent** (Josh says "resume clearpath-dev"):
```bash
rm -f ~/.claude-remote/default/agents/clearpath-dev/kill-switch
curl -s -X POST https://clearpath-production-c86d.up.railway.app/api/guardrails/controls \
  -H "X-Api-Key: $CLEARPATH_API_KEY" -H "Content-Type: application/json" \
  -d '{"agentName":"clearpath-dev","enabled":true,"updatedBy":"frank"}'
bash ../../core/bus/send-telegram.sh $CHAT_ID "clearpath-dev is resumed."
```

**Check all agent statuses:**
```bash
curl -s https://clearpath-production-c86d.up.railway.app/api/guardrails/controls \
  -H "X-Api-Key: $CLEARPATH_API_KEY" | jq '.items[] | {agent: .agentName, enabled: .enabled}'
```

## Token Budgets

**Check today's usage:**
```bash
curl -s https://clearpath-production-c86d.up.railway.app/api/guardrails/tokens \
  -H "X-Api-Key: $CLEARPATH_API_KEY" | jq '.items[] | "\(.agentName): \(.tokensUsed)/\(.dailyBudget) (\((.tokensUsed/.dailyBudget*100)|round)%)"'
```

**Set a budget:**
```bash
curl -s -X POST https://clearpath-production-c86d.up.railway.app/api/guardrails/tokens/set-budget \
  -H "X-Api-Key: $CLEARPATH_API_KEY" -H "Content-Type: application/json" \
  -d '{"agentName":"clearpath-dev","dailyBudget":300000}'
```

## Approval Queues

**Check pending approvals:**
```bash
curl -s "https://clearpath-production-c86d.up.railway.app/api/guardrails/approvals?status=pending" \
  -H "X-Api-Key: $CLEARPATH_API_KEY" | jq '.items[]'
```

**Approve/reject:**
```bash
# Approve (id=42)
curl -s -X PATCH https://clearpath-production-c86d.up.railway.app/api/guardrails/approvals/42 \
  -H "X-Api-Key: $CLEARPATH_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"approved","reviewedBy":"frank"}'

# Reject
curl -s -X PATCH https://clearpath-production-c86d.up.railway.app/api/guardrails/approvals/42 \
  -H "X-Api-Key: $CLEARPATH_API_KEY" -H "Content-Type: application/json" \
  -d '{"status":"rejected","reviewedBy":"frank","reviewNote":"Josh declined"}'
```
