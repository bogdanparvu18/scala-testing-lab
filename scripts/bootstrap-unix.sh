#!/usr/bin/env bash
# aurora-container-runtime-v1
# Linux half of bootstrap-windows.ps1 --Docker. The two scripts are self-contained.
set -euo pipefail
umask 077
ROOT=/workspace
SCALA_BRANCH=main
LANGIUM_BRANCH=main
STARTUP_TIMEOUT=180
CONTAINER_RUNTIME=0
RELAUNCH_COUNT=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --container-runtime) CONTAINER_RUNTIME=1; shift ;;
        --root|--scala-branch|--langium-branch|--startup-timeout|--relaunch-count)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            case "$1" in
                --root) ROOT=$2 ;;
                --scala-branch) SCALA_BRANCH=$2 ;;
                --langium-branch) LANGIUM_BRANCH=$2 ;;
                --startup-timeout) STARTUP_TIMEOUT=$2 ;;
                --relaunch-count) RELAUNCH_COUNT=$2 ;;
            esac
            shift 2 ;;
        --help) echo 'Linux runtime worker: bootstrap-unix.sh --container-runtime --root /workspace [--scala-branch NAME] [--langium-branch NAME] [--startup-timeout SECONDS]. Start with bootstrap-windows.ps1 --Docker; tools and repositories remain in the persistent Linux runtime.'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ "$CONTAINER_RUNTIME" = 1 ] && [ -f /.dockerenv ] || { echo 'This script is the Linux worker for bootstrap-windows.ps1 --Docker. It must run inside its selected persistent Linux container.' >&2; exit 1; }
[[ "$STARTUP_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$STARTUP_TIMEOUT" -ge 30 ] && [ "$STARTUP_TIMEOUT" -le 600 ] || { echo 'Invalid startup timeout.' >&2; exit 1; }
[[ "$RELAUNCH_COUNT" =~ ^[012]$ ]] || { echo 'Invalid relaunch count.' >&2; exit 1; }
# Package names below are reviewed for this seed; do not guess at a different OS.
. /etc/os-release
[ "$ID" = ubuntu ] && [ "$VERSION_ID" = 24.04 ] || { echo 'The existing runtime image is incompatible: Ubuntu 24.04 is required. No packages were changed.' >&2; exit 1; }
[ "$ROOT" = /workspace ] || { echo 'The persistent runtime mount must be /workspace.' >&2; exit 1; }
[ ! -L "$ROOT" ] && [ -d "$ROOT" ] || { echo 'Persistent workspace is missing or linked.' >&2; exit 1; }
RUNTIME="$ROOT/medication-lab-setup/automatic"
STATE="$RUNTIME/state"
TOOLS="$RUNTIME/tools"
DATA="$RUNTIME/data/2026-10-05"
mkdir -p "$STATE" "$TOOLS" "$DATA/rrf" "$RUNTIME/downloads" "$ROOT/repos"
HEALTH="$STATE/health.json"
LOCK="$STATE/bootstrap.lock"
mkdir "$LOCK" 2>/dev/null || { echo "A runtime bootstrap is already active, or its lock needs recovery: $LOCK" >&2; exit 1; }
finish_runtime() {
    local status=$?
    if [ "$status" -ne 0 ]; then
        printf '{"status":"failed","exitCode":%s}\n' "$status" > "$HEALTH"
        echo "Runtime setup failed; see the command error above. Health: $HEALTH" >&2
    fi
    rmdir "$LOCK" 2>/dev/null || true
}
trap finish_runtime EXIT
printf '{"status":"running"}\n' > "$HEALTH"
[ "${PGHOST:-}" = 127.0.0.1 ] && [ "${PGPORT:-}" = 5432 ] && [ "${PGDATABASE:-}" = rxnorm_public ] && [ "${PGUSER:-}" = rxnorm_lab ] && [ -n "${PGPASSWORD:-}" ] || { echo 'Runtime PostgreSQL configuration is missing/incompatible. Recover the matching container and credentials.' >&2; exit 1; }
export PGCONNECT_TIMEOUT=10 PGSSLMODE=disable
unset PGHOSTADDR PGSERVICE

# Runtime tooling lives in the persistent container. Host binaries are never used.
tool_fail() { printf '%s\n' "Tool discovery: $*" >&2; return 1; }
version_at_least() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }
prepend_tool_path() {
    local directory=$1 entry rebuilt=$1
    local -a entries
    IFS=: read -r -a entries <<< "$PATH"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] || [ "$entry" = "$directory" ] || rebuilt="$rebuilt:$entry"
    done
    export PATH="$rebuilt"
}

