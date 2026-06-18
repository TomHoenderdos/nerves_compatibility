const PACKAGE_RE = /^[a-z][a-z0-9_]*$/;

export async function onRequestPost({ request, env }) {
  let body;

  try {
    body = await request.json();
  } catch (_error) {
    return json({ message: "Invalid JSON body." }, 400);
  }

  const packageName = String(body.package || "").trim().toLowerCase();

  if (!PACKAGE_RE.test(packageName)) {
    return json({ message: "Enter a valid Hex package name." }, 400);
  }

  const turnstileToken = body.turnstile_token;

  if (!env.TURNSTILE_SECRET_KEY) {
    return json({ message: "Cloudflare Turnstile is not configured." }, 503);
  }

  const turnstile = await verifyTurnstile(env.TURNSTILE_SECRET_KEY, turnstileToken, request);

  if (!turnstile.success) {
    return json({ message: "Human check failed." }, 403);
  }

  if (!env.ORCHESTRATOR_SCAN_REQUEST_URL || !env.SCAN_REQUEST_SHARED_SECRET) {
    return json({ message: "Scan request backend is not configured." }, 503);
  }

  const upstream = await fetch(env.ORCHESTRATOR_SCAN_REQUEST_URL, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      authorization: `Bearer ${env.SCAN_REQUEST_SHARED_SECRET}`
    },
    body: JSON.stringify({
      package: packageName,
      source: "anonymous_turnstile",
      verified: true,
      verification_provider: "cloudflare_turnstile"
    })
  });

  const payload = await upstream.json().catch(() => ({}));
  return json(payload, upstream.status);
}

async function verifyTurnstile(secret, token, request) {
  const form = new FormData();
  form.append("secret", secret);
  form.append("response", token || "");

  const remoteIp = request.headers.get("CF-Connecting-IP");
  if (remoteIp) form.append("remoteip", remoteIp);

  const response = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
    method: "POST",
    body: form
  });

  return response.json();
}

function json(body, status) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" }
  });
}
