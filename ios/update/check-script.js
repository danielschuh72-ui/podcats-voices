// Loads an update file's script the way the app does and runs it on samples: node check-script.js podcats-update.json
const fs = require('fs'), vm = require('vm');
const pack = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (!pack.js) { console.log('no script in this update'); process.exit(0); }
const ctx = vm.createContext({});
vm.runInContext(pack.js, ctx, { timeout: 2000 });
if (typeof ctx.prepareText !== 'function') throw new Error('the script has no prepareText function');
const samples = ['Revenue was $1,250,000 in 2024. A test.', 'A/R fell to ($3,400,000) and (120) units.', '', 'Plain words (an aside) stay as they are.'];
for (const s of samples) {
  const out = vm.runInContext('prepareText(' + JSON.stringify(s) + ')', ctx, { timeout: 2000 });
  if (typeof out !== 'string') throw new Error('prepareText did not return text for: ' + s);
  console.log(JSON.stringify(s), '->', JSON.stringify(out));
}