# One shared inventory is reused by all probes; only a successful installation
# invalidates it. find does not follow directory symlinks into unrelated trees.
TOOL_INVENTORY_READY=0
TOOL_DISCOVERY_ERRORS=''
declare -a TOOL_INVENTORY=()
build_tool_inventory() {
    [ "$TOOL_INVENTORY_READY" = 0 ] || return 0
    TOOL_INVENTORY=()
    TOOL_DISCOVERY_ERRORS=''
    local directory results errors entry
    results=$(mktemp); errors=$(mktemp)
    for directory in "$TOOLS" /opt /usr/local /usr/lib/jvm /usr/lib/postgresql /usr/share/sbt /usr/share/java /root/.local /root/.sdkman/candidates /root/.sbt/launchers; do
        if [ -L "$directory" ]; then
            TOOL_DISCOVERY_ERRORS="$TOOL_DISCOVERY_ERRORS Skipped linked search root: $directory."
            continue
        fi
        [ ! -e "$directory" ] || {
            if ! find -P "$directory" \( -type f -o -type l \) \( -name java -o -name node -o -name npm -o -name git -o -name psql -o -name pg_isready -o -name sbt -o -name 'sbt-launch*.jar' -o -name curl -o -name unzip -o -name xz \) -print >> "$results" 2>> "$errors"; then
                TOOL_DISCOVERY_ERRORS="$TOOL_DISCOVERY_ERRORS Search incomplete under $directory."
            fi
        }
    done
    if [ -s "$errors" ]; then TOOL_DISCOVERY_ERRORS="$TOOL_DISCOVERY_ERRORS $(cat "$errors")"; fi
    while IFS= read -r entry; do TOOL_INVENTORY+=("$entry"); done < "$results"
    rm -f "$results" "$errors"
    TOOL_INVENTORY_READY=1
}

PACKAGE_DATABASE_READY=0
check_package_database() {
    [ "$PACKAGE_DATABASE_READY" = 0 ] || return 0
    if [ ! -r /var/lib/dpkg/status ] || ! dpkg-query -W -f='${binary:Package}\n' >/dev/null 2>&1; then
        tool_fail 'Package database cannot be read reliably. Discovery is inconclusive; no installation is allowed.'
        return 4
    fi
    PACKAGE_DATABASE_READY=1
}

installed_package_evidence() {
    # Query exit 1 means a requested package is absent; a database error does not.
    local output status
    if output=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' "$@" 2>/dev/null); then :; else
        status=$?
        [ "$status" = 1 ] || return 4
    fi
    # Config files left after an uninstall are not an installed executable.
    printf '%s\n' "$output" | awk 'NF >= 2 && $2 != "not-installed" && $2 != "config-files" { print $1 " (" $2 ")" }'
}

probe_runtime_tool() {
    local tool=$1 executable=$2 output version
    [ -x "$executable" ] || return 1
    case "$tool" in
        java)
            output=$(timeout 20 "$executable" -version 2>&1) || return 1
            version=$(printf '%s\n' "$output" | sed -n 's/.*version "\([0-9][0-9.]*\).*/\1/p' | head -n 1)
            [ "${version%%.*}" = 21 ] || return 1 ;;
        node)
            output=$(timeout 20 "$executable" --version 2>&1) || return 1
            version=${output#v}
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$version" 22.12.0 || return 1 ;;
        npm)
            version=$(timeout 20 "$executable" --version 2>/dev/null) || return 1
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$version" 10.2.3 || return 1 ;;
        git)
            output=$(timeout 20 "$executable" --version 2>&1) || return 1
            version=$(printf '%s\n' "$output" | sed -n 's/^git version \([0-9][0-9.]*\).*/\1/p')
            [ -n "$version" ] && version_at_least "$version" 2.25.0 || return 1 ;;
        psql|pg_isready)
            output=$(timeout 20 "$executable" --version 2>&1) || return 1
            version=$(printf '%s\n' "$output" | sed -n 's/.*PostgreSQL) \([0-9][0-9.]*\).*/\1/p')
            [ -n "$version" ] && version_at_least "$version" 16 || return 1 ;;
        sbt)
            output=$(timeout 30 "$executable" --script-version 2>&1) || return 1
            version=$(printf '%s\n' "$output" | sed -n 's/^\(1\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p' | tail -n 1)
            [ "$version" = 1.10.2 ] || return 1 ;;
        curl|unzip|xz)
            if [ "$tool" = unzip ]; then output=$(timeout 20 "$executable" -v 2>&1) || return 1
            else output=$(timeout 20 "$executable" --version 2>&1) || return 1; fi
            version=$(printf '%s\n' "$output" | head -n 1) ;;
        *) tool_fail "Unknown tool: $tool"; return 1 ;;
    esac
    printf '%s\n' "$version"
}

# Return 0 compatible, 3 absent, 2 incompatible/incomplete, 4 inconclusive.
# Keep diagnostics separate from output: TOOL_SELECTED is the selected executable.
discover_runtime_tool() {
    local tool=$1 hint=${2:-} candidate version directory package_evidence evidence=''
    local -a candidates=() packages=()
    local -A seen=()
    TOOL_SELECTED=''
    check_package_database || return 4
    if [ -n "$hint" ]; then candidates+=("$hint"); fi
    while IFS= read -r candidate; do [ -z "$candidate" ] || candidates+=("$candidate"); done < <(type -a -p "$tool" 2>/dev/null || true)
    for candidate in /usr/bin/"$tool" /bin/"$tool"; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then candidates+=("$candidate"); fi
    done
    # Recognizable manual installation roots count as installation evidence even
    # when their executable was removed by a failed/partial installation.
    case "$tool" in
        java)
            for directory in /usr/lib/jvm/* /opt/jdk* /opt/jre* /opt/java-* /usr/local/jdk*; do
                [ ! -d "$directory" ] || candidates+=("$directory/bin/java")
            done ;;
        node)
            for directory in "$TOOLS"/node-v* /opt/node-v* /opt/nodejs /usr/local/node-v* /usr/local/nodejs; do
                [ ! -d "$directory" ] || candidates+=("$directory/bin/node")
            done ;;
        psql|pg_isready)
            for directory in /usr/lib/postgresql/[0-9]*; do
                [ ! -d "$directory" ] || candidates+=("$directory/bin/$tool")
            done ;;
    esac
    build_tool_inventory
    for candidate in "${TOOL_INVENTORY[@]}"; do [ "${candidate##*/}" != "$tool" ] || candidates+=("$candidate"); done
    for candidate in "${candidates[@]}"; do
        [ -n "$candidate" ] || continue
        [ -z "${seen[$candidate]:-}" ] || continue
        seen[$candidate]=1
        if version=$(probe_runtime_tool "$tool" "$candidate"); then
            TOOL_SELECTED="$candidate"
            printf 'Reuse %s: %s (%s)\n' "$tool" "$TOOL_SELECTED" "$version"
            return 0
        fi
        evidence="$evidence $candidate"
    done
    case "$tool" in
        java) packages=('openjdk-*-jdk*' 'openjdk-*-jre*' 'temurin-*-jdk*') ;;
        node) packages=(nodejs) ;;
        psql|pg_isready) packages=('postgresql-client-[0-9]*') ;;
        *) packages=("$tool") ;;
    esac
    package_evidence=$(installed_package_evidence "${packages[@]}") || {
        tool_fail "Package evidence for $tool could not be read. Discovery is inconclusive."
        return 4
    }
    evidence="$evidence $package_evidence"
    if [ -n "${evidence//[[:space:]]/}" ]; then
        tool_fail "$tool is installed but incompatible or incomplete:$evidence. Repair explicitly; no installation or upgrade was attempted."
        return 2
    fi
    if [ -n "$TOOL_DISCOVERY_ERRORS" ]; then
        tool_fail "Cannot establish that $tool is absent.$TOOL_DISCOVERY_ERRORS No installation was attempted."
        return 4
    fi
    return 3
}

