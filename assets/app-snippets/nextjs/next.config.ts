// next.config.ts changes for self-hosting on ECS Fargate behind ALB (+ optional CloudFront).
// Merge into the existing config; do not replace framework-specific options you already have.
import type { NextConfig } from 'next'

const config: NextConfig = {
  // Required: produces .next/standalone with a self-contained server.js (what the Dockerfile copies).
  output: 'standalone',

  // Version-skew protection during rolling ECS deploys: old and new tasks serve different builds for a
  // minute or two; deploymentId makes asset URLs and server actions build-specific.
  deploymentId: process.env.GIT_SHA,
  generateBuildId: async () => process.env.GIT_SHA ?? null,

  // Let CloudFront (if enabled) compress; the ALB does not compress and Node compression costs CPU.
  // Set to true if you do NOT put CloudFront in front.
  compress: process.env.CDN_COMPRESSION !== 'true',

  images: {
    // Add the media CDN host (S3 + CloudFront) and, during the overlap, the old Vercel Blob host.
    remotePatterns: [
      { protocol: 'https', hostname: process.env.MEDIA_HOST ?? 'cdn.example.com' },
      { protocol: 'https', hostname: '*.public.blob.vercel-storage.com' },
    ],
    // Next 16 default is 4h; raise when images are immutable.
    minimumCacheTTL: 14400,
  },

  // Multi-task ISR: each Fargate task has its own in-memory/disk cache. Either disable ISR
  // (force-dynamic + CloudFront s-maxage) or configure a shared cache handler (see cache-handler.md).
  // cacheHandler: require.resolve('./cache-handler.mjs'),
  // cacheMaxMemorySize: 0,

  // Keep native/server-only packages out of the bundle (Payload CMS, pg, sharp).
  serverExternalPackages: ['sharp', 'pg'],
}

export default config
