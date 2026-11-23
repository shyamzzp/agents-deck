// Layout preferences belong to the browser displaying the deck.
export const drawerFont = {
  key: 'agents.drawerTitleSize', values: [16, 18, 20, 22, 24, 26, 28, 32, 36], defaultValue: 24,
};
export const tileFont = {
  key: 'agents.tileNameSize', values: [0, 12, 14, 16, 18, 20, 22, 24, 28], defaultValue: 0, zeroLabel: 'Automatic',
};

export const tileBorder = {
  key: 'agents.tileBorderWidth', values: [0, 0.5, 1, 2, 3], defaultValue: 0.5,
};

export function layoutValue(pref) {
  try {
    const saved = localStorage.getItem(pref.key);
    if (saved !== null && pref.values.includes(Number(saved))) return Number(saved);
  } catch { /* use the default when storage is unavailable */ }
  return pref.defaultValue;
}
