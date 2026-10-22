import { revalidateTag, revalidatePath } from 'next/cache'
export async function POST(req: Request) {
  const url = new URL(req.url)
  if (url.searchParams.get('secret') !== process.env.REVALIDATE_SECRET) return new Response('nope', { status: 401 })
  revalidateTag('posts')
  revalidatePath('/')
  return Response.json({ ok: true })
}
