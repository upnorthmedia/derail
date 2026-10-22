// Shared node-postgres pool for RDS. Replaces PgBouncer transaction pooling from Railway: with one
// long-lived Node process per Fargate task, a small driver pool is all you need (2 tasks x 10 = 20
// connections; db.t4g.micro allows ~80). Remove `?pgbouncer=true` and any DIRECT_URL split for RDS.
import { Pool } from 'pg'
import fs from 'node:fs'

const caPath = process.env.RDS_CA_BUNDLE_PATH // e.g. /app/global-bundle.pem baked into the image
export const pool = new Pool({
  connectionString: process.env.DATABASE_URL,
  max: Number(process.env.PG_POOL_MAX ?? 10),
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
  // RDS PostgreSQL 15+ sets rds.force_ssl=1: TLS is mandatory. verify-full needs the CA bundle.
  ssl: caPath ? { ca: fs.readFileSync(caPath, 'utf8'), rejectUnauthorized: true } : { rejectUnauthorized: false },
})

// Prisma 6: DATABASE_URL="postgresql://...?sslmode=verify-full&sslrootcert=/app/global-bundle.pem&connection_limit=10"
// Drizzle:  drizzle({ client: pool })
// Dockerfile line to bake the bundle:
//   ADD --chown=node:node https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem /app/global-bundle.pem
