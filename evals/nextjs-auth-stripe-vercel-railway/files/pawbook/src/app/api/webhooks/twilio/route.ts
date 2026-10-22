import twilio from 'twilio'
export async function POST(req: Request) {
  const params = Object.fromEntries(new URLSearchParams(await req.text()))
  const valid = twilio.validateRequest(process.env.TWILIO_AUTH_TOKEN!, req.headers.get('x-twilio-signature') ?? '', req.url, params)
  if (!valid) return new Response('forbidden', { status: 403 })
  return new Response('<Response></Response>', { headers: { 'content-type': 'text/xml' } })
}
