#!/usr/bin/env -S npx tsx
/**
 * blob_to_s3.ts - copy a Vercel Blob store into an S3 bucket, re-runnably.
 *
 *   BLOB_READ_WRITE_TOKEN=... AWS_REGION=us-east-1 S3_BUCKET=my-media npx tsx blob_to_s3.ts [options]
 *
 * Options:
 *   --dry-run              list + count only (objects, bytes, how many already exist in S3); no copies
 *   --prefix <p>           only blobs whose pathname starts with <p> (Vercel-side filter)
 *   --concurrency <n>      parallel copies (default 8; Vercel Blob simple ops: Hobby 20/s, Pro 120/s)
 *   --manifest <file>      ndjson manifest (default migration/blob-manifest.ndjson; appended, git-ignore it)
 *   --limit <n>            stop after n blobs (testing)
 *   --help
 *
 * Environment:
 *   BLOB_READ_WRITE_TOKEN  required (from the Vercel Storage tab / env pull). Never printed.
 *   S3_BUCKET              required. S3_PREFIX optional (e.g. "media/" to match a Payload collection prefix).
 *   BLOB_ACCESS            "public" (default) or "private" (private stores: fetched via get(pathname, {access:'private'})).
 *   AWS_REGION / AWS_PROFILE / task role: standard SDK credential chain. No static keys needed.
 *
 * Behaviour (data-migration.md 5.1): list() with cursor pagination; head() per blob for contentType /
 * cacheControl / contentDisposition (list() does not return them); HeadObject size check so re-runs
 * skip objects already copied; parallel copy with p-limit; ndjson manifest {from, to, size, contentType}
 * for the later DB URL rewrite. Keys preserve the Blob pathname exactly (S3_PREFIX + pathname).
 */
import { list, head } from '@vercel/blob';
import { S3Client, HeadObjectCommand } from '@aws-sdk/client-s3';
import { Upload } from '@aws-sdk/lib-storage';
import { Readable } from 'node:stream';
import fs from 'node:fs';
import path from 'node:path';
import pLimit from 'p-limit';

type Blob = { pathname: string; url: string; downloadUrl: string; size: number; uploadedAt: Date };

function arg(name: string, def?: string): string | undefined {
  const i = process.argv.indexOf(name);
  if (i === -1) return def;
  const v = process.argv[i + 1];
  if (!v || v.startsWith('--')) return 'true';
  return v;
}
function has(name: string): boolean {
  return process.argv.includes(name);
}

