#!/usr/bin/env bash
# aurora-container-runtime-v1
# Linux half of bootstrap-windows.ps1 --Docker.
set -euo pipefail
umask 077
ROOT=/workspace
SCALA_BRANCH=main
LANGIUM_BRANCH=main
STARTUP_TIMEOUT=180
CONTAINER_RUNTIME=0
RELAUNCH_COUNT=0
ALLOW_TOOL_UPGRADE=0
NON_INTERACTIVE=0
PROVISION_DATABASE=0
PG_ADMIN_USER=postgres
while [ "$#" -gt 0 ]; do
    case "$1" in
        --container-runtime) CONTAINER_RUNTIME=1; shift ;;
        --allow-tool-upgrade) ALLOW_TOOL_UPGRADE=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --provision-database) PROVISION_DATABASE=1; shift ;;
        --root|--scala-branch|--langium-branch|--startup-timeout|--relaunch-count|--pg-admin-user)
            [ "$#" -ge 2 ] || { echo "Missing value for $1" >&2; exit 1; }
            case "$1" in
                --root) ROOT=$2 ;;
                --scala-branch) SCALA_BRANCH=$2 ;;
                --langium-branch) LANGIUM_BRANCH=$2 ;;
                --startup-timeout) STARTUP_TIMEOUT=$2 ;;
                --relaunch-count) RELAUNCH_COUNT=$2 ;;
                --pg-admin-user) PG_ADMIN_USER=$2 ;;
            esac
            shift 2 ;;
        --help) echo 'Linux runtime worker: bootstrap-unix.sh --container-runtime --root /workspace [--scala-branch NAME] [--langium-branch NAME] [--startup-timeout SECONDS] [--allow-tool-upgrade] [--pg-admin-user NAME] [--provision-database] [--non-interactive]. Start with bootstrap-windows.ps1 --Docker; tools and repositories remain in the persistent Linux runtime.'; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done
[ "$CONTAINER_RUNTIME" = 1 ] && [ -f /.dockerenv ] || { echo 'This script is the Linux worker for bootstrap-windows.ps1 --Docker. It must run inside its selected persistent Linux container.' >&2; exit 1; }
[[ "$STARTUP_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$STARTUP_TIMEOUT" -ge 30 ] && [ "$STARTUP_TIMEOUT" -le 600 ] || { echo 'Invalid startup timeout.' >&2; exit 1; }
[[ "$RELAUNCH_COUNT" =~ ^[012]$ ]] || { echo 'Invalid relaunch count.' >&2; exit 1; }
# Package names below are reviewed for this seed; do not guess at a different OS.
. /etc/os-release
case "$ID" in
    ubuntu|debian) ;;
    *) echo 'Ubuntu or Debian is required for reliable package inventory. Ubuntu 24.04 is the supported APT installation environment.' >&2; exit 1 ;;
esac
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
# Both managed and host-network runtimes use the application's loopback-only contract.
if [[ ${PGUSER:-} = scala_lab && -z ${PGPASSWORD:-} ]]; then export PGPASSWORD=aurora; fi
if [[ ${PGHOST:-} != 127.0.0.1 && ${PGHOST:-} != ::1 ]] ||
   ! [[ ${PGPORT:-} =~ ^[1-9][0-9]{0,4}$ ]] || ((PGPORT > 65535)) ||
   ! [[ ${PGDATABASE:-} =~ ^[A-Za-z_][A-Za-z_0-9]{0,62}$ ]] ||
   [[ -z ${PGUSER:-} || -z ${PGPASSWORD:-} ]]; then
    echo 'Select a loopback PostgreSQL endpoint, valid port/database and the existing credentials.' >&2
    exit 1
fi
export PGCONNECT_TIMEOUT=10 PGSSLMODE=disable
unset PGHOSTADDR PGSERVICE
BOOTSTRAP_ADMIN_PASSWORD=${AURORA_PG_ADMIN_PASSWORD:-}
export -n BOOTSTRAP_ADMIN_PASSWORD
unset AURORA_PG_ADMIN_PASSWORD

# Selection is scoped to this Linux runtime. A stale PATH does not imply absence.
tool_fail() { printf 'Tool discovery: %s\n' "$*" >&2; return 1; }
version_at_least() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)" = "$2" ]; }
confirm_tool_upgrade() {
    local action=$1 answer
    if [ "${ALLOW_TOOL_UPGRADE:-0}" = 1 ]; then printf 'Approved by --allow-tool-upgrade: %s\n' "$action" >&2; return 0; fi
    if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ ! -t 0 ]; then
        tool_fail "$action requires consent. Rerun interactively or pass --allow-tool-upgrade."
        return 1
    fi
    printf '%s? [y/N] ' "$action" >&2
    IFS= read -r answer || return 1
    [[ "$answer" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]
}
prepend_tool_path() {
    local directory=$1 entry rebuilt=$1
    local -a entries
    IFS=: read -r -a entries <<< "$PATH"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] || [ "$entry" = "$directory" ] || rebuilt="$rebuilt:$entry"
    done
    export PATH="$rebuilt"
}

