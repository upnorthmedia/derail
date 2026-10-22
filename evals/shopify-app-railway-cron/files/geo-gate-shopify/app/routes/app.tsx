import { Outlet, useLoaderData } from "react-router";
import { AppProvider } from "@shopify/shopify-app-react-router/react";
import { authenticate } from "../shopify.server";
export const loader = async ({ request }: any) => { await authenticate.admin(request); return { apiKey: process.env.SHOPIFY_API_KEY || "" }; };
export default function App() { const { apiKey } = useLoaderData<typeof loader>(); return (<AppProvider embedded apiKey={apiKey}><Outlet /></AppProvider>); }
