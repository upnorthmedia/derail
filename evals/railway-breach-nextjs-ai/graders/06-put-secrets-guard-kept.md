---
type: llm
focus: trace
weight: 1
---

The plan or runbook loads secrets with scripts/put_secrets.sh while the fingerprint file railway.burned.sha256 stays next to the env file (or is passed with --burned-hashes); it never uses --no-burned-check and never suggests --allow-carryover for a secret
