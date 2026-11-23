// JXA, called through osascript on macOS. Inspect only terminal identifiers.
function run([action, targetApp, targetTTY, targetID]) {
  const result = {preferred: 'Terminal', panes: []};
  for (const [bundle, name] of [['com.googlecode.iterm2','iTerm2'], ['com.apple.Terminal','Terminal']]) {
    let app;
    try { app = Application(bundle); } catch { continue; }
    if (name === 'iTerm2') result.preferred = name;
    if ((action !== 'list' && name !== targetApp) || !app.running()) continue;
    for (const [wi,w] of app.windows().entries()) {
      for (const [ti,t] of w.tabs().entries()) {
        const sessions = name === 'iTerm2' ? t.sessions() : [t];
        for (const [pi,p] of sessions.entries()) {
          const tty = p.tty();
          const id = name === 'iTerm2' ? p.id() : String(w.id())+'/'+tty;
          if (action !== 'list' && tty === targetTTY && id === targetID) {
            if (name === 'iTerm2') {
              t.select();
              if (action === 'pane') p.select();
              w.select();
            } else { t.selected = true; w.index = 1; }
            app.activate();
            return 'focused';
          }
          result.panes.push({app:name, window:wi+1, tab:ti+1, pane:pi+1, tty, id});
        }
      }
    }
  }
  if (action !== 'list') throw Error('The terminal moved or closed. Refresh and retry.');
  return JSON.stringify(result);
}
