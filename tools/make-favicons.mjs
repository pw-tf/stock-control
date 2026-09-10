/**
 * Generate the favicon / app-icon set from tools/icon-src.png.
 *
 *   npm i sharp && node tools/make-favicons.mjs
 *
 * A dev utility, like tools/process-guide-art.mjs — sharp never ships to the
 * browser and the app itself stays dependency-free. The source is committed
 * beside this script (1024px, palette-encoded, ~39KB) so the whole set is
 * reproducible without hunting for the original artwork.
 *
 * WHY EACH OUTPUT
 * ---------------
 * favicon.ico          16/32/48 in one file. Every browser probes /favicon.ico
 *                      whether or not a <link> points at it, and Chromium
 *                      prefers this over the PNGs even when both are declared.
 *                      Entries are stored as PNG rather than BMP: universally
 *                      supported for years now, and a fraction of the size.
 * favicon-16/32.png    For engines that prefer an explicit PNG over the .ico.
 * favicon-180.png      apple-touch-icon. Flattened onto white, because iOS
 *                      composites a transparent icon onto BLACK — and this
 *                      artwork is black-outlined, so it would disappear.
 * icon-192/512.png     Web app manifest sizes. Kept transparent; the browser
 *                      grounds them itself.
 * icon-maskable-512    Android crops a maskable icon to a circle/squircle, and
 *                      only guarantees the central 80% diameter. A square
 *                      inscribed in that circle is 0.8/sqrt(2) = 56% of the
 *                      canvas, so the artwork is drawn at 56% and centred on an
 *                      opaque ground. Without this Android letterboxes the
 *                      normal icon inside a white circle instead.
 */

import sharp from 'sharp';
import { writeFile, mkdir } from 'node:fs/promises';
import { statSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(HERE, '..');
const SRC = path.join(HERE, 'icon-src.png');

// Trim the transparent margin, then re-pad to a square with an even one. The
// supplied artwork's margin is uneven (40px left against 30px top at 2048), and
// an icon that touches its own edges looks cramped in a tab strip.
const trimmed = await sharp(SRC).trim({ threshold: 8 }).toBuffer();
const t = await sharp(trimmed).metadata();
const box = Math.round(Math.max(t.width, t.height) * 1.06);   // ~3% per side
const master = await sharp({
    create: { width: box, height: box, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } }
}).composite([{ input: trimmed,
    left: Math.round((box - t.width) / 2), top: Math.round((box - t.height) / 2) }])
  .png().toBuffer();

const render = (size, bg) => {
    let p = sharp(master).resize(size, size, { fit: 'contain', kernel: 'lanczos3',
        background: { r: 0, g: 0, b: 0, alpha: 0 } });
    if (bg) p = p.flatten({ background: bg });
    return p.png({ compressionLevel: 9 }).toBuffer();
};

/**
 * Pack PNGs into an ICO container. The format is a 6-byte header, then one
 * 16-byte directory entry per image, then the payloads back to back.
 */
function ico(images) {
    const head = Buffer.alloc(6);
    head.writeUInt16LE(0, 0);                 // reserved
    head.writeUInt16LE(1, 2);                 // 1 = icon (2 would be a cursor)
    head.writeUInt16LE(images.length, 4);
    let offset = 6 + images.length * 16;
    const dir = [], body = [];
    for (const { size, data } of images) {
        const e = Buffer.alloc(16);
        e.writeUInt8(size >= 256 ? 0 : size, 0);   // 0 encodes 256
        e.writeUInt8(size >= 256 ? 0 : size, 1);
        e.writeUInt8(0, 2);                        // palette size, 0 for truecolour
        e.writeUInt8(0, 3);                        // reserved
        e.writeUInt16LE(1, 4);                     // colour planes
        e.writeUInt16LE(32, 6);                    // bits per pixel
        e.writeUInt32LE(data.length, 8);
        e.writeUInt32LE(offset, 12);
        offset += data.length;
        dir.push(e); body.push(data);
    }
    return Buffer.concat([head, ...dir, ...body]);
}

await mkdir(path.join(ROOT, 'assets/icons'), { recursive: true });

const icoSizes = [16, 32, 48];
const icoFile = path.join(ROOT, 'favicon.ico');
await writeFile(icoFile, ico(await Promise.all(
    icoSizes.map(async s => ({ size: s, data: await render(s) })))));

const pngs = [
    ['favicon-16.png',  16,  null],
    ['favicon-32.png',  32,  null],
    ['favicon-180.png', 180, '#ffffff'],
    ['icon-192.png',    192, null],
    ['icon-512.png',    512, null],
];

// White, not the app's accent: the artwork is black-outlined with pale fills,
// so it needs a light ground to read at all. Same reasoning as the 180.
const MASKABLE_GROUND = '#ffffff';
const MASKABLE_SAFE = 0.56;

console.log(`source ${t.width}x${t.height} trimmed -> ${box}x${box} master`);
console.log(`favicon.ico`.padEnd(20) + `${icoSizes.join('/')}  ${(statSync(icoFile).size / 1024).toFixed(1)}KB`);
for (const [name, size, bg] of pngs) {
    const buf = await render(size, bg);
    await writeFile(path.join(ROOT, 'assets/icons', name), buf);
    console.log(name.padEnd(20) + `${size}px${bg ? ' on ' + bg : ''}  ${(buf.length / 1024).toFixed(1)}KB`);
}

const MSIZE = 512;
const inner = Math.round(MSIZE * MASKABLE_SAFE);
const maskable = await sharp({
    create: { width: MSIZE, height: MSIZE, channels: 4, background: MASKABLE_GROUND }
}).composite([{
    input: await sharp(master).resize(inner, inner, { fit: 'contain', kernel: 'lanczos3',
        background: { r: 0, g: 0, b: 0, alpha: 0 } }).png().toBuffer(),
    left: Math.round((MSIZE - inner) / 2), top: Math.round((MSIZE - inner) / 2)
}]).png({ compressionLevel: 9 }).toBuffer();
await writeFile(path.join(ROOT, 'assets/icons/icon-maskable-512.png'), maskable);
console.log('icon-maskable-512.png'.padEnd(20) + `${MSIZE}px, art at ${inner}px on ${MASKABLE_GROUND}  ${(maskable.length / 1024).toFixed(1)}KB`);
