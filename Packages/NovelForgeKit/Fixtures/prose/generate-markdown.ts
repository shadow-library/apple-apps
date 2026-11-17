import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const platformRepo = process.env.PLATFORM_REPO;
if (!platformRepo) throw new Error('PLATFORM_REPO must point at the platform checkout');

const sanitize = await import(join(platformRepo, 'apps/novel-forge-server/src/common/sanitize-content.ts'));
const outDir = dirname(fileURLToPath(import.meta.url));

const SCHEMES = ['javascript', 'JavaScript', 'JAVASCRIPT', 'vbscript', 'VbScript', 'data', 'DATA', 'http', 'https', 'mailto', 'file', 'ftp', 'tel', 'javascripts', 'xjavascript', 'java script'];
const SEPARATORS = [':', '&colon;', '&COLON;', '&#58;', '&#x3a;', '&#X3A;', '&#58', '&colon', '&Colon;'];
const PADDING = ['', ' ', '\t', '  ', '&Tab;', '&#9;', '&#x09;', '&newline;', '&NewLine;', '&#10;'];
const LETTERS = ['', '&#106;', '&#x6A;', '&#74;', '&amp;#106;', '&lt;', '&nbsp;', '&sol;', '&apos;', '&quot;'];
const TAILS = ['alert(1)', 'text/html,<b>', '//example.com', '/path#frag', '', 'x y'];

const urls = new Set<string>(['', 'https://example.com', '/relative', '#anchor', '?q=javascript:', 'a:b']);
for (const scheme of SCHEMES) {
  for (const separator of SEPARATORS) {
    for (const tail of TAILS) urls.add(`${scheme}${separator}${tail}`);
  }
}
for (const pad of PADDING) {
  for (const letters of LETTERS) {
    urls.add(`${pad}java${letters}script:alert(1)`);
    urls.add(`java${pad}script:alert(1)`);
    urls.add(`${pad}${letters}javascript:x`);
  }
}
for (const url of ['javascript\\:alert(1)', 'java\\script:x', 'javascript\\&colon;x', '\\javascript:x', 'data\\:text/html', 'javascript:\\x']) urls.add(url);
for (const code of [0, 1, 9, 10, 13, 31, 32, 33, 0x110000, 0xd800, 0xdfff, 99999999999]) {
  urls.add(`java&#${code};script:x`);
  urls.add(`javascript&#x${code.toString(16)};:x`);
}

const cases: [string, boolean][] = [];
for (const url of [...urls].sort()) {
  if (/[<>\n\r]/.test(url)) continue;
  const markdown = `[t](<${url}>)`;
  const output = sanitize.sanitizeMarkdown(markdown);
  if (output !== 't' && output !== markdown) continue;
  cases.push([url, output === 't']);
}

writeFileSync(join(outDir, 'markdown-urls.json'), JSON.stringify({ cases }) + '\n');
