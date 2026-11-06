// Find the compiler that sbt will use before sbt can resolve or download it.
// Usage: node check-scala.cjs SCALA_PROJECT [--fast | PORTABLE_ROOT_OR_FILE ...]
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

// SHA-256 of the unmodified Maven Central jar for this project's reviewed pin.
// Unknown future pins may use their normal sbt resolver; never seed unverified SDK bytes.
const hashes = {'3.5.1':'30da39aa70525abd415db5bd9505a6f122e0e01156561209ec55fb6c9417f1c0'};
const isWin = process.platform === 'win32';
const files = isWin ? ['scala.exe','scala.bat','scala.cmd','scalac.exe','scalac.bat','scalac.cmd','scala-cli.exe'] : ['scala','scalac','scala-cli'];
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const stat = file => fs.statSync(file,{throwIfNoEntry:false});
function children(dir) {
    if (!dir || !stat(dir)?.isDirectory()) return [];
    return fs.readdirSync(dir,{withFileTypes:true});
}
function cacheLocations() {
    const home = os.homedir();
    const legacy = path.join(home,'.coursier/cache/v1');
    const defaultCache = isWin ? path.join(process.env.LOCALAPPDATA || path.join(home,'AppData/Local'),'Coursier/Cache/v1')
        : path.join(process.env.XDG_CACHE_HOME || path.join(home,'.cache'),'coursier/v1');
    const active = process.env.COURSIER_CACHE || (stat(legacy)?.isDirectory() ? legacy : defaultCache);
    return {active, all:[...new Set([active,defaultCache,legacy])]};
}
const mirrors = ['https/repo1.maven.org/maven2','https/repo.maven.apache.org/maven2'];
function publishVerified(source, destination, digest) {
    if (stat(destination)) {
        if (sha256(destination) !== digest) throw Error('Existing compiler cache has unexpected contents: ' + destination);
        return;
    }
    fs.mkdirSync(path.dirname(destination),{recursive:true});
    const part = path.join(path.dirname(destination), '.' + path.basename(destination) + '.' + crypto.randomUUID() + '.part');
    try {
        fs.copyFileSync(source, part, fs.constants.COPYFILE_EXCL);
        if (sha256(part) !== digest) throw Error('Compiler JAR failed SHA-256 verification: ' + source);
        // Publish one complete inode, without overwriting a concurrent resolver's file.
        try { fs.linkSync(part,destination); }
        catch (e) { if (e.code !== 'EEXIST' || sha256(destination) !== digest) throw e; }
    } finally { fs.rmSync(part,{force:true}); }
}
function probe(command) {
    const opts = {encoding:'utf8',timeout:10000,env:{...process.env,COURSIER_MODE:'offline'}};
    let result;
    if (isWin && /\.(bat|cmd)$/i.test(command)) {
        opts.windowsVerbatimArguments=true;
        opts.env.AURORA_SCALA_BIN=command;
        const cmd = path.join(process.env.SystemRoot,'System32/cmd.exe');
        result=spawnSync(cmd,['/d','/v:off','/s','/c','""%AURORA_SCALA_BIN%" -version"'],opts);
    } else result=spawnSync(command,['-version'],opts);
    if (result.status!==0) return;
    const output = result.stdout+'\n'+result.stderr;
    return output.match(/Scala (?:code runner |compiler )?version(?: \(default\))?\s*:?\s*(\d+\.\d+\.\d+(?:-[\w.-]+)?)/i)?.[1];
}

