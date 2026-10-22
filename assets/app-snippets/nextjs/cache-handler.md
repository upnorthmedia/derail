# ISR and the Next.js cache on multiple Fargate tasks

On Vercel, ISR pages and `revalidateTag()` are backed by a shared, globally purged cache. Self-hosted,
each ECS task keeps its own in-memory (50 MB) + disk cache, so with two tasks a revalidation only
refreshes the task that handled the request, and CloudFront keeps its copy until `s-maxage` expires.

Pick one of these, in order of simplicity:

1. **Disable ISR for CMS-driven pages.** `export const dynamic = 'force-dynamic'` (or
   `revalidate = 0`) on those routes and let CloudFront cache with a short TTL via response headers
   (`Cache-Control: public, s-maxage=60, stale-while-revalidate=300`). Zero infrastructure. Good
   default for marketing sites and Payload-driven pages where a 60 s delay is fine.

2. **Shared cache handler on Valkey/Redis.** Enable the `valkey` cache in the Terraform root (ElastiCache
   Serverless Valkey ~ $6/month) and install a maintained handler. As of Oct 2026 the Next.js docs list
   `@trieb.work/nextjs-turbo-redis-cache` (ISR) and `@mrjasonroy/cache-components-cache-handler` (`use cache`);
   `@fortedigital/nextjs-cache-handler` is the maintained lineage of the old neshca handler. Do NOT use
   `@neshca/cache-handler` (unmaintained since 2024). Set `cacheHandler` and `cacheMaxMemorySize: 0` in
   next.config, and also set `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` to the same value on every task of a build.

3. **Move to OpenNext/SST** if ISR semantics matter more than anything else; it ships S3 + DynamoDB +
   SQS caching that behaves like Vercel. See references/aws-target-architecture.md for when that is the right call.

Whatever you choose, `revalidateTag()`/`revalidatePath()` never purge CloudFront. If pages must update
instantly, call `cloudfront:CreateInvalidation` for `/path*` from the same hook (task role permission
`cloudfront:CreateInvalidation` on the distribution ARN; first 1,000 paths/month free).
