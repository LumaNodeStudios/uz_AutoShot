const path = require('path');
const fs   = require('fs');

// Safe module imports — keeps the resource alive and reporting clear diagnostics
// if node_modules hasn't been installed yet.
let PNG = null;
try {
    ({ PNG } = require('pngjs'));
} catch (e) {
    console.log('^1[uz_AutoShot]^0 pngjs is not installed, captures are disabled. Delete .yarn.installed in the resource folder and restart the server, or run "npm install" there.');
}

let webp = null;
let webpReady = false;
let webpPromise = null;
try {
    webp = require('webp-wasm');
    if (webp && typeof webp.load === 'function') {
        webpPromise = webp.load().then(() => {
            webpReady = true;
        }).catch((err) => {
            console.log('^3[uz_AutoShot]^0 WebP WASM preload warning: ' + (err && err.message ? err.message : err));
        });
    }
} catch (e) {
    console.log('^3[uz_AutoShot]^0 webp-wasm is not installed, WebP encoding will be unavailable until npm/yarn install runs.');
}

let axios = null;
try {
    axios = require('axios');
} catch (_) {}

let FormData = null;
try {
    FormData = require('form-data');
} catch (_) {}

let S3Client = null;
let PutObjectCommand = null;
try {
    ({ S3Client, PutObjectCommand } = require('@aws-sdk/client-s3'));
} catch (_) {}

const RESOURCE      = GetCurrentResourceName();
const RES_PATH      = GetResourcePath(RESOURCE);
const OUTPUT_DIR    = path.resolve(path.join(RES_PATH, 'shots'));
const MAPPINGS_FILE = path.join(OUTPUT_DIR, 'mappings.json');
const MAPPINGS_TABLE = 'autoshot_images';

const MAX_PAYLOAD_BYTES = 20 * 1024 * 1024;

try {
    if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });
} catch (err) {
    console.log('^1[uz_AutoShot]^0 Output dir error: ' + err.message);
}

// ════════════════════════════════════════════════════════
// CONFIG & SETTINGS HELPERS
// ════════════════════════════════════════════════════════

function getConvarConfig() {
    const rawFormat = (GetConvar('uz_autoshot_format', 'webp') || 'webp').toLowerCase();
    const format = rawFormat === 'jpeg' ? 'jpg' : (rawFormat === 'webp' || rawFormat === 'jpg' ? rawFormat : 'png');
    const rawLayout = (GetConvar('uz_autoshot_path_layout', 'lns') || 'lns').toLowerCase().trim();
    const pathLayout = (rawLayout === 'uz' || rawLayout === 'autoshot' || rawLayout === 'legacy') ? 'autoshot' : 'lns_appearance';
    const quality = parseFloat(GetConvar('uz_autoshot_quality', '0.85'));
    return {
        aceRestricted: GetConvar('uz_autoshot_ace_restricted', 'false') === 'true',
        aceCommand:    GetConvar('uz_autoshot_command', 'shotmaker') || 'shotmaker',
        format,
        quality:       Number.isFinite(quality) ? quality : 0.85,
        pathLayout,
        transparent:   GetConvar('uz_autoshot_transparent', 'true') === 'true',
    };
}

function getSvSettings() {
    try {
        const res = global.exports[RESOURCE] && global.exports[RESOURCE].GetSvSettings
            ? global.exports[RESOURCE].GetSvSettings()
            : null;
        return (res && typeof res === 'object') ? res : {};
    } catch (e) {
        return {};
    }
}

function getStorageSettings() {
    const sv = getSvSettings();
    const s = (sv && sv.ImageStorage && typeof sv.ImageStorage === 'object') ? sv.ImageStorage : {};
    const type = String(s.Type || 'local').toLowerCase();
    const mappingStorage = String(s.MappingStorage || 'auto').toLowerCase();
    const webpQualityRaw = Number(s.WebPQuality);
    const webpQuality = Number.isFinite(webpQualityRaw) ? Math.min(100, Math.max(1, Math.round(webpQualityRaw))) : 85;
    return {
        type: (type === 'qbox' || type === 'fivemanage' || type === 'r2') ? type : 'local',
        mappingStorage: (mappingStorage === 'mysql' || mappingStorage === 'json') ? mappingStorage : 'auto',
        webpQuality,
        saveLocalCopy: s.SaveLocalCopy === true,
        qbox: (s.Qbox && typeof s.Qbox === 'object') ? s.Qbox : {},
        fivemanage: (s.Fivemanage && typeof s.Fivemanage === 'object') ? s.Fivemanage : {},
        r2: (s.R2 && typeof s.R2 === 'object') ? s.R2 : {},
    };
}

function checkPermission(src) {
    if (!src || src === 0 || src === '0') return true;
    const cfg = getConvarConfig();
    if (!cfg.aceRestricted) return true;

    const s = src.toString();
    const numSrc = Number(src);
    if (
        IsPlayerAceAllowed(s, 'command.' + cfg.aceCommand) ||
        IsPlayerAceAllowed(s, 'command') ||
        IsPlayerAceAllowed(s, 'admin') ||
        IsPlayerAceAllowed(s, 'group.admin')
    ) {
        return true;
    }

    if (GetResourceState('qbx_core') === 'started') {
        try {
            const qbx = global.exports['qbx_core'];
            if (qbx && (qbx.HasPermission(numSrc, 'admin') || qbx.HasPermission(numSrc, 'god'))) {
                return true;
            }
        } catch (_) {}
    }

    if (GetResourceState('es_extended') === 'started') {
        try {
            const esx = global.exports['es_extended'];
            const ESX = esx && esx.getSharedObject ? esx.getSharedObject() : null;
            const p = ESX && ESX.GetPlayerFromId ? ESX.GetPlayerFromId(numSrc) : null;
            const group = p && p.getGroup ? p.getGroup() : null;
            if (group === 'admin' || group === 'god' || group === 'superadmin') {
                return true;
            }
        } catch (_) {}
    }

    return false;
}

