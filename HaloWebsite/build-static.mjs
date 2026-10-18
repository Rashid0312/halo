import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

const ROOT_DIR = path.resolve(__dirname, 'src', 'HaloWebsite');
const WWWROOT_DIR = path.resolve(ROOT_DIR, 'wwwroot');
const PAGES_DIR = path.resolve(ROOT_DIR, 'Pages');
const LAYOUT_PATH = path.resolve(PAGES_DIR, 'Shared', '_Layout.cshtml');
const DIST_DIR = path.resolve(__dirname, 'dist');

function renderPage(pagePath) {
    const layoutRaw = fs.readFileSync(LAYOUT_PATH, 'utf-8');
    const pageRaw = fs.readFileSync(pagePath, 'utf-8');

    let pageTitle = 'Halo AI — The Smarter Mac Assistant';
    const titleMatch = pageRaw.match(/ViewData\["Title"\]\s*=\s*"([^"]+)"/);
    if (titleMatch && titleMatch[1]) {
        pageTitle = titleMatch[1];
    }

    let body = pageRaw
        .replace(/^@page[^\r\n]*/m, '')
        .replace(/^@model[^\r\n]*/m, '')
        .replace(/@\{[\s\S]*?\}/m, '')
        .trim();

    let html = layoutRaw
        .replace('@RenderBody()', body)
        .replace(/@ViewData\["Title"\]/g, pageTitle)
        .replace(/@DateTime\.Now\.Year/g, new Date().getFullYear().toString())
        .replace(/asp-append-version="true"/g, '')
        .replace(/~\//g, './'); // relative path for local file:// opening

    return html;
}

if (!fs.existsSync(DIST_DIR)) {
    fs.mkdirSync(DIST_DIR, { recursive: true });
}

// Copy wwwroot assets to dist
fs.cpSync(WWWROOT_DIR, DIST_DIR, { recursive: true });

// Render HTML pages
const indexHtml = renderPage(path.resolve(PAGES_DIR, 'Index.cshtml'));
fs.writeFileSync(path.resolve(DIST_DIR, 'index.html'), indexHtml, 'utf-8');

const changelogHtml = renderPage(path.resolve(PAGES_DIR, 'Changelog.cshtml'));
fs.writeFileSync(path.resolve(DIST_DIR, 'changelog.html'), changelogHtml, 'utf-8');

console.log('✓ Successfully rendered static files to:', DIST_DIR);
