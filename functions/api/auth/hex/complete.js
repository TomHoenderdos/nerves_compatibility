const PACKAGE_RE = /^[a-z][a-z0-9_]*$/;

export async function onRequestPost({ request, env }) {
  let body;

  try {
    body = await request.json();
  } catch (_error) {
    return json({ message: "Invalid JSON body." }, 400);
  }

  const packageName = String(body.package || "").trim().toLowerCase();
  const deviceCode = String(body.device_code || "").trim();

  if (!PACKAGE_RE.test(packageName)) {
    return json({ message: "Enter a valid Hex package name." }, 400);
  }

  if (!deviceCode) {
    return json({ message: "Missing Hex device code." }, 400);
  }

  if (!env.ORCHESTRATOR_SCAN_REQUEST_URL || !env.SCAN_REQUEST_SHARED_SECRET) {
    return json({ message: "Scan request backend is not configured." }, 503);
  }

  const baseUrl = env.ORCHESTRATOR_SCAN_REQUEST_URL.replace(/\/scan-requests$/, "");
  const upstream = await fetch(`${baseUrl}/auth/hex/complete`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.SCAN_REQUEST_SHARED_SECRET}`
    },
    body: JSON.stringify({
      package: packageName,
      device_code: deviceCode
    })
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
