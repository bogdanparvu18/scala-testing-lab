#!/usr/bin/env bash
# stop on errors and keep new files private
set -euo pipefail
umask 077

# defaults, use the current folder
ROOT="$PWD"
PORT=55433
CONTAINER=aurora-medication-auto-pg
VOLUME=aurora-medication-auto-pgdata
OPEN_EDITOR=1

# read any options passed in
while [ "$#" -gt 0 ]; do
    case "$1" in
        --root) ROOT="$2"; shift 2 ;;
        --port) PORT="$2"; shift 2 ;;
        --container) CONTAINER="$2"; shift 2 ;;
        --volume) VOLUME="$2"; shift 2 ;;
        --no-editor) OPEN_EDITOR=0; shift ;;
        --help) echo 'Usage: bootstrap-unix.sh [--root PATH] [--port NUMBER] [--container NAME] [--volume NAME] [--no-editor]'; exit ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# check the tools we need
mkdir -p "$ROOT"
ROOT=$(cd "$ROOT" && pwd)
echo "Setup folder: $ROOT"
# find java on macos or linux
OS=$(uname -s)
if [ "$OS" = Darwin ]; then
    export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 21)}"
else
    export JAVA_HOME="${JAVA_HOME:-/usr/lib/jvm/java-21-openjdk-amd64}"
fi
export PATH="$JAVA_HOME/bin:$PATH"
for tool in git curl unzip java node npm docker; do command -v "$tool" >/dev/null; done
test -x "$JAVA_HOME/bin/java"
java -version 2>&1 | grep -E 'version "21[."]'
node -e 'const [major, minor] = process.versions.node.split(".").map(Number); if (major < 22 || (major === 22 && minor < 12)) throw Error("Use Node 22.12 or newer");'
docker info >/dev/null
if [ "$OPEN_EDITOR" = 1 ]; then command -v code >/dev/null; fi

# keep the setup files together
SCALA="$ROOT/scala-testing-lab"
LANGIUM="$ROOT/langium_dsl_lab/clinical-dsl-demo"
RUNTIME="$ROOT/medication-lab-setup/automatic"
TOOLS="$RUNTIME/tools"
DATA="$RUNTIME/data/2026-10-05"
mkdir -p "$RUNTIME/state" "$TOOLS/sbt/bin" "$RUNTIME/downloads" "$DATA/rrf" "$RUNTIME/editor-profile/User"

# clone the repos if needed
if [ ! -d "$SCALA" ]; then
    git clone https://github.com/bogdanparvu18/scala-testing-lab.git "$SCALA"
    git -C "$SCALA" checkout --detach 6d5f13851c4cccd90273d3a2e25688e2ba15028b
fi
if [ ! -d "$ROOT/langium_dsl_lab" ]; then
    git clone https://github.com/bogdanparvu18/langium_dsl_lab.git "$ROOT/langium_dsl_lab"
    git -C "$ROOT/langium_dsl_lab" checkout --detach d7f75fee45838345c5b902c8f22bf8cd87bfd224
fi
test "$(git -C "$SCALA" rev-parse HEAD)" = 6d5f13851c4cccd90273d3a2e25688e2ba15028b
test "$(git -C "$ROOT/langium_dsl_lab" rev-parse HEAD)" = d7f75fee45838345c5b902c8f22bf8cd87bfd224

# reuse the build when we can
cd "$LANGIUM"
BUILD=0
if [ ! -f node_modules/.package-lock.json ] || [ package-lock.json -nt node_modules/.package-lock.json ]; then
    npm ci
    BUILD=1
fi
if [ "$BUILD" = 1 ] || [ ! -f packages/extension/out/extension/main.cjs ] || [ ! -f packages/language/out/index.js ] || \
    [ ! -f packages/extension/syntaxes/clinical-dsl.tmLanguage.json ] || [ package-lock.json -nt packages/extension/out/extension/main.cjs ]; then
    npm run langium:generate
    npm run build
fi
# download the scala build tool once
SBT="$TOOLS/sbt/bin/sbt-launch.jar"
if [ ! -f "$SBT" ]; then
    curl -fL https://repo.maven.apache.org/maven2/org/scala-sbt/sbt-launch/1.10.2/sbt-launch-1.10.2.jar -o "$SBT.part"
    mv "$SBT.part" "$SBT"
fi

# make a password once, reuse it later
SECRETS="$RUNTIME/state/secrets.json"
if [ ! -f "$SECRETS" ]; then
    node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({password:require("crypto").randomBytes(32).toString("hex")}), {mode:0o600});' "$SECRETS"
fi
chmod 600 "$SECRETS"
export PGHOST=127.0.0.1 PGPORT="$PORT" PGDATABASE=rxnorm_public PGUSER=rxnorm_lab
PGPASSWORD=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).password)' "$SECRETS")
export PGPASSWORD POSTGRES_PASSWORD="$PGPASSWORD"

# start the container, or create it
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    docker start "$CONTAINER" >/dev/null
    test "$(docker port "$CONTAINER" 5432/tcp)" = "127.0.0.1:$PORT"
else
    if docker volume inspect "$VOLUME" >/dev/null 2>&1; then
        echo "Volume $VOLUME already exists without its container. Choose another --volume." >&2
        exit 1
    fi
    docker run -d --name "$CONTAINER" -e POSTGRES_USER="$PGUSER" -e POSTGRES_DB="$PGDATABASE" \
        -e POSTGRES_PASSWORD -p "127.0.0.1:$PORT:5432" -v "$VOLUME:/var/lib/postgresql/data" postgres:16
