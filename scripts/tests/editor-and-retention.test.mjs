import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import http from 'node:http';
import { mkdtemp, mkdir, writeFile, readdir, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { promisify } from 'node:util';
import test from 'node:test';

const run = promisify(execFile);
const scripts = fileURLToPath(new URL('../', import.meta.url));

test('autocomplete uses project settings and identifies a wrong-release response', async t => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), 'aurora-search-'));
    t.after(() => rm(tmp, {recursive:true, force:true}));
    let responseRelease = '2026-10-05';
    const server = http.createServer((request, response) => {
        const url = new URL(request.url, 'http://localhost');
        assert.equal(url.pathname, '/products');
        assert.equal(url.searchParams.get('release'), '2026-10-05');
        response.end(JSON.stringify({schemaVersion:'1', release:responseRelease, query:'aspi',
            items:[{rxcui:'123', release:responseRelease}]}));
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => server.close());
    const settings = path.join(tmp, 'settings.json');
    await writeFile(settings, JSON.stringify({'clinicalDsl.rxnorm.searchUrl':'http://127.0.0.1:' + server.address().port,
        'clinicalDsl.rxnorm.release':'2026-10-05'}));
    const status = async () => (await run(process.execPath, [path.join(scripts, 'probe-editor.mjs'), 'autocomplete', settings])).stdout.trim();
    assert.equal(await status(), 'ready');
    responseRelease = 'other';
    assert.equal(await status(), 'unexpected-response');
    await writeFile(settings, JSON.stringify({'clinicalDsl.rxnorm.searchEnabled':false}));
    assert.equal(await status(), 'disabled');
});

test('keep three completed smoke fixtures, failed runs and directories with user files', async t => {
    const tmp = await mkdtemp(path.join(os.tmpdir(), 'aurora-retain-'));
    t.after(() => rm(tmp, {recursive:true, force:true}));
    for (const name of ['smoke.AAAAAA', 'smoke.BBBBBB', 'smoke.CCCCCC', 'smoke.DDDDDD', 'smoke.EEEEEE', 'smoke.FFFFFF']) {
        const dir = path.join(tmp, name);
        await mkdir(dir);
        for (const kind of ['valid', 'invalid']) {
            for (const suffix of ['clinical', 'ast.json', 'result.json']) await writeFile(path.join(dir, kind + '.' + suffix), 'fixture');
        }
        if (name === 'smoke.AAAAAA') await writeFile(path.join(dir, 'notes.txt'), 'keep');
        if (name !== 'smoke.BBBBBB') await run(process.execPath, [path.join(scripts, 'finish-smoke.mjs'), dir]);
    }
    assert.deepEqual((await readdir(tmp)).sort(), ['smoke.AAAAAA', 'smoke.BBBBBB','smoke.DDDDDD','smoke.EEEEEE','smoke.FFFFFF']);
});
