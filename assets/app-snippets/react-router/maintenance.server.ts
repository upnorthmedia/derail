// React Router v7 / Remix: write-freeze switch for the cutover window, used by the OLD deployment.
// Call `assertWritable(request)` at the top of every `action` (or in a root-level middleware if your
// version has it). Reads keep working; mutations return 503 while MAINTENANCE_MODE=true.
// If you cannot redeploy the old app in time, freeze at the database instead:
//   ALTER DATABASE railway SET default_transaction_read_only = on;  (and terminate app backends)
export function assertWritable(request: Request) {
  if (process.env.MAINTENANCE_MODE !== 'true') return
  if (['POST', 'PUT', 'PATCH', 'DELETE'].includes(request.method)) {
    throw new Response(JSON.stringify({ error: 'Maintenance in progress. Try again in a few minutes.' }), {
      status: 503,
      headers: { 'content-type': 'application/json', 'retry-after': '600' },
    })
  }
}
