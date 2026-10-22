import { buildConfig } from 'payload'
import { vercelPostgresAdapter } from '@payloadcms/db-vercel-postgres'
import { vercelBlobStorage } from '@payloadcms/storage-vercel-blob'
import { seoPlugin } from '@payloadcms/plugin-seo'
import sharp from 'sharp'
import { revalidatePath } from 'next/cache'

export default buildConfig({
  secret: process.env.PAYLOAD_SECRET || '',
  serverURL: process.env.NEXT_PUBLIC_SERVER_URL,
  sharp,
  db: vercelPostgresAdapter({ pool: { connectionString: process.env.DATABASE_URL }, push: false, migrationDir: './src/migrations' }),
  collections: [
    { slug: 'pages', fields: [{ name: 'title', type: 'text' }, { name: 'content', type: 'richText' }],
      hooks: { afterChange: [({ doc }) => { revalidatePath(`/${doc.slug}`) }] } },
    { slug: 'media', upload: true, fields: [{ name: 'alt', type: 'text' }] },
    { slug: 'users', auth: true, fields: [] },
  ],
  plugins: [
    vercelBlobStorage({ collections: { media: { prefix: 'media' } }, token: process.env.LUMEN_BLOB_READ_WRITE_TOKEN || '' }),
    seoPlugin({}),
  ],
})