TOOL_INVENTORY_READY=0
TOOL_DISCOVERY_ERRORS=''
declare -a TOOL_INVENTORY=()
build_tool_inventory() {
    [ "$TOOL_INVENTORY_READY" = 0 ] || return 0
    local directory results errors entry
    local -A explicit=()
    local -a additional=() roots=("$TOOLS" /opt /usr/local /usr/lib/jvm /usr/lib/postgresql /usr/share/sbt /usr/share/java
        "$HOME/.local/bin" "${SDKMAN_CANDIDATES_DIR:-$HOME/.sdkman/candidates}" "${NVM_DIR:-$HOME/.nvm}/versions/node"
        "${VOLTA_HOME:-$HOME/.volta}/tools/image" "${FNM_DIR:-$HOME/.local/share/fnm}/node-versions"
        "${ASDF_DATA_DIR:-$HOME/.asdf}/installs" "${MISE_DATA_DIR:-$HOME/.local/share/mise}/installs"
        /home/linuxbrew/.linuxbrew/opt)
    IFS=: read -r -a additional <<< "${AURORA_TOOL_SEARCH_PATH:-}"
    for directory in "${additional[@]}"; do [ -z "$directory" ] || explicit[$directory]=1; done
    TOOL_INVENTORY=(); TOOL_DISCOVERY_ERRORS=''
    results=$(mktemp); errors=$(mktemp)
    for directory in "${roots[@]}" "${additional[@]}"; do
        [ -n "$directory" ] || continue
        if [ -L "$directory" ] && [ ! -d "$directory" ]; then
            TOOL_DISCOVERY_ERRORS+=" Unresolved search root: $directory."; continue
        fi
        if [ ! -d "$directory" ]; then
            if [ -n "${explicit[$directory]:-}" ]; then TOOL_DISCOVERY_ERRORS+=" Configured search directory is unavailable: $directory."; fi
            continue
        fi
        # -H resolves an explicitly named root. Never recursively chase symlink cycles.
        find -H "$directory" \( -type f -o -type l \) \( -name java -o -name node -o -name npm -o -name npm-cli.js -o -name git -o -name psql -o -name pg_isready -o -name sbt -o -name 'sbt-launch*.jar' -o -name curl -o -name unzip -o -name xz \) -print0 >> "$results" 2>> "$errors" || TOOL_DISCOVERY_ERRORS+=" Search incomplete under $directory."
    done
    [ ! -s "$errors" ] || TOOL_DISCOVERY_ERRORS+=" $(cat "$errors")"
    while IFS= read -r -d '' entry; do TOOL_INVENTORY+=("$entry"); done < "$results"
    rm -f "$results" "$errors"
    TOOL_INVENTORY_READY=1
}
PACKAGE_DATABASE_READY=0
check_package_database() {
    [ "$PACKAGE_DATABASE_READY" = 0 ] || return 0
    if [ ! -r /var/lib/dpkg/status ] || ! dpkg-query -W -f='${binary:Package}\n' >/dev/null 2>&1; then
        tool_fail 'Package database cannot be read reliably. Discovery is inconclusive.'
        return 4
    fi
    PACKAGE_DATABASE_READY=1
}
installed_package_evidence() {
    local output status
    if output=$(dpkg-query -W -f='${binary:Package}\t${db:Status-Status}\n' "$@" 2>/dev/null); then :; else
        status=$?; [ "$status" = 1 ] || return 4
    fi
    printf '%s\n' "$output" | awk 'NF >= 2 && $2 != "not-installed" && $2 != "config-files" { print $1 }'
}

probe_runtime_tool() {
    local tool=$1 executable=$2 output version major home minimum npm_node_dir="${NODE_HOME:-}/bin"
    [ -f "$executable" ] && [ -x "$executable" ] || return 1
    case "$tool" in
        java)
            output=$(timeout 20 "$executable" -XshowSettings:properties -version 2>&1) || return 1
            version=$(sed -n 's/^ *java.version = //p' <<< "$output")
            home=$(sed -n 's/^ *java.home = //p' <<< "$output")
            major=${version%%[.-]*}
            [ -x "$home/bin/java" ] && [[ "$major" =~ ^[0-9]+$ ]] && [ "$major" -ge 11 ] || { printf '%s' "${version:-incomplete JVM}"; return 1; }
            if [ "${KNOWN_JDK_ONLY:-0}" = 1 ] && [ "$major" != 11 ] && [ "$major" != 17 ] && [ "$major" != 21 ]; then printf '%s' "$version"; return 1; fi
            printf '%s\t%s\n' "$version" "$home"; return 0 ;;
        node)
            output=$(timeout 20 "$executable" -p 'process.versions.node + "\t" + process.execPath') || return 1
            IFS=$'\t' read -r version home <<< "$output"; major=${version%%.*}
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && { [ "$major" -ge 24 ] || { [ "$major" = 22 ] && version_at_least "$version" 22.12.0; }; } || { printf '%s' "$version"; return 1; }
            [ -f "$home" ] && [ -x "$home" ] || return 1
            printf '%s\t%s\n' "$version" "$home"; return 0 ;;
        npm)
            version=$(PATH="$npm_node_dir:$PATH" timeout 20 "$executable" --version 2>/dev/null) || return 1
            [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && version_at_least "$version" 10.2.3 || { printf '%s' "$version"; return 1; } ;;
        git|psql|pg_isready)
            output=$(timeout 20 "$executable" --version 2>&1) || return 1
            if [ "$tool" = git ]; then
                version=$(sed -n 's/^git version \([0-9][0-9.]*\).*/\1/p' <<< "$output"); minimum=2.25.0
            else
                version=$(sed -n 's/.*PostgreSQL) \([0-9][0-9.]*\).*/\1/p' <<< "$output"); minimum=15
            fi
            [ -n "$version" ] && version_at_least "$version" "$minimum" || { printf '%s' "$version"; return 1; } ;;
        curl|unzip|xz)
            if [ "$tool" = unzip ]; then output=$(timeout 20 "$executable" -v 2>&1) || return 1
            else output=$(timeout 20 "$executable" --version 2>&1) || return 1; fi
            version=${output%%$'\n'*} ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$version"
}

