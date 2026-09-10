/**
 * Normalises the supplied manufacturer artwork into the files guides.html loads
 * from assets/devices/ and assets/logos/.
 *
 * DEV UTILITY, NOT PART OF THE APP. The app itself has no build step and no
 * dependencies; this runs by hand when new artwork arrives, and its output is
 * committed. Nothing here ships to the browser.
 *
 *   npm install sharp
 *   node tools/process-guide-art.mjs <source-dir> [--out .]
 *
 * WHY EACH STEP
 * -------------
 * The supplied photos are shot at whatever angle the manufacturer chose — some
 * lying diagonally, some upright. Each is levelled to a canonical horizontal
 * pose and corrected there, which is also the pose the cards present, so a row
 * of device cards reads as one set of terminals rather than six stock photos.
 *
 * Rotation angles are not eyeballed: `--measure` prints the principal axis of
 * each image's alpha mask (a PCA over the opaque pixels), and the angles in
 * DEVICES below are those measurements. They are stored rather than recomputed
 * so the output is reproducible even if a source file is replaced.
 *
 * The pipeline is measure -> level -> mirror -> repair -> present, in that
 * order. Levelling first is what lets the branding repair below be specified in
 * fixed pixel coordinates: they are measured against the horizontal pose, so
 * changing how the device is finally presented never invalidates them. That is
 * what made switching the cards back to landscape a one-constant change.
 *
 * Devices are trimmed, scaled to a common content box and centred on one canvas
 * size, so no card's artwork looks heavier than its neighbour's.
 */

import sharp from 'sharp';
import { mkdir, copyFile, stat } from 'node:fs/promises';
import path from 'node:path';

// Output canvas. Landscape, matching the card's art slot and the shape of the
// brand marks beside them. The pixel size is ~4x the slot so the art stays
// crisp on a retina phone.
const CANVAS = { w: 320, h: 200 };
const CONTENT = { w: 300, h: 176 };   // the box the device is scaled to fit

// Applied to every device after it has been levelled and repaired. Levelling
// already leaves each terminal horizontal, which is the pose we present, so
// there is no final turn — set this to -90 to stand them upright instead.
const FINAL_TURN = 0;

const DEVICES = [
    {
        out: 'cba-move5000.webp',
        src: 'MOVE5000.png',
        rotate: 39.0,
        note: 'CBA-branded — <vendor>-<device>, so it wins only under CBA',
    },
    {
        out: 'move5000.webp',
        src: 'MOVE5000.png',
        rotate: 39.0,
        // The Move5000 is used under CBA, NAB, Westpac and Suncorp, but the photo
        // carries Commonwealth Bank branding on the bezel. Paint it out for the
        // generic file so a NAB job does not show a CBA terminal.
        inpaint: [{ from: [351, 28], to: [391, 107], width: 20, feather: 1.2 }],
        note: 'branding removed — the default for every non-CBA vendor',
    },
    { out: 'qt850.webp', src: 'quest qt850.avif', rotate: -20.7, flop: true, trimThin: true },
    { out: 'cm5p.webp',  src: 'verifone-cm5p.png', rotate: 17.9 },
    { out: 'p630.webp',  src: 'p630.png', rotate: 83.9 },
    { out: 't650p.webp', src: 'verifone-t650p-eftpos-terminal.png', rotate: 45.5 },
    { out: 'p400.webp',  src: 'p400.png', rotate: 45.1 },
];

// Manufacturer wordmarks. Dark-on-transparent lettering, rendered in the page
// through a CSS mask in currentColor, so they only ever need trimming.
const LOGOS = [
    { out: 'ingenico.svg', src: 'Ingenico_Logo.svg', copy: true },
    { out: 'verifone.webp', src: 'Verifone_logotype_black_rgb.png', logo: true },
];

// Bank marks, keyed by vendor_id. These are full-colour pictorial logos, not
// wordmarks, so they are rendered as images on a light tile rather than masked
// — Hungry Jack's in particular is a solid red tile whose alpha channel is the
// whole square, which would mask to a featureless blob.
//
// Their aspect ratios run from 1.02 (Hungry Jack's, square) to 5.0 (Westpac, a
// long wordmark). A plain contain-fit would let the square mark tower over the
// wordmarks, so each is scaled to a common AREA instead and only then clamped
// to the box. That is what makes a row of them look evenly weighted.
const BRAND_CANVAS = { w: 288, h: 176 };
const BRAND_BOX = { w: 264, h: 140 };
const BRAND_AREA = 0.40 * BRAND_BOX.w * BRAND_BOX.h;

const BRANDS = [
    { out: 'cba.webp', src: 'cba-src.webp' },
    { out: 'nab.webp', src: 'nab-src.png' },
    { out: 'wpb.webp', src: 'wpb-src.webp', note: 'Westpac — WPB covers Westpac, BankSA and St.George' },
    { out: 'sun.webp', src: 'sun-src.png' },
    { out: 'hjk.webp', src: 'hjk-src.png' },
];

/**
 * Principal axis of the opaque pixels, in degrees. Rotating by its negation
 * lays the device's long axis horizontal.
 */
