import Stripe from 'stripe'
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!)
export async function POST(req: Request) {
  const raw = await req.text()
  const event = stripe.webhooks.constructEvent(raw, req.headers.get('stripe-signature')!, process.env.STRIPE_WEBHOOK_SECRET!)
  // handle checkout.session.completed -> mark booking paid
  return Response.json({ received: true, type: event.type })
}
