// Not currently deployed anywhere; runs ad hoc from a laptop. Processes queued email digests with Resend.
import { pool } from './db'
async function main() { const { rows } = await pool.query('select id from email_jobs where sent_at is null limit 50'); console.log(rows.length) }
main()
