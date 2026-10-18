import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.resolve(__dirname, 'src', 'HaloWebsite');
const WWWROOT_DIR = path.resolve(ROOT_DIR, 'wwwroot');
const PAGES_DIR = path.resolve(ROOT_DIR, 'Pages');
const LAYOUT_PATH = path.resolve(PAGES_DIR, 'Shared', '_Layout.cshtml');

const PORT = parseInt(process.env.PORT || '8088', 10);

const MIME_TYPES = {
    '.html': 'text/html; charset=utf-8',
    '.css': 'text/css; charset=utf-8',
    '.js': 'application/javascript; charset=utf-8',
    '.mjs': 'application/javascript; charset=utf-8',
    '.json': 'application/json; charset=utf-8',
    '.svg': 'image/svg+xml',
    '.png': 'image/png',
    '.jpg': 'image/jpeg',
    '.jpeg': 'image/jpeg',
    '.webp': 'image/webp',
    '.ico': 'image/x-icon',
    '.dmg': 'application/x-apple-diskimage',
    '.zip': 'application/zip'
};

function renderPage(pagePath) {
    if (!fs.existsSync(pagePath) || !fs.existsSync(LAYOUT_PATH)) {
        return '<h1>500 - Page template missing</h1>';
    }

    const layoutRaw = fs.readFileSync(LAYOUT_PATH, 'utf-8');
    const pageRaw = fs.readFileSync(pagePath, 'utf-8');

    // Extract title from @{ ViewData["Title"] = "..."; }
    let pageTitle = 'Halo AI — The Smarter Mac Assistant';
    const titleMatch = pageRaw.match(/ViewData\["Title"\]\s*=\s*"([^"]+)"/);
    if (titleMatch && titleMatch[1]) {
        pageTitle = titleMatch[1];
    }

    // Strip Razor header blocks: @page, @model ..., and @{ ... }
    let body = pageRaw
        .replace(/^@page[^\r\n]*/m, '')
        .replace(/^@model[^\r\n]*/m, '')
        .replace(/@\{[\s\S]*?\}/m, '')
        .trim();

    // Combine with layout
    let html = layoutRaw
        .replace('@RenderBody()', body)
        .replace(/@ViewData\["Title"\]/g, pageTitle)
        .replace(/@DateTime\.Now\.Year/g, new Date().getFullYear().toString())
        .replace(/asp-append-version="true"/g, '')
        .replace(/~\//g, '/');

    return html;
}

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    let pathname = decodeURIComponent(url.pathname);

    // Normalize route
    if (pathname === '/' || pathname === '/index' || pathname === '/index.html') {
        const html = renderPage(path.resolve(PAGES_DIR, 'Index.cshtml'));
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(html);
    }

    if (pathname === '/changelog' || pathname === '/changelog.html') {
        const html = renderPage(path.resolve(PAGES_DIR, 'Changelog.cshtml'));
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(html);
    }

    if (pathname === '/download') {
        // Download redirect or informative page
        res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
        return res.end(`
            <!DOCTYPE html>
            <html lang="en">
            <head>
                <meta charset="utf-8">
                <title>Downloading Halo AI for macOS</title>
                <link rel="stylesheet" href="/css/site.css">
                <style>
                    body { display: flex; align-items: center; justify-content: center; min-height: 100vh; text-align: center; font-family: -apple-system, BlinkMacSystemFont, "SF Pro", sans-serif; background: #000; color: #fff; }
                    .dl-box { max-width: 480px; padding: 48px; border-radius: 24px; background: rgba(30, 30, 35, 0.8); border: 1px solid rgba(255, 255, 255, 0.15); backdrop-filter: blur(24px); box-shadow: 0 20px 50px rgba(0,0,0,0.5); }
                    .dl-badge { font-size: 13px; color: #38bdf8; font-weight: 600; text-transform: uppercase; margin-bottom: 12px; }
                    h1 { font-size: 28px; margin-bottom: 14px; }
                    p { color: #a1a1a6; font-size: 16px; line-height: 1.5; margin-bottom: 24px; }
                    .btn { display: inline-flex; align-items: center; justify-content: center; padding: 12px 28px; border-radius: 980px; background: #0071E3; color: #fff; font-weight: 600; text-decoration: none; }
                </style>
            </head>
            <body>
                <div class="dl-box">
                    <div class="dl-badge">Apple Silicon · macOS 26+</div>
                    <h1>Halo AI Download</h1>
                    <p>Halo AI (Mercy) is ready for your Mac. In production, this links to your Cloudflare R2 bucket holding <code>HaloAI.dmg</code>.</p>
                    <a href="/" class="btn">← Back to Halo Website</a>
                </div>
            </body>
            </html>
        `);
    }

    // Static assets in wwwroot
    let filePath = path.resolve(WWWROOT_DIR, pathname.startsWith('/') ? pathname.slice(1) : pathname);

    // Prevent directory traversal
    if (!filePath.startsWith(WWWROOT_DIR)) {
        res.writeHead(403, { 'Content-Type': 'text/plain' });
        return res.end('403 Forbidden');
    }

    if (fs.existsSync(filePath) && fs.statSync(filePath).isFile()) {
        const ext = path.extname(filePath).toLowerCase();
        const contentType = MIME_TYPES[ext] || 'application/octet-stream';
        res.writeHead(200, { 'Content-Type': contentType });
        const stream = fs.createReadStream(filePath);
        return stream.pipe(res);
    }

    // Not found
    res.writeHead(404, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end('<h1>404 Not Found</h1><p><a href="/">Return to Halo Home</a></p>');
});

server.listen(PORT, '127.0.0.1', () => {
    console.log(`[HaloWebsite] Server listening on http://localhost:${PORT}`);
});
