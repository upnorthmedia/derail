import type { ActionFunctionArgs } from "react-router";
import { authenticate } from "../shopify.server";
import prisma from "../db.server";
// Shopify verifies X-Shopify-Hmac-Sha256 over the raw body inside authenticate.webhook
export const action = async ({ request }: ActionFunctionArgs) => {
  const { shop, payload } = await authenticate.webhook(request);
  const status = (payload as any)?.app_subscription?.status;
  await prisma.shopSettings.update({ where: { shop }, data: { plan: status === "ACTIVE" ? "pro" : "free" } });
  return new Response();
};
