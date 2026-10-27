import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { probeLanguageServer } from '../bootstrap-lsp-smoke.mjs';

// Protocol tests use a fake child process, NOT a real Langium/PostgreSQL install.
async function fixture(mode, run) {
    const directory = await mkdtemp(path.join(os.tmpdir(), 'clinical lsp smoke '));
    const documentPath = path.join(directory, 'valid.clinical');
    const serverPath = path.join(directory, 'server.cjs');
    await writeFile(documentPath, 'Patient P9999: age 30, condition Fever\n');
    await writeFile(serverPath, `
const mode = ${JSON.stringify(mode)};
let buffer = Buffer.alloc(0);
function send(value) {
 const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...value }));
 const frame = Buffer.concat([Buffer.from('Content-Length: ' + body.length + '\\r\\n\\r\\n'), body]);
 // Deliberately fragment header and body, with non-ASCII diagnostic text.
 process.stdout.write(frame.subarray(0, 9)); process.stdout.write(frame.subarray(9));
}
process.stdin.on('data', chunk => {
 buffer = Buffer.concat([buffer, chunk]);
 while (true) {
  const boundary = buffer.indexOf('\\r\\n\\r\\n'); if (boundary < 0) return;
  const size = Number(/Content-Length: (\\d+)/.exec(buffer.subarray(0, boundary).toString())[1]);
  const end = boundary + 4 + size; if (buffer.length < end) return;
  const message = JSON.parse(buffer.subarray(boundary + 4, end)); buffer = buffer.subarray(end);
  if (message.method === 'initialize') {
   if (mode === 'early-exit') return process.exit(1);
   if (mode === 'timeout') continue;
   if (mode === 'bad-header') { process.stdout.write('Bad: 1\\r\\n\\r\\nx'); continue; }
   if (mode === 'bad-json') { process.stdout.write('Content-Length: 1\\r\\n\\r\\nx'); continue; }
   if (mode === 'initialize-error') { send({ id: 1, error: { code: -32603, message: 'init failed' } }); continue; }
   send({ id: 1, result: { capabilities: { textDocumentSync: 2 } } });
  } else if (message.method === 'textDocument/didOpen') {
   send({ method: 'textDocument/publishDiagnostics', params: {
    uri: mode === 'encoded-uri' ? message.params.textDocument.uri.replace('valid.clinical', 'valid%2Eclinical') : message.params.textDocument.uri, version: 1,
    diagnostics: [{ severity: mode === 'diagnostic-error' ? 1 : 2, message: 'caf\u00e9: fixture diagnostic' }]
   } });
  } else if (message.method === 'shutdown') {
   if (mode === 'shutdown-error') send({ id: 2, error: { code: -32603, message: 'shutdown failed' } });
   else send({ id: 2, result: null });
  } else if (message.method === 'exit') process.exit(mode === 'bad-exit' ? 1 : 0);
 }
});
`);
    try { await run({ serverPath, documentPath }); }
    finally { await rm(directory, { recursive: true, force: true }); }
}

test('requires initialize, matching document diagnostics, shutdown and clean exit', async () => {
    await fixture('success', async args => {
        assert.deepEqual(await probeLanguageServer({ ...args, timeoutMs: 3000 }), {
            initialized: true, validated: true, shutdown: true
        });
    });
});
for (const [mode, expected] of [
    ['initialize-error', /initialize failed/],
    ['diagnostic-error', /Clinical document validation failed/],
    ['early-exit', /exited before readiness/],
    ['bad-header', /Content-Length/],
    ['bad-json', /JSON/],
    ['shutdown-error', /shutdown failed/],
    ['bad-exit', /exited before readiness/]
]) {
    test(`rejects ${mode}`, async () => {
        await fixture(mode, args => assert.rejects(probeLanguageServer({ ...args, timeoutMs: 3000 }), expected));
    });
}
test('times out and reaps an unresponsive language-server child', async () => {
    await fixture('timeout', args => assert.rejects(probeLanguageServer({ ...args, timeoutMs: 200 }), /timed out/));
});
test('rejects invalid timeout configuration', async () => {
    await assert.rejects(probeLanguageServer({ timeoutMs: 0 }), /Invalid probe timeout/);
});

test('accepts equivalent percent-encoded document URIs', async () => {
    await fixture('encoded-uri', async args => {
        assert.equal((await probeLanguageServer({ ...args, timeoutMs: 3000 })).validated, true);
    });
});
