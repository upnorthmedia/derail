// Better Auth 1.7.x behind ALB / CloudFront.
import { betterAuth } from 'better-auth'
import { Pool } from 'pg'

export const auth = betterAuth({
  // Always set the base URL explicitly (the docs warn against inferring it from the request).
  // Multi-host (prod + staging from one image): baseURL: { allowedHosts: [...], protocol: 'https', fallback: '...' }
  baseURL: process.env.BETTER_AUTH_URL, // https://app.example.com
  // Versioned secrets allow zero-downtime rotation later: BETTER_AUTH_SECRETS="2:new,1:old".
  secret: process.env.BETTER_AUTH_SECRET,

  database: new Pool({
    connectionString: process.env.DATABASE_URL,
    max: 10,
    ssl: { rejectUnauthorized: true }, // RDS enforces TLS; use the RDS CA bundle (see payload snippet)
  }),

  advanced: {
    useSecureCookies: true,
    // Rate limiting and audit need the real client IP. ALB sets X-Forwarded-For; CloudFront adds a hop.
    ipAddress: { ipAddressHeaders: ['cloudfront-viewer-address', 'x-forwarded-for'] },
    trustedProxyHeaders: true,
  },
  trustedOrigins: [process.env.BETTER_AUTH_URL!],
})

// After cutover: update OAuth redirect URIs (Google/GitHub consoles) to the new host, and run
// `npx auth@latest migrate` (or your ORM migration) against RDS from a one-off ECS task, not a laptop.
