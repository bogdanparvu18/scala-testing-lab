#!/usr/bin/env node
// Dependency-free probe of the real bundled language server. A successful process
// spawn is NOT readiness: require initialize, document diagnostics and clean exit.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export async function probeLanguageServer({ serverPath, documentPath, timeoutMs = 30000 }) {
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('Invalid probe timeout.');
    const absoluteDocument = path.resolve(documentPath);
    const text = await readFile(absoluteDocument, 'utf8');
    const uri = pathToFileURL(absoluteDocument).href;
    const normalize = value => process.platform === 'win32' ? value.toLowerCase() : value;
    const sameDocument = value => {
        try { return normalize(path.resolve(fileURLToPath(value))) === normalize(absoluteDocument); }
        catch { return false; }
    };
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, [path.resolve(serverPath), '--stdio'], {
            cwd: path.dirname(absoluteDocument), stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true
        });
        let buffer = Buffer.alloc(0);
        let stderr = '';
        let initialized = false;
        let validated = false;
        let shutdown = false;
        let failure;
        const fail = error => {
            failure ??= error instanceof Error ? error : new Error(String(error));
            child.kill('SIGKILL');
        };
        const timer = setTimeout(() => fail(new Error(`Language server timed out after ${timeoutMs} ms.`)), timeoutMs);
        function send(message) {
            const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message }), 'utf8');
            child.stdin.write(Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]));
        }
        function receive(message) {
            if (message.method && message.id !== undefined) {
                // These are the optional client services used during initialization.
                if (message.method === 'workspace/configuration') {
                    send({ id: message.id, result: (message.params?.items ?? []).map(() => null) });
                } else if (['client/registerCapability', 'window/workDoneProgress/create', 'workspace/workspaceFolders'].includes(message.method)) {
                    send({ id: message.id, result: null });
                } else {
                    send({ id: message.id, error: { code: -32601, message: 'Not implemented by bootstrap probe' } });
                }
            } else if (message.id === 1) {
                if (message.error || !message.result?.capabilities) throw new Error(`Language-server initialize failed: ${JSON.stringify(message.error ?? message.result)}`);
                initialized = true;
                send({ method: 'initialized', params: {} });
                send({ method: 'textDocument/didOpen', params: { textDocument: { uri, languageId: 'clinical-dsl', version: 1, text } } });
            } else if (message.method === 'textDocument/publishDiagnostics' && sameDocument(message.params?.uri) && initialized && !validated) {
                if (message.params.version !== undefined && message.params.version !== 1) return;
                if (!Array.isArray(message.params.diagnostics)) throw new Error('Malformed document diagnostics.');
                const errors = message.params.diagnostics.filter(d => d.severity === 1);
                if (errors.length) throw new Error(`Clinical document validation failed: ${errors.map(e => e.message).join('; ')}`);
                validated = true;
                send({ id: 2, method: 'shutdown', params: null });
            } else if (message.id === 2) {
                if (!validated || message.error || message.result !== null) throw new Error('Language-server shutdown failed.');
                shutdown = true;
                send({ method: 'exit' });
                child.stdin.end();
            }
        }
        child.stdout.on('data', chunk => {
            if (failure) return;
            try {
                buffer = Buffer.concat([buffer, chunk]);
                if (buffer.length > 8 * 1024 * 1024) throw new Error('Language-server frame exceeds 8 MiB.');
                while (true) {
                    const boundary = buffer.indexOf('\r\n\r\n');
                    if (boundary < 0) break;
                    const header = buffer.subarray(0, boundary).toString('ascii');
                    const match = /^Content-Length:\s*(\d+)\s*$/im.exec(header);
                    if (!match) throw new Error('Invalid language-server Content-Length header.');
                    const length = Number(match[1]);
                    if (!Number.isSafeInteger(length) || length > 8 * 1024 * 1024) throw new Error('Invalid language-server frame size.');
                    const end = boundary + 4 + length;
                    if (buffer.length < end) break;
                    const message = JSON.parse(buffer.subarray(boundary + 4, end).toString('utf8'));
                    buffer = buffer.subarray(end);
                    receive(message);
                }
            } catch (error) { fail(error); }
        });
        child.stderr.on('data', chunk => { stderr = (stderr + chunk.toString()).slice(-8000); });
        child.stdin.on('error', fail);
        child.on('error', fail);
        child.on('close', (code, signal) => {
            clearTimeout(timer);
            if (failure) return reject(failure);
            if (code !== 0 || !initialized || !validated || !shutdown) {
                return reject(new Error(`Language server exited before readiness (code=${code}, signal=${signal}). ${stderr}`));
            }
            resolve({ initialized: true, validated: true, shutdown: true });
        });
        send({ id: 1, method: 'initialize', params: {
            processId: process.pid, rootUri: null, workspaceFolders: null,
            capabilities: { workspace: { configuration: false, workspaceFolders: false } }
        } });
    });
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    const [serverPath, documentPath] = process.argv.slice(2);
    if (!serverPath || !documentPath) {
        console.error('Usage: node bootstrap-lsp-smoke.mjs <bundled-server.cjs> <fixture.clinical>');
        process.exitCode = 1;
    } else {
        probeLanguageServer({ serverPath, documentPath }).then(() => {
            console.log('PASS: Node language server initialize -> .clinical diagnostics -> clean shutdown');
        }).catch(error => { console.error(error.message); process.exitCode = 1; });
    }
}
