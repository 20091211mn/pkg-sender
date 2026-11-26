// Support relay for the app (Cloudflare Worker, free plan).
//
// The app cannot write to a private GitHub repository without exposing a token, so it
// talks to this small relay. The relay keeps the token and stores every conversation as
// an issue in a PRIVATE support repository. A ticket is protected by a random key that
// only the phone that created it knows.
//
// Settings (Worker > Settings > Variables and Secrets):
//   SUPPORT_REPO  (text)    owner/name of the private repository, e.g. "me/pkg-sender-support"
//   GITHUB_TOKEN  (secret)  fine-grained token: only that repository, permission Issues = Read and write

const json = (data, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });

const gh = (env, path, init = {}) =>
  fetch('https://api.github.com' + path, {
    ...init,
    headers: {
      Authorization: `Bearer ${env.GITHUB_TOKEN}`,
      Accept: 'application/vnd.github+json',
      'User-Agent': 'pkg-sender-support',
      'X-GitHub-Api-Version': '2022-11-28',
      'Content-Type': 'application/json',
    },
  });

const clean = (v, max = 60) => String(v ?? '').replace(/[\r\n`<>]/g, ' ').trim().slice(0, max);

function randomKey() {
  const b = new Uint8Array(16);
  crypto.getRandomValues(b);
  return [...b].map((x) => x.toString(16).padStart(2, '0')).join('');
}

const KEY_RE = /<!-- key:([0-9a-f]{32}) -->/;

/** Loads the issue and checks the key. Returns null when the key is wrong. */
async function loadIssue(env, id, key) {
  if (!/^\d+$/.test(String(id)) || !/^[0-9a-f]{32}$/.test(String(key))) return null;
  const r = await gh(env, `/repos/${env.SUPPORT_REPO}/issues/${id}`);
  if (!r.ok) return null;
  const issue = await r.json();
  const m = KEY_RE.exec(issue.body || '');
  return m && m[1] === key ? issue : null;
}

async function create(request, env) {
  const b = await request.json();
  const message = String(b.message ?? '').trim();
  if (message.length < 3 || message.length > 2000) return json({ error: 'bad_message' }, 400);
  const contact = clean(b.contact, 200);
  const meta = `App: ${clean(b.app)} ${clean(b.version)} | ${clean(b.platform)} | ${clean(b.lang)}`;
  const key = randomKey();
  const title = 'Ticket: ' + message.replace(/\s+/g, ' ').slice(0, 60);
  const body =
    `${meta}\n` + (contact ? `Contact: ${contact}\n` : '') + `\n---\n${message}\n\n<!-- key:${key} -->`;

  // make sure the label exists (ignore "already exists")
  await gh(env, `/repos/${env.SUPPORT_REPO}/labels`, {
    method: 'POST',
    body: JSON.stringify({ name: 'ticket', color: '1B3FD8' }),
  });
  const r = await gh(env, `/repos/${env.SUPPORT_REPO}/issues`, {
    method: 'POST',
    body: JSON.stringify({ title, body, labels: ['ticket'] }),
  });
  if (!r.ok) return json({ error: 'github_error', status: r.status }, 502);
  const issue = await r.json();
  return json({ id: issue.number, key });
}

async function read(url, env) {
  const id = url.searchParams.get('id');
  const key = url.searchParams.get('key');
  const issue = await loadIssue(env, id, key);
  if (!issue) return json({ error: 'not_found' }, 404);
  const r = await gh(env, `/repos/${env.SUPPORT_REPO}/issues/${id}/comments?per_page=100`);
  const comments = r.ok ? await r.json() : [];

  const first = (issue.body || '').split('\n---\n')[1] || '';
  const messages = [
    { from: 'user', text: first.replace(KEY_RE, '').trim(), date: issue.created_at },
  ];
  for (const c of comments) {
    const body = String(c.body || '');
    if (body.startsWith('[user]')) {
      messages.push({ from: 'user', text: body.replace(/^\[user\]\s*/, '').trim(), date: c.created_at });
    } else {
      messages.push({ from: 'admin', text: body.replace(/^\[admin\]\s*/, '').trim(), date: c.created_at });
    }
  }
  return json({ id: issue.number, status: issue.state, title: issue.title, messages });
}

async function reply(request, env) {
  const b = await request.json();
  const message = String(b.message ?? '').trim();
  if (message.length < 1 || message.length > 2000) return json({ error: 'bad_message' }, 400);
  const issue = await loadIssue(env, b.id, b.key);
  if (!issue) return json({ error: 'not_found' }, 404);
  const r = await gh(env, `/repos/${env.SUPPORT_REPO}/issues/${issue.number}/comments`, {
    method: 'POST',
    body: JSON.stringify({ body: `[user]\n\n${message}` }),
  });
  if (!r.ok) return json({ error: 'github_error', status: r.status }, 502);
  if (issue.state === 'closed') {
    await gh(env, `/repos/${env.SUPPORT_REPO}/issues/${issue.number}`, {
      method: 'PATCH',
      body: JSON.stringify({ state: 'open' }),
    });
  }
  return json({ ok: true });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    try {
      if (request.method === 'POST' && url.pathname === '/ticket') return await create(request, env);
      if (request.method === 'GET' && url.pathname === '/ticket') return await read(url, env);
      if (request.method === 'POST' && url.pathname === '/reply') return await reply(request, env);
      if (url.pathname === '/') return json({ ok: true, service: 'pkg-sender-support' });
      return json({ error: 'not_found' }, 404);
    } catch (e) {
      return json({ error: 'server_error' }, 500);
    }
  },
};
