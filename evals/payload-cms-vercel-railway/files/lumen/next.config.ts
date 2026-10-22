import { withPayload } from '@payloadcms/next/withPayload'
import type { NextConfig } from 'next'

const nextConfig: NextConfig = {
  images: {
    remotePatterns: [{ protocol: 'https', hostname: 'abc123.public.blob.vercel-storage.com' }],
  },
  async redirects() {
    return [{ source: '/old', destination: '/new', permanent: true }]
  },
}

export default withPayload(nextConfig)