APT_INDEX_READY=0
install_missing_apt_package() {
    local package=$1 simulation
    check_package_database || return 4
    [ "$(id -u)" = 0 ] || { tool_fail "Installing missing $package requires root in the runtime container."; return 1; }
    if [ "$APT_INDEX_READY" = 0 ]; then
        apt-get update || return $?
        APT_INDEX_READY=1
    fi
    simulation=$(apt-get -s --no-upgrade --no-install-recommends install "$package") || return 1
    if printf '%s\n' "$simulation" | grep -Eq '^Inst [^ ]+ \[|^Remv '; then
        tool_fail "Installing missing $package would upgrade or remove an existing dependency. Reconcile explicitly."
        return 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-upgrade --no-install-recommends "$package" || return $?
    TOOL_INVENTORY_READY=0
    PACKAGE_DATABASE_READY=0
    hash -r
}

ensure_apt_runtime_tool() {
    local tool=$1 package=$2 hint=${3:-} result
    if discover_runtime_tool "$tool" "$hint"; then return 0; else result=$?; fi
    [ "$result" = 3 ] || return "$result"
    printf 'Install missing %s using %s.\n' "$tool" "$package"
    install_missing_apt_package "$package" || return $?
    discover_runtime_tool "$tool" "$hint" || { tool_fail "$package installation did not produce a compatible $tool."; return 1; }
}

install_missing_node() {
    local architecture archive directory checksums expected
    architecture=$(uname -m)
    case "$architecture" in x86_64) architecture=x64 ;; aarch64) architecture=arm64 ;; *) tool_fail "Unsupported Node architecture: $architecture"; return 1 ;; esac
    archive="node-v22.14.0-linux-$architecture.tar.xz"
    directory="$TOOLS/node-v22.14.0-linux-$architecture"
    # A previous failed extraction must be repaired explicitly, never overwritten.
    [ ! -e "$directory" ] || { tool_fail "Incomplete Node installation at $directory."; return 1; }
    mkdir -p "$TOOLS/downloads"
    checksums="$TOOLS/downloads/node-v22.14.0-SHASUMS256.txt"
    curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v22.14.0/SHASUMS256.txt" -o "$checksums.part"
    mv "$checksums.part" "$checksums"
    expected=$(awk -v name="$archive" '$2 == name { print $1 }' "$checksums")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { tool_fail 'Node checksum metadata is invalid.'; return 1; }
    if [ ! -e "$TOOLS/downloads/$archive" ]; then
        curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v22.14.0/$archive" -o "$TOOLS/downloads/$archive.part"
        mv "$TOOLS/downloads/$archive.part" "$TOOLS/downloads/$archive"
    fi
    printf '%s  %s\n' "$expected" "$TOOLS/downloads/$archive" | sha256sum -c -
    tar -xJf "$TOOLS/downloads/$archive" -C "$TOOLS"
    TOOL_INVENTORY_READY=0
    NODE_HOME="$directory"
    export NODE_HOME
    prepend_tool_path "$NODE_HOME/bin"
}

