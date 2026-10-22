// Payload CMS 3.x: adapter swaps for AWS. Replace @payloadcms/db-vercel-postgres with db-postgres and
// @payloadcms/storage-vercel-blob with storage-s3. Both old packages can be uninstalled afterwards.
import { buildConfig } from 'payload'
import { postgresAdapter } from '@payloadcms/db-postgres'
import { s3Storage } from '@payloadcms/storage-s3'
import sharp from 'sharp'
import fs from 'node:fs'

const rdsCa = process.env.RDS_CA_BUNDLE_PATH ? fs.readFileSync(process.env.RDS_CA_BUNDLE_PATH).toString() : undefined

export default buildConfig({
  secret: process.env.PAYLOAD_SECRET!, // keep the SAME value as on Vercel through cutover, rotate later
  serverURL: process.env.NEXT_PUBLIC_SERVER_URL, // https://app.example.com (used for absolute URLs/emails)
  sharp,

  db: postgresAdapter({
    pool: {
      connectionString: process.env.DATABASE_URL,
      max: 10, // per task; 2 tasks x 10 is far below db.t4g.micro's ~80 max_connections
      // RDS PostgreSQL 15+ enforces TLS (rds.force_ssl=1). verify-full with the RDS CA bundle is the
      // safe setting; download it in the Dockerfile from https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
      ssl: rdsCa ? { ca: rdsCa, rejectUnauthorized: true } : { rejectUnauthorized: false },
    },
    push: false, // production: migrations only (`payload migrate` as a one-off ECS task before rollout)
    migrationDir: './src/migrations',
  }),

  plugins: [
    s3Storage({
      enabled: Boolean(process.env.S3_BUCKET),
      collections: {
        media: {
          prefix: 'media', // must equal the Blob pathname prefix used by scripts/blob_to_s3.ts (S3_PREFIX)
          // Serve public assets straight from CloudFront instead of proxying through Next.js.
          generateFileURL: ({ filename, prefix }) =>
            `https://${process.env.MEDIA_HOST}/${[prefix, filename].filter(Boolean).join('/')}`,
          disablePayloadAccessControl: true,
        },
      },
      bucket: process.env.S3_BUCKET!,
      // No `credentials`: the AWS SDK resolves the ECS task role automatically. Never ship access keys.
      config: { region: process.env.AWS_REGION },
      acl: undefined, // bucket has Block Public Access on; CloudFront reads via OAC
      clientUploads: false, // Fargate has no 4.5 MB body limit, keep server-side uploads
    }),
  ],
})