function aliasVerifiedCache(source,destination,digest) {
    const sourceStat=fs.statSync(source), other=stat(destination);
    if (other) {
        // The normal case is a hard link, so no second file read is needed.
        if (other.dev===sourceStat.dev && other.ino===sourceStat.ino && other.ino!==0) return;
        if (sourceStat.size!==other.size || digest!==sha256(destination)) throw Error('Conflicting Central cache aliases: ' + destination);
        return;
    }
    try {
        fs.mkdirSync(path.dirname(destination),{recursive:true});
        fs.linkSync(source,destination);
    } catch (e) {
        if (e.code==='EEXIST') return aliasVerifiedCache(source,destination,digest);
        if (!['EACCES','EPERM','EROFS','ENOTSUP','EXDEV'].includes(e.code)) throw e;
        console.log('The cached compiler is readable at '+source+'; another resolver URL may need its own entry.');
    }
}
function main([project, ...extra]) {
    if (extra[0]==='--inventory-file') {
        if (extra.length!==2) throw Error('Expected one UTF-8 inventory file.');
        const items=JSON.parse(fs.readFileSync(extra[1],'utf8').replace(/^\uFEFF/,''));
        if (!Array.isArray(items) || !items.every(item=>typeof item==='string' && path.isAbsolute(item))) throw Error('Invalid Scala inventory paths.');
        extra=[...new Set(items)];
    }
    const pin = fs.readFileSync(path.join(project,'build.sbt'),'utf8')
        .match(/^\s*(?:ThisBuild\s*\/\s*)?scalaVersion\s*:=\s*"(3\.\d+\.\d+(?:-[\w.-]+)?)"\s*$/m)?.[1];
    if (!pin) throw Error('Cannot identify the Scala 3 compiler version in build.sbt.');
    const jar = 'scala3-compiler_3-' + pin + '.jar';
    const relative = path.join('org/scala-lang/scala3-compiler_3',pin,jar);
    const digest = hashes[pin];
    const caches=cacheLocations();
    const targets = mirrors.map(base=>path.join(caches.active,base,relative));
    function recover(file) {
        if (!stat(file)?.isFile()) return false;
        if (!digest) return false;
        if (sha256(file)!==digest) throw Error('Compiler differs from the reviewed Maven Central artifact: ' + file);
        // sbt/Coursier use either Central hostname. The two cache entries share
        // a cache-owned inode. Never hard-link the user's original SDK file.
        publishVerified(file,targets[0],digest);
        aliasVerifiedCache(targets[0],targets[1],digest);
        console.log(`Scala ${pin}: reusing verified project compiler ${file}.`);
        return true;
    }
    for (const target of targets) {
        if (stat(target)?.isFile()) {
            if (digest && sha256(target)!==digest) throw Error('Damaged compiler cache: '+target);
            if (digest) aliasVerifiedCache(target,targets.find(file=>file!==target),digest);
            console.log(`Scala ${pin}: found project compiler in the active Coursier cache: ${target}`);
            return 0;
        }
    }
    const home = os.homedir();
    const cached = caches.all.flatMap(dir=>mirrors.map(base=>path.join(dir,base,relative)));
    cached.push(path.join(home,'.m2/repository',relative),
        path.join(process.env.IVY_HOME || path.join(home,'.ivy2'),'cache/org.scala-lang/scala3-compiler_3/jars',jar));
    for (const candidate of cached) if (recover(candidate)) return 0;

    const sdks = new Set(), commands = new Set(), existing = new Set(), unknown = new Set();
    function sdk(dir) { if (dir && path.isAbsolute(dir) && stat(dir)?.isDirectory()) sdks.add(dir); }
    function command(file,trusted) {
        if (!stat(file)?.isFile()) return;
        const real = fs.realpathSync(file);
        sdk(path.dirname(path.dirname(real)));
        if (trusted) commands.add(real); else unknown.add(file);
    }
    function addSdkChildren(dir, which=()=>true) {
        for (const item of children(dir)) if (which(item.name)) sdk(path.join(dir,item.name));
    }
    if (process.env.SCALA_HOME && stat(process.env.SCALA_HOME)?.isDirectory()) unknown.add(process.env.SCALA_HOME);
    sdk(process.env.SCALA_HOME);
    for (const dir of (process.env.PATH || '').split(path.delimiter).filter(p=>path.isAbsolute(p))) {
        for (const file of files) command(path.join(dir,file),true);
    }
    const sdkman = process.env.SDKMAN_CANDIDATES_DIR || path.join(process.env.SDKMAN_DIR || path.join(home,'.sdkman'),'candidates');
    addSdkChildren(path.join(sdkman,'scala'));
    if (isWin) {
        for (const dir of [process.env.ProgramFiles,process.env['ProgramFiles(x86)']])
            addSdkChildren(dir,n=>/^scala(?:$|[- .\d])/i.test(n));
        addSdkChildren(path.join(process.env.SCOOP || path.join(home,'scoop'),'apps/scala'));
    } else {
        for (const dir of ['/opt','/usr/share','/usr/local']) addSdkChildren(dir,n=>/^scala(?:$|[-.\d])/i.test(n));
    }

    function inspectJar(file) {
        const name = path.basename(file);
        if (name === jar && recover(file)) return true;
        const other = name.match(/^(?:scala3-compiler_3|scala-compiler)-(\d+\.\d+\.\d+(?:-[\w.-]+)?)\.jar$/);
        if (other) existing.add(other[1]);
        return false;
    }
    // Fallback explicitly supplied by the caller (e.g. a portable installation).
    // Walk directories once, skip linked children to avoid cycles, and report incomplete searches.
    const seen=new Set();
    function portable(input) {
        const info=stat(input);
        if (!info) throw Error('Configured Scala search path could not be inspected: '+input);
        if (info.isFile()) {
            if (files.includes(path.basename(input).toLowerCase())) command(input,false);
            return inspectJar(input);
        }
        const resolved=fs.realpathSync(input);
        if (seen.has(resolved)) return false;
        seen.add(resolved);
        for (const item of children(resolved)) {
            const child=path.join(resolved,item.name);
            if (item.isDirectory() && !['.git','node_modules'].includes(item.name) && portable(child)) return true;
            if (item.isFile() && (files.includes(item.name.toLowerCase()) || /^(?:scala3-compiler_3|scala-compiler).*\.jar$/.test(item.name))
                && portable(child)) return true;
        }
        return false;
    }
    const fast=extra.length===1 && extra[0]==='--fast';
    if (!fast) for (const item of extra) if (portable(path.resolve(item))) return 0;
    for (const dir of sdks) {
        for (const suffix of ['maven2','lib/maven2','libexec/maven2']) if (recover(path.join(dir,suffix,relative))) return 0;
        for (const suffix of ['lib','libexec/lib']) {
            const lib=path.join(dir,suffix);
            for (const item of children(lib)) if (/^(?:scala3-compiler_3|scala-compiler).*\.jar$/.test(item.name) && inspectJar(path.join(lib,item.name))) return 0;
        }
        // Probe known SDK launchers only. Never execute an arbitrary scanned script.
        if ([...unknown].some(p=>stat(p)?.isFile() && path.dirname(path.dirname(fs.realpathSync(p)))===dir)) continue;
        for (const file of files) if (stat(path.join(dir,'bin',file))?.isFile()) commands.add(fs.realpathSync(path.join(dir,'bin',file)));
    }
    if (fast) return 12;
    for (const file of commands) {
        const version=probe(file);
        if (version) existing.add(version); else unknown.add(file);
    }
    if (!existing.size && unknown.size) throw Error('A Scala installation was found but its compiler could not be identified: '+[...unknown].join(', ')+'. Set SCALA_HOME to the SDK root.');
    if (existing.size) {
        console.log(`Existing Scala: ${[...existing, ...unknown].join(', ')}. The sbt project requires ${pin}; its compiler could not be recovered. Set SCALA_HOME or supply its location to reuse the distribution.`);
        return 11;
    }
    console.log(`No installed Scala distribution or cached project compiler was found. sbt will resolve Scala ${pin} in its project cache.`);
    return 0;
}
module.exports={main,publishVerified};
if (require.main===module) {
    try { process.exitCode=main(process.argv.slice(2)); }
    catch (e) { console.error('Scala compiler discovery inconclusive: '+e.message); process.exitCode=20; }
}
