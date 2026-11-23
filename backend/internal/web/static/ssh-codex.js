const endpoint = '/admin/v1/ssh-codex';
const form = document.querySelector('#ssh-form');
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
