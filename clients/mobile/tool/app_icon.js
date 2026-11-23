// The iOS app icon: the critter in its propeller hat, the same one the menu bar
// app and the boards draw (clients/macos/tool/app_icon.js).
// Run from the repository root: node clients/mobile/tool/app_icon.js
//
// Two things differ from the macOS icon. iOS applies its own rounded mask, so
// the plate is full-bleed here rather than a rounded square inset in the
// canvas; and an iOS icon may not carry alpha, so this writes opaque RGB. The
// sizes are not all powers of two (120, 152, 180...), so it draws once at a
// large multiple and box-filters down to each one.
const fs = require('fs'), zlib = require('zlib'), path = require('path');
const N = 1024, BG = [0x0A, 0x0A, 0x0A], ORANGE = [0xFF, 0x4D, 0x00];
const HAT = { a: [0x6F, 0x8F, 0xD8], b: [0x4A, 0x63, 0xA3], c: [0xF7, 0xF4, 0xEC], d: [0x7A, 0x77, 0x6F] };

const px = new Float64Array(N * N * 3);
for (let i = 0; i < N * N; i++) { px[i * 3] = BG[0]; px[i * 3 + 1] = BG[1]; px[i * 3 + 2] = BG[2]; }

// The critter sits on the same grid as the macOS icon, a little smaller so the
// corners iOS rounds away never clip a leg or an arm.
const U = 40, X0 = (N - 14 * U) / 2, Y0 = Math.round((N - 11.6 * U) / 2) + 4 * U;
const rect = (x, y, w, h, col) => {
  const x0 = Math.round(X0 + x * U), y0 = Math.round(Y0 + y * U);
  const x1 = Math.round(X0 + (x + w) * U), y1 = Math.round(Y0 + (y + h) * U);
  for (let yy = Math.max(0, y0); yy < Math.min(N, y1); yy++)
    for (let xx = Math.max(0, x0); xx < Math.min(N, x1); xx++) {
      const o = (yy * N + xx) * 3;
      px[o] = col[0]; px[o + 1] = col[1]; px[o + 2] = col[2];
    }
};
rect(1, 0, 12, 6, ORANGE);                                   // body
rect(0, 2, 1, 2, ORANGE); rect(13, 2, 1, 2, ORANGE);         // arms
[2, 4, 9, 11].forEach((x) => rect(x, 6, 1, 1.6, ORANGE));    // legs
rect(4, 1.5, 1, 2, BG); rect(9, 1.5, 1, 2, BG);              // eyes
['..cccc.aaaa...', '.......d......', '....ababab....', '...aaaaaaaa...'].forEach((row, r) =>
  [...row].forEach((ch, c) => { if (HAT[ch]) rect(c, -4 + r, 1, 1, HAT[ch]); }));

/// Area average from the N x N source into w x w, so an odd size stays even.
const resize = (w) => {
  const out = new Float64Array(w * w * 3), s = N / w;
  for (let y = 0; y < w; y++) for (let x = 0; x < w; x++) {
    const y0 = Math.floor(y * s), y1 = Math.max(y0 + 1, Math.floor((y + 1) * s));
    const x0 = Math.floor(x * s), x1 = Math.max(x0 + 1, Math.floor((x + 1) * s));
    let r = 0, g = 0, b = 0, n = 0;
    for (let yy = y0; yy < y1; yy++) for (let xx = x0; xx < x1; xx++) {
      const o = (yy * N + xx) * 3; r += px[o]; g += px[o + 1]; b += px[o + 2]; n++;
    }
    const o = (y * w + x) * 3; out[o] = r / n; out[o + 1] = g / n; out[o + 2] = b / n;
  }
  return out;
};

/// Opaque 8-bit RGB PNG: colour type 2, no alpha channel at all.
const png = (w, data) => {
  const raw = Buffer.alloc((w * 3 + 1) * w);
  for (let y = 0; y < w; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 3, o = y * (w * 3 + 1) + 1 + x * 3;
    raw[o] = Math.round(data[i]); raw[o + 1] = Math.round(data[i + 1]); raw[o + 2] = Math.round(data[i + 2]);
  }
  const chunk = (t, d) => {
    const b = Buffer.alloc(12 + d.length);
    b.writeUInt32BE(d.length, 0); b.write(t, 4, 'ascii'); d.copy(b, 8);
    b.writeUInt32BE(zlib.crc32(b.subarray(4, 8 + d.length)), 8 + d.length);
    return b;
  };
  const hdr = Buffer.alloc(13);
  hdr.writeUInt32BE(w, 0); hdr.writeUInt32BE(w, 4); hdr[8] = 8; hdr[9] = 2; // 8-bit, RGB
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk('IHDR', hdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
};

// Every slot the asset catalogue asks for, at the pixel size it wants.
const set = 'clients/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset/';
const meta = JSON.parse(fs.readFileSync(path.join(set, 'Contents.json'), 'utf8'));
const wanted = new Map();
for (const img of meta.images) {
  if (!img.filename) continue;
  const w = Math.round(parseFloat(img.size) * parseFloat(img.scale));
  wanted.set(img.filename, w);
}
for (const [name, w] of [...wanted].sort((a, b) => b[1] - a[1])) {
  fs.writeFileSync(set + name, png(w, w === N ? px : resize(w)));
}
console.log(`${wanted.size} icons written, ${Math.min(...wanted.values())}–${Math.max(...wanted.values())} px`);