ensure_runtime_tools() {
    local result certificates hint=''
    check_package_database || return 4
    certificates=$(installed_package_evidence ca-certificates) || return 4
    if [ -z "$certificates" ]; then
        install_missing_apt_package ca-certificates
    fi
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { tool_fail 'Installed CA certificates are incomplete.'; return 1; }
    ensure_apt_runtime_tool curl curl
    prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool xz xz-utils
    prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool unzip unzip
    prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool git git
    prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    [ -z "${JAVA_HOME:-}" ] || hint="$JAVA_HOME/bin/java"
    ensure_apt_runtime_tool java openjdk-21-jdk-headless "$hint"
    JAVA_HOME=$(dirname "$(dirname "$(readlink -f "$TOOL_SELECTED")")")
    export JAVA_HOME
    prepend_tool_path "$JAVA_HOME/bin"

    hint=''; [ -z "${NODE_HOME:-}" ] || hint="$NODE_HOME/bin/node"
    if discover_runtime_tool node "$hint"; then :; else
        result=$?
        [ "$result" = 3 ] || return "$result"
        install_missing_node
        discover_runtime_tool node "$NODE_HOME/bin/node" || return 1
    fi
    NODE_HOME=$(dirname "$(dirname "$(readlink -f "$TOOL_SELECTED")")")
    export NODE_HOME
    prepend_tool_path "$NODE_HOME/bin"
    if ! discover_runtime_tool npm "$NODE_HOME/bin/npm"; then
        tool_fail "Existing Node installation has no compatible npm >=10.2.3. Repair npm explicitly."
        return 1
    fi
    prepend_tool_path "$(dirname "$TOOL_SELECTED")"

    hint=''; [ -z "${PGHOME:-}" ] || hint="$PGHOME/bin/psql"
    ensure_apt_runtime_tool psql postgresql-client-16 "$hint"
    PSQL="$TOOL_SELECTED"
    PGHOME=$(dirname "$(dirname "$PSQL")")
    export PGHOME PSQL
    prepend_tool_path "$(dirname "$PSQL")"
    if ! discover_runtime_tool pg_isready "$(dirname "$PSQL")/pg_isready"; then
        tool_fail 'Existing PostgreSQL client installation is incomplete; pg_isready >=16 is required.'
        return 1
    fi
    PG_ISREADY="$TOOL_SELECTED"
    export PG_ISREADY

    ensure_sbt_launcher
}

verify_sbt_launcher() {
    local launcher=$1
    [ -f "$launcher" ] && [ -r "$launcher" ] || return 1
    printf '%s  %s\n' cdd6963b622f42690cb2e3154bde3f3257a03839f216e1b5d7420000d6a71817 "$launcher" | sha256sum -c - >/dev/null 2>&1
}

ensure_sbt_launcher() {
    local candidate directory result evidence=''
    local -a candidates=()
    local -A seen=()
    SBT="$TOOLS/sbt/bin/sbt-launch.jar"
    if [ -e "$SBT" ] || [ -L "$SBT" ]; then
        verify_sbt_launcher "$SBT" || { tool_fail "Existing sbt launcher is incomplete or incompatible: $SBT. Repair explicitly."; return 1; }
        printf 'Reuse verified sbt 1.10.2 launcher: %s\n' "$SBT"
        export SBT
        return 0
    fi
    build_tool_inventory
    for candidate in "${TOOL_INVENTORY[@]}"; do
        case "${candidate##*/}" in sbt-launch*.jar) candidates+=("$candidate") ;; esac
    done
    # SDKMAN's current directory is a link, so include these known launcher
    # locations explicitly without recursively following arbitrary directory links.
    for directory in /usr/share/sbt /opt/sbt* /usr/local/sbt* /root/.sdkman/candidates/sbt/*; do
        [ ! -d "$directory" ] || candidates+=("$directory/bin/sbt-launch.jar")
    done
    for candidate in /root/.sbt/launchers/*/sbt-launch.jar; do
        if [ -e "$candidate" ] || [ -L "$candidate" ]; then candidates+=("$candidate"); fi
    done
    for candidate in "${candidates[@]}"; do
        [ -z "${seen[$candidate]:-}" ] || continue
        seen[$candidate]=1
        if verify_sbt_launcher "$candidate"; then
            mkdir -p "$(dirname "$SBT")"
            ln -s "$(readlink -f "$candidate")" "$SBT" || return 1
            printf 'Reuse verified sbt 1.10.2 launcher: %s (linked at %s)\n' "$candidate" "$SBT"
            export SBT
            return 0
        fi
        evidence="$evidence $candidate"
    done
    if [ -n "$evidence" ]; then
        tool_fail "Installed sbt launcher candidates are incompatible or incomplete:$evidence. No replacement was downloaded."
        return 2
    fi
    if discover_runtime_tool sbt; then
        tool_fail "Existing sbt at $TOOL_SELECTED has no discoverable verified 1.10.2 launcher JAR. Restore its launcher explicitly; no second installation was added."
        return 2
    else
        result=$?
        [ "$result" = 3 ] || return "$result"
    fi
    mkdir -p "$(dirname "$SBT")"
    curl --fail --location --proto '=https' --tlsv1.2 'https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar' -o "$SBT.part" || return 1
    verify_sbt_launcher "$SBT.part" || { tool_fail 'Downloaded sbt launcher checksum failed.'; return 1; }
    mv "$SBT.part" "$SBT"
    export SBT
}

run_sbt() {
    "$JAVA_HOME/bin/java" -Xmx2G -Dsbt.supershell=false -Dsbt.log.noformat=true -Dsbt.server.autostart=false -jar "$SBT" "$@"
}

