#!/usr/bin/env bash
# shellcheck disable=SC2034 # Variables below are inputs to the sourced production functions.
# Regression tests of the Linux discovery path; no Docker engine or package changes.
set -euo pipefail
script=$(cd "$(dirname "$0")/.." && pwd)/bootstrap-unix.sh
# shellcheck source=/dev/null
source <(sed -n '/^tool_fail()/,/^ensure_runtime_tools$/p' "$script" | sed '$d')
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
TOOLS="$tmp/lab tools"; STATE="$tmp/state"; mkdir -p "$TOOLS" "$STATE"
NON_INTERACTIVE=1
expect_code() {
    local expected=$1 actual=0; shift
    "$@" >/dev/null 2>&1 || actual=$?
    [ "$actual" = "$expected" ] || { echo "Expected $expected, got $actual: $*" >&2; exit 1; }
}
fake_node() {
    local dst=$1 version=$2 actual=${3:-$1}
    mkdir -p "$(dirname "$dst")"
    printf '#!/usr/bin/env bash\nprintf "%%s\\t%%s\\n" %q %q\n' "$version" "$actual" > "$dst"
    chmod +x "$dst"
}
fake_java() {
    local dst=$1 version=$2
    mkdir -p "$dst/bin"
    printf '#!/usr/bin/env bash\nprintf "    java.version = %%s\\n    java.home = %%s\\n" %q %q >&2\n' "$version" "$dst" > "$dst/bin/java"
    chmod +x "$dst/bin/java"  # Pure Scala project also works on a compatible JVM without javac.
}
fake_node "$tmp/node23/bin/node" 23.10.0
fake_node "$tmp/node22/bin/node" 22.12.0
fake_node "$tmp/shims/node" 22.12.0 "$tmp/node22/bin/node"
fake_java "$tmp/jdk11" 11.0.33
fake_java "$tmp/jdk25" 25.0.2
expect_code 1 probe_runtime_tool node "$tmp/node23/bin/node"
expect_code 0 probe_runtime_tool node "$tmp/node22/bin/node"
# Resolving an explicit executable must avoid scanning the filesystem or dpkg.
(
    build_tool_inventory() { exit 17; }; check_package_database() { exit 19; }
    discover_runtime_tool node "$tmp/shims/node" >/dev/null
    [ "$TOOL_REPORTED_HOME" = "$tmp/node22/bin/node" ]
    discover_runtime_tool java "$tmp/jdk11/bin/java" >/dev/null; select_java
    [ "$JAVA_HOME" = "$tmp/jdk11" ] && [ "$JAVA_VERSION" = 11.0.33 ]
)
# Recovery through a specified symlinked root searches the target without following cycles.
mkdir -p "$tmp/manual/installation/bin"
touch "$tmp/manual/installation/bin/pg_isready"
ln -s "$tmp/manual" "$tmp/manual/loop"
ln -s "$tmp/manual" "$tmp/legacy-root"
(
    AURORA_TOOL_SEARCH_PATH="$tmp/legacy-root"
    find() { [ "$2" != "$tmp/legacy-root" ] || command find "$@"; }
    build_tool_inventory
    printf '%s\n' "${TOOL_INVENTORY[@]}" | grep -Fx "$tmp/legacy-root/installation/bin/pg_isready" >/dev/null
    [ -z "$TOOL_DISCOVERY_ERRORS" ]
)
expect_code 1 confirm_tool_upgrade 'Replace incompatible Java'
ALLOW_TOOL_UPGRADE=1 expect_code 0 confirm_tool_upgrade 'Replace incompatible Java'
(
    discover_runtime_tool() { return 4; }
    install_missing_apt_package() { touch "$tmp/unexpected-install"; }
    ALLOW_TOOL_UPGRADE=1
    expect_code 4 ensure_apt_runtime_tool java openjdk-21-jdk-headless
    [ ! -e "$tmp/unexpected-install" ]
)
(
    discover_runtime_tool() { return 2; }
    install_missing_apt_package() { touch "$tmp/unexpected-install"; }
    expect_code 2 ensure_apt_runtime_tool java openjdk-21-jdk-headless
    [ ! -e "$tmp/unexpected-install" ]
)
# A different JDK or local sbt JAR is only accepted after a successful probe of
# this checkout. Network/build failures do not authorize downloading alternatives.
(
    SCALA="$tmp/project"; mkdir -p "$SCALA/project" "$SCALA/scripts"
    echo sbt.version=1.10.2 > "$SCALA/project/build.properties"
    echo 'ThisBuild / scalaVersion := "3.5.1"' > "$SCALA/build.sbt"
    # Compiler cache recovery has separate Node tests. Keep this shell fixture
    # runnable in the pristine Ubuntu seed before Node has been installed.
    node() { [ "$1" = "$SCALA/scripts/check-scala.cjs" ] && [ "$2" = "$SCALA" ]; }
    SBT="$tmp/runner.jar"; touch "$SBT"; SBT_NEEDS_PROBE=1; SBT_ALTERNATIVES=()
    JAVA_HOME="$tmp/jdk25"; JAVA_VERSION=25.0.2
    JAVA_ALTERNATE_HOMES=(); JAVA_ALTERNATE_VERSIONS=()
    run_sbt() { printf '[info] 1.10.2\n[info] 3.5.1\n'; }
    verify_project_runtime >/dev/null
    [ "$(readlink -f "$SBT_HOME/bin/sbt-launch.jar")" = "$SBT" ]
    run_sbt() { echo 'Temporary failure in name resolution' >&2; return 1; }
    confirm_tool_upgrade() { touch "$tmp/unexpected-consent"; return 0; }
    expect_code 1 verify_project_runtime
    [ ! -e "$tmp/unexpected-consent" ]
    fake_java "$tmp/jdk24" 24.0.2; mkdir -p "$TOOLS/selected-bin"
    JAVA_ALTERNATE_HOMES=("$tmp/jdk24"); JAVA_ALTERNATE_VERSIONS=(24.0.2)
    run_sbt() {
        if [ "$JAVA_HOME" = "$tmp/jdk25" ]; then echo 'Unsupported class file major version' >&2; return 1; fi
        printf '[info] 1.10.2\n[info] 3.5.1\n'
    }
    verify_project_runtime >/dev/null
    [ "$JAVA_HOME" = "$tmp/jdk24" ] && [ ! -e "$tmp/unexpected-consent" ]
)
printf 'PASS Linux tool recovery, engine ranges, consent, symlink root and project compatibility checks\n'
