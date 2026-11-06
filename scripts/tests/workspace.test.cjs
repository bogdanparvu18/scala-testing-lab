// Run with node --test scripts/tests/workspace.test.cjs (uses only local fixtures).
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync, execFileSync } = require('node:child_process');

const checker = path.resolve(__dirname, '../check-workspace.cjs');
const npm = process.env.npm_execpath || [
    path.join(path.dirname(process.execPath), 'node_modules/npm/bin/npm-cli.js'),
    path.resolve(path.dirname(process.execPath), '../lib/node_modules/npm/bin/npm-cli.js'),
    '/usr/share/nodejs/npm/bin/npm-cli.js'
].find(file => fs.existsSync(file));
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2));
function fixture(t) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'aurora-workspace-test-'));
    t.after(() => fs.rmSync(dir, {recursive: true, force: true}));
    const project = path.join(dir, 'project'), global = path.join(dir, 'global');
    fs.mkdirSync(project); fs.mkdirSync(global);
    const manifest = {name:'demo', version:'1.0.0', dependencies:{langium:'4.4.0'}};
    const packages = {'':manifest, 'node_modules/langium':{version:'4.4.0', resolved: 'https://registry.invalid.test/langium/-/langium-4.4.0.tgz'}};
    function saveLock() { writeJson(path.join(project, 'package-lock.json'), { name:'demo', version:'1.0.0', lockfileVersion:3, packages }); }
    writeJson(path.join(project, 'package.json'), manifest); saveLock();
    const env = {...process.env, npm_config_cache:path.join(dir,'npm-cache'), npm_config_registry:'https://registry.invalid.test',
        npm_config_offline:'true', NODE_PATH:''};
    function run(...args) { return spawnSync(process.execPath, [checker, ...args], {cwd:project, env, encoding:'utf8'}); }
    function npmRun(...args) { return execFileSync(process.execPath, [npm, ...args], {cwd:project, env, encoding:'utf8', stdio:['ignore','pipe','pipe']}); }
    function makePackage(parent, version) {
        const pkg = path.join(parent,'langium');
        fs.mkdirSync(pkg, {recursive:true});
        writeJson(path.join(pkg,'package.json'), {name:'langium',version,main:'main.js'});
        fs.writeFileSync(path.join(pkg,'main.js'),'module.exports = 42;\n');
        return pkg;
    }
    return { dir, project, global, packages, saveLock, run, npmRun, makePackage, env };
}

test('missing, local mismatch, compatible tree, and unsafe lock are distinct decisions', t => {
    const f = fixture(t);
    assert.equal(f.run('check').status, 10);
    f.makePackage(path.join(f.project,'node_modules'), '3.0.0');
    assert.equal(f.run('check').status, 11);
    f.makePackage(path.join(f.project,'node_modules'), '4.4.0');
    assert.equal(f.run('check').status, 0);
    f.packages[''].dependencies.langium='3.0.0'; f.saveLock();
    assert.equal(f.run('check').status, 20);
});
test('different global version requests consent; compatible workspace needs no global repair', t => {
    const f=fixture(t); f.makePackage(f.global,'3.0.0');
    assert.equal(f.run('inspect-globals', f.global).status, 11);
    f.makePackage(path.join(f.project,'node_modules'),'4.4.0');
    assert.equal(f.run('inspect-globals', f.global).status, 0);
});
test('a linked node_modules parent blocks mutation', t => {
    const f=fixture(t); fs.symlinkSync(f.global, path.join(f.project,'node_modules'), process.platform==='win32'?'junction':'dir');
    assert.equal(f.run('check').status,20);
});
test('cold cache recovers a locally installed package by exact lock integrity and works offline', { skip: !npm }, t => {
    const f=fixture(t); const pkg=f.makePackage(f.global,'4.4.0');
    f.npmRun('pack',pkg,'--offline','--ignore-scripts','--pack-destination',f.dir,'--silent');
    const tgz=fs.readFileSync(path.join(f.dir,'langium-4.4.0.tgz'));
    f.packages['node_modules/langium'].integrity='sha512-'+crypto.createHash('sha512').update(tgz).digest('base64');
    f.saveLock(); fs.rmSync(f.env.npm_config_cache,{recursive:true,force:true});
    const before=f.run('snapshot').stdout;
    const result=f.run('prepare-install',f.global,npm);
    assert.equal(result.status,0,result.stderr);
    assert.match(result.stdout,/Recovered langium@4.4.0/);
    f.npmRun('install','--offline','--no-save','--ignore-scripts','--no-fund','--no-audit');
    assert.equal(f.run('check').status,0);
    assert.equal(f.run('snapshot').stdout,before);
    // An interrupted/manual replacement can leave npm's hidden inventory stale.
    f.makePackage(path.join(f.project, 'node_modules'), '3.0.0');
    assert.equal(f.run('check').status,11);
    assert.equal(f.run('prepare-install',f.global,npm).status,0);
    f.npmRun('install','--offline','--no-save','--ignore-scripts','--no-fund','--no-audit');
    assert.equal(f.run('check').status,0, 'Approved repair must restore the locked version.');
    assert.equal(f.run('snapshot').stdout,before);
});
test('same-version modified global files cannot seed the locked registry package', {skip: !npm}, t => {
    const f=fixture(t); f.makePackage(f.global,'4.4.0');
    f.packages['node_modules/langium'].integrity='sha512-'+Buffer.alloc(64).toString('base64'); f.saveLock();
    const result=f.run('prepare-install',f.global,npm);
    assert.equal(result.status,0,result.stderr);
    assert.doesNotMatch(result.stdout,/Recovered langium/);
    assert.throws(()=>f.npmRun('install','--offline','--no-save','--ignore-scripts','--no-fund','--no-audit'));
});
