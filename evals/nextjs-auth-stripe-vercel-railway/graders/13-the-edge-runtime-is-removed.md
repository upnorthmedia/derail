---
type: llm
focus: trace
weight: 1
---

The edge runtime is removed from the cron route and both vercel.json crons are mapped to EventBridge Scheduler (or an equivalent AWS scheduler) in Terraform
