// Called by the checkout UI extension / Shopify Function at checkout time. Must be fast and public (CORS).
import prisma from "../db.server";
export const loader = async ({ request }: any) => {
  const shop = new URL(request.url).searchParams.get("shop")!;
  const rules = await prisma.restrictionRule.findMany({ where: { shop } });
  return Response.json(rules, { headers: { "access-control-allow-origin": "*", "cache-control": "public, max-age=60" } });
};
