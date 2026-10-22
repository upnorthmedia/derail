// proxy.ts (Next.js 16) or middleware.ts (Next.js 15): a maintenance switch for the cutover window.
// Deploy this to the OLD platform (Vercel/Railway) ahead of time. During cutover set MAINTENANCE_MODE=true
// and redeploy: writes get a 503 so the final database dump is consistent, reads keep working.
import { NextResponse, type NextRequest } from 'next/server'

const MUTATING = new Set(['POST', 'PUT', 'PATCH', 'DELETE'])
const ALWAYS_ALLOW = ['/api/health', '/maintenance']

export function proxy(request: NextRequest) {
  if (process.env.MAINTENANCE_MODE !== 'true') return NextResponse.next()
  const { pathname } = request.nextUrl
  if (ALWAYS_ALLOW.some((p) => pathname.startsWith(p))) return NextResponse.next()

  // Block writes (forms, server actions, API mutations). Reads still work.
  const isServerAction = request.headers.has('next-action')
  if (MUTATING.has(request.method) || isServerAction) {
    return new NextResponse(
      JSON.stringify({ error: 'Maintenance in progress. Please try again in a few minutes.' }),
      { status: 503, headers: { 'content-type': 'application/json', 'retry-after': '600' } },
    )
  }
  return NextResponse.next()
}

// Next 15: `export const middleware = proxy` and keep the file named middleware.ts.
export const config = { matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'] }
