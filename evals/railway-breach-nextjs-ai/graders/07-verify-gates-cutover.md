---
type: llm
focus: trace
weight: 1
---

The runbook runs scripts/breach_check.sh --verify against the fingerprint file before cutover (and again before decommissioning Railway), and treats a non-zero exit as a blocker