async function principalAxis(file) {
    const { data, info } = await sharp(file).ensureAlpha().raw()
        .toBuffer({ resolveWithObject: true });
    const { width: w, height: h, channels: c } = info;
    let n = 0, sx = 0, sy = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        if (data[(y * w + x) * c + 3] > 40) { n++; sx += x; sy += y; }
    }
    const cx = sx / n, cy = sy / n;
    let mxx = 0, myy = 0, mxy = 0;
    for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
        if (data[(y * w + x) * c + 3] > 40) {
            const dx = x - cx, dy = y - cy;
            mxx += dx * dx; myy += dy * dy; mxy += dx * dy;
        }
    }
    return 0.5 * Math.atan2(2 * mxy / n, (mxx - myy) / n) * 180 / Math.PI;
}

/**
 * Replace a narrow strip of the image by interpolating the surface either side
 * of it along the strip's own axis.
 *
 * The branding sits on a smooth bezel whose colour changes gradually from one
 * end of the strip to the other, and whose cross-section (dark inner edge to
 * lighter outer edge) is near enough constant. So for a pixel at axial position
 * t and perpendicular offset s, the honest replacement is the colour found at
 * the same offset s just beyond each end of the strip, blended by t. That keeps
 * the bezel's gradient and its shading instead of flat-filling a grey rectangle
 * over it, which is what makes the patch invisible rather than merely blurred.
 */
function inpaintStrip(buf, w, h, c, spec) {
    const [x0, y0] = spec.from, [x1, y1] = spec.to;
    const dx = x1 - x0, dy = y1 - y0;
    const len = Math.hypot(dx, dy);
    const ux = dx / len, uy = dy / len;          // along the strip
    const px = -uy, py = ux;                     // across it
    const half = spec.width / 2;
    const pad = 11;                              // sample this far past each end

    const at = (x, y) => {
        const xi = Math.max(0, Math.min(w - 1, Math.round(x)));
        const yi = Math.max(0, Math.min(h - 1, Math.round(y)));
        const o = (yi * w + xi) * c;
        return [buf[o], buf[o + 1], buf[o + 2], buf[o + 3]];
    };

    const out = Buffer.from(buf);
    for (let y = Math.floor(Math.min(y0, y1) - half - 2); y <= Math.ceil(Math.max(y0, y1) + half + 2); y++) {
        for (let x = Math.floor(Math.min(x0, x1) - half - 2); x <= Math.ceil(Math.max(x0, x1) + half + 2); x++) {
            if (x < 0 || y < 0 || x >= w || y >= h) continue;
            const rx = x - x0, ry = y - y0;
            const t = rx * ux + ry * uy;          // axial position, 0..len
            const s = rx * px + ry * py;          // perpendicular offset
            if (t < 0 || t > len || Math.abs(s) > half) continue;

            const a = at(x0 - ux * pad + px * s, y0 - uy * pad + py * s);
            const b = at(x1 + ux * pad + px * s, y1 + uy * pad + py * s);
            const f = t / len;

            // Feather the perpendicular edges so the patch has no hard seam.
            const edge = Math.min(1, (half - Math.abs(s)) / (spec.feather ?? 1));
            const o = (y * w + x) * c;
            for (let k = 0; k < 3; k++) {
                const repl = a[k] * (1 - f) + b[k] * f;
                out[o + k] = Math.round(buf[o + k] * (1 - edge) + repl * edge);
            }
        }
    }
    return out;
}

/**
 * Drop leading/trailing columns that hold only a thin sliver of content — a
 * trailing cable, say — so the device itself fills the frame.
 */
async function trimThinEdges(buf) {
    const { data, info } = await sharp(buf).raw().toBuffer({ resolveWithObject: true });
    const { width: w, height: h, channels: c } = info;
    const col = new Array(w).fill(0);
    for (let x = 0; x < w; x++) {
        for (let y = 0; y < h; y++) if (data[(y * w + x) * c + 3] > 40) col[x]++;
    }
    const peak = Math.max(...col);
    const min = peak * 0.10;
    let l = 0, r = w - 1;
    while (l < r && col[l] < min) l++;
    while (r > l && col[r] < min) r--;
    if (l === 0 && r === w - 1) return buf;
    return sharp(buf).extract({ left: l, top: 0, width: r - l + 1, height: h }).toBuffer();
}

