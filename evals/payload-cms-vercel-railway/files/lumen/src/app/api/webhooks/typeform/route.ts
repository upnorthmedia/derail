import crypto from 'node:crypto'
export const runtime = 'nodejs'
export async function POST(req: Request) {
  const raw = await req.text()
  const sig = req.headers.get('typeform-signature') ?? ''
  const expected = 'sha256=' + crypto.createHmac('sha256', process.env.TYPEFORM_SELF_TEST_SECRET!).update(raw).digest('base64')
  if (sig !== expected) return new Response('bad signature', { status: 401 })
  const body = JSON.parse(raw)
  const kind = body.form_response?.hidden?.kind
  const hook = kind === 'lasik' ? process.env.SELF_TEST_LASIK_WEBHOOK_URL : kind === 'cataract' ? process.env.SELF_TEST_CATARACT_WEBHOOK_URL : process.env.SELF_TEST_RLE_WEBHOOK_URL
  await fetch(hook!, { method: 'POST', body: raw, headers: { 'content-type': 'application/json' } })
  return Response.json({ ok: true })
}
