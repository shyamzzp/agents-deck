// The saved theme, applied before the page is first painted.
//
// Loaded as a plain blocking script in <head>, not a module: a module is
// deferred until after the document parses, which would show the stock
// colours for a frame on the way to yours. The page's CSP is
// script-src 'self', so this cannot be inline either.
//
// Only the tokens are read here. theme.js does the rest: the picker, and
// following a change made in the other tab.
(function () {
  try {
    var saved = JSON.parse(localStorage.getItem('agents.themeTokens') || 'null');
    if (!saved || !saved.tokens) return;
    var root = document.documentElement;
    for (var k in saved.tokens) {
      if (k.slice(0, 2) === '--') root.style.setProperty(k, saved.tokens[k]);
    }
    root.style.colorScheme = saved.light ? 'light' : 'dark';
  } catch (e) {
    // Storage blocked, or a half-written value: the stock theme stands.
  }
})();
