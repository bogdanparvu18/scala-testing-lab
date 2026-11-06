// Mark completed checks; retain the latest three and every unfinished run.
import fs from 'node:fs';
import path from 'node:path';

const current = path.resolve(process.argv[2]);
const parent = path.dirname(current);
const marker = '.aurora-smoke-passed';
const files = new Set([marker, ...['valid', 'invalid'].flatMap(name =>
    [name + '.clinical', name + '.ast.json', name + '.result.json'])]);
const runName = /^smoke(?:-[0-9a-f]{32}|\.[a-zA-Z0-9]{6})$/;

function completedRuns() {
    const runs = [];
    for (const entry of fs.readdirSync(parent, {withFileTypes:true})) {
        if (!entry.isDirectory() || !runName.test(entry.name)) continue;
        const dir = path.join(parent, entry.name);
        const contents = fs.readdirSync(dir, {withFileTypes:true});
        if (contents.length !== files.size || contents.some(f => !f.isFile() || !files.has(f.name))) continue;
        const finished = fs.statSync(path.join(dir, marker)).mtimeMs;
        runs.push({dir, finished});
    }
    return runs.sort((a,b) => b.finished - a.finished);
}

try {
    if (!runName.test(path.basename(current)) || !fs.lstatSync(current).isDirectory()) {
        throw new Error('Unexpected smoke directory: ' + current);
    }
    fs.writeFileSync(path.join(current, marker), '', {flag:'wx'});
    const older = completedRuns().filter(run => run.dir !== current).slice(2);
    for (const {dir} of older) {
        // Never recursively delete a directory or remove files outside our list.
        for (const name of files) fs.unlinkSync(path.join(dir, name));
        fs.rmdirSync(dir);
    }
} catch (error) {
    console.warn('Smoke history cleanup skipped: ' + error.message);
}
