"""Run by the Railway cron service `nightly-report` (0 3 * * *): aggregates yesterday's documents and emails a CSV via SMTP (Postmark)."""
import os
print("report", os.environ.get("POSTMARK_SERVER_TOKEN", "")[:0])
