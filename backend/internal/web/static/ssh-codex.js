const endpoint = '/admin/v1/ssh-codex';
const form = document.querySelector('#ssh-form');
const deck = document.querySelector('#ssh-deck');
const host = document.querySelector('#ssh-host');
const feedback = document.querySelector('#ssh-feedback');
async function request(options, path = endpoint) {
  const response = await fetch(path, { cache: 'no-store', ...options });
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
      const expanded = new Set(Array.from(
        list.querySelectorAll('details[open]'), item => item.dataset.id));
      list.replaceChildren(...sessions.map(session => {
        const tile = document.createElement('li');
        const details = document.createElement('details');
        details.dataset.id = session.id;
        details.open = expanded.has(session.id);
        const summary = document.createElement('summary');
        summary.textContent = (session.title || session.id) + ' · ' +
          (online ? session.status : 'offline');
        details.append(summary);
        const fields = [
          ['ID', session.id], ['Folder', session.cwd], ['Branch', session.branch],
          ['Model', session.model], ['Last prompt', session.lastPrompt],
          ['Activity', session.activity?.detail || session.activity?.tool],
          ['Waiting', session.waiting?.title],
          ['Last active', session.lastActive && new Date(session.lastActive).toLocaleString()],
          ['Context', session.context?.window && session.context.used + ' / ' + session.context.window],
          ['Tokens (input / cached / output)', session.tokens &&
            [session.tokens.input, session.tokens.cacheRead, session.tokens.output].join(' / ')],
          ['Turns observed', session.turns],
          ['Terminal command', 'agentctl attach --ssh ' + session.id],
        ];
        const info = document.createElement('dl');
        for (const [label, value] of fields) {
          if (value === null || value === undefined || value === '') continue;
          const key = document.createElement('dt');
          const val = document.createElement('dd');
          key.textContent = label;
          val.textContent = value;
          info.append(key, val);
        }
        details.append(info);
        if (online && data.terminal) {
          const button = document.createElement('button');
          button.type = 'button';
          button.textContent = 'Open in Terminal';
          button.onclick = async () => {
            button.disabled = true;
            try {
              await request({method: 'POST', headers: {'Content-Type': 'application/json'},
                body: JSON.stringify({host: data.host, id: session.id})}, endpoint + '/attach');
            } catch (error) { window.alert(error.message); }
            finally { button.disabled = false; }
          };
          details.append(button);
        }
        tile.append(details);
        return tile;
      }));
    } catch {
      status.textContent = 'Deck connection lost';
      list.replaceChildren();
    } finally { setTimeout(refresh, 5000); }
  }
  refresh();
}