# Globals contain the tested path, version and (for Java) the JVM's own home.
# seen and evidence are local to the caller, shared across fast and fallback passes.
try_tool_candidates() {
    local tool=$1 candidate probe version
    shift
    for candidate in "$@"; do
        [ -n "$candidate" ] && [ -z "${seen[$candidate]:-}" ] || continue
        seen[$candidate]=1
        if probe=$(probe_runtime_tool "$tool" "$candidate"); then
            IFS=$'\t' read -r version TOOL_REPORTED_HOME <<< "$probe"
            if [ "$tool" = java ]; then
                case "${version%%[.-]*}" in
                    11|17|21) ;;
                    *) if [ -z "${trial_seen[$TOOL_REPORTED_HOME]:-}" ]; then
                           trial_seen[$TOOL_REPORTED_HOME]=1
                           trial_paths+=("$candidate"); trial_homes+=("$TOOL_REPORTED_HOME"); trial_versions+=("$version")
                       fi
                       continue ;;
                esac
            fi
            TOOL_SELECTED="$candidate"; TOOL_VERSION="$version"
            printf 'Reuse %s %s at %s\n' "$tool" "$version" "$candidate"
            return 0
        fi
        evidence+=" $candidate (${probe:-incomplete})"
    done
    return 1
}
discover_runtime_tool() {
    local -a trial_paths=() trial_homes=() trial_versions=()
    local -A trial_seen=()
    local tool=$1 hint=${2:-} candidate directory package_evidence pkg files evidence=''
    local -a candidates=() packages=()
    local -A seen=()
    TOOL_SELECTED=''; TOOL_VERSION=''; TOOL_REPORTED_HOME=''
    if [ "$tool" = java ]; then JAVA_ALTERNATE_HOMES=(); JAVA_ALTERNATE_VERSIONS=(); fi
    [ -z "$hint" ] || candidates+=("$hint")
    while IFS= read -r candidate; do candidates+=("$candidate"); done < <(type -a -p "$tool" 2>/dev/null || :)
    if command -v update-alternatives >/dev/null; then
        while IFS= read -r candidate; do candidates+=("$candidate"); done < <(update-alternatives --list "$tool" 2>/dev/null || :)
    fi
    case "$tool" in
        java) packages=('openjdk-*-jdk*' 'openjdk-*-jre*' 'temurin-*-jdk*')
            for directory in /usr/lib/jvm/* /opt/jdk* "${SDKMAN_CANDIDATES_DIR:-$HOME/.sdkman/candidates}"/java/*; do
                [ ! -d "$directory" ] || candidates+=("$directory/bin/java")
            done ;;
        node|npm) packages=("$tool"); [ "$tool" != node ] || packages=(nodejs)
            for directory in "$TOOLS"/node-v* /opt/node* "${NVM_DIR:-$HOME/.nvm}"/versions/node/* "${FNM_DIR:-$HOME/.local/share/fnm}"/node-versions/*/installation "${VOLTA_HOME:-$HOME/.volta}"/tools/image/node/*; do
                [ -d "$directory" ] || continue
                # Node can be distributed without npm. Only count actual npm files
                # (or a package record) as evidence that npm is already installed.
                if [ "$tool" = node ] || [ -e "$directory/bin/npm" ] || [ -L "$directory/bin/npm" ]; then
                    candidates+=("$directory/bin/$tool")
                fi
            done ;;
        psql|pg_isready) packages=('postgresql-client-[0-9]*')
            for directory in /usr/lib/postgresql/[0-9]*; do [ ! -d "$directory" ] || candidates+=("$directory/bin/$tool"); done ;;
        xz) packages=(xz-utils) ;;
        *) packages=("$tool") ;;
    esac
    try_tool_candidates "$tool" "${candidates[@]}" && return 0
    candidates=()
    check_package_database || return 4
    package_evidence=$(installed_package_evidence "${packages[@]}") || return 4
    for pkg in $package_evidence; do
        files=$(dpkg-query -L "$pkg") || { tool_fail "Unable to inspect files installed by $pkg."; return 4; }
        while IFS= read -r candidate; do
            if [ "${candidate##*/}" = "$tool" ] || { [ "$tool" = npm ] && [ "${candidate##*/}" = npm-cli.js ]; }; then candidates+=("$candidate"); fi
        done <<< "$files"
    done
    try_tool_candidates "$tool" "${candidates[@]}" && return 0
    build_tool_inventory; candidates=()
    for candidate in "${TOOL_INVENTORY[@]}"; do
        if [ "${candidate##*/}" = "$tool" ] || { [ "$tool" = npm ] && [ "${candidate##*/}" = npm-cli.js ]; }; then candidates+=("$candidate"); fi
    done
    try_tool_candidates "$tool" "${candidates[@]}" && return 0
    if [ "${#trial_paths[@]}" -gt 0 ]; then
        TOOL_SELECTED=${trial_paths[0]}; TOOL_REPORTED_HOME=${trial_homes[0]}; TOOL_VERSION=${trial_versions[0]}
        JAVA_ALTERNATE_HOMES=("${trial_homes[@]:1}"); JAVA_ALTERNATE_VERSIONS=("${trial_versions[@]:1}")
        printf 'Trying Java %s at %s. Project compatibility will be checked before use.\n' "$TOOL_VERSION" "$TOOL_SELECTED"
        return 0
    fi
    if [ -n "$TOOL_DISCOVERY_ERRORS" ]; then tool_fail "Cannot complete $tool discovery.$TOOL_DISCOVERY_ERRORS"; return 4; fi
    if [ -n "$evidence$package_evidence" ]; then tool_fail "$tool found but incompatible or incomplete:$evidence $package_evidence"; return 2; fi
    return 3
}

APT_INDEX_READY=0
install_missing_apt_package() {
    local package=$1 upgrade=${2:-0} simulation changes
    local -a apt_flags=(--no-remove --no-upgrade --no-install-recommends)
    [ "$upgrade" = 0 ] || apt_flags=(--no-remove --no-install-recommends)
    check_package_database || return 4
    [ "$ID:$VERSION_ID" = ubuntu:24.04 ] || { tool_fail "Automatic APT changes require Ubuntu 24.04. Supply a compatible $package in this $ID $VERSION_ID runtime."; return 1; }
    [ "$(id -u)" = 0 ] || { tool_fail "Installing $package requires root in the runtime."; return 1; }
    if [ "$APT_INDEX_READY" = 0 ]; then apt-get update || return $?; APT_INDEX_READY=1; fi
    simulation=$(apt-get -s "${apt_flags[@]}" install "$package") || return 1
    if grep -Eq '^Remv ' <<< "$simulation"; then
        tool_fail "APT would remove an existing package while installing $package. Reconcile explicitly."
        return 1
    fi
    changes=$(awk '$1=="Inst" && $3 ~ /^\[/ {print $2}' <<< "$simulation")
    if [ -n "$changes" ]; then
        if [ "$upgrade" != 1 ]; then tool_fail "Installing $package would upgrade existing packages: $changes"; return 1; fi
        if [ "$changes" != "$package" ]; then confirm_tool_upgrade "Allow these required APT package upgrades: $changes" || return 2; fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${apt_flags[@]}" "$package" || return $?
    # The package database and explicit binary paths are re-read for this tool only.
    PACKAGE_DATABASE_READY=0; hash -r
}
ensure_apt_runtime_tool() {
    local tool=$1 package=$2 hint=${3:-} result
    if discover_runtime_tool "$tool" "$hint"; then return 0; else result=$?; fi
    case "$result" in
        2) confirm_tool_upgrade "Use the supported $package package for incompatible $tool in this container" || return 2 ;;
        3) printf 'Install missing %s using %s.\n' "$tool" "$package" ;;
        *) return "$result" ;;
    esac
    if [ "$result" = 2 ]; then install_missing_apt_package "$package" 1 || return $?; else install_missing_apt_package "$package" || return $?; fi
    discover_runtime_tool "$tool" "$hint" || { tool_fail "Installation did not produce a compatible $tool."; return 1; }
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
    curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v22.14.0/SHASUMS256.txt" -o "$checksums.part" || return 1
    mv -T "$checksums.part" "$checksums" || return 1
    expected=$(awk -v name="$archive" '$2 == name { print $1 }' "$checksums")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { tool_fail 'Node checksum metadata is invalid.'; return 1; }
    if ! printf '%s  %s\n' "$expected" "$TOOLS/downloads/$archive" | sha256sum --status -c - 2>/dev/null; then
        curl --fail --location --proto '=https' --tlsv1.2 "https://nodejs.org/dist/v22.14.0/$archive" -o "$TOOLS/downloads/$archive.part" || return 1
        printf '%s  %s\n' "$expected" "$TOOLS/downloads/$archive.part" | sha256sum -c - || return 1
        mv -T "$TOOLS/downloads/$archive.part" "$TOOLS/downloads/$archive" || return 1
    fi
    local stage
    stage=$(mktemp -d "$TOOLS/node-stage.XXXXXX")
    tar -xJf "$TOOLS/downloads/$archive" -C "$stage" || return 1
    mv -T "$stage/node-v22.14.0-linux-$architecture" "$directory" || return 1
    rmdir "$stage"
    NODE_HOME="$directory"
    export NODE_HOME
    prepend_tool_path "$NODE_HOME/bin"
}

