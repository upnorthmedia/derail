// app/api/webhooks/stripe/route.ts
// Webhook signature checks need the RAW body. Works unchanged on Vercel and Fargate, but two platform
// details matter on AWS:
//  1. CloudFront strips headers that are not in the origin request policy. The cloudfront_app module
//     uses the managed AllViewer policy on /api/*, so `stripe-signature`, Svix (`svix-*`) and
//     `X-Twilio-Signature` headers reach the container. If you customise policies, keep that.
//  2. Twilio signs the FULL public URL. Behind a proxy build it from config (APP_URL + path), never from
//     req.url, or every Twilio webhook fails validation.
import Stripe from 'stripe'
import { headers } from 'next/headers'

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!)
export const dynamic = 'force-dynamic'

export async function POST(req: Request) {
  const raw = await req.text()
  const sig = (await headers()).get('stripe-signature')
  if (!sig) return new Response('missing signature', { status: 400 })

  let event: Stripe.Event
  try {
    // Dual-register the AWS endpoint in Stripe before cutover; it gets its own signing secret.
    event = stripe.webhooks.constructEvent(raw, sig, process.env.STRIPE_WEBHOOK_SECRET!)
  } catch (err) {
    return new Response(`invalid signature: ${(err as Error).message}`, { status: 400 })
  }

  // Return 2xx quickly (Stripe times out ~30 s; CloudFront origin timeout is 60 s max). Queue heavy work.
  switch (event.type) {
    case 'checkout.session.completed':
      // ... idempotent handling keyed on event.id
      break
  }
  return Response.json({ received: true })
}
