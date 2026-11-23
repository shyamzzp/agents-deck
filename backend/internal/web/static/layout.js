// Drawer layout preferences belong to the browser displaying the deck.
export const titleSizeKey = 'agents.drawerTitleSize';
export const titleSizes = [16, 18, 20, 22, 24, 26, 28, 32, 36];

export function titleSize() {
  try {
    const size = Number(localStorage.getItem(titleSizeKey));
    if (titleSizes.includes(size)) return size;
  } catch { /* use the default when storage is unavailable */ }
  return 24;
}