// ════════════════════════════════════════════════════════
// KEY NORMALIZATION & PATH LAYOUT HELPERS
// ════════════════════════════════════════════════════════

const LNS_COMPONENT_FOLDERS = {
    0: 'components', 1: 'masks', 2: 'hair', 3: 'torsos',
    4: 'legs', 5: 'bags', 6: 'shoes', 7: 'accessories',
    8: 'undershirts', 9: 'armor', 10: 'decals', 11: 'tops',
};

const LNS_PROP_FOLDERS = {
    0: 'hats', 1: 'glasses', 2: 'ears', 6: 'watches', 7: 'bracelets',
};

function normalizeKey(rawKey) {
    if (typeof rawKey !== 'string') return null;
    let key = rawKey.trim().replace(/^\/+|\/+$/g, '');
    if (!key || key.includes('\0') || key.includes('\\') || path.isAbsolute(key)) return null;

    // Strip optional trailing image extension so keys stay canonical across formats
    key = key.replace(/\.(webp|png|jpe?g)$/i, '');
    if (!key) return null;

    const segments = key.split('/');
    for (const seg of segments) {
        if (!seg || seg === '.' || seg === '..' || seg.includes('..')) return null;
    }

    if (key.length > 191) return null;
    return key;
}

function buildPhotoKey(gender, itemType, id, drawable, texture, layoutOverride) {
    const raw = String(layoutOverride || getConvarConfig().pathLayout || 'lns').toLowerCase().trim();
    const layout = (raw === 'uz' || raw === 'autoshot' || raw === 'legacy') ? 'autoshot' : 'lns_appearance';
    const g = gender === 'female' ? 'female' : 'male';
    const numId = Number(id) || 0;
    const numDraw = Number(drawable) || 0;
    const numTex = Number(texture) || 0;

    if (layout === 'lns_appearance') {
        if (itemType === 'component') {
            const folder = LNS_COMPONENT_FOLDERS[numId] || `component_${numId}`;
            return `${g}/${folder}/${numDraw}/${numTex}`;
        }
        if (itemType === 'prop') {
            const folder = LNS_PROP_FOLDERS[numId] || `prop_${numId}`;
            return `${g}/${folder}/${numDraw}/${numTex}`;
        }
        if (itemType === 'overlay') {
            return `${g}/overlays/${numId}/${numDraw}`;
        }
        if (itemType === 'tattoo') {
            return `${g}/tattoos/${String(id).toLowerCase()}/${String(drawable).toLowerCase()}`;
        }
        if (itemType === 'vehicle') {
            return `vehicles/${String(id)}`;
        }
        if (itemType === 'object') {
            return `objects/${String(id)}`;
        }
    }

    // Default 'autoshot' layout
    if (itemType === 'component') {
        return numTex > 0 ? `${g}/${numId}/${numDraw}_${numTex}` : `${g}/${numId}/${numDraw}`;
    }
    if (itemType === 'prop') {
        return numTex > 0 ? `${g}/prop_${numId}/${numDraw}_${numTex}` : `${g}/prop_${numId}/${numDraw}`;
    }
    if (itemType === 'overlay') {
        return `${g}/overlay_${numId}/${numDraw}`;
    }
    if (itemType === 'tattoo') {
        return `${g}/tattoos/${String(id).toLowerCase()}/${String(drawable).toLowerCase()}`;
    }
    if (itemType === 'vehicle') {
        return `vehicles/${String(id)}`;
    }
    if (itemType === 'object') {
        return `objects/${String(id)}`;
    }
    return null;
}

function getSafeLocalPath(key, ext) {
    const cleanKey = normalizeKey(key);
    if (!cleanKey) return null;
    const targetPath = path.resolve(path.join(OUTPUT_DIR, `${cleanKey}.${ext}`));
    if (!targetPath.startsWith(OUTPUT_DIR + path.sep)) return null;
    return targetPath;
}

// ════════════════════════════════════════════════════════
// MAPPING PERSISTENCE (oxmysql auto-detect + JSON fallback)
// ════════════════════════════════════════════════════════

let cdnMappingsCache   = {};
let localMappingsCache = {};
let usingMysql         = false;
let mappingsLoaded     = false;
let mappingsLoadPromise = null;
let jsonWriteQueue     = Promise.resolve();

// Debounced batch broadcast for connected clients during large capture runs
let pendingClientPatch = {};
let pendingPatchCount  = 0;
let patchFlushTimer    = null;

function flushClientPatch() {
    if (patchFlushTimer) {
        clearTimeout(patchFlushTimer);
        patchFlushTimer = null;
    }
    if (pendingPatchCount === 0) return;
    const patch = pendingClientPatch;
    pendingClientPatch = {};
    pendingPatchCount  = 0;
    emitNet('uz_autoshot:client:mappingsPatch', -1, patch);
}

function queueClientMappingBroadcast(key, url, directSrc) {
    if (directSrc && Number(directSrc) > 0) {
        emitNet('uz_autoshot:client:mappingUpdated', Number(directSrc), key, url);
    }
    pendingClientPatch[key] = url;
    pendingPatchCount++;

    if (pendingPatchCount >= 25) {
        flushClientPatch();
        return;
    }
    if (!patchFlushTimer) {
        patchFlushTimer = setTimeout(flushClientPatch, 600);
    }
}

function scanLocalShotsDir() {
    const found = {};
    if (!fs.existsSync(OUTPUT_DIR)) return found;

    const exts = new Set(['.png', '.webp', '.jpg', '.jpeg']);
    function walk(dir, relPrefix) {
        let entries;
        try {
            entries = fs.readdirSync(dir, { withFileTypes: true });
        } catch (_) {
            return;
        }
        for (const entry of entries) {
            if (entry.name.startsWith('.')) continue;
            const full = path.join(dir, entry.name);
            const rel  = relPrefix ? `${relPrefix}/${entry.name}` : entry.name;
            if (entry.isDirectory()) {
                walk(full, rel);
            } else if (entry.isFile()) {
                if (rel === 'mappings.json') continue;
                const ext = path.extname(entry.name).toLowerCase();
                if (!exts.has(ext)) continue;
                const key = rel.slice(0, -ext.length);
                found[key] = `https://cfx-nui-${RESOURCE}/shots/${rel}`;
            }
        }
    }
    walk(OUTPUT_DIR, '');
    return found;
}

