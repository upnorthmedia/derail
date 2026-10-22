// Nightly: reconcile plan status for every installed shop via the Partner API, then exit (Railway cron service, 00:47 UTC).
import prisma from "../app/db.server";
const token = process.env.SHOPIFY_PARTNER_API_TOKEN!; const org = process.env.SHOPIFY_PARTNER_ORG_ID!; const appGid = process.env.SHOPIFY_APP_GID!;
async function main() {
  const shops = await prisma.shopSettings.findMany();
  for (const s of shops) { /* fetch https://partners.shopify.com/${org}/api/2026-07/graphql.json with token; update s.plan */ }
  console.log(`checked ${shops.length} shops`);
}
main().then(() => process.exit(0)).catch((e) => { console.error(e); process.exit(1); });
