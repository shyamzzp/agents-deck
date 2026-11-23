// Drawer layout preferences belong to the browser displaying the deck.
export const titleWidthKey = 'agents.drawerTitleWidth';
export const titleWidths = [60, 70, 80, 90, 95, 100];

export function titleWidth() {
  try {
    const width = Number(localStorage.getItem(titleWidthKey));
    if (titleWidths.includes(width)) return width;
  } catch { /* use the default when storage is unavailable */ }
  return 95;
}