function isMysqlAvailable() {
    if (GetResourceState('oxmysql') !== 'started') return false;
    try {
        return !!(global.exports.oxmysql && typeof global.exports.oxmysql.execute_async === 'function');
    } catch (_) {
        return false;
    }
}

async function ensureMappingsTable() {
    await global.exports.oxmysql.execute_async(
        `CREATE TABLE IF NOT EXISTS \`${MAPPINGS_TABLE}\` (
            \`image_key\` VARCHAR(191) NOT NULL PRIMARY KEY,
            \`url\` VARCHAR(512) NOT NULL,
            \`updated_at\` TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )`
    );
}

function readJsonMappings() {
    if (!fs.existsSync(MAPPINGS_FILE)) return {};
    try {
        const raw = fs.readFileSync(MAPPINGS_FILE, 'utf8');
        const parsed = JSON.parse(raw);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
            return parsed;
        }
    } catch (e) {
        console.log('^3[uz_AutoShot]^0 Failed to parse shots/mappings.json: ' + e.message);
    }
    return {};
}

function writeJsonMappings(snapshot) {
    jsonWriteQueue = jsonWriteQueue.then(() => {
        try {
            if (!fs.existsSync(OUTPUT_DIR)) fs.mkdirSync(OUTPUT_DIR, { recursive: true });
            const tmp = MAPPINGS_FILE + '.tmp';
            fs.writeFileSync(tmp, JSON.stringify(snapshot, null, 2), 'utf8');
            fs.renameSync(tmp, MAPPINGS_FILE);
        } catch (e) {
            console.log('^1[uz_AutoShot]^0 Failed to write shots/mappings.json: ' + e.message);
        }
    });
    return jsonWriteQueue;
}

async function loadMappings(force) {
    if (mappingsLoaded && !force) return;
    if (mappingsLoadPromise && !force) return mappingsLoadPromise;

    mappingsLoadPromise = (async () => {
        const storage = getStorageSettings();
        const wantMysql = storage.mappingStorage === 'mysql'
            || (storage.mappingStorage === 'auto' && isMysqlAvailable());

        usingMysql = false;
        cdnMappingsCache = {};

        if (wantMysql && isMysqlAvailable()) {
            try {
                await ensureMappingsTable();
                const rows = await global.exports.oxmysql.query_async(
                    `SELECT \`image_key\`, \`url\` FROM \`${MAPPINGS_TABLE}\``
                );
                for (const row of rows || []) {
                    if (row && row.image_key && row.url) {
                        cdnMappingsCache[row.image_key] = row.url;
                    }
                }
                usingMysql = true;
            } catch (e) {
                console.log('^3[uz_AutoShot]^0 oxmysql unavailable for mappings, falling back to shots/mappings.json: ' + e.message);
                usingMysql = false;
                cdnMappingsCache = readJsonMappings();
            }
        } else {
            if (storage.mappingStorage === 'mysql') {
                console.log('^3[uz_AutoShot]^0 MappingStorage is set to "mysql" but oxmysql is not started; using shots/mappings.json until MySQL is ready.');
            }
            cdnMappingsCache = readJsonMappings();
        }

        localMappingsCache = scanLocalShotsDir();
        mappingsLoaded = true;
    })();

    try {
        await mappingsLoadPromise;
    } finally {
        mappingsLoadPromise = null;
    }
}

async function saveMapping(key, url, src, isLocal) {
    await loadMappings(false);

    if (isLocal) {
        localMappingsCache[key] = url;
        queueClientMappingBroadcast(key, url, src);
        return;
    }

    cdnMappingsCache[key] = url;
    if (usingMysql) {
        try {
            await global.exports.oxmysql.execute_async(
                `INSERT INTO \`${MAPPINGS_TABLE}\` (\`image_key\`, \`url\`) VALUES (?, ?)
                 ON DUPLICATE KEY UPDATE \`url\` = VALUES(\`url\`)`,
                [key, url]
            );
        } catch (e) {
            console.log('^1[uz_AutoShot]^0 Failed to persist MySQL mapping for ' + key + ': ' + e.message);
        }
    } else {
        await writeJsonMappings({ ...cdnMappingsCache });
    }

    queueClientMappingBroadcast(key, url, src);
}

function getEffectiveOutputFormat(desiredFormat, transparent) {
    const cfg = getConvarConfig();
    let fmt = (desiredFormat || cfg.format || 'png').toLowerCase();
    if (fmt === 'jpeg') fmt = 'jpg';
    if (fmt !== 'png' && fmt !== 'webp' && fmt !== 'jpg') fmt = 'png';
    // Only JPG cannot preserve transparency
    if (transparent && fmt === 'jpg') fmt = 'png';
    return fmt;
}

function getPublicBaseUrl(storage) {
    if (storage.type === 'local') {
        return `https://cfx-nui-${RESOURCE}/shots`;
    }
    if (storage.type === 'r2') {
        const pub = (storage.r2.PublicUrl || '').replace(/\/+$/g, '');
        if (!pub || pub.includes('pub-xxx.r2.dev')) return '';
        const folder = (storage.r2.Folder || '').replace(/^\/+|\/+$/g, '');
        return folder ? `${pub}/${folder}` : pub;
    }
    return '';
}

function getPublicMappingState() {
    const storage = getStorageSettings();
    const cfg = getConvarConfig();
    const format = getEffectiveOutputFormat(cfg.format, cfg.transparent);
    const activeMap = storage.type === 'local' ? { ...localMappingsCache } : { ...cdnMappingsCache };

    return {
        storageType: storage.type,
        baseUrl: getPublicBaseUrl(storage),
        format,
        pathLayout: cfg.pathLayout,
        mappings: activeMap,
    };
}

