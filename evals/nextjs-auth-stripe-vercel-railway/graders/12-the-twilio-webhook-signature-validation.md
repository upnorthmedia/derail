---
type: llm
focus: trace
weight: 1
---

The Twilio webhook signature validation is fixed to use the configured public URL instead of req.url, and the Stripe webhook is planned as a dual-registered endpoint with its own signing secret
