import { NextResponse } from 'next/server'
import type { NextRequest } from 'next/server'

export function middleware(req: NextRequest) {
  const country = req.headers.get('x-vercel-ip-country') ?? 'US'
  const res = NextResponse.next()
  res.headers.set('x-country', country)
  return res
}
export const config = { matcher: ['/((?!_next|api).*)'] }