# Recover npm independently when a compatible Node is already installed.
install_project_npm() {
    local version=10.9.2 directory="$TOOLS/npm-10.9.2" metadata archive expected actual stage
    [ ! -e "$directory" ] || { tool_fail "Existing managed npm at $directory is incomplete. Repair it explicitly."; return 1; }
    mkdir -p "$TOOLS/downloads"
    metadata="$TOOLS/downloads/npm-$version.json"; archive="$TOOLS/downloads/npm-$version.tgz"
    curl --fail --location --proto '=https' --tlsv1.2 "https://registry.npmjs.org/npm/$version" -o "$metadata.part" || return 1
    mv -T "$metadata.part" "$metadata" || return 1
    expected=$(node -e 'const m=require(process.argv[1]); if(m.name!=="npm"||m.version!==process.argv[2]||!/^sha512-[A-Za-z0-9+/=]+$/.test(m.dist.integrity))process.exit(1); console.log(m.dist.integrity)' "$metadata" "$version") || return 1
    curl --fail --location --proto '=https' --tlsv1.2 "https://registry.npmjs.org/npm/-/npm-$version.tgz" -o "$archive.part" || return 1
    actual=$(node -e 'const fs=require("node:fs");console.log("sha512-"+require("node:crypto").createHash("sha512").update(fs.readFileSync(process.argv[1])).digest("base64"))' "$archive.part") || return 1
    [ "$actual" = "$expected" ] || { tool_fail 'Downloaded npm failed its published integrity check.'; return 1; }
    mv -T "$archive.part" "$archive" || return 1
    stage=$(mktemp -d "$TOOLS/npm-stage.XXXXXX")
    tar -xzf "$archive" --strip-components=1 -C "$stage" || return 1
    mv -T "$stage" "$directory" || return 1
    TOOL_SELECTED="$directory/bin/npm-cli.js"
    probe_runtime_tool npm "$TOOL_SELECTED" >/dev/null || return 1
}
select_tool_link() {
    local source=$1 target=$2
    if [ -L "$target" ]; then [ "$(readlink "$target")" != "$source" ] || return 0
    elif [ -e "$target" ]; then tool_fail "Unmanaged file occupies $target."; return 1; fi
    ln -sfnT "$source" "$target"
}
select_java() {
    JAVA_HOME=$TOOL_REPORTED_HOME; JAVA_VERSION=$TOOL_VERSION
    export JAVA_HOME
    prepend_tool_path "$JAVA_HOME/bin"
}
ensure_runtime_tools() {
    local result certificates hint=''
    check_package_database || return 4
    certificates=$(installed_package_evidence ca-certificates) || return 4
    [ -n "$certificates" ] || install_missing_apt_package ca-certificates || return 1
    [ -s /etc/ssl/certs/ca-certificates.crt ] || { tool_fail 'Installed CA certificates are incomplete.'; return 1; }
    ensure_apt_runtime_tool curl curl; prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool xz xz-utils; prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool unzip unzip; prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    ensure_apt_runtime_tool git git; prepend_tool_path "$(dirname "$TOOL_SELECTED")"
    [ -z "${JAVA_HOME:-}" ] || hint="$JAVA_HOME/bin/java"
    ensure_apt_runtime_tool java openjdk-21-jdk-headless "$hint"
    select_java
    hint=''; [ -z "${NODE_HOME:-}" ] || hint="$NODE_HOME/bin/node"
    if discover_runtime_tool node "$hint"; then :; else
        result=$?
        if [ "$result" = 2 ]; then confirm_tool_upgrade 'Install project Node 22.14.0 alongside the incompatible installation' || return 2
        elif [ "$result" != 3 ]; then return "$result"; fi
        install_missing_node || return 1
        discover_runtime_tool node "$NODE_HOME/bin/node" || return 1
    fi
    local selected_node selected_bin="$TOOLS/selected-bin" npm_hint
    selected_node=$(readlink -f "$TOOL_REPORTED_HOME") || return 1
    NODE_HOME=$(dirname "$(dirname "$selected_node")"); export NODE_HOME
    prepend_tool_path "$NODE_HOME/bin"
    npm_hint=''; [ ! -e "$NODE_HOME/bin/npm" ] || npm_hint="$NODE_HOME/bin/npm"
    if [ -x "$TOOLS/npm-10.9.2/bin/npm-cli.js" ] && [ -z "$npm_hint" ]; then npm_hint="$TOOLS/npm-10.9.2/bin/npm-cli.js"; fi
    if discover_runtime_tool npm "$npm_hint"; then :; else
        result=$?
        if [ "$result" = 2 ]; then confirm_tool_upgrade 'Install project-local npm 10.9.2 for the selected Node' || return 2
        elif [ "$result" != 3 ]; then return "$result"; fi
        install_project_npm || return 1
    fi
    NPM=$(readlink -f "$TOOL_SELECTED") || return 1
    export NPM
    mkdir -p "$selected_bin"
    select_tool_link "$JAVA_HOME/bin/java" "$selected_bin/java"
    select_tool_link "$selected_node" "$selected_bin/node"
    select_tool_link "$NPM" "$selected_bin/npm"
    prepend_tool_path "$selected_bin"
    hint=''; [ -z "${PGHOME:-}" ] || hint="$PGHOME/bin/psql"
    ensure_apt_runtime_tool psql postgresql-client-16 "$hint"
    PSQL="$TOOL_SELECTED"; PGHOME=$(dirname "$(dirname "$PSQL")"); export PGHOME PSQL
    prepend_tool_path "$(dirname "$PSQL")"
    ensure_apt_runtime_tool pg_isready postgresql-client-16 "$(dirname "$PSQL")/pg_isready"
    PG_ISREADY=$TOOL_SELECTED; export PG_ISREADY
    # Selecting /usr/bin for PostgreSQL must not shadow the recovered Node/npm.
    prepend_tool_path "$selected_bin"
    ensure_sbt_launcher
}

