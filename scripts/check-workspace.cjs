// Shared by the Windows bootstrap and the Linux worker after the repositories are synced.
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');

const OK = 0, MISSING = 10, VERSION_CHANGE = 11, INCONCLUSIVE = 20;
const root = process.cwd();
const json = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const hash = (data, algorithm = 'sha256', encoding = 'hex') =>
    crypto.createHash(algorithm).update(data).digest(encoding);
function safe(relative) {
    const absolute = path.resolve(root, relative);
    if (!absolute.startsWith(root + path.sep)) throw Error(`Lock path escapes workspace: ${relative}`);
    return absolute;
}
function eligible(entry) {
    const header = entry.libc && process.platform === 'linux' ? process.report.getReport().header : undefined;
    for (const [field, actual] of [['os', process.platform], ['cpu', process.arch],
        ['libc', header ? (header.glibcVersionRuntime ? 'glibc' : 'musl') : undefined]]) {
        if (!entry[field] || !actual) continue;
        const list = [].concat(entry[field]);
        if (list.includes('!' + actual) || (!list.includes(actual) && !list.includes('any') && list.some(x => !x.startsWith('!')))) return false;
    }
    return true;
}
const isWorkspace = relative => !relative.split('/').includes('node_modules');
const normalized = object => JSON.stringify(Object.entries(object || {}).sort(([a], [b]) => a.localeCompare(b)));
function loadLock() {
    const lock = json('package-lock.json');
    if (![2, 3].includes(lock.lockfileVersion) || !lock.packages || !lock.packages['']) throw Error('A v2/v3 npm lockfile is required.');
    return Object.entries(lock.packages);
}
function snapshot(entries) {
    const paths = ['package-lock.json', ...entries.filter(([dir]) => isWorkspace(dir)).map(([dir]) => dir ? path.join(dir, 'package.json') : 'package.json')];
    return JSON.stringify(paths.map(file => [file, hash(fs.readFileSync(safe(file)))]));
}
function check(entries) {
    const missing = [], incompatible = [], unsafe = [];
    // npm would write through a linked ancestor (including a node_modules junction).
    const directories = new Set();
    function checkParents(location) {
        if (location === root || directories.has(location)) return;
        checkParents(path.dirname(location));
        if (fs.lstatSync(location, { throwIfNoEntry: false })?.isSymbolicLink()) throw Error('Linked dependency parent: ' + location);
        directories.add(location);
    }
    for (const [relative, entry] of entries) {
        if (entry.optional && !eligible(entry)) continue;
        if (isWorkspace(relative)) {
            const manifest = json(relative ? path.join(safe(relative), 'package.json') : 'package.json');
            if (entry.version && manifest.version !== entry.version) unsafe.push(`${relative || '.'}: workspace version disagrees with lock`);
            for (const field of ['dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies']) {
                if (normalized(manifest[field]) !== normalized(entry[field])) unsafe.push(`${relative || '.'}: ${field} disagrees with lock`);
            }
            continue;
        }
        const location = safe(relative);
        checkParents(path.dirname(location));
        const stat = fs.lstatSync(location, { throwIfNoEntry: false });
        if (!stat) { missing.push(relative); continue; }
        if (entry.link) {
            if (!stat.isSymbolicLink() || fs.realpathSync(location) !== fs.realpathSync(safe(entry.resolved))) unsafe.push(`${relative}: unexpected workspace link`);
            continue;
        }
        if (!stat.isDirectory() || stat.isSymbolicLink()) { unsafe.push(`${relative}: unexpected installation path`); continue; }
        const manifest = json(path.join(location, 'package.json'));
        if (manifest.version !== entry.version) {
            incompatible.push(`${relative}: installed ${manifest.version}, locked ${entry.version}`);
            continue;
        }
        const bins = typeof manifest.bin === 'string' ? {[manifest.name.split('/').pop()]: manifest.bin} : manifest.bin || {};
        for (const [name, executable] of Object.entries(bins)) {
            const file = path.resolve(location, executable);
            if (path.basename(name) !== name || !file.startsWith(location + path.sep) || !fs.existsSync(file)) {
                unsafe.push(`${relative}: invalid or missing executable ${name}`);
                continue;
            }
            const modules = location.slice(0, location.lastIndexOf(path.sep + 'node_modules' + path.sep)) + path.sep + 'node_modules';
            const bin = path.join(modules, '.bin');
            checkParents(bin);
            if (!fs.existsSync(path.join(bin, name + (process.platform === 'win32' ? '.cmd' : '')))) missing.push(path.join(bin, name));
        }
    }
    for (const [items, status, label] of [[unsafe, INCONCLUSIVE, 'Review unsafe or inconsistent entries'],
        [incompatible, VERSION_CHANGE, 'Installed versions differ from package-lock.json'], [missing, MISSING, 'Missing workspace packages or bin links']]) {
        if (items.length) { console.log(`${label} (${items.length}):\n${items.slice(0, 30).join('\n')}`); return status; }
    }
    console.log('Reusing the installed, locked Langium workspace and CLI.');
    return OK;
}
function globalPlan(entries, globalRoot) {
    if (!globalRoot || !path.isAbsolute(globalRoot)) throw Error('npm did not return an absolute global module directory.');
    const nodeDir = path.dirname(process.execPath);
    const roots = new Set([globalRoot, ...(process.env.NODE_PATH || '').split(path.delimiter).filter(p => path.isAbsolute(p)),
        path.join(nodeDir, 'node_modules'), path.resolve(nodeDir, '../lib/node_modules')]);
    // Other active npm prefixes, including nvm/Volta shims and user-installed
    // Windows .cmd tools. Inspect metadata without executing global packages.
    const npmNames = process.platform === 'win32' ? ['npm.cmd','langium.cmd'] : ['npm','langium'];
    for (const dir of (process.env.PATH || '').split(path.delimiter).filter(p => path.isAbsolute(p))) {
        if (!npmNames.some(name => fs.existsSync(path.join(dir,name)))) continue;
        roots.add(path.join(dir, 'node_modules'));
        roots.add(path.resolve(dir, '../lib/node_modules'));
    }
    if (process.env.npm_config_prefix) {
        roots.add(path.join(process.env.npm_config_prefix, process.platform === 'win32' ? 'node_modules' : 'lib/node_modules'));
    }
    const plans = [];
    for (const [relative, entry] of entries) {
        const name = path.posix.basename(relative);
        if (isWorkspace(relative) || !['langium', 'langium-cli'].includes(name) || entry.link) continue;
        if (!/^\d+\.\d+\.\d+(?:[-+][\w.+-]+)?$/.test(entry.version)) throw Error('Invalid locked version for ' + name);
        const local = path.join(safe(relative), 'package.json');
        if (fs.existsSync(local) && json(local).version === entry.version) continue;
        const matches = new Set(), versions = new Set();
        for (const dir of roots) {
            for (const candidate of [path.join(dir, name), path.join(dir, 'langium-cli', 'node_modules', name)]) {
                let installed;
                try { installed = json(path.join(candidate, 'package.json')); }
                catch (error) { if (['ENOENT', 'ENOTDIR'].includes(error.code)) continue; throw error; }
                if (installed.name !== name) throw Error(`Unexpected package identity at ${candidate}`);
                versions.add(installed.version);
                if (installed.version === entry.version) matches.add(fs.realpathSync(candidate));
            }
        }
        plans.push({name, entry, matches, versions});
    }
    return plans;
}
// A global install has a different dependency graph. Recover only registry-identical
// tarballs for npm's cache. npm itself creates the workspace tree and its bin links.
function seedCache(plans, npmPath) {
    if (!plans.some(p => p.matches.size)) return;
    const npmDir = path.dirname(path.resolve(npmPath));
    const cli = [fs.realpathSync(npmPath), path.join(npmDir, 'node_modules/npm/bin/npm-cli.js'),
        path.resolve(npmDir, '../lib/node_modules/npm/bin/npm-cli.js')].find(p => path.basename(p) === 'npm-cli.js' && fs.existsSync(p));
    if (!cli) { console.log('This npm wrapper exposes no npm-cli.js for offline packing. Using the configured npm cache.'); return; }
    const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'aurora-langium-'));
    function npm(args) {
        return execFileSync(process.execPath, [cli, ...args], { encoding: 'utf8', cwd: root, stdio: ['ignore', 'pipe', 'pipe'] });
    }
    try {
        for (const {name, entry, matches} of plans) {
            // npm registry v3 locks normally contain one sha512 digest. Never import
            // weak or unverified local material; npm may fetch the original instead.
            const digest = /^sha512-([A-Za-z0-9+/]+={0,2})$/.exec(entry.integrity || '');
            if (!digest) continue;
            for (const dir of matches) {
                const packed = path.join(temp, `${name}-${entry.version}.tgz`);
                try {
                    npm(['pack', dir, '--offline', '--ignore-scripts', '--pack-destination', temp, '--silent']);
                    if (hash(fs.readFileSync(packed), 'sha512', 'base64') !== digest[1]) continue;
                    npm(['cache', 'add', packed, '--offline', '--ignore-scripts']);
                    console.log(`Recovered ${name}@${entry.version} from ${dir} into npm's cache (verified sha512).`);
                    break;
                } catch { console.log(`Could not reproduce the locked tarball from ${dir}. Using npm's normal integrity-checked resolution.`); }
                finally { fs.rmSync(packed, {force: true}); }
            }
        }
    } finally { fs.rmSync(temp, {recursive: true, force: true}); }
}
try {
    const [mode, globalRoot, npmPath] = process.argv.slice(2);
    const entries = loadLock();
    if (mode === 'check') process.exitCode = check(entries);
    else if (mode === 'snapshot') console.log(snapshot(entries));
    else if (mode === 'inspect-globals' || mode === 'prepare-install') {
        const plans = globalPlan(entries, globalRoot);
        if (mode === 'prepare-install') {
            seedCache(plans, npmPath);
            // npm may trust its generated inventory even when an installed package was
            // replaced or damaged outside npm. Only invalidate it on a repair path.
            const modules = path.join(root, 'node_modules');
            const dir = fs.lstatSync(modules, { throwIfNoEntry: false });
            if (dir && (!dir.isDirectory() || dir.isSymbolicLink())) throw Error('Untrusted node_modules directory: ' + modules);
            fs.rmSync(path.join(modules, '.package-lock.json'), { force: true });
        }
        else for (const {name, entry, matches, versions} of plans) {
            if (!versions.size) continue;
            console.log(`Global ${name}: ${[...versions].join(', ')}; workspace requires ${entry.version}.`);
            if (!matches.size) process.exitCode = VERSION_CHANGE;
        }
    } else throw Error('Expected check, snapshot, inspect-globals, or prepare-install.');
} catch (error) {
    console.error('Workspace discovery inconclusive: ' + error.message);
    process.exitCode = INCONCLUSIVE;
}
