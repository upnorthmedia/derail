import { put, del } from '@vercel/blob'
export async function upload(name: string, body: Blob) {
  return put(name, body, { access: 'public', token: process.env.BLOB_READ_WRITE_TOKEN })
}
export const CDN = 'https://abc123.public.blob.vercel-storage.com'