# Only downloads require this pinned checksum. Locally installed launchers also
# qualify if their manifest/boot configuration and the actual project probe pass.
verify_sbt_launcher() {
    local launcher=$1
    [ -f "$launcher" ] && [ -r "$launcher" ] &&
        printf '%s  %s\n' cdd6963b622f42690cb2e3154bde3f3257a03839f216e1b5d7420000d6a71817 "$launcher" | sha256sum -c - >/dev/null 2>&1
}
download_project_launcher() {
    local path="$TOOLS/sbt-launch-1.10.2.jar"
    if ! verify_sbt_launcher "$path"; then
        curl --fail --location --proto '=https' --tlsv1.2 'https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar' -o "$path.part" || return 1
        verify_sbt_launcher "$path.part" || { tool_fail 'Downloaded sbt launcher checksum failed.'; return 1; }
        mv -T "$path.part" "$path" || return 1
    fi
    SBT=$path; SBT_NEEDS_PROBE=0
}
ensure_sbt_launcher() {
    local candidate wrapper prefix directory canonical manifest boot evidence='' packages files c
    local -a candidates=() wrappers=() jars=()
    local -A seen=()
    SBT_NEEDS_PROBE=0; SBT_ALTERNATIVES=()
    [ -z "${SBT_LAUNCH_JAR:-}" ] || candidates+=("$SBT_LAUNCH_JAR")
    candidates+=("$TOOLS/sbt/bin/sbt-launch.jar" "$TOOLS/sbt-launch-1.10.2.jar")
    while IFS= read -r wrapper; do wrappers+=("$wrapper"); done < <(type -a -p sbt 2>/dev/null || :)
    for wrapper in "${wrappers[@]}"; do
        canonical=$(readlink -f "$wrapper") || continue
        prefix=$(dirname "$(dirname "$canonical")")
        candidates+=("$prefix/bin/sbt-launch.jar" "$prefix/share/sbt/bin/sbt-launch.jar")
        evidence+=" $wrapper"
    done
    for directory in "${SBT_HOME:-}" /usr/share/sbt /opt/sbt* /usr/local/sbt* "${SDKMAN_CANDIDATES_DIR:-$HOME/.sdkman/candidates}"/sbt/*; do
        [ -d "$directory" ] || continue
        candidates+=("$directory/bin/sbt-launch.jar" "$directory"/lib/sbt-launch*.jar)
    done
    for candidate in "$HOME"/.sbt/launchers/*/sbt-launch.jar "$HOME"/.sbt/boot/sbt-launch/*/sbt-launch*.jar \
        "${SBT_IVY_HOME:-$HOME/.ivy2}"/cache/org.scala-sbt/sbt-launch/jars/sbt-launch*.jar \
        "${MAVEN_REPO_LOCAL:-$HOME/.m2/repository}"/org/scala-sbt/sbt-launch/*/sbt-launch*.jar; do
        [ ! -f "$candidate" ] || candidates+=("$candidate")
    done
    for directory in "${COURSIER_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/coursier/v1}" "$HOME/.coursier/cache/v1"; do
        for candidate in "$directory"/https/*/*/org/scala-sbt/sbt-launch/*/sbt-launch*.jar "$directory"/https/*/org/scala-sbt/sbt-launch/*/sbt-launch*.jar; do
            [ ! -f "$candidate" ] || candidates+=("$candidate")
        done
    done
    # The common launcher avoids any broad inventory.
    for candidate in "${candidates[@]}"; do
        if verify_sbt_launcher "$candidate"; then SBT=$candidate; printf 'Reuse verified sbt launcher %s\n' "$SBT"; return 0; fi
    done
    check_package_database || return 4
    packages=$(installed_package_evidence sbt sbt-launcher) || return 4
    for c in $packages; do
        files=$(dpkg-query -L "$c") || return 4
        while IFS= read -r candidate; do
            case "${candidate##*/}" in sbt-launch*.jar) candidates+=("$candidate");; esac
        done <<< "$files"
    done
    build_tool_inventory
    for candidate in "${TOOL_INVENTORY[@]}"; do
        case "${candidate##*/}" in sbt-launch*.jar) candidates+=("$candidate");; sbt) evidence+=" $candidate";; esac
    done
    for candidate in "${candidates[@]}"; do
        [ -f "$candidate" ] || { [ ! -L "$candidate" ] || evidence+=" $candidate"; continue; }
        canonical=$(readlink -f "$candidate") || return 4
        [ -z "${seen[$canonical]:-}" ] || continue; seen[$canonical]=1
        if verify_sbt_launcher "$canonical"; then SBT=$canonical; printf 'Reuse verified sbt launcher %s\n' "$SBT"; return 0; fi
        manifest=$(unzip -p "$canonical" META-INF/MANIFEST.MF 2>/dev/null | tr -d '\r') || manifest=''
        boot=$(unzip -p "$canonical" sbt/sbt.boot.properties 2>/dev/null) || boot=''
        if grep -Eq '^Main-Class: xsbt\.boot\.Boot$' <<< "$manifest" && grep -Fq 'read(sbt.version)' <<< "$boot"; then
            jars+=("$canonical")
        fi
        evidence+=" $candidate"
    done
    if [ "${#jars[@]}" -gt 0 ]; then
        SBT=${jars[0]}; SBT_ALTERNATIVES=("${jars[@]:1}"); SBT_NEEDS_PROBE=1
        printf 'Trying existing sbt launcher with project/build.properties: %s\n' "$SBT"
        return 0
    fi
    [ -z "$TOOL_DISCOVERY_ERRORS" ] || { tool_fail "sbt search incomplete.$TOOL_DISCOVERY_ERRORS"; return 4; }
    if [ -n "$evidence$packages${SBT_LAUNCH_JAR:-}${SBT_HOME:-}" ]; then
        printf 'Existing sbt evidence:%s %s\n' "$evidence" "$packages" >&2
        confirm_tool_upgrade 'Install the verified project sbt launcher (extension requires a launcher JAR)' || return 2
    fi
    download_project_launcher
}
run_sbt() {
    "$JAVA_HOME/bin/java" -Xmx2G -Dsbt.supershell=false -Dsbt.log.noformat=true -Dsbt.server.autostart=false -jar "$SBT" "$@"
}
verify_project_runtime() {
    local expected_sbt expected_scala log status major candidate
    expected_sbt=$(sed -n 's/^sbt.version=//p' "$SCALA/project/build.properties" | tr -d '\r')
    expected_scala=$(sed -n 's/^ThisBuild \/ scalaVersion := "\([^"]*\)".*/\1/p' "$SCALA/build.sbt")
    [ -n "$expected_sbt" ] && [ -n "$expected_scala" ] || { tool_fail 'Could not determine pinned sbt/Scala versions.'; return 1; }
    local -a scala_roots=()
    IFS=: read -r -a scala_roots <<< "${AURORA_TOOL_SEARCH_PATH:-}"
    if node "$SCALA/scripts/check-scala.cjs" "$SCALA" "${scala_roots[@]}"; then :; else
        status=$?
        [ "$status" = 11 ] || return "$status"
        confirm_tool_upgrade "Allow sbt to obtain Scala $expected_scala for this project alongside the installed Scala" || return 2
    fi
    major=${JAVA_VERSION%%[.-]*}
    if [ "$SBT_NEEDS_PROBE" = 1 ] || { [ "$major" != 11 ] && [ "$major" != 17 ] && [ "$major" != 21 ]; }; then
        log="$STATE/project-toolchain-check.log"
        while :; do
            if (cd "$SCALA" && run_sbt 'show sbtVersion' 'show scalaVersion' compile) 2>&1 | tee "$log"; then
                if grep -Fxq "[info] $expected_sbt" "$log" && grep -Fxq "[info] $expected_scala" "$log"; then break; fi
                [ "$SBT_NEEDS_PROBE" = 1 ] || { tool_fail "Unexpected project tool versions; see $log."; return 1; }
            else
                status=${PIPESTATUS[0]}
                if [ "$major" != 11 ] && [ "$major" != 17 ] && [ "$major" != 21 ] && grep -Eiq 'UnsupportedClassVersionError|Unsupported class file major version|Unsupported major.minor version|Unrecognized VM option|not compatible with (this version of )?Java' "$log"; then
                    if [ "${#JAVA_ALTERNATE_HOMES[@]}" -gt 0 ]; then
                        TOOL_REPORTED_HOME=${JAVA_ALTERNATE_HOMES[0]}; TOOL_VERSION=${JAVA_ALTERNATE_VERSIONS[0]}
                        JAVA_ALTERNATE_HOMES=("${JAVA_ALTERNATE_HOMES[@]:1}"); JAVA_ALTERNATE_VERSIONS=("${JAVA_ALTERNATE_VERSIONS[@]:1}")
                        printf 'Trying another installed Java %s at %s.\n' "$TOOL_VERSION" "$TOOL_REPORTED_HOME"
                    else
                        KNOWN_JDK_ONLY=1
                        ensure_apt_runtime_tool java openjdk-21-jdk-headless || return $?
                    fi
                    select_java; select_tool_link "$JAVA_HOME/bin/java" "$TOOLS/selected-bin/java" || return 1; major=${JAVA_VERSION%%[.-]*}; continue
                fi
                if [ "$SBT_NEEDS_PROBE" != 1 ] || ! grep -Eiq 'Invalid or corrupt jarfile|Could not find or load main class xsbt.boot.Boot|no main manifest attribute' "$log"; then
                    tool_fail "Project compatibility probe failed (exit $status); see $log. No upgrade is inferred from this error."; return 1
                fi
            fi
            if [ "${#SBT_ALTERNATIVES[@]}" -gt 0 ]; then
                candidate=${SBT_ALTERNATIVES[0]}; SBT_ALTERNATIVES=("${SBT_ALTERNATIVES[@]:1}"); SBT=$candidate
            else
                confirm_tool_upgrade "Use the verified project sbt launcher after $SBT failed the project compatibility check" || return 2
                download_project_launcher || return 1
            fi
        done
    fi
    # Preserve the extension's required layout without replacing user tools or
    # copying launcher bytes. Only the owned selection link may be retargeted.
    local resolved target
    resolved=$(readlink -f "$SBT") || return 1
    if [[ "$resolved" = */bin/sbt-launch.jar ]]; then
        SBT_HOME=$(dirname "$(dirname "$resolved")")
    else
        SBT_HOME="$TOOLS/selected-sbt"; target="$SBT_HOME/bin/sbt-launch.jar"; mkdir -p "$SBT_HOME/bin"
        select_tool_link "$resolved" "$target" || return 1
    fi
    export SBT_HOME
    printf 'Selected Java %s (%s), sbt %s (%s), Scala %s (build.sbt).\n' "$JAVA_VERSION" "$JAVA_HOME" "$expected_sbt" "$resolved" "$expected_scala"
}


