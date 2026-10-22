import Image from 'next/image'
export const revalidate = 60
export default async function Page({ params }: { params: Promise<{ slug: string }> }) {
  const { slug } = await params
  const res = await fetch(`${process.env.NEXT_PUBLIC_SERVER_URL}/api/posts/${slug}`, { next: { tags: ['posts'] } })
  const post = await res.json()
  return <Image src={post.hero} alt="" width={800} height={400} />
}
