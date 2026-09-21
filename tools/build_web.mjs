import { readFile, mkdir, writeFile } from 'node:fs/promises';

const root = new URL('../', import.meta.url);
const source = await readFile(new URL('tools/kiwoom_proxy.ps1', root), 'utf8');
const match = source.match(/function Get-DashboardHtml\s*\{\s*return @'\r?\n([\s\S]*?)\r?\n'@/);
if (!match || !match[1].includes('</html>')) throw new Error('Dashboard HTML not found');
const html = match[1].replace('</head>', '<script>globalThis.TOPPICKS_CLOUD=true;</script>\n</head>');
await mkdir(new URL('dist/', root), { recursive: true });
await writeFile(new URL('dist/index.html', root), html, 'utf8');
console.log('Built dist/index.html from the shared dashboard; no reports or credentials included.');
