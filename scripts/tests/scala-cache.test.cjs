const {test} = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const {spawnSync} = require('node:child_process');
const check = path.resolve(__dirname, '../check-scala.cjs');
const {publishVerified}=require(check);
const jarName = 'scala3-compiler_3-3.5.1.jar';
function fixture(t) {
    const dir=fs.mkdtempSync(path.join(os.tmpdir(),'aurora-scala-'));
    t.after(()=>fs.rmSync(dir,{recursive:true,force:true}));
    const sdk=path.join(dir,'scala-sdk'), cache=path.join(dir,'cache'), bin=path.join(sdk,'bin');
    fs.mkdirSync(bin,{recursive:true}); fs.mkdirSync(path.join(sdk,'lib'));
    fs.writeFileSync(path.join(dir,'build.sbt'),'ThisBuild / scalaVersion := "3.5.1"\n');
    const env={...process.env,HOME:dir,USERPROFILE:dir,IVY_HOME:path.join(dir,'ivy'),SDKMAN_DIR:path.join(dir,'sdkman'),
        SCALA_HOME:sdk,PATH:bin,COURSIER_CACHE:cache,LOCALAPPDATA:path.join(dir,'local')};
    return {dir,sdk,cache,bin,run(...args) {return spawnSync(process.execPath,[check,dir,...args],{env,encoding:'utf8'});}};
}
test('older installed Scala asks for project-only provisioning before any cache mutation', t=>{
    const f=fixture(t);
    const script=path.join(f.bin,process.platform==='win32'?'scala.cmd':'scala');
    fs.writeFileSync(script,process.platform==='win32'?'@echo Scala code runner version 2.13.14\r\n':"#!/bin/sh\necho 'Scala code runner version 2.13.14'\n",{mode:0o755});
    const result=f.run(); assert.equal(result.status,11,result.stderr); assert.match(result.stdout,/2.13.14/);
    assert.equal(fs.existsSync(f.cache),false);
});
test('unreadable SDK identity and tampered matching-name compiler fail closed', t=>{
    const f=fixture(t); assert.equal(f.run().status,20);
    fs.writeFileSync(path.join(f.sdk,'lib',jarName),'fake jar content');
    const result=f.run(); assert.equal(result.status,20); assert.match(result.stderr,/reviewed Maven Central/);
    assert.equal(fs.existsSync(f.cache),false);
});
test('a verified compiler cache write can be repeated and cannot overwrite a conflict', t=>{
    const f=fixture(t), source=path.join(f.dir,'source.jar'), target=path.join(f.cache,'a','target.jar');
    fs.writeFileSync(source,'fixture'); const digest=crypto.createHash('sha256').update('fixture').digest('hex');
    publishVerified(source,target,digest); publishVerified(source,target,digest); assert.equal(fs.readFileSync(target,'utf8'),'fixture');
    fs.writeFileSync(target,'external change'); assert.throws(()=>publishVerified(source,target,digest));
    assert.equal(fs.readFileSync(target,'utf8'),'external change');
});
test('exact Scala 3.5.1 SDK is recovered for sbt and is visible on the next run without the SDK', {skip:!process.env.AURORA_TEST_SCALA_JAR},t=>{
    const f=fixture(t), sdkJar=path.join(f.sdk,'lib',jarName);
    fs.copyFileSync(process.env.AURORA_TEST_SCALA_JAR,sdkJar);
    const first=f.run(); assert.equal(first.status,0,first.stderr); assert.match(first.stdout,/reusing verified/);
    fs.rmSync(sdkJar);
    const repo1=path.join(f.cache,'https/repo1.maven.org/maven2/org/scala-lang/scala3-compiler_3/3.5.1',jarName);
    fs.unlinkSync(repo1); // Simulate having used only the other Central hostname.
    const second=f.run(); assert.equal(second.status,0); assert.match(second.stdout,/active Coursier cache/); assert.ok(fs.existsSync(repo1));
});

test('large Unicode fallback inventory is passed as a single filename', t=>{
    const f=fixture(t), portable=path.join(f.dir,'Știință și date');
    fs.mkdirSync(portable);
    const old=path.join(portable,'scala3-compiler_3-3.3.4.jar');
    fs.writeFileSync(old,'earlier release');
    const file=path.join(f.dir,'lista de căi.json');
    const large=JSON.stringify(Array(1200).fill(old));
    assert.ok(large.length>32767); fs.writeFileSync(file,large,'utf8');
    const result=f.run('--inventory-file',file);
    assert.equal(result.status,11,result.stderr); assert.match(result.stdout,/3.3.4/);
});
