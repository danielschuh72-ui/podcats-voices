// Runs the web app's own parser (cut out of app/page.html) over sample scripts and writes what it produced,
// for CoreTests to hold the Swift port against.  node ci/make-fixtures.js <page.html> <scripts dir> <out.json>
const fs = require('fs'), path = require('path');
const [page, dir, out] = process.argv.slice(2);
const src = fs.readFileSync(page, 'utf8');
const a = src.indexOf('var SPEAKER_RE'), b = src.indexOf('function hash(s)');
if (a < 0 || b < 0) throw new Error('parser not found in ' + page);
const api = new Function(src.slice(a, b) + '; return { parseScript, splitSentences, splitLong, buildSegments };')();
const cases = [];
for (const f of fs.readdirSync(dir).sort()) {
  if (!/\.(txt|md)$/.test(f)) continue;
  const script = fs.readFileSync(path.join(dir, f), 'utf8');
  for (const [duo, pause] of [[true, 0.35], [false, 0.2]]) {
    const r = api.buildSegments({ script, format: duo ? 'duo' : 'solo', host1: 'A', host2: 'B', pause });
    cases.push({ name: f, duo, pause, script, lines: r.lines.map(l => [l.speaker, l.text]), segs: r.segs.map(s => [s.line, s.text, s.voice, s.pause]) });
  }
}
fs.writeFileSync(out, JSON.stringify(cases));
console.log(cases.length, 'cases,', cases.reduce((n, c) => n + c.segs.length, 0), 'segments');