function syncAllToPlayer(target) {
    emitNet('uz_autoshot:client:syncMappings', target, getPublicMappingState());
}

on('onResourceStart', (resourceName) => {
    if (resourceName !== RESOURCE) return;
    setTimeout(async () => {
        await loadMappings(true);
        syncAllToPlayer(-1);
    }, 250);
});

onNet('uz_autoshot:server:requestMappings', async () => {
    const src = source;
    await loadMappings(false);
    syncAllToPlayer(src);
});

// ════════════════════════════════════════════════════════
// IMAGE PROCESSING (CHROMA KEY + RESIZE + PNG/WEBP ENCODE)
// ════════════════════════════════════════════════════════

function stripDataUri(b64) {
    if (typeof b64 !== 'string') return b64;
    if (!b64.startsWith('data:')) return b64;
    const comma = b64.indexOf(',');
    return comma === -1 ? b64 : b64.slice(comma + 1);
}

function isPngBuffer(buf) {
    return Buffer.isBuffer(buf) && buf.length >= 8 &&
        buf[0] === 0x89 && buf[1] === 0x50 && buf[2] === 0x4E && buf[3] === 0x47;
}

function isWebpBuffer(buf) {
    return Buffer.isBuffer(buf) && buf.length >= 12 &&
        buf.toString('ascii', 0, 4) === 'RIFF' && buf.toString('ascii', 8, 12) === 'WEBP';
}

function isJpgBuffer(buf) {
    return Buffer.isBuffer(buf) && buf.length >= 3 &&
        buf[0] === 0xFF && buf[1] === 0xD8 && buf[2] === 0xFF;
}

async function ensureWebpReady() {
    if (!webp) return false;
    if (webpReady) return true;
    if (webpPromise) {
        try {
            await webpPromise;
        } catch (_) {}
    } else if (typeof webp.load === 'function') {
        try {
            await webp.load();
            webpReady = true;
        } catch (_) {}
    }
    return webpReady;
}

// Operates in place on a decoded PNG (RGBA).
function removeChromaKey(png, mode) {
    const d = png.data;
    const w = png.width, h = png.height;
    let removed = 0;
    const isMagenta = mode === 'magenta';

    for (let i = 0; i < d.length; i += 4) {
        const r = d[i], g = d[i + 1], b = d[i + 2];
        let keyness = 0;

        if (isMagenta) {
            const rOverG = r - g;
            const bOverG = b - g;
            const minOver = rOverG < bOverG ? rOverG : bOverG;
            const primary = r < b ? r : b;
            if (minOver > 0 && primary > 10) {
                const edgeSoft = minOver < 20 ? minOver / 20 : 1;
                const primarySoft = primary < 40 ? (primary - 10) / 30 : 1;
                keyness = Math.min(1, (rOverG + bOverG) / (r + b + 1)) * edgeSoft * primarySoft;
            }
        } else {
            const gOverR = g - r;
            const gOverB = g - b;
            const minOver = gOverR < gOverB ? gOverR : gOverB;
            if (minOver > 0 && g > 10) {
                const edgeSoft = minOver < 20 ? minOver / 20 : 1;
                const primarySoft = g < 40 ? (g - 10) / 30 : 1;
                keyness = Math.min(1, (gOverR + gOverB) / (g + 1)) * edgeSoft * primarySoft;
            }
        }

        if (keyness > 0) {
            d[i + 3] = (255 * (1 - keyness) + 0.5) | 0;
            if (isMagenta) {
                d[i]     = (r - (r - g) * keyness + 0.5) | 0;
                d[i + 2] = (b - (b - g) * keyness + 0.5) | 0;
            } else {
                const cap = r > b ? r : b;
                d[i + 1] = (g - (g - cap) * keyness + 0.5) | 0;
            }
            removed++;
        }
    }

    // Two-pass alpha feather: 5x5 box blur on alpha channel
    const RADIUS = 2;
    const KERNEL = (RADIUS * 2 + 1) * (RADIUS * 2 + 1);
    const totalPx = w * h;
    const src = new Uint8Array(totalPx);

    for (let pass = 0; pass < 2; pass++) {
        for (let i = 0; i < totalPx; i++) src[i] = d[(i << 2) + 3];

        for (let y = RADIUS; y < h - RADIUS; y++) {
            for (let x = RADIUS; x < w - RADIUS; x++) {
                const idx = y * w + x;
                const a = src[idx];
                if ((a === 0 || a === 255) &&
                    src[idx - 1] === a && src[idx + 1] === a &&
                    src[idx - w] === a && src[idx + w] === a) continue;

                let sum = 0;
                for (let ky = -RADIUS; ky <= RADIUS; ky++) {
                    const rowOff = (y + ky) * w + x;
                    for (let kx = -RADIUS; kx <= RADIUS; kx++) {
                        sum += src[rowOff + kx];
                    }
                }
                d[(idx << 2) + 3] = (sum / KERNEL + 0.5) | 0;
            }
        }
    }

    console.log('^2[uz_AutoShot]^0 Chroma key (' + mode + '): ' + removed + '/' + totalPx + ' pixels removed, edges feathered');
}