if (has('--help') || has('-h')) {
  const header = fs.readFileSync(new URL(import.meta.url), 'utf8').split('*/')[0];
  console.log(header.replace(/^#!.*\n/, '').replace(/^\/\*\*?\n?/, '').replace(/^ \* ?/gm, '').trim());
  process.exit(0);
}

const DRY = has('--dry-run');
const PREFIX_FILTER = arg('--prefix');
const CONCURRENCY = Number(arg('--concurrency', '8'));
const MANIFEST = arg('--manifest', 'migration/blob-manifest.ndjson')!;
const LIMIT = arg('--limit') ? Number(arg('--limit')) : Infinity;
const BUCKET = process.env.S3_BUCKET;
const S3_PREFIX = process.env.S3_PREFIX ?? '';
const ACCESS = (process.env.BLOB_ACCESS ?? 'public') as 'public' | 'private';

function die(msg: string): never {
  console.error(`error: ${msg}`);
  process.exit(2);
}
if (!process.env.BLOB_READ_WRITE_TOKEN) die('BLOB_READ_WRITE_TOKEN is not set (vercel env pull, or the Storage tab). Secret-type vars must be re-sourced.');
if (!process.env.BLOB_READ_WRITE_TOKEN.startsWith('vercel_blob_rw_')) die('BLOB_READ_WRITE_TOKEN does not look like a read-write token (expected prefix vercel_blob_rw_)');
if (!BUCKET && !DRY) die('S3_BUCKET is not set');
if (!['public', 'private'].includes(ACCESS)) die('BLOB_ACCESS must be public or private');

const s3 = new S3Client({});
const limit = pLimit(CONCURRENCY);
let manifest: fs.WriteStream | undefined;
if (!DRY) {
  fs.mkdirSync(path.dirname(MANIFEST), { recursive: true });
  manifest = fs.createWriteStream(MANIFEST, { flags: 'a' });
}

async function s3Size(key: string): Promise<number | null> {
  if (!BUCKET) return null;
  try {
    const h = await s3.send(new HeadObjectCommand({ Bucket: BUCKET, Key: key }));
    return h.ContentLength ?? null;
  } catch {
    return null;
  }
}

async function withRetry<T>(fn: () => Promise<T>, what: string, tries = 5): Promise<T> {
  let delay = 500;
  for (let i = 1; ; i++) {
    try {
      return await fn();
    } catch (e: any) {
      const status = e?.status ?? e?.$metadata?.httpStatusCode;
      const retryable = status === 429 || (status >= 500 && status < 600) || e?.code === 'ECONNRESET' || e?.name === 'BlobServiceRateLimited';
      if (!retryable || i >= tries) throw e;
      await new Promise((r) => setTimeout(r, delay));
      delay = Math.min(delay * 2, 8000);
      console.error(`retry ${i}/${tries} ${what}: ${e?.message ?? e}`);
    }
  }
}

async function openBody(b: Blob): Promise<Readable> {
  if (ACCESS === 'private') {
    const { get } = await import('@vercel/blob');
    const r: any = await withRetry(() => (get as any)(b.pathname, { access: 'private' }), `get ${b.pathname}`);
    if (!r?.stream) throw new Error(`no stream for private blob ${b.pathname}`);
    return Readable.fromWeb(r.stream as any);
  }
  const res = await withRetry(() => fetch(b.url), `fetch ${b.pathname}`);
  if (!res.ok || !res.body) throw new Error(`${res.status} fetching ${b.pathname}`);
  return Readable.fromWeb(res.body as any);
}

type Outcome = 'copied' | 'skipped';

async function copyOne(b: Blob): Promise<Outcome> {
  const key = S3_PREFIX + b.pathname;
  const existing = await s3Size(key);
  if (existing !== null && existing === b.size) return 'skipped';
  let meta: any = {};
  try {
    meta = await withRetry(() => (head as any)(b.url, ACCESS === 'private' ? { access: 'private' } : undefined), `head ${b.pathname}`);
  } catch (e: any) {
    console.error(`warn: head() failed for ${b.pathname}: ${e?.message ?? e}; using defaults`);
  }
  const body = await openBody(b);
  await new Upload({
    client: s3,
    params: {
      Bucket: BUCKET!,
      Key: key,
      Body: body,
      ContentType: meta.contentType ?? 'application/octet-stream',
      CacheControl: meta.cacheControl ?? 'public, max-age=31536000, immutable',
      ContentDisposition: meta.contentDisposition || undefined,
      Metadata: {
        'vercel-blob-url': b.url,
        'vercel-uploaded-at': String(meta.uploadedAt?.toISOString?.() ?? b.uploadedAt?.toISOString?.() ?? ''),
      },
    },
    queueSize: 4,
    partSize: 8 * 1024 * 1024,
  }).done();
  manifest?.write(
    JSON.stringify({ from: b.url, to: `s3://${BUCKET}/${key}`, size: b.size, contentType: meta.contentType ?? null, copiedAt: new Date().toISOString() }) + '\n',
  );
  return 'copied';
}

async function main() {
  let cursor: string | undefined;
  let total = 0, bytes = 0, copied = 0, skipped = 0, failed = 0, present = 0;
  const sample: string[] = [];
  console.log(`blob_to_s3: mode=${DRY ? 'DRY-RUN (count only)' : 'copy'} access=${ACCESS} bucket=${BUCKET ?? '-'} s3Prefix='${S3_PREFIX}' blobPrefix='${PREFIX_FILTER ?? ''}' concurrency=${CONCURRENCY}`);
  do {
    const page: any = await withRetry(() => list({ cursor, limit: 1000, prefix: PREFIX_FILTER, mode: 'expanded' } as any), 'list');
    const blobs: Blob[] = page.blobs ?? [];
    const slice = blobs.slice(0, Math.max(0, Math.min(blobs.length, LIMIT - total)));
    if (DRY) {
      for (const b of slice) {
        total++;
        bytes += b.size;
        if (sample.length < 10) sample.push(b.pathname);
      }
      if (BUCKET) {
        const found = await Promise.all(slice.map((b) => limit(async () => (await s3Size(S3_PREFIX + b.pathname)) === b.size)));
        present += found.filter(Boolean).length;
      }
    } else {
      const results = await Promise.allSettled(slice.map((b) => limit(() => copyOne(b))));
      results.forEach((r, i) => {
        total++;
        bytes += slice[i].size;
        if (r.status === 'rejected') {
          failed++;
          process.exitCode = 1;
          console.error(`FAILED ${slice[i].pathname}: ${(r.reason as any)?.message ?? r.reason}`);
        } else if (r.value === 'copied') copied++;
        else skipped++;
      });
    }
    console.log(`progress total=${total} bytes=${bytes} copied=${copied} skipped=${skipped} failed=${failed}${DRY && BUCKET ? ` alreadyInS3=${present}` : ''}`);
    cursor = page.hasMore && total < LIMIT ? page.cursor : undefined;
  } while (cursor);

  if (DRY) {
    console.log(`\nDRY-RUN summary: ${total} objects, ${(bytes / 1024 / 1024).toFixed(1)} MiB${BUCKET ? `, ${present} already present in s3://${BUCKET}/${S3_PREFIX}` : ''}`);
    if (sample.length) console.log('sample pathnames:\n  ' + sample.join('\n  '));
    console.log('Keys will be S3_PREFIX + pathname. For Payload set S3_PREFIX to the collection prefix (e.g. "media/") only if pathnames do NOT already include it.');
  } else {
    manifest?.end();
    console.log(`\ndone: copied=${copied} skipped=${skipped} failed=${failed} manifest=${MANIFEST}`);
    console.log('Re-run during the cutover window to pick up new uploads (existing objects are skipped by size).');
  }
}

main().catch((e) => {
  console.error(`fatal: ${e?.message ?? e}`);
  process.exit(1);
});
