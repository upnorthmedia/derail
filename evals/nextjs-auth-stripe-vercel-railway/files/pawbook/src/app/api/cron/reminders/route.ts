export const runtime = 'edge'
export async function GET(req: Request) {
  if (req.headers.get('authorization') !== `Bearer ${process.env.CRON_SECRET}`) return new Response('unauthorized', { status: 401 })
  // send SMS reminders for tomorrow's bookings via Twilio messaging service
  return Response.json({ ok: true })
}