fi
# wait for postgres and check the password
for attempt in {1..60}; do
    if docker exec "$CONTAINER" pg_isready -U "$PGUSER" -d "$PGDATABASE" >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec -e PGPASSWORD "$CONTAINER" psql -h 127.0.0.1 -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c 'SELECT 1;' >/dev/null
# skip the import if this dataset is ready
QUERY="SELECT 1 FROM rxnorm_lab.release r JOIN rxnorm_lab.product_release p USING (release)
WHERE r.release='2026-10-05' AND r.state='ready' AND p.state='ready' AND p.base_identity=r.identity
AND r.scope='all-active-rxnorm-pg-v4' AND p.policy='single-component-mass-v1'
AND r.sha256_json::jsonb->>'RXNCONSO.RRF'='555730c3ff2a981796dc5d649acc482e4685f7a31f7b0442941393ae50dd5209'
AND r.sha256_json::jsonb->>'RXNREL.RRF'='cca47f32a2c32ef60d65c6789851385ff5dcf287750ca01a53f800a5cf5ef694'
AND p.sha256_json::jsonb->>'RXNSAT.RRF'='b5a476f2bfbef9082144fd2bf00eb0de46f7b0b63da822d856067b9935914dda';"
READY=$(docker exec "$CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE" -Atc "$QUERY" 2>/dev/null || true)
if [ "$READY" != 1 ]; then
    # get the public rxnorm files, no login needed
    ARCHIVE="$RUNTIME/downloads/RxNorm_full_prescribe_10052026.zip"
    if [ ! -f "$ARCHIVE" ]; then
        curl -fL https://download.nlm.nih.gov/rxnorm/RxNorm_full_prescribe_10052026.zip -o "$ARCHIVE.part"
        mv "$ARCHIVE.part" "$ARCHIVE"
    fi
    # use the checksum tool that comes with the os
    if [ "$OS" = Darwin ]; then
        echo "8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977  $ARCHIVE" | shasum -a 256 -c -
    else
        echo "8ed351c29f3cb56bedeb8e2bcb8fa56931f8d7eb88e2280dc9772d7d3eb16977  $ARCHIVE" | sha256sum -c -
    fi
    unzip -o -j "$ARCHIVE" 'rrf/RXNCONSO.RRF' 'rrf/RXNREL.RRF' 'rrf/RXNSAT.RRF' -d "$DATA/rrf"
    cd "$SCALA"
    # use a fresh java process for each import
    java -Xmx2G -Dsbt.supershell=false -jar "$SBT" "run import-rxnorm \"$DATA/rrf\" 2026-10-05"
    java -Xmx2G -Dsbt.supershell=false -jar "$SBT" "run import-product-attributes \"$DATA/rrf\" 2026-10-05"
    docker exec "$CONTAINER" psql -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -c 'ANALYZE;'
else
    echo 'RxNorm is already imported.'
fi

# point the editor at the tools and database
NODE_HOME=$(dirname "$(dirname "$(node -p 'process.execPath')")")
node - "$RUNTIME" "$SCALA" "$JAVA_HOME" "$NODE_HOME" "$PORT" <<'JS'
const fs = require('fs');
const [runtime, scala, javaHome, nodeHome, port] = process.argv.slice(2);
fs.writeFileSync(runtime + '/tools/layout.json', JSON.stringify({javaHome, nodeHome, sbtHome: runtime + '/tools/sbt'}, null, 2));
const file = runtime + '/editor-profile/User/settings.json';
const settings = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file)) : {};
// autosave triggers the database check after edits
Object.assign(settings, {
    'clinicalDsl.rxnorm.scalaRoot': scala, 'clinicalDsl.rxnorm.toolsRoot': runtime + '/tools',
    'clinicalDsl.rxnorm.release': '2026-10-05', 'clinicalDsl.rxnorm.onSave': true,
    'files.autoSave': 'afterDelay', 'files.autoSaveDelay': 1000,
    'clinicalDsl.rxnorm.pgHost': '127.0.0.1', 'clinicalDsl.rxnorm.pgPort': Number(port),
    'clinicalDsl.rxnorm.pgDatabase': 'rxnorm_public', 'clinicalDsl.rxnorm.pgUser': 'rxnorm_lab',
    'clinicalDsl.rxnorm.timeoutSeconds': 300
});
fs.writeFileSync(file, JSON.stringify(settings, null, 2));
JS
# leave an existing demo alone
if [ ! -f "$RUNTIME/aspirin-demo.clinical" ]; then
    cat > "$RUNTIME/aspirin-demo.clinical" <<'DEMO'
Patient P9999: age 30, condition Fever
Medication aspirin: 100 mg, strength 325 mg, doseForm Oral Tablet, route PO, frequency PRN
Plan DemoPlan: for P9999, prescribe aspirin
show DemoPlan
DEMO
fi
echo "Ready: $RUNTIME/aspirin-demo.clinical"
# open the editor with the extension loaded
if [ "$OPEN_EDITOR" = 1 ]; then
    code --new-window --user-data-dir "$RUNTIME/editor-profile" \
        --extensionDevelopmentPath="$LANGIUM/packages/extension" "$LANGIUM" "$RUNTIME/aspirin-demo.clinical"
fi
