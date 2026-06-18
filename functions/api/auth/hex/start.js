export async function onRequestPost({ env }) {
  if (!env.ORCHESTRATOR_SCAN_REQUEST_URL || !env.SCAN_REQUEST_SHARED_SECRET) {
    return json({ message: "Scan request backend is not configured." }, 503);
  }

  const baseUrl = env.ORCHESTRATOR_SCAN_REQUEST_URL.replace(/\/scan-requests$/, "");
  const upstream = await fetch(`${baseUrl}/auth/hex/start`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.SCAN_REQUEST_SHARED_SECRET}`
    },
    body: "{}"
  });

  const payload = await upstream.json().catch(() => ({}));
  return json(payload, upstream.status);
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}