function resizePNG(src, targetW, targetH) {
    if (src.width === targetW && src.height === targetH) return src;

    const srcAspect = src.width / src.height;
    const dstAspect = targetW / targetH;

    let cropX = 0, cropY = 0, cropW = src.width, cropH = src.height;
    if (srcAspect > dstAspect) {
        cropW = Math.round(src.height * dstAspect);
        cropX = Math.round((src.width - cropW) / 2);
    } else if (srcAspect < dstAspect) {
        cropH = Math.round(src.width / dstAspect);
        cropY = Math.round((src.height - cropH) / 2);
    }

    const dst = new PNG({ width: targetW, height: targetH, fill: true });
    const sd = src.data, dd = dst.data;
    const sw = src.width;
    const xRatio = cropW / targetW;
    const yRatio = cropH / targetH;
    const isDownscale = cropW > targetW || cropH > targetH;

    if (isDownscale) {
        for (let y = 0; y < targetH; y++) {
            const sy0 = cropY + y * yRatio;
            const sy1 = cropY + (y + 1) * yRatio;
            const iy0 = sy0 | 0;
            const iy1 = Math.min((sy1 | 0) + 1, cropY + cropH);

            for (let x = 0; x < targetW; x++) {
                const sx0 = cropX + x * xRatio;
                const sx1 = cropX + (x + 1) * xRatio;
                const ix0 = sx0 | 0;
                const ix1 = Math.min((sx1 | 0) + 1, cropX + cropW);

                let r = 0, g = 0, b = 0, a = 0, totalW = 0;

                for (let sy = iy0; sy < iy1; sy++) {
                    const wy = (sy < sy0 ? 1 - (sy0 - sy) : sy + 1 > sy1 ? sy1 - sy : 1);
                    const rowOff = sy * sw;

                    for (let sx = ix0; sx < ix1; sx++) {
                        const wx = (sx < sx0 ? 1 - (sx0 - sx) : sx + 1 > sx1 ? sx1 - sx : 1);
                        const w = wx * wy;
                        const si = (rowOff + sx) << 2;
                        r += sd[si]     * w;
                        g += sd[si + 1] * w;
                        b += sd[si + 2] * w;
                        a += sd[si + 3] * w;
                        totalW += w;
                    }
                }

                const di = (y * targetW + x) << 2;
                const inv = 1 / totalW;
                dd[di]     = (r * inv + 0.5) | 0;
                dd[di + 1] = (g * inv + 0.5) | 0;
                dd[di + 2] = (b * inv + 0.5) | 0;
                dd[di + 3] = (a * inv + 0.5) | 0;
            }
        }
    } else {
        const maxCropX = cropX + cropW - 1;
        const maxCropY = cropY + cropH - 1;

        for (let y = 0; y < targetH; y++) {
            const srcY = cropY + y * yRatio;
            const y0 = srcY | 0;
            const y1 = y0 < maxCropY ? y0 + 1 : maxCropY;
            const yf = srcY - y0;
            const yf1 = 1 - yf;
            const rowA = y0 * sw;
            const rowB = y1 * sw;

            for (let x = 0; x < targetW; x++) {
                const srcX = cropX + x * xRatio;
                const x0 = srcX | 0;
                const x1 = x0 < maxCropX ? x0 + 1 : maxCropX;
                const xf = srcX - x0;
                const xf1 = 1 - xf;

                const i00 = (rowA + x0) << 2;
                const i10 = (rowA + x1) << 2;
                const i01 = (rowB + x0) << 2;
                const i11 = (rowB + x1) << 2;
                const di  = (y * targetW + x) << 2;

                const w00 = xf1 * yf1, w10 = xf * yf1, w01 = xf1 * yf, w11 = xf * yf;
                dd[di]     = (sd[i00]     * w00 + sd[i10]     * w10 + sd[i01]     * w01 + sd[i11]     * w11 + 0.5) | 0;
                dd[di + 1] = (sd[i00 + 1] * w00 + sd[i10 + 1] * w10 + sd[i01 + 1] * w01 + sd[i11 + 1] * w11 + 0.5) | 0;
                dd[di + 2] = (sd[i00 + 2] * w00 + sd[i10 + 2] * w10 + sd[i01 + 2] * w01 + sd[i11 + 2] * w11 + 0.5) | 0;
                dd[di + 3] = (sd[i00 + 3] * w00 + sd[i10 + 3] * w10 + sd[i01 + 3] * w01 + sd[i11 + 3] * w11 + 0.5) | 0;
            }
        }
    }

    if (isDownscale) {
        const STRENGTH = 0.3;
        for (let y = 1; y < targetH - 1; y++) {
            for (let x = 1; x < targetW - 1; x++) {
                const ci = (y * targetW + x) << 2;
                if (dd[ci + 3] === 0) continue;
                const t = (ci - (targetW << 2));
                const b = (ci + (targetW << 2));
                for (let c = 0; c < 3; c++) {
                    const sharp = 5 * dd[ci + c] - dd[t + c] - dd[b + c] - dd[ci - 4 + c] - dd[ci + 4 + c];
                    const blended = dd[ci + c] + (sharp - dd[ci + c]) * STRENGTH;
                    dd[ci + c] = blended < 0 ? 0 : blended > 255 ? 255 : (blended + 0.5) | 0;
                }
            }
        }
    }

    console.log('^2[uz_AutoShot]^0 Crop+Resize: ' + src.width + 'x' + src.height + ' -> ' + cropW + 'x' + cropH + ' -> ' + targetW + 'x' + targetH + (isDownscale ? ' (area avg + sharpen)' : ' (bilinear)'));
    return dst;
}

// ════════════════════════════════════════════════════════
// STORAGE BACKENDS (LOCAL, FIVEMANAGE, R2, QBOX)
// ════════════════════════════════════════════════════════

function getContentType(ext) {
    if (ext === 'webp') return 'image/webp';
    if (ext === 'png')  return 'image/png';
    if (ext === 'jpg' || ext === 'jpeg') return 'image/jpeg';
    return 'image/png';
}

let cachedR2Signature = '';
let cachedR2Client = null;

function getR2Client(config) {
    if (!S3Client) throw new Error('@aws-sdk/client-s3 is not installed');
    const sig = `${config.AccountId}|${config.AccessKeyId}|${config.SecretAccessKey}`;
    if (!cachedR2Client || cachedR2Signature !== sig) {
        cachedR2Client = new S3Client({
            region: 'auto',
            endpoint: `https://${config.AccountId}.r2.cloudflarestorage.com`,
            credentials: {
                accessKeyId: config.AccessKeyId,
                secretAccessKey: config.SecretAccessKey,
            },
        });
        cachedR2Signature = sig;
    }
    return cachedR2Client;
}

