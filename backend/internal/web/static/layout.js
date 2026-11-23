// Layout preferences belong to the browser displaying the deck.
export const drawerFont = {
  key: 'agents.drawerTitleSize', sizes: [16, 18, 20, 22, 24, 26, 28, 32, 36], defaultSize: 24,
};
export const tileFont = {
  key: 'agents.tileNameSize', sizes: [0, 12, 14, 16, 18, 20, 22, 24, 28], defaultSize: 0,
};

export function fontSize(pref) {
  try {
    const saved = localStorage.getItem(pref.key);
    if (saved !== null && pref.sizes.includes(Number(saved))) return Number(saved);
  } catch { /* use the default when storage is unavailable */ }
  return pref.defaultSize;
}
