---
type: llm
focus: trace
weight: 1
---

Every exposed credential not yet rotated (database password / DATABASE_PUBLIC_URL, AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY, STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, GITHUB_CLIENT_SECRET) is scheduled to rotate now, before migration work, not on day 1-2 after cutover