verify_node_modules() {
    node - <<'JS'
// Exit 0 = verified, 10 = genuinely missing packages, 20 = incompatible/incomplete.
const fs = require('node:fs');
const path = require('node:path');
const root = process.cwd();
const missing = [], errors = [];
function json(file) { return JSON.parse(fs.readFileSync(file, 'utf8')); }
function safe(relative) {
    const absolute = path.resolve(root, relative);
    if (!absolute.startsWith(root + path.sep)) throw Error(`Lock path escapes workspace: ${relative}`);
    return absolute;
}
function eligible(entry) {
    for (const [field, actual] of [['os', process.platform], ['cpu', process.arch]]) {
        if (!entry[field]) continue;
        const list = Array.isArray(entry[field]) ? entry[field] : [entry[field]];
        if (list.includes('!' + actual) || (list.some(x => !x.startsWith('!')) && !list.includes(actual) && !list.includes('any'))) return false;
    }
    if (entry.libc && process.platform === 'linux') {
        const libc = process.report.getReport().header.glibcVersionRuntime ? 'glibc' : 'musl';
        const list = Array.isArray(entry.libc) ? entry.libc : [entry.libc];
        if (list.includes('!' + libc) || (list.some(x => !x.startsWith('!')) && !list.includes(libc) && !list.includes('any'))) return false;
    }
    return true;
}
try {
    const lock = json('package-lock.json');
    if (![2, 3].includes(lock.lockfileVersion) || !lock.packages) throw Error('A v2/v3 package-lock.json is required.');
    for (const [relative, entry] of Object.entries(lock.packages)) {
        if (entry.optional && !eligible(entry)) continue;
        if (!relative || !relative.split('/').includes('node_modules')) {
            const manifest = json(relative ? path.join(safe(relative), 'package.json') : 'package.json');
            if (entry.version && manifest.version !== entry.version) errors.push(`${relative || '.'}: workspace version disagrees with lock`);
            for (const field of ['dependencies', 'devDependencies', 'optionalDependencies']) {
                const normalized = object => JSON.stringify(Object.entries(object || {}).sort(([a], [b]) => a.localeCompare(b)));
                if (normalized(manifest[field]) !== normalized(entry[field])) errors.push(`${relative || '.'}: ${field} disagrees with lock`);
            }
            continue;
        }
        const location = safe(relative);
        let stat;
        try { stat = fs.lstatSync(location); }
        catch (error) { if (error.code === 'ENOENT') { missing.push(relative); continue; } throw error; }
        if (entry.link) {
            const target = safe(entry.resolved);
            if (!stat.isSymbolicLink() || fs.realpathSync(location) !== fs.realpathSync(target)) errors.push(`${relative}: wrong workspace link`);
            continue;
        }
        if (!stat.isDirectory() || stat.isSymbolicLink()) { errors.push(`${relative}: unexpected installation path`); continue; }
        let manifest;
        try { manifest = json(path.join(location, 'package.json')); }
        catch (error) { errors.push(`${relative}: installed directory is incomplete (${error.code || error.message})`); continue; }
        if (manifest.version !== entry.version) errors.push(`${relative}: installed ${manifest.version}, locked ${entry.version}`);
        const bins = typeof manifest.bin === 'string' ? {[manifest.name.split('/').pop()]: manifest.bin} : manifest.bin || {};
        for (const [name, executable] of Object.entries(bins)) {
            if (!fs.existsSync(path.resolve(location, executable))) errors.push(`${relative}: missing executable ${executable}`);
            const modules = location.slice(0, location.lastIndexOf(path.sep + 'node_modules' + path.sep)) + path.sep + 'node_modules';
            const shim = path.join(modules, '.bin', name + (process.platform === 'win32' ? '.cmd' : ''));
            if (!fs.existsSync(shim)) missing.push(path.relative(root, shim));
        }
    }
    if (errors.length) {
        console.error('Dependencies are incompatible/incomplete; explicitly reconcile them before retrying. No installation attempted.\n' + errors.slice(0, 30).join('\n'));
        process.exitCode = 20;
    } else if (missing.length) {
        console.log(`Missing dependency entries (${missing.length}): ${missing.slice(0, 20).join(', ')}`);
        process.exitCode = 10;
    } else console.log('All locked dependency versions and workspace links are installed; skipping npm installation.');
} catch (error) { console.error(`Dependency discovery inconclusive: ${error.message}`); process.exitCode = 20; }

JS
}


