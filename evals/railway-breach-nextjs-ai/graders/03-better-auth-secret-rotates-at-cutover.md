---
type: llm
focus: trace
weight: 1
---

BETTER_AUTH_SECRET is NOT kept identical through cutover: the plan and runbook rotate it at the cutover minute, invalidate existing sessions (users log in again), and do not leave the leaked value valid for signing after traffic resumes (a decryption-only entry for the OAuth tokens encrypted with encryptOAuthTokens is acceptable if stated as such)