function saveLocalImage(key, ext, buffer) {
    const outputPath = getSafeLocalPath(key, ext);
    if (!outputPath) throw new Error('Invalid or unsafe local output path for ' + key);
    const dir = path.dirname(outputPath);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(outputPath, buffer);
    return `https://cfx-nui-${RESOURCE}/shots/${key}.${ext}`;
}

async function uploadToFivemanage(buffer, key, ext, config) {
    if (!axios || !FormData) throw new Error('axios/form-data not installed');
    const relPath = `${key}.${ext}`;
    const relDir  = path.posix.dirname(relPath);
    const baseName = path.posix.basename(relPath);
    const baseFolder = (config.Folder || '').replace(/^\/+|\/+$/g, '');
    const subDir = relDir && relDir !== '.' ? relDir : '';
    const fullFolder = [baseFolder, subDir].filter(Boolean).join('/');

    const form = new FormData();
    form.append('file', buffer, {
        filename: baseName,
        contentType: getContentType(ext),
    });
    form.append('filename', baseName);
    if (fullFolder) form.append('path', fullFolder);

    const response = await axios.post(config.Url || 'https://api.fivemanage.com/api/v3/file', form, {
        headers: {
            ...form.getHeaders(),
            'Authorization': config.Token,
        },
        maxBodyLength: Infinity,
        maxContentLength: Infinity,
        timeout: 30000,
    });

    if (response.data) {
        if (response.data.url) return response.data.url;
        if (response.data.data && response.data.data.url) return response.data.data.url;
    }
    throw new Error('Invalid response from Fivemanage');
}

async function uploadToR2(buffer, key, ext, config) {
    if (!PutObjectCommand) throw new Error('@aws-sdk/client-s3 is not installed');
    const s3 = getR2Client(config);
    const folder = (config.Folder || '').replace(/^\/+|\/+$/g, '');
    const s3Key = folder ? `${folder}/${key}.${ext}` : `${key}.${ext}`;

    await s3.send(new PutObjectCommand({
        Bucket: config.Bucket,
        Key: s3Key,
        Body: buffer,
        ContentType: getContentType(ext),
    }));

    const baseUrl = (config.PublicUrl || '').replace(/\/+$/g, '');
    return `${baseUrl}/${s3Key}`;
}

async function uploadToQbox(buffer, key, ext, config) {
    if (!axios || !FormData) throw new Error('axios/form-data not installed');
    const flatFilename = `${key.replace(/\//g, '_')}.${ext}`;
    const form = new FormData();
    form.append('file', buffer, {
        filename: flatFilename,
        contentType: getContentType(ext),
    });

    const response = await axios.post('https://api.qbox.re/v1/file', form, {
        headers: {
            ...form.getHeaders(),
            'Authorization': config.ApiKey,
        },
        maxBodyLength: Infinity,
        maxContentLength: Infinity,
        timeout: 30000,
    });

    if (response.data) {
        if (response.data.url) return response.data.url;
        if (response.data.data && response.data.data.url) return response.data.data.url;
    }
    throw new Error('Invalid response from Qbox CDN');
}

function validateStorageSetup(storage, outExt) {
    if (outExt === 'webp' && !webp) {
        return 'webp-wasm missing on server. Run npm install in uz_AutoShot or delete .yarn.installed and restart.';
    }
    if (storage.type === 'local') return null;

    if (storage.type === 'qbox') {
        if (!axios || !FormData) return 'axios/form-data missing on server for Qbox CDN.';
        if (!storage.qbox.ApiKey) return 'Qbox CDN ApiKey is missing in server/sv_settings.lua.';
        return null;
    }
    if (storage.type === 'fivemanage') {
        if (!axios || !FormData) return 'axios/form-data missing on server for Fivemanage.';
        if (!storage.fivemanage.Token) return 'Fivemanage Token is missing in server/sv_settings.lua.';
        return null;
    }
    if (storage.type === 'r2') {
        if (!S3Client || !PutObjectCommand) return '@aws-sdk/client-s3 missing on server for Cloudflare R2.';
        const c = storage.r2;
        if (!c.AccountId || !c.AccessKeyId || !c.SecretAccessKey || !c.Bucket || !c.PublicUrl || c.PublicUrl.includes('pub-xxx.r2.dev')) {
            return 'Cloudflare R2 configuration is incomplete in server/sv_settings.lua.';
        }
        return null;
    }
    return 'Unknown storage type: ' + storage.type;
}

// ════════════════════════════════════════════════════════
// CORE PROCESS & UPLOAD PIPELINE
// ════════════════════════════════════════════════════════

function resolveQualityPercent(rawQuality, fallbackQuality) {
    if (rawQuality !== undefined && rawQuality !== null) {
        const q = Number(rawQuality);
        if (Number.isFinite(q)) {
            if (q > 0 && q <= 1) return Math.min(100, Math.max(1, Math.round(q * 100)));
            return Math.min(100, Math.max(1, Math.round(q)));
        }
    }
    return fallbackQuality || 85;
}

