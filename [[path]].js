/**
 * SINABOS Cloudflare Pages Function
 *
 * Frontend memanggil /api pada origin yang sama. Function ini menambahkan
 * kredensial API Apps Script dari Cloudflare Variables & Secrets, sehingga
 * URL dan API token tidak perlu diketik pada halaman publik.
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

export async function onRequestGet() {
  return json({ ok: true, service: 'SINABOS Cloudflare API proxy' });
}