ensure_runtime_tools
printf 'Linux repositories: %s/repos (persistent Docker workspace).\n' "$ROOT"

sql() { "$PSQL" -X -w -v ON_ERROR_STOP=1 -Atc "$1"; }
initialize_lab_database() {
    local admin_password server_number has_role has_db verification_db literal
    [[ "$PGUSER" =~ ^[A-Za-z_][A-Za-z_0-9]{0,62}$ ]] || { echo 'Creating a lab role requires a simple PostgreSQL identifier.' >&2; return 1; }
    echo "Cannot connect as '$PGUSER' to '$PGDATABASE'. An administrator must check whether the role or database is missing." >&2
    # The PowerShell launcher may already have authenticated/recovered the
    # managed-container administrator. Otherwise try the requested default once.
    admin_password=${BOOTSTRAP_ADMIN_PASSWORD:-postgres}
    if ! server_number=$(PGPASSWORD="$admin_password" "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atc 'SHOW server_version_num;' 2>/dev/null); then
        if [ "${NON_INTERACTIVE:-0}" = 1 ] || [ ! -t 0 ]; then
            echo "Default PostgreSQL administrator authentication failed for '$PG_ADMIN_USER'. Run interactively to enter the existing password or recover access. Existing credentials were not changed." >&2
            return 1
        fi
        echo "The default administrator password was rejected for '$PG_ADMIN_USER'." >&2
        IFS= read -r -s -p "Existing administrator password (Enter for recovery instructions): " admin_password || return 1
        printf '\n' >&2
        if [ -z "$admin_password" ] || ! server_number=$(PGPASSWORD="$admin_password" "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atc 'SHOW server_version_num;'); then
            echo "PostgreSQL administrator authentication failed. For a Windows-hosted server, run bootstrap-windows.ps1 -RecoverPostgresPassword -PgAdminUser '$PG_ADMIN_USER' -Port '$PGPORT' in an elevated PowerShell session, then rerun Docker setup. Managed Docker recovery is offered by the PowerShell launcher before this worker starts. No role or database was changed." >&2
            return 1
        fi
    fi
    [[ "$server_number" =~ ^[0-9]+$ ]] && ((server_number >= 150000)) || { echo 'PostgreSQL 15+ is required before creating lab objects.' >&2; return 1; }
    has_role=$(PGPASSWORD="$admin_password" "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM pg_catalog.pg_roles WHERE rolname='$PGUSER';") || return 1
    has_db=$(PGPASSWORD="$admin_password" "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atc "SELECT count(*) FROM pg_catalog.pg_database WHERE datname='$PGDATABASE';") || return 1
    [[ "$has_role" =~ ^[01]$ && "$has_db" =~ ^[01]$ ]] || { echo 'Unexpected PostgreSQL catalog response; stopping provisioning.' >&2; return 1; }
    if [ "$has_role" = 0 ]; then
        echo "Creating missing PostgreSQL login '$PGUSER'." >&2
        literal=${PGPASSWORD//\'/\'\'}
        # SQL travels through stdin, not command arguments/files. Suppress errors
        # for this statement because the server may echo its password literal.
        if ! printf 'SET standard_conforming_strings = on;\nCREATE ROLE "%s" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD '\''%s'\'';\n' "$PGUSER" "$literal" |
            PGPASSWORD="$admin_password" PGCLIENTENCODING=UTF8 "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -f - >/dev/null 2>&1; then
            echo "Could not create PostgreSQL role '$PGUSER'. Check the administrator's CREATEROLE permission. Existing roles were not changed." >&2
            return 1
        fi
        unset literal
    fi
    verification_db=postgres
    [ "$has_db" = 0 ] || verification_db=$PGDATABASE
    if ! "$PSQL" -X -w -d "$verification_db" -v ON_ERROR_STOP=1 -Atc 'SELECT 1;' >/dev/null; then
        echo "PostgreSQL authentication/access failed: role '$PGUSER' exists, but the configured password or permissions were rejected for '$verification_db'. Supply the correct PGPASSWORD or check LOGIN/CONNECT permissions. The existing password was not reset." >&2
        return 1
    fi
    if [ "$has_db" = 0 ]; then
        PGPASSWORD="$admin_password" "$PSQL" -X -w -U "$PG_ADMIN_USER" -d postgres -v ON_ERROR_STOP=1 -Atc "CREATE DATABASE \"$PGDATABASE\" OWNER \"$PGUSER\";" >&2 || return 1
    fi
}
open_lab_database() {
    local version
    if ! version=$(sql 'SHOW server_version_num;'); then
        if [[ "$PGUSER" != scala_lab && "${PROVISION_DATABASE:-0}" != 1 ]]; then
            echo "PostgreSQL authentication/connection failed for '$PGUSER'. Check credentials or use -ProvisionDatabase for a custom role. Existing credentials were not changed." >&2
            return 1
        fi
        initialize_lab_database || return 1
        version=$(sql 'SHOW server_version_num;') || return 1
    fi
    printf '%s\n' "$version"
}
start=$SECONDS
until "$PG_ISREADY" -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -t 3 >/dev/null 2>&1; do
    [ "$((SECONDS - start))" -lt "$STARTUP_TIMEOUT" ] || { echo 'PostgreSQL did not become ready.' >&2; exit 1; }
    sleep 1
done
# This authenticated query checks both login and the actual server version.
server_version=$(open_lab_database)
unset BOOTSTRAP_ADMIN_PASSWORD
[[ "$server_version" =~ ^[0-9]+$ ]] || { echo 'Cannot determine the authenticated PostgreSQL server version.' >&2; exit 1; }
if ((server_version < 150000)); then
    if confirm_tool_upgrade "PostgreSQL $server_version is below the supported 15+ range. Show manual upgrade steps"; then
        echo 'Verify a backup, then have the database administrator run pg_upgrade --check on the old and new directories. https://www.postgresql.org/docs/current/pgupgrade.html' >&2
    fi
    echo 'Select a compatible existing cluster or complete its migration before rerunning.' >&2
    exit 1
fi

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
    relaunch_options=()
    [ "$ALLOW_TOOL_UPGRADE" = 0 ] || relaunch_options+=(--allow-tool-upgrade)
    [ "$NON_INTERACTIVE" = 0 ] || relaunch_options+=(--non-interactive)
    [ "$PROVISION_DATABASE" = 0 ] || relaunch_options+=(--provision-database)
    relaunch_options+=(--pg-admin-user "$PG_ADMIN_USER")
    exec bash "$SCALA/scripts/bootstrap-unix.sh" "${relaunch_options[@]}" --container-runtime --root "$ROOT" --scala-branch "$SCALA_BRANCH" --langium-branch "$LANGIUM_BRANCH" --startup-timeout "$STARTUP_TIMEOUT" --relaunch-count "$((RELAUNCH_COUNT + 1))"
fi

verify_project_runtime
# Editor processes need the same non-secret environment as the bootstrap.
profile=/etc/profile.d/aurora-tools.sh
profile_text=$(
    printf 'export JAVA_HOME=%q\n' "$JAVA_HOME"
    printf 'export NODE_HOME=%q\n' "$NODE_HOME"
    printf 'export SBT_HOME=%q\n' "$SBT_HOME"
    [ -z "${COURSIER_CACHE:-}" ] || printf 'export COURSIER_CACHE=%q\n' "$COURSIER_CACHE"
    printf 'export PGHOME=%q\n' "$PGHOME"
    printf 'export PATH=%q\n' "$PATH"
)
if ! cmp -s "$profile" <(printf '%s\n' "$profile_text"); then
    profile_part=$(mktemp "/etc/profile.d/.aurora-tools.XXXXXX")
    printf '%s\n' "$profile_text" > "$profile_part"
    chmod 644 "$profile_part"
    mv -T "$profile_part" "$profile"
fi

cd "$LANGIUM"
WORKSPACE_CHECK="$SCALA/scripts/check-workspace.cjs"
if node "$WORKSPACE_CHECK" check; then :; else
    dependency_status=$?
    case "$dependency_status" in 10|11) ;; *) exit "$dependency_status";; esac
    global_root=$("$NPM" root --global)
    global_status=0
    node "$WORKSPACE_CHECK" inspect-globals "$global_root" || global_status=$?
    case "$global_status" in 0|11) ;; *) exit "$global_status";; esac
    if [ "$dependency_status" = 11 ] || [ "$global_status" = 11 ]; then
        confirm_tool_upgrade 'Install the versions in package-lock.json in this Langium workspace? Global packages will be preserved.' || exit 1
    fi
    before=$(node "$WORKSPACE_CHECK" snapshot)
    node "$WORKSPACE_CHECK" prepare-install "$global_root" "$NPM"
    "$NPM" install --prefer-offline --no-save --ignore-scripts --include=dev --no-audit --no-fund
    [ "$(node "$WORKSPACE_CHECK" snapshot)" = "$before" ] || { echo 'npm changed a source manifest; inspect the changes before proceeding.' >&2; exit 1; }
    node "$WORKSPACE_CHECK" check
