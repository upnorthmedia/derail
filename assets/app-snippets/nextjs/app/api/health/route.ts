// app/api/health/route.ts
// The ALB target group and the ECS container health check call this every 15-30 seconds.
// It must: return 200 fast, require no auth, and NOT touch the database (a slow DB would otherwise
// make ECS kill healthy tasks and the circuit breaker roll back good deploys).
// Add a separate /api/ready that checks the DB if you need a deeper probe for dashboards.
export const dynamic = 'force-dynamic'

export function GET() {
  return Response.json(
    { status: 'ok', sha: process.env.GIT_SHA ?? 'unknown', uptime: Math.round(process.uptime()) },
    { headers: { 'cache-control': 'no-store' } },
  )
}
