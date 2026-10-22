export async function POST(req: Request) {
  const data = await req.json()
  await fetch(process.env.CONTACT_FORM_WEBHOOK_URL!, { method: 'POST', body: JSON.stringify(data) })
  return Response.json({ ok: true })
}
