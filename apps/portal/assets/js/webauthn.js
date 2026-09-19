// WebAuthn glue for the login and security-settings pages.
//
// Both are controller-rendered, not LiveView, so this binds plain listeners
// rather than registering hooks. Every binary crosses the wire base64url
// encoded, because JSON has no way to carry an ArrayBuffer.

const b64urlToBuf = (value) => {
  const padded = value + "=".repeat((4 - (value.length % 4)) % 4)
  const binary = atob(padded.replace(/-/g, "+").replace(/_/g, "/"))
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i) }
  return bytes.buffer
}

const bufToB64url = (buffer) => {
  const bytes = new Uint8Array(buffer)
  let binary = ""
  for (let i = 0; i < bytes.length; i++) { binary += String.fromCharCode(bytes[i]) }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

const csrfToken = () =>
  document.querySelector("meta[name='csrf-token']").getAttribute("content")

const postJSON = async (url, body) => {
  const response = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: {
      "content-type": "application/json",
      accept: "application/json",
      "x-csrf-token": csrfToken()
    },
    body: JSON.stringify(body || {})
  })

  const data = await response.json()
  if (!response.ok) { throw new Error(data.error || "Request failed") }
  return data
}

export async function loginWithPasskey() {
  const options = await postJSON("/auth/passkey/challenge", {})

  const assertion = await navigator.credentials.get({
    publicKey: {
      challenge: b64urlToBuf(options.challenge),
      rpId: options.rp_id,
      timeout: options.timeout * 1000,
      userVerification: "required"
      // No allowCredentials: the credential is discoverable, so the
      // authenticator picks one and tells us whose it is via userHandle.
    }
  })

  const result = await postJSON("/auth/passkey/verify", {
    credential_id: bufToB64url(assertion.rawId),
    authenticator_data: bufToB64url(assertion.response.authenticatorData),
    signature: bufToB64url(assertion.response.signature),
    client_data_json: bufToB64url(assertion.response.clientDataJSON),
    user_handle: assertion.response.userHandle
      ? bufToB64url(assertion.response.userHandle)
      : null
  })

  window.location.assign(result.redirect_to)
}

export async function registerPasskey(nickname) {
  const options = await postJSON("/settings/security/passkeys/challenge", {})

  const credential = await navigator.credentials.create({
    publicKey: {
      challenge: b64urlToBuf(options.challenge),
      rp: {id: options.rp_id, name: options.rp_name},
      user: {
        id: b64urlToBuf(options.user_handle),
        name: options.user_name,
        displayName: options.user_name
      },
      // ES256 first, RS256 as the fallback some Windows Hello stacks need.
      pubKeyCredParams: [
        {type: "public-key", alg: -7},
        {type: "public-key", alg: -257}
      ],
      timeout: options.timeout * 1000,
      attestation: "none",
      excludeCredentials: options.exclude_credentials.map((id) => ({
        type: "public-key",
        id: b64urlToBuf(id)
      })),
      authenticatorSelection: {
        // Discoverable, so the passwordless login flow can find it without a
        // username. This is the browser half of that; the server half is
        // omitting allowCredentials.
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "required"
      }
    }
  })

  await postJSON("/settings/security/passkeys", {
    nickname: nickname,
    attestation_object: bufToB64url(credential.response.attestationObject),
    client_data_json: bufToB64url(credential.response.clientDataJSON),
    transports: credential.response.getTransports
      ? credential.response.getTransports()
      : []
  })

  window.location.reload()
}

const run = async (button, statusEl, work) => {
  button.disabled = true
  if (statusEl) { statusEl.textContent = "" }

  try {
    await work()
  } catch (error) {
    // AbortError and NotAllowedError mean the person dismissed the browser
    // prompt. That is not a failure worth shouting about.
    const dismissed = error.name === "NotAllowedError" || error.name === "AbortError"
    if (statusEl) {
      statusEl.textContent = dismissed ? "Cancelled." : error.message
    }
    button.disabled = false
  }
}

export function initWebAuthn() {
  const supported = Boolean(window.PublicKeyCredential)

  const loginButton = document.getElementById("passkey-login")
  if (loginButton) {
    const block = loginButton.closest("[data-passkey-block]")
    if (!supported && block) {
      block.hidden = true
    } else {
      const status = document.getElementById("passkey-login-status")
      loginButton.addEventListener("click", (event) => {
        event.preventDefault()
        run(loginButton, status, loginWithPasskey)
      })
    }
  }

  const registerButton = document.getElementById("passkey-register")
  if (registerButton) {
    const block = registerButton.closest("[data-passkey-block]")
    if (!supported && block) {
      block.hidden = true
    } else {
      const status = document.getElementById("passkey-register-status")
      const nicknameInput = document.getElementById("passkey-nickname")
      registerButton.addEventListener("click", (event) => {
        event.preventDefault()
        run(registerButton, status, () =>
          registerPasskey(nicknameInput ? nicknameInput.value : "")
        )
      })
    }
  }
}