async function buildDevice(srcDir, outDir, d) {
    const src = path.join(srcDir, d.src);

    let buf = await sharp(src).ensureAlpha()
        .rotate(d.rotate, { background: { r: 0, g: 0, b: 0, alpha: 0 } })
        .trim({ threshold: 1 })
        .toBuffer();

    // Mirror as its own pass. sharp applies flop before rotate within a single
    // pipeline regardless of chain order, which would mirror the source and
    // leave the rotation angle pointing the wrong way.
    if (d.flop) buf = await sharp(buf).flop().toBuffer();

    if (d.inpaint) {
        const { data, info } = await sharp(buf).raw().toBuffer({ resolveWithObject: true });
        let raw = data;
        for (const spec of d.inpaint) raw = inpaintStrip(raw, info.width, info.height, info.channels, spec);
        buf = await sharp(raw, { raw: { width: info.width, height: info.height, channels: info.channels } })
            .png().toBuffer();
    }

    if (d.trimThin) buf = await trimThinEdges(buf);

    // Final presentation turn, now that every coordinate-sensitive step is done.
    // Skipped when it is a no-op: rotate(0) would still cost a re-encode.
    if (FINAL_TURN % 360 !== 0) {
        buf = await sharp(buf)
            .rotate(FINAL_TURN, { background: { r: 0, g: 0, b: 0, alpha: 0 } })
            .trim({ threshold: 1 })
            .toBuffer();
    }

    const file = path.join(outDir, 'assets/devices', d.out);
    await sharp(buf)
        .resize({ ...CONTENT, fit: 'inside', withoutEnlargement: false })
        .extend(await centreOn(buf))
        .resize(CANVAS.w, CANVAS.h, { fit: 'contain', background: { r: 0, g: 0, b: 0, alpha: 0 } })
        .webp({ quality: 82, alphaQuality: 90, effort: 6 })
        .toFile(file);
    return file;
}

// The contain-resize below already centres, so extension is a no-op kept for
// clarity of the pipeline's shape.
async function centreOn() { return { top: 0, bottom: 0, left: 0, right: 0, background: { r: 0, g: 0, b: 0, alpha: 0 } }; }

/**
 * Trim, scale to a common optical weight, and centre a brand mark.
 */
async function buildBrand(srcDir, outDir, brandDir, l) {
    const src = path.join(brandDir || srcDir, l.src);
    const trimmed = await sharp(src).ensureAlpha().trim({ threshold: 1 }).toBuffer();
    const m = await sharp(trimmed).metadata();

    // Equal-area scaling, then clamp so nothing overflows the box.
    let scale = Math.sqrt(BRAND_AREA / (m.width * m.height));
    scale = Math.min(scale, BRAND_BOX.w / m.width, BRAND_BOX.h / m.height);
    const w = Math.max(1, Math.round(m.width * scale));
    const h = Math.max(1, Math.round(m.height * scale));

    const resized = await sharp(trimmed).resize(w, h, { fit: 'fill' }).toBuffer();
    const file = path.join(outDir, 'assets/logos', l.out);
    await sharp({
        create: { width: BRAND_CANVAS.w, height: BRAND_CANVAS.h, channels: 4,
                  background: { r: 0, g: 0, b: 0, alpha: 0 } }
    })
        .composite([{ input: resized, gravity: 'center' }])
        .webp({ quality: 90, alphaQuality: 100, effort: 6 })
        .toFile(file);
    return { file, w, h };
}

async function main() {
    const srcDir = process.argv[2];
    if (!srcDir) { console.error('usage: node tools/process-guide-art.mjs <source-dir> [--out DIR]'); process.exit(1); }
    const oi = process.argv.indexOf('--out');
    const outDir = oi > -1 ? process.argv[oi + 1] : '.';

    if (process.argv.includes('--measure')) {
        for (const d of DEVICES) {
            const a = await principalAxis(path.join(srcDir, d.src));
            console.log(`${d.src.padEnd(38)} principal axis ${a.toFixed(1)}°  -> rotate ${(-a).toFixed(1)}°`);
        }
        return;
    }

    await mkdir(path.join(outDir, 'assets/devices'), { recursive: true });
    await mkdir(path.join(outDir, 'assets/logos'), { recursive: true });

    for (const d of DEVICES) {
        const f = await buildDevice(srcDir, outDir, d);
        const m = await sharp(f).metadata();
        const { size } = await stat(f);
        console.log(`${d.out.padEnd(20)} ${m.width}x${m.height}  ${(size / 1024).toFixed(1)}KB${d.note ? '   # ' + d.note : ''}`);
    }

    const brandDir = path.join(srcDir, 'brand');
    for (const l of BRANDS) {
        const { file, w, h } = await buildBrand(srcDir, outDir, brandDir, l);
        const { size } = await stat(file);
        console.log(`${l.out.padEnd(20)} ${w}x${h} on ${BRAND_CANVAS.w}x${BRAND_CANVAS.h}  ${(size / 1024).toFixed(1)}KB${l.note ? '   # ' + l.note : ''}`);
    }

    for (const l of LOGOS) {
        const dest = path.join(outDir, 'assets/logos', l.out);
        if (l.copy) {
            await copyFile(path.join(srcDir, l.src), dest);
            console.log(`${l.out.padEnd(20)} copied verbatim`);
        } else {
            await sharp(path.join(srcDir, l.src)).ensureAlpha().trim({ threshold: 1 })
                .resize({ width: 480, fit: 'inside' })
                .webp({ quality: 90, alphaQuality: 100, effort: 6 }).toFile(dest);
            const m = await sharp(dest).metadata();
            const { size } = await stat(dest);
            console.log(`${l.out.padEnd(20)} ${m.width}x${m.height}  ${(size / 1024).toFixed(1)}KB`);
        }
    }
}

main().catch(e => { console.error(e); process.exit(1); });
