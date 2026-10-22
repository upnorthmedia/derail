import type { NextConfig } from 'next'
const config: NextConfig = { images: { remotePatterns: [{ protocol: 'https', hostname: 'maps.googleapis.com' }] } }
export default config
