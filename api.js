/**
 * SINABOS Cloudflare Pages Function: /api
 * Menyimpan URL Apps Script dan API token di Cloudflare Variables & Secrets.
 */
function json(data, status) {
  return new Response(JSON.stringify(data), {
    status: status || 200,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      'Cache-Control': 'no-store'
    }
  });
}

export async function onRequestGet() {
  return json({ ok: true, service: 'SINABOS Cloudflare API proxy' });
}

export async function onRequestPost(context) {
  const { request, env } = context;
  const upstreamUrl = env.APPS_SCRIPT_WEB_APP_URL;
  const apiToken = env.API_TOKEN;

  if (!upstreamUrl || !apiToken) {
    return json({ ok: false, error: 'Cloudflare API Variables belum dikonfigurasi' }, 500);
  }

  let payload;
  try {
    payload = JSON.parse(await request.text() || '{}');
  } catch (error) {
    return json({ ok: false, error: 'Payload JSON tidak valid' }, 400);
  }

  payload.token = apiToken;

  try {
    const response = await fetch(upstreamUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'text/plain;charset=utf-8' },
      body: JSON.stringify(payload)
    });
    const text = await response.text();
    return new Response(text, {
      status: response.status,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store'
      }
    });
  } catch (error) {
    return json({ ok: false, error: 'Apps Script API tidak dapat dihubungi' }, 502);
  }
}