async function processAndUploadImage(inputData, rawKey, opts = {}, src = 0) {
    const cleanKey = normalizeKey(rawKey);
    if (!cleanKey) {
        throw new Error('Invalid image key/filename: ' + String(rawKey));
    }

    let rawBuffer;
    if (Buffer.isBuffer(inputData)) {
        rawBuffer = inputData;
    } else if (typeof inputData === 'string' && inputData.length > 0) {
        if (inputData.length > Math.ceil(MAX_PAYLOAD_BYTES * 4 / 3) + 64) {
            throw new Error('Payload too large for ' + cleanKey);
        }
        rawBuffer = Buffer.from(stripDataUri(inputData), 'base64');
    } else {
        throw new Error('Empty image data for ' + cleanKey);
    }

    if (!rawBuffer || rawBuffer.length === 0) {
        throw new Error('Invalid base64/buffer for ' + cleanKey);
    }

    const cfg         = getConvarConfig();
    const storage     = getStorageSettings();
    const wantTransp  = opts.transparent !== undefined
        ? (opts.transparent === true || opts.transparent === '1' || opts.transparent === 1)
        : cfg.transparent;
    const chromaKey   = typeof opts.chromaKey === 'string' ? opts.chromaKey.toLowerCase() : 'green';
    const wantWidth   = parseInt(opts.width, 10) || 0;
    const wantHeight  = parseInt(opts.height, 10) || 0;
    const wantResize  = wantWidth > 0 && wantHeight > 0;
    const outExt      = getEffectiveOutputFormat(opts.format || opts.outputFormat || cfg.format, wantTransp);
    const qualityPct  = resolveQualityPercent(opts.quality, storage.webpQuality);

    const storageErr = validateStorageSetup(storage, outExt);
    if (storageErr) throw new Error(storageErr);

    let finalBuffer = rawBuffer;
    const inputIsPng  = isPngBuffer(rawBuffer);
    const inputIsWebp = isWebpBuffer(rawBuffer);
    const inputIsJpg  = isJpgBuffer(rawBuffer);

    const needPngDecode = wantTransp || wantResize || (outExt === 'webp' && !inputIsWebp);

    if (needPngDecode) {
        if (!inputIsPng) {
            if (outExt === 'jpg' && inputIsJpg && !wantTransp && !wantResize) {
                // Already JPEG and no processing needed
            } else if (!inputIsWebp) {
                throw new Error('PNG input is required for chroma key, resize, or WebP encoding (' + cleanKey + ')');
            }
        } else {
            if (!PNG) throw new Error('pngjs is not installed (' + cleanKey + ')');

            let png;
            try {
                png = PNG.sync.read(rawBuffer);
            } catch (e) {
                throw new Error('PNG decode failed for ' + cleanKey + ': ' + e.message);
            }

            let changed = false;
            if (wantTransp) {
                removeChromaKey(png, chromaKey);
                changed = true;
            }

            if (wantResize) {
                const MAX_DIM = 4096;
                const clampedW = Math.min(Math.max(wantWidth, 16), MAX_DIM);
                const clampedH = Math.min(Math.max(wantHeight, 16), MAX_DIM);
                const resized = resizePNG(png, clampedW, clampedH);
                if (resized !== png) {
                    png = resized;
                    changed = true;
                }
            }

            if (outExt === 'webp') {
                const ok = await ensureWebpReady();
                if (!ok) throw new Error('webp-wasm failed to initialize');
                const webpData = await webp.encode({
                    data: new Uint8ClampedArray(png.data),
                    width: png.width,
                    height: png.height,
                }, { quality: qualityPct });
                finalBuffer = Buffer.from(webpData);
            } else if (changed || outExt === 'png') {
                finalBuffer = changed ? PNG.sync.write(png, { colorType: 6 }) : rawBuffer;
            }
        }
    }

    let uploadedUrl = null;

    if (storage.type === 'local') {
        uploadedUrl = saveLocalImage(cleanKey, outExt, finalBuffer);
        await saveMapping(cleanKey, uploadedUrl, src, true);
    } else {
        if (storage.saveLocalCopy) {
            try {
                saveLocalImage(cleanKey, outExt, finalBuffer);
            } catch (e) {
                console.log('^3[uz_AutoShot]^0 SaveLocalCopy warning for ' + cleanKey + ': ' + e.message);
            }
        }

        if (storage.type === 'fivemanage') {
            uploadedUrl = await uploadToFivemanage(finalBuffer, cleanKey, outExt, storage.fivemanage);
        } else if (storage.type === 'r2') {
            uploadedUrl = await uploadToR2(finalBuffer, cleanKey, outExt, storage.r2);
        } else if (storage.type === 'qbox') {
            uploadedUrl = await uploadToQbox(finalBuffer, cleanKey, outExt, storage.qbox);
        }

        await saveMapping(cleanKey, uploadedUrl, src, false);
    }

    const sizeKB = Math.max(1, Math.round(finalBuffer.length / 1024));
    const label = wantTransp ? `${outExt}, bg removed` : outExt;
    console.log(`^2[uz_AutoShot]^0 Saved [${storage.type}]: ${cleanKey}.${outExt} (${sizeKB} KB, ${label})`);

    return {
        ok: true,
        key: cleanKey,
        url: uploadedUrl,
        format: outExt,
        storageType: storage.type,
    };
}

// ════════════════════════════════════════════════════════
// NETWORK EVENTS
// ════════════════════════════════════════════════════════

onNet('uz_autoshot:server:processCapture', async (payload) => {
    const src = source;
    const uploadId = payload && typeof payload === 'object' ? payload.id : undefined;

    try {
        if (!checkPermission(src)) {
            console.log('^1[uz_AutoShot]^0 Refused capture: player ' + src + ' lacks permission');
            return;
        }
        if (!payload || typeof payload !== 'object') return;

        await processAndUploadImage(payload.imageData, payload.filename, {
            format:      payload.outputFormat || payload.format,
            quality:     payload.quality,
            transparent: payload.transparent,
            chromaKey:   payload.chromaKey,
            width:       payload.width,
            height:      payload.height,
        }, src);
    } catch (err) {
        console.log('^1[uz_AutoShot]^0 Process error: ' + (err && err.message ? err.message : err));
    } finally {
        if (uploadId !== undefined) {
            emitNet('uz_autoshot:client:captureProcessed', src, uploadId);
        }
    }
});