fi
"$NPM" run langium:generate
"$NPM" run build
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
    declare -A rrf_hash=(
        [RXNCONSO.RRF]=555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209
        [RXNREL.RRF]=cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694
        [RXNSAT.RRF]=b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda
    )
    needed=()
    for file in "${!rrf_hash[@]}"; do
        if ! printf '%s  %s\n' "${rrf_hash[$file]}" "$DATA/rrf/$file" | sha256sum -c --status 2>/dev/null; then
            needed+=("$file")
        fi
    done
    if ((${#needed[@]})); then
        ARCHIVE="$RUNTIME/downloads/RxNorm_full_prescribe_10052026.zip"
        archive_sha=8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977
        if ! printf '%s  %s\n' "$archive_sha" "$ARCHIVE" | sha256sum -c --status 2>/dev/null; then
            part=$(mktemp "$RUNTIME/downloads/rxnorm.XXXXXX")
            if curl --fail --location --proto '=https' --tlsv1.2 https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip -o "$part" &&
                printf '%s  %s\n' "$archive_sha" "$part" | sha256sum -c --status; then
                mv -f -- "$part" "$ARCHIVE"
            else
                rm -f -- "$part"
                echo 'RxNorm download failed verification. Retry to download a fresh copy.' >&2
                exit 1
            fi
        fi
        for file in "${needed[@]}"; do
            part=$(mktemp "$DATA/rrf/extract.XXXXXX")
            if unzip -p "$ARCHIVE" "rrf/$file" > "$part" &&
                printf '%s  %s\n' "${rrf_hash[$file]}" "$part" | sha256sum -c --status; then
                mv -f -- "$part" "$DATA/rrf/$file"
            else
                rm -f -- "$part"
                echo "Failed to recover $file from the release archive." >&2
                exit 1
            fi
        done
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
if [ "${#IMPORT_COMMANDS[@]}" -gt 0 ]; then
    sql 'ANALYZE;' >/dev/null
    [ "$(sql "$QUERY")" = 1 ] || { echo 'RxNorm release/product provenance verification failed.' >&2; exit 1; }
fi
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
node "$SCALA/scripts/probe-editor.mjs" lsp "$LANGIUM/packages/extension/out/language/main.cjs" "$SMOKE/valid.clinical"
[ "$(sql 'SELECT 1;')" = 1 ] || { echo 'Final PostgreSQL health check failed.' >&2; exit 1; }
node - "$RUNTIME" "$SCALA" "$LANGIUM" "$JAVA_HOME" "$NODE_HOME" "$HEALTH" <<'JS'
const fs = require('node:fs');
const {execFileSync} = require('node:child_process');
const [runtime, scala, langium, javaHome, nodeHome, health] = process.argv.slice(2);
function writeSettings(file, value) {
    const text = JSON.stringify(value, null, 2);
    if (fs.existsSync(file) && fs.readFileSync(file, 'utf8') === text) return;
    const part = file + '.aurora-' + process.pid;
    try {
        fs.writeFileSync(part, text, {flag:'wx'});
        fs.renameSync(part, file);
    } finally { fs.rmSync(part, {force:true}); }
}
writeSettings(runtime + '/tools/layout.json', {javaHome, nodeHome, sbtHome: process.env.SBT_HOME});
// Attached VS Code uses the Linux workspace's settings and paths.
const settingsFile = '/workspace/.vscode/settings.json';
fs.mkdirSync('/workspace/.vscode', {recursive:true});
const settings = fs.existsSync(settingsFile) ? JSON.parse(fs.readFileSync(settingsFile, 'utf8')) : {};
Object.assign(settings, {
    'clinicalDsl.rxnorm.scalaRoot': scala, 'clinicalDsl.rxnorm.toolsRoot': runtime + '/tools',
    'clinicalDsl.rxnorm.release': '2026-10-05', 'clinicalDsl.rxnorm.onSave': true,
    'files.autoSave': 'afterDelay', 'files.autoSaveDelay': 1000,
    'clinicalDsl.rxnorm.pgHost': process.env.PGHOST, 'clinicalDsl.rxnorm.pgPort': Number(process.env.PGPORT),
    'clinicalDsl.rxnorm.pgDatabase': process.env.PGDATABASE, 'clinicalDsl.rxnorm.pgUser': process.env.PGUSER,
    'clinicalDsl.rxnorm.timeoutSeconds': 300
});
writeSettings(settingsFile, settings);
const autocomplete = execFileSync(process.execPath,
    [scala + '/scripts/probe-editor.mjs', 'autocomplete', settingsFile], {encoding:'utf8'}).trim();
console.log('RxNorm autocomplete: ' + autocomplete + '. See ' + scala + '/PRODUCT-AUTOCOMPLETE.md for the editor service.');
const head = cwd => execFileSync('git', ['rev-parse', 'HEAD'], {cwd,encoding:'utf8'}).trim();
fs.writeFileSync(health, JSON.stringify({status:'runtime-checks-passed', checkedAt:new Date().toISOString(),
    databaseMode:'docker-linux-runtime', scalaHead:head(scala), langiumHead:head(langium),
    autocomplete, postgres:'authenticated-query-pass', rxnorm:'provenance-pass', scala:'incremental-compile-test-pass',
    langium:'generate-build-pass', clinicalValid:'pass', clinicalInvalid:'pass', languageServer:'initialize-diagnostics-pass'}, null, 2));
JS
node "$SCALA/scripts/finish-smoke.mjs" "$SMOKE"
printf 'Linux runtime checks passed. Demo: %s\nHealth: %s\n' "$DEMO" "$HEALTH"
