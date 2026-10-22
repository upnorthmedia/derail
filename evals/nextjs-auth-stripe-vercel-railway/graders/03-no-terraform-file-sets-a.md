---
type: llm
focus: trace
weight: 1
---

No Terraform file sets a plaintext database password or secret value (RDS uses manage_master_user_password or a write-only argument; no `secret_string =` with a literal)