check_language_server() {
    node --input-type=module - "$LANGIUM/packages/extension/out/language/main.cjs" "$SMOKE/valid.clinical" <<'JS'
// Inline readiness probe: no separate helper or test file is required.
import { spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

async function probeLanguageServer({ serverPath, documentPath, timeoutMs = 30000 }) {
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

const [serverPath, documentPath] = process.argv.slice(2);
if (!serverPath || !documentPath) {
    console.error('Bootstrap language-server check requires server and document paths.');
    process.exitCode = 1;
} else {
    probeLanguageServer({ serverPath, documentPath }).then(() => {
        console.log('PASS: Node language server initialize -> .clinical diagnostics -> clean shutdown');
    }).catch(error => { console.error(error.message); process.exitCode = 1; });
}

JS
}


ensure_runtime_tools
# Editor processes need the same non-secret environment as the bootstrap.
# Existing unrelated profile content is not modified; only this owned file is written.
{
    printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"
    printf 'export NODE_HOME=%q\n' "$NODE_HOME"
    printf 'export PGHOME=%q\n' "$PGHOME"
    printf 'export PATH=%q\n' "$PATH"
} > /etc/profile.d/aurora-tools.sh
printf 'Linux repositories: %s/repos (persistent Docker workspace).\n' "$ROOT"

sql() { "$PSQL" -X -w -v ON_ERROR_STOP=1 -Atc "$1"; }
start=$SECONDS
until "$PG_ISREADY" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t 3 >/dev/null 2>&1; do
    [ "$((SECONDS - start))" -lt "$STARTUP_TIMEOUT" ] || { echo 'PostgreSQL did not become ready.' >&2; exit 1; }
    sleep 1
done
[ "$(sql 'SELECT 1;')" = 1 ] || { echo 'Authenticated PostgreSQL readiness failed.' >&2; exit 1; }
server_version=$(sql 'SHOW server_version_num;')
[[ "$server_version" =~ ^[0-9]+$ ]] && [ "$server_version" -ge 160000 ] && [ "$server_version" -lt 170000 ] || { echo 'Existing PostgreSQL server is incompatible with the selected postgres:16 runtime.' >&2; exit 1; }

# Fast-forward only. Personal source/data are never removed, renamed or stashed.
# Restore/remove only generated files which overlap files the incoming commit changes.
sync_runtime_repo() {
    local name=$1 branch=$2 directory="$ROOT/repos/$1" url="https://github.com/bogdanparvu18/$1.git"
    local before remote file plan
    git check-ref-format --branch "$branch" >/dev/null
    if [ ! -e "$directory" ]; then
        git clone --branch "$branch" --single-branch "$url" "$directory"
        return
    fi
    [ ! -L "$directory" ] && [ -d "$directory/.git" ] && [ ! -L "$directory/.git" ] || { echo "Existing repository is incomplete or external: $directory. Recover it explicitly." >&2; return 1; }
    [ "$(git -C "$directory" remote get-url origin)" = "$url" ] || { echo "Unexpected origin for $directory; no source was replaced." >&2; return 1; }
    [ "$(git -C "$directory" branch --show-current)" = "$branch" ] || { echo "Existing repository uses another branch: $directory. Select it explicitly." >&2; return 1; }
    git -C "$directory" fetch --prune origin "+refs/heads/$branch:refs/remotes/origin/$branch"
    before=$(git -C "$directory" rev-parse HEAD)
    remote=$(git -C "$directory" rev-parse "refs/remotes/origin/$branch")
    if [ "$before" = "$remote" ]; then
        printf '%s: upstream unchanged; keeping build outputs and local files.\n' "$name"
        return
    fi
    git -C "$directory" merge-base --is-ancestor HEAD "$remote" || { echo "Divergent/local commits in $directory. Reconcile explicitly; no source was replaced." >&2; return 1; }
    plan=$(mktemp "$STATE/conflicts.XXXXXX")
    node - "$directory" "$remote" "$name" > "$plan" <<'JS'
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const [root, remote, name] = process.argv.slice(2);
const git = args => execFileSync('git', ['-C', root, ...args], {encoding: 'utf8', maxBuffer: 128 * 1024 * 1024}).split('\0').filter(Boolean);
const incoming = git(['diff', '--name-only', '-z', 'HEAD', remote, '--']);
const dirty = [...git(['diff', '--name-only', '-z', '--']), ...git(['diff', '--cached', '--name-only', '-z', '--']), ...git(['ls-files', '--others', '--exclude-standard', '-z'])];
const scopes = name === 'scala-testing-lab' ? [/^(target|project\/target|project\/project\/target|\.metals|\.bsp|\.bloop)\//] : [/^(clinical-dsl-demo\/node_modules|clinical-dsl-demo\/packages\/[^/]+\/node_modules|clinical-dsl-demo\/packages\/[^/]+\/out|clinical-dsl-demo\/packages\/language\/src\/generated|clinical-dsl-demo\/packages\/language\/syntaxes|clinical-dsl-demo\/packages\/extension\/syntaxes)\//];
const generated = file => scopes.some(re => re.test(file)) || (name === 'langium_dsl_lab' && /^clinical-dsl-demo\/[^/]+\.tsbuildinfo$/.test(file));
const overlaps = (a,b) => a === b || a.startsWith(b + '/') || b.startsWith(a + '/');
const conflicting = dirty.filter(file => incoming.some(next => overlaps(file,next)));
// Git may overwrite ignored files during a checkout; guard exact incoming targets too.
for (const file of incoming) {
    const absolute = path.resolve(root, file);
    if (!absolute.startsWith(root + path.sep)) throw Error('Incoming path escapes repository.');
    if (fs.existsSync(absolute)) {
        try { execFileSync('git', ['-C',root,'check-ignore','-q','--',file]); conflicting.push(file); }
        catch (error) { if (error.status !== 1) throw error; }
    }
}
for (const file of conflicting) if (!generated(file)) throw Error(`Incoming commit conflicts with local source/personal file ${file}; reconcile explicitly.`);
for (const file of new Set(conflicting)) {
    let cursor = path.join(root, file);
    while (cursor !== root) {
        if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) throw Error(`Conflicting output crosses a symlink: ${file}`);
        cursor = path.dirname(cursor);
    }
    const absolute = path.join(root, file);
    if (fs.existsSync(absolute) && !fs.lstatSync(absolute).isFile()) throw Error(`Conflicting generated path is not an ordinary file: ${file}`);
    if (!file || /[\r\n\0]/.test(file) || file.length > 4096) throw Error('Unsafe generated-output path.');
}
// Emit only after every path has passed protection checks.
for (const file of new Set(conflicting)) process.stdout.write(file + '\0');
JS
    # One exact allowlisted file per command bounds argv and leaves other caches intact.
    while IFS= read -r -d '' file; do
        if git -C "$directory" cat-file -e "HEAD:$file" 2>/dev/null; then
            git -C "$directory" restore --source=HEAD --staged --worktree -- ":(top,literal)$file"
        else
            git -C "$directory" rm --cached --ignore-unmatch -- ":(top,literal)$file" >/dev/null
            if [ -e "$directory/$file" ]; then rm -- "$directory/$file"; fi
        fi
    done < "$plan"
    rm -f "$plan"
    git -C "$directory" merge --ff-only --no-autostash --no-overwrite-ignore "$remote"
    [ "$(git -C "$directory" rev-parse HEAD)" = "$remote" ] || { echo "Repository failed to reach fetched commit: $name" >&2; return 1; }
}

sync_runtime_repo scala-testing-lab "$SCALA_BRANCH"
sync_runtime_repo langium_dsl_lab "$LANGIUM_BRANCH"
SCALA="$ROOT/repos/scala-testing-lab"
LANGIUM="$ROOT/repos/langium_dsl_lab/clinical-dsl-demo"
if ! cmp -s "$0" "$SCALA/scripts/bootstrap-unix.sh"; then
    [ "$RELAUNCH_COUNT" -lt 2 ] || { echo 'Bootstrap changed repeatedly while fetching. Retry after upstream is stable.' >&2; exit 1; }
    grep -qx '# aurora-container-runtime-v1' "$SCALA/scripts/bootstrap-unix.sh" || { echo 'Selected Scala branch does not contain the persistent Docker runtime bootstrap. Select the implementation branch explicitly.' >&2; exit 1; }
    echo 'Bootstrap changed upstream; restarting the fetched Linux worker.'
    rmdir "$LOCK"
    trap - EXIT
    exec bash "$SCALA/scripts/bootstrap-unix.sh" --container-runtime --root "$ROOT" --scala-branch "$SCALA_BRANCH" --langium-branch "$LANGIUM_BRANCH" --startup-timeout "$STARTUP_TIMEOUT" --relaunch-count "$((RELAUNCH_COUNT + 1))"
fi

cd "$LANGIUM"
# Snapshot source manifest bytes; npm is allowed to fill missing modules only.
manifest_snapshot() {
    node - <<'JS'
const fs = require('node:fs');
const crypto = require('node:crypto');
const lock = JSON.parse(fs.readFileSync('package-lock.json', 'utf8'));
const files = ['package-lock.json', 'package.json', ...Object.keys(lock.packages).filter(p => p && !p.split('/').includes('node_modules')).map(p => p + '/package.json')];
process.stdout.write(JSON.stringify(files.map(file => [file, crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')])));
JS
}
manifest_before=$(manifest_snapshot)
if verify_node_modules; then :; else
    dependency_status=$?
    [ "$dependency_status" = 10 ] || exit "$dependency_status"
    npm install --no-save --ignore-scripts --include=dev --no-audit --no-fund
    [ "$(manifest_snapshot)" = "$manifest_before" ] || { echo 'npm changed source manifests unexpectedly; review those changes before continuing.' >&2; exit 1; }
    verify_node_modules
fi
npm run langium:generate
npm run build
for artifact in packages/language/out/index.js packages/extension/out/extension/main.cjs packages/extension/out/language/main.cjs packages/extension/syntaxes/clinical-dsl.tmLanguage.json; do
    [ -f "$artifact" ] || { echo "Missing build artifact: $artifact" >&2; exit 1; }
done

QUERY="SELECT 1 FROM rxnorm_lab.release r JOIN rxnorm_lab.product_release p USING (release)
WHERE r.release='2026-10-05' AND r.state='ready' AND p.state='ready' AND p.base_identity=r.identity
AND r.scope='all-active-rxnorm-pg-v4' AND p.policy='single-component-mass-v1'
AND r.sha256_json::jsonb->>'RXNCONSO.RRF' ~ '^[0-9a-fA-F]{64}$'
AND r.sha256_json::jsonb->>'RXNREL.RRF' ~ '^[0-9a-fA-F]{64}$'
AND p.sha256_json::jsonb->>'RXNSAT.RRF' ~ '^[0-9a-fA-F]{64}$'
AND p.sha256_json::jsonb->>'RXNCONSO.RRF'=r.sha256_json::jsonb->>'RXNCONSO.RRF'
AND p.sha256_json::jsonb->>'RXNREL.RRF'=r.sha256_json::jsonb->>'RXNREL.RRF';"
manifest=$(sql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NOT NULL AND to_regclass('rxnorm_lab.product_release') IS NOT NULL THEN 1 ELSE 0 END;")
ready=''
if [ "$manifest" = 1 ]; then ready=$(sql "$QUERY"); fi
IMPORT_COMMANDS=()
if [ "$ready" != 1 ]; then
    has_base=$(sql "SELECT CASE WHEN to_regclass('rxnorm_lab.release') IS NOT NULL THEN 1 ELSE 0 END;")
    if [ "$has_base" = 1 ] && [ "$(sql "SELECT count(*) FROM rxnorm_lab.release WHERE release='2026-10-05';")" != 0 ]; then
        echo 'The existing 2026-10-05 import is incomplete/incompatible. Complete it explicitly with its original archive; no data was replaced.' >&2
        exit 1
    fi
    ARCHIVE="$RUNTIME/downloads/RxNorm_full_prescribe_10052026.zip"
    if [ ! -e "$ARCHIVE" ]; then
        curl --fail --location --proto '=https' --tlsv1.2 https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip -o "$ARCHIVE.part"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    printf '%s  %s\n' 8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977 "$ARCHIVE" | sha256sum -c -
    expected_rrf() {
        printf '%s  %s\n' 555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209 "$DATA/rrf/RXNCONSO.RRF"
        printf '%s  %s\n' cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694 "$DATA/rrf/RXNREL.RRF"
        printf '%s  %s\n' b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda "$DATA/rrf/RXNSAT.RRF"
    }
    if ! expected_rrf | sha256sum -c - >/dev/null 2>&1; then
        unzip -o -j "$ARCHIVE" 'rrf/RXNCONSO.RRF' 'rrf/RXNREL.RRF' 'rrf/RXNSAT.RRF' -d "$DATA/rrf"
        expected_rrf | sha256sum -c -
    fi
    IMPORT_COMMANDS=("run import-rxnorm \"$DATA/rrf\" 2026-10-05" "run import-product-attributes \"$DATA/rrf\" 2026-10-05")
else
    echo 'Verified RxNorm import reused; no extraction or import needed.'
fi
DEMO="$RUNTIME/aspirin-demo.clinical"
fixture='Patient P9999: age 30, condition Fever
Medication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN
Plan DemoPlan: for P9999, prescribe aspirin
show DemoPlan'
[ -e "$DEMO" ] || printf '%s\n' "$fixture" > "$DEMO"
SMOKE=$(mktemp -d "$STATE/smoke.XXXXXX")
printf '%s\n' "$fixture" > "$SMOKE/valid.clinical"
printf '%s\n' "${fixture/strength 325 mg/strength 32500 mg}" > "$SMOKE/invalid.clinical"
for case_name in valid invalid; do
    node "$SCALA/bridge/export-ast.mjs" --langium-root "$LANGIUM" --input "$SMOKE/$case_name.clinical" --release 2026-10-05 --output "$SMOKE/$case_name.ast.json"
done
cd "$SCALA"
run_sbt compile test "${IMPORT_COMMANDS[@]}" "run resolve \"$SMOKE/valid.ast.json\" \"$SMOKE/valid.result.json\"" "run resolve \"$SMOKE/invalid.ast.json\" \"$SMOKE/invalid.result.json\""
if [ "${#IMPORT_COMMANDS[@]}" -gt 0 ]; then sql 'ANALYZE;' >/dev/null; fi
[ "$(sql "$QUERY")" = 1 ] || { echo 'RxNorm release/product provenance verification failed.' >&2; exit 1; }
node - "$SMOKE" <<'JS'
const fs = require('node:fs');
const root = process.argv[2];
for (const name of ['valid', 'invalid']) {
    const report = JSON.parse(fs.readFileSync(`${root}/${name}.result.json`, 'utf8'));
    if (report.terminologyRelease !== '2026-10-05' || report.resolutions?.length !== 1) throw Error(`Unexpected ${name} report`);
    const item = report.resolutions[0];
    if (name === 'valid') {
        if (item.status !== 'resolved' || !item.selectedProduct?.rxcui || !item.productEvidence) throw Error('Valid fixture failed RxNorm resolution');
    } else if (item.status !== 'productNotFound' || !item.diagnostics?.some(x => x.startsWith('PRODUCT_NOT_FOUND:'))) throw Error('Invalid fixture did not reject unsupported product');
    console.log(`PASS: ${name} .clinical -> Langium -> Scala -> PostgreSQL/RxNorm`);
}
JS
check_language_server
[ "$(sql 'SELECT 1;')" = 1 ] || { echo 'Final PostgreSQL health check failed.' >&2; exit 1; }
node - "$RUNTIME" "$SCALA" "$LANGIUM" "$JAVA_HOME" "$NODE_HOME" "$HEALTH" <<'JS'
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const [runtime, scala, langium, javaHome, nodeHome, health] = process.argv.slice(2);
fs.writeFileSync(runtime + '/tools/layout.json', JSON.stringify({javaHome, nodeHome, sbtHome: runtime + '/tools/sbt'}, null, 2));
// Attached VS Code uses the Linux workspace's settings and paths.
const settingsFile = '/workspace/.vscode/settings.json';
fs.mkdirSync('/workspace/.vscode', {recursive:true});
const settings = fs.existsSync(settingsFile) ? JSON.parse(fs.readFileSync(settingsFile, 'utf8')) : {};
Object.assign(settings, {
    'clinicalDsl.rxnorm.scalaRoot': scala, 'clinicalDsl.rxnorm.toolsRoot': runtime + '/tools',
    'clinicalDsl.rxnorm.release': '2026-10-05', 'clinicalDsl.rxnorm.onSave': true,
    'files.autoSave': 'afterDelay', 'files.autoSaveDelay': 1000,
    'clinicalDsl.rxnorm.pgHost': '127.0.0.1', 'clinicalDsl.rxnorm.pgPort': 5432,
    'clinicalDsl.rxnorm.pgDatabase': 'rxnorm_public', 'clinicalDsl.rxnorm.pgUser': 'rxnorm_lab',
    'clinicalDsl.rxnorm.timeoutSeconds': 300
});
fs.writeFileSync(settingsFile, JSON.stringify(settings, null, 2));
const head = cwd => execFileSync('git', ['rev-parse', 'HEAD'], {cwd,encoding:'utf8'}).trim();
fs.writeFileSync(health, JSON.stringify({status:'runtime-checks-passed', checkedAt:new Date().toISOString(),
    databaseMode:'docker-linux-runtime', scalaHead:head(scala), langiumHead:head(langium),
    postgres:'authenticated-query-pass', rxnorm:'provenance-pass', scala:'incremental-compile-test-pass',
    langium:'generate-build-pass', clinicalValid:'pass', clinicalInvalid:'pass', languageServer:'initialize-diagnostics-pass'}, null, 2));
JS
printf 'Linux runtime checks passed. Demo: %s\nHealth: %s\n' "$DEMO" "$HEALTH"
