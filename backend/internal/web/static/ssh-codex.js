const endpoint = '/admin/v1/ssh-codex';
const form = document.querySelector('#ssh-form');
const deck = document.querySelector('#ssh-deck');
const host = document.querySelector('#ssh-host');
const feedback = document.querySelector('#ssh-feedback');
async function request(options) {
  const response = await fetch(endpoint, { cache: 'no-store', ...options });
  const data = await response.json();
  if (!response.ok) throw new Error(data.error || 'Could not reach the deck');
  return data;
}

if (form) {
  let edited = false;
  host.addEventListener('input', () => { edited = true; });
  request().then(data => { if (!edited) host.value = data.host; })
    .catch(e => { feedback.textContent = e.message; });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    try {
      const data = await request({ method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ host: host.value.trim() }) });
      feedback.textContent = data.host ? 'SSH host saved.' : 'Disconnected.';
    } catch (e) { feedback.textContent = e.message; }
  });
}

if (deck) {
  const status = document.querySelector('#ssh-status');
  const list = document.querySelector('#ssh-sessions');
  async function refresh() {
    try {
      const data = await request();
      deck.hidden = !data.host;
      const sessions = data.sessions || [];
      const online = data.connection === 'online';
      status.textContent = data.host + ' · ' + data.connection;
      if (online && !sessions.length) status.textContent += ' · No sessions in the last six hours.';
      if (!online && sessions.length) {
        status.textContent += ' · Last seen ' + new Date(data.lastSeen).toLocaleTimeString();
      }
      list.replaceChildren(...sessions.map(session => {
        const tile = document.createElement('li');
        const title = document.createElement('strong');
        title.textContent = session.title || session.id;
        tile.append(title, document.createTextNode(online ? session.status : 'offline'));
        return tile;
      }));
    } catch {
      status.textContent = 'Deck connection lost';
      list.replaceChildren();
    } finally { setTimeout(refresh, 5000); }
  }
  refresh();
}
