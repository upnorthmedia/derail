import { ImageResponse } from 'next/og'
export const runtime = 'edge'
export const preferredRegion = 'iad1'
export async function GET() {
  return new ImageResponse(<div>hello</div>)
}