// Readiness check sent by the client before entering the studio.
onNet('uz_autoshot:server:ping', async (opts) => {
    const src = source;
    let reason = null;
    const cfg = getConvarConfig();
    const storage = getStorageSettings();
    const wantTransp = (opts && opts.transparent !== undefined) ? opts.transparent === true : cfg.transparent;
    const desiredExt = getEffectiveOutputFormat(opts && opts.format ? opts.format : cfg.format, wantTransp);

    if (!checkPermission(src)) {
        reason = 'You lack permission (command.' + cfg.aceCommand + ') on the server.';
    } else if (!PNG) {
        reason = 'pngjs missing on server. Delete .yarn.installed and restart the server.';
    } else {
        if (desiredExt === 'webp') {
            await ensureWebpReady();
        }
        reason = validateStorageSetup(storage, desiredExt);
    }

    emitNet('uz_autoshot:client:pong', src, {
        ok: reason === null,
        reason,
        storageType: storage.type,
        format: desiredExt,
        baseUrl: getPublicBaseUrl(storage),
    });
});

onNet('uz_autoshot:server:setBucket', (bucket) => {
    const src = source;
    if (!checkPermission(src)) {
        console.log('^1[uz_AutoShot]^0 Refused setBucket: player ' + src + ' lacks permission');
        return;
    }
    SetPlayerRoutingBucket(src.toString(), bucket);
    console.log('^2[uz_AutoShot]^0 Player ' + src + ' -> bucket ' + bucket);
});

onNet('uz_autoshot:server:resetBucket', () => {
    const src = source;
    if (!checkPermission(src)) {
        console.log('^1[uz_AutoShot]^0 Refused resetBucket: player ' + src + ' lacks permission');
        return;
    }
    SetPlayerRoutingBucket(src.toString(), 0);
    console.log('^2[uz_AutoShot]^0 Player ' + src + ' -> bucket 0');
});

// ════════════════════════════════════════════════════════
// SERVER EXPORTS
// ════════════════════════════════════════════════════════

global.exports('GetImageMappings', () => {
    const state = getPublicMappingState();
    return state;
});

global.exports('GetStorageConfig', () => {
    const cfg = getConvarConfig();
    const storage = getStorageSettings();
    return {
        type: storage.type,
        mappingStorage: storage.mappingStorage,
        webpQuality: storage.webpQuality,
        saveLocalCopy: storage.saveLocalCopy,
        baseUrl: getPublicBaseUrl(storage),
        format: getEffectiveOutputFormat(cfg.format, cfg.transparent),
        pathLayout: cfg.pathLayout,
    };
});

global.exports('HasImage', (rawKey) => {
    const cleanKey = normalizeKey(rawKey);
    if (!cleanKey) return false;
    const storage = getStorageSettings();
    if (storage.type === 'local') {
        if (localMappingsCache[cleanKey]) return true;
        for (const ext of ['webp', 'png', 'jpg']) {
            const p = getSafeLocalPath(cleanKey, ext);
            if (p && fs.existsSync(p)) return true;
        }
        return false;
    }
    return Boolean(cdnMappingsCache[cleanKey]);
});

global.exports('GetPhotoURL', (genderOrKey, itemType, id, drawable, texture, opts) => {
    const state = getPublicMappingState();
    let key = null;
    let ext = state.format;
    let layout = (opts && opts.pathLayout) || state.pathLayout;

    if (itemType === undefined && typeof genderOrKey === 'string') {
        if (typeof id === 'string') ext = id;
        key = normalizeKey(genderOrKey);
    } else {
        if (opts && opts.format) ext = getEffectiveOutputFormat(opts.format, true);
        key = buildPhotoKey(genderOrKey, itemType, id, drawable, texture, layout);
    }

    if (!key) return null;
    if (state.mappings && state.mappings[key]) return state.mappings[key];
    if (state.baseUrl) return `${state.baseUrl}/${key}.${ext}`;
    return null;
});

global.exports('UploadCapture', async (base64OrBuffer, key, opts) => {
    try {
        return await processAndUploadImage(base64OrBuffer, key, opts || {}, 0);
    } catch (err) {
        console.log('^1[uz_AutoShot]^0 UploadCapture failed: ' + (err && err.message ? err.message : err));
        return { ok: false, error: err && err.message ? err.message : String(err) };
    }
});

global.exports('DeleteMapping', async (rawKey) => {
    const cleanKey = normalizeKey(rawKey);
    if (!cleanKey) return false;
    await loadMappings(false);

    const storage = getStorageSettings();
    let changed = false;

    if (cdnMappingsCache[cleanKey]) {
        delete cdnMappingsCache[cleanKey];
        changed = true;
        if (usingMysql) {
            try {
                await global.exports.oxmysql.execute_async(
                    `DELETE FROM \`${MAPPINGS_TABLE}\` WHERE \`image_key\` = ?`,
                    [cleanKey]
                );
            } catch (e) {
                console.log('^1[uz_AutoShot]^0 Failed to delete MySQL mapping: ' + e.message);
            }
        } else {
            await writeJsonMappings({ ...cdnMappingsCache });
        }
    }

    if (localMappingsCache[cleanKey]) {
        delete localMappingsCache[cleanKey];
        changed = true;
    }

    if (storage.type === 'local' || storage.saveLocalCopy) {
        for (const ext of ['webp', 'png', 'jpg', 'jpeg']) {
            const p = getSafeLocalPath(cleanKey, ext);
            if (p && fs.existsSync(p)) {
                try { fs.unlinkSync(p); } catch (_) {}
            }
        }
    }

    if (changed) syncAllToPlayer(-1);
    return changed;
});

global.exports('ClearMappings', async () => {
    await loadMappings(false);
    cdnMappingsCache = {};
    if (usingMysql) {
        try {
            await global.exports.oxmysql.execute_async(`TRUNCATE TABLE \`${MAPPINGS_TABLE}\``);
        } catch (e) {
            console.log('^1[uz_AutoShot]^0 Failed to clear MySQL mappings: ' + e.message);
        }
    } else {
        await writeJsonMappings({});
    }
    localMappingsCache = scanLocalShotsDir();
    syncAllToPlayer(-1);
    return true;
});
