#!/usr/bin/env bash
#
# Tests the command scripts offline. go and gofmt are real (Go must be on the
# PATH), and run against copies of tests/fixtures, which need no modules from
# the network: clean, which every check passes, and dirty, which every check
# finds something in. golangci-lint, gotestsum, gofumpt, benchstat and the
# CircleCI CLI are stand-ins that record how they were run and answer with
# the scenario each test picks; the gotestsum stand-in runs the real go test.
#
# What the real tools print is checked by test-deploy.yml, which runs every
# command with them.
#
# Run from a checkout:
#   bash tests/commands_test.sh

set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
STUBS="${WORK}/stubs"
CALLS="${WORK}/calls"
mkdir -p "${STUBS}" "${CALLS}"
export CALLS

if ! REAL_GO=$(command -v go); then
    echo "FAIL: these tests run the real go, and there is none on the PATH."
    exit 1
fi
REAL_GO_DIR=$(dirname "${REAL_GO}")
export REAL_GO
# The tests pick the Go settings; the job's must not change what go does.
unset GOFLAGS GOEXPERIMENT GOWORK GOTOOLCHAIN CGO_ENABLED GOOS GOARCH
export GOTOOLCHAIN=local GOPROXY=off GOSUMDB=off GOCACHE="${WORK}/gocache"

FAILURES=0
OUTPUT=""
RC=0

begin() {
    echo "--- $1"
}
check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok: ${name}"
    else
        echo "  FAIL: ${name}"
        tail -n 25 <<< "${OUTPUT}" | while IFS= read -r line; do printf '    | %s\n' "${line}"; done
        FAILURES=$((FAILURES + 1))
    fi
}
succeeded() { [[ "${RC}" -eq 0 ]]; }
failed() { [[ "${RC}" -ne 0 ]]; }
said() { grep -qF -- "$1" <<< "${OUTPUT}"; }
not_said() { ! said "$1"; }
# called_with TOOL WORD...: some call of TOOL had every WORD among its arguments.
called_with() {
    local tool=$1 file word ok
    shift
    for file in "${CALLS}/${tool}".*; do
        [[ -f "${file}" ]] || continue
        ok=true
        for word in "$@"; do
            grep -qxF -- "${word}" "${file}" || ok=false
        done
        if [[ "${ok}" == true ]]; then
            return 0
        fi
    done
    OUTPUT+=$'\n'"calls of ${tool}:"$'\n'"$(for f in "${CALLS}/${tool}".*; do [[ -f "${f}" ]] && tr '\n' ' ' < "${f}" && echo; done)"
    return 1
}
# not_called_with TOOL WORD...: no call of TOOL had every WORD.
not_called_with() {
    local saved=${OUTPUT}
    if called_with "$@"; then
        return 1
    fi
    OUTPUT=${saved}
}
call_count() { [[ "$(find "${CALLS}" -name "$1.*" | wc -l)" -eq "$2" ]]; }
file_has() { grep -qF -- "$2" "$1"; }
not_file_has() { ! grep -qF -- "$2" "$1" 2> /dev/null; }
json_is() { [[ "$(jq -r "$2" "$1" 2> /dev/null)" == "$3" ]] || { OUTPUT+=$'\n'"$1: $2 is $(jq -c "$2" "$1" 2>&1)"; return 1; }; }
exists() { [[ -e "$1" ]]; }
absent() { [[ ! -e "$1" ]]; }

# Stand-ins. Each records its arguments, one per line, to CALLS/<tool>.<n>.
record() {
    cat << 'EOF'
n=$(find "${CALLS}" -name "${0##*/}.*" | wc -l)
printf '%s\n' "$@" > "${CALLS}/${0##*/}.$((n + 1))"
EOF
}

# circleci: env subst expands $NAME and ${NAME} on stdin, as the real CLI
# does; tests split gives node CIRCLE_NODE_INDEX every CIRCLE_NODE_TOTAL-th
# line, and records its arguments. STUB_SPLIT=crash makes it fail.
{
    echo '#!/usr/bin/env bash'
    cat << 'EOF'
if [[ "$1 $2" == "tests split" ]]; then
EOF
    record
    cat << 'EOF'
    if [[ "${STUB_SPLIT:-}" == crash ]]; then echo "Error: could not read the timings" >&2; exit 1; fi
    awk -v n="${CIRCLE_NODE_TOTAL:-1}" -v i="${CIRCLE_NODE_INDEX:-0}" '(NR - 1) % n == i'
    exit 0
fi
input=$(cat)
output=""
re='^([^$]*)\$(\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))(.*)$'
while [[ "${input}" =~ ${re} ]]; do
    name=${BASH_REMATCH[3]:-${BASH_REMATCH[4]}}
    output+="${BASH_REMATCH[1]}${!name-}"
    input=${BASH_REMATCH[5]}
done
printf '%s\n' "${output}${input}"
EOF
} > "${STUBS}/circleci"

# golangci-lint: STUB_LINT is clean, issues, bymodule (issues in a directory
# named dirty, none elsewhere), typecheck, logged (an error it only logs,
# exiting 0), config (a version 1 configuration), goversion (built with an
# older Go than go.mod asks for), nojson (exits 0 writing no report),
# nofiles (no Go files, exit code 5) or nopathmode (a release without
# --path-mode). STUB_LINT_VERSION is the version it
# reports. Like golangci-lint 2, it writes paths relative to the directory
# of its config (--config, or the nearest .golangci.yml above), with
# --path-prefix before them, or absolute with --path-mode=abs. It exits
# with STUB_LINT_ISSUES_EXIT for issues, as a config's run.issues-exit-code
# makes golangci-lint do, unless --issues-exit-code is given.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == version ]]; then
    echo "golangci-lint has version ${STUB_LINT_VERSION:-2.15.0} built with go1.27.0 from 25c5369a on 2026-10-16T11:03:09Z"
    exit 0
fi
json="" sarif="" prefix="" abs=false base="" issues_exit=${STUB_LINT_ISSUES_EXIT:-1}
for arg in "$@"; do
    case "${arg}" in
        --issues-exit-code=*) issues_exit=${arg#*=} ;;
        --output.json.path=*) json=${arg#*=} ;;
        --output.sarif.path=*) sarif=${arg#*=} ;;
        --path-prefix=*) prefix="${arg#*=}/" ;;
        --path-mode=abs) abs=true ;;
        --config=*) base=$(dirname "${arg#*=}") ;;
    esac
done
dir=${PWD}
while [[ -z "${base}" && "${dir}" != / ]]; do
    [[ -f "${dir}/.golangci.yml" ]] && base=${dir}
    dir=$(dirname "${dir}")
done
base=${base:-${PWD}}
file=${PWD#"${base}"}
file="${prefix}${file#/}${file:+/}parse/parse.go"
if [[ "${abs}" == true ]]; then
    file="${PWD}/parse/parse.go"
fi
mode=${STUB_LINT:-clean}
if [[ "${mode}" == bymodule ]]; then
    mode=clean
    [[ "${PWD##*/}" == dirty ]] && mode=issues
fi
issue() {
    printf '{"FromLinter":"%s","Text":"%s","Severity":"","SourceLines":["\\tos.Remove(path)"],"Pos":{"Filename":"%s","Offset":1,"Line":%s,"Column":%s}}' "$@"
}
case "${mode}" in
    config) echo 'Error: can'"'"'t load config: unsupported version of the configuration: "" See https://golangci-lint.run/docs/product/migration-guide' >&2; exit 3 ;;
    goversion) echo "Error: can't load config: the Go language version (go1.25) used to build golangci-lint is lower than the targeted Go version (1.26.0)" >&2; exit 3 ;;
    nofiles) echo 'level=error msg="Running error: context loading failed: no go files to analyze"' >&2; exit 5 ;;
    nojson) exit 0 ;;
    nopathmode) echo 'Error: unknown flag: --path-mode' >&2; exit 3 ;;
esac
issues="" rc=0
case "${mode}" in
    issues) issues="$(issue errcheck 'Error return value of `os.Remove` is not checked' "${file}" 30 11),$(issue govet 'assign: self-assignment of s' "${file}" 24 2)"; rc=${issues_exit} ;;
    typecheck) issues="$(issue typecheck 'undefined: x' "${file}" 3 1)"; rc=${issues_exit} ;;
    logged) echo 'level=error msg="[linters_context] typechecking error: stat ./nope: directory not found"' >&2 ;;
esac
printf '{"Issues":[%s],"Report":{"Linters":[]}}\n' "${issues}" > "${json}"
if [[ -n "${sarif}" ]]; then
    results=""
    [[ -n "${issues}" ]] && results='{"ruleId":"errcheck","locations":[{"physicalLocation":{"artifactLocation":{"uri":"'"${file}"'","index":0},"region":{"startLine":30}}}]}'
    printf '{"version":"2.1.0","$schema":"https://example","runs":[{"tool":{"driver":{"name":"golangci-lint"}},"results":[%s]}]}\n' "${results}" > "${sarif}"
fi
[[ -n "${issues}" ]] && printf '%s:30:11: Error return value is not checked (errcheck)\n' "${file}"
exit "${rc}"
EOF
} > "${STUBS}/golangci-lint"

# gotestsum: runs the real go test -json with the go test arguments after
# --, writing --jsonfile and a JUnit file for --junitfile, and exits with go
# test's exit code. STUB_GOTESTSUM=crash exits 2 without running anything.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "${STUB_GOTESTSUM:-}" == crash ]]; then echo "gotestsum: something broke" >&2; exit 2; fi
json="" junit="" packages=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --jsonfile) json=$2; shift 2 ;;
        --junitfile) junit=$2; shift 2 ;;
        --packages) packages=$2; shift 2 ;;
        --format | --rerun-fails-report) shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
read -r -a list <<< "${packages}"
rc=0
"${REAL_GO}" test -json "$@" "${list[@]}" > "${json:-/dev/null}" || rc=$?
if [[ -n "${junit}" ]]; then
    printf '<testsuites tests="1"></testsuites>\n' > "${junit}"
fi
exit "${rc}"
EOF
} > "${STUBS}/gotestsum"

# gofumpt: the real gofmt, which takes the same -l and -d.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "$1" == --version ]]; then echo "v0.12.0 (go1.27.1)"; exit 0; fi
exec gofmt "$@"
EOF
} > "${STUBS}/gofumpt"

# benchstat: prints STUB_BENCHSTAT_CSV with -format csv, and a stand-in table
# otherwise. STUB_BENCHSTAT=crash fails.
{
    echo '#!/usr/bin/env bash'
    record
    cat << 'EOF'
if [[ "${STUB_BENCHSTAT:-}" == crash ]]; then echo "benchstat: parse error" >&2; exit 1; fi
if [[ "$1 $2" == "-format csv" ]]; then cat "${STUB_BENCHSTAT_CSV:-/dev/null}"; exit 0; fi
echo "stand-in benchstat table for: $*"
EOF
} > "${STUBS}/benchstat"
chmod +x "${STUBS}"/*

# A go that says it is Go 1.22, and one that writes go vet -json's report to
# stderr between "# package" lines, as releases before 1.26 do.
mkdir -p "${WORK}/go122" "${WORK}/go125"
cat > "${WORK}/go122/go" << 'EOF'
#!/usr/bin/env bash
if [[ "$1 $2" == "env GOVERSION" ]]; then echo go1.22.12; exit 0; fi
if [[ "$1 $2" == "mod tidy" ]]; then echo "flag provided but not defined: -diff" >&2; exit 2; fi
exec "${REAL_GO}" "$@"
EOF
cat > "${WORK}/go125/go" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == vet ]]; then
    rc=0
    out=$("${REAL_GO}" "$@") || rc=$?
    { echo "# example.com/dirty/parse"; echo "# [example.com/dirty/parse]"; printf '%s\n' "${out}"; } >&2
    exit "${rc}"
fi
exec "${REAL_GO}" "$@"
EOF
chmod +x "${WORK}/go122/go" "${WORK}/go125/go"

# The fixtures, in a git repository of their own, so generate_check and
# bench can compare with git.
REPO="${WORK}/repo"
mkdir -p "${REPO}"
cp -R "${ROOT}/tests/fixtures/." "${REPO}/"
git -C "${REPO}" init -q
git -C "${REPO}" add -A
git -C "${REPO}" -c user.name=test -c user.email=test@example.com commit -q -m fixtures
CLEAN="${REPO}/clean"
DIRTY="${REPO}/dirty"
OUT="${WORK}/out"

# reset_repo: puts the fixtures back as they were committed.
reset_repo() {
    git -C "${REPO}" checkout -q -- .
    git -C "${REPO}" clean -q -fdx
}

# run COMMAND [NAME=VALUE ...] [-- VAR=value ...]: runs a command's script
# through tests/run_command.sh, with its parameter defaults and output_dir
# set to OUT, overridden by NAME=VALUE, and the stand-ins first on the PATH
# with VAR=value set in the environment. Sets RC and OUTPUT.
run() {
    local command=$1 env=()
    shift
    local params=("output_dir=${OUT}")
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == -- ]]; then
            shift
            env=("$@")
            break
        fi
        params+=("$1")
        shift
    done
    rm -rf "${CALLS:?}"/* "${OUT}"
    RC=0
    OUTPUT=$(env "PATH=${STUBS}:${PATH}" ${env[@]+"${env[@]}"} bash "${ROOT}/tests/run_command.sh" "${command}" "${params[@]}" 2>&1) || RC=$?
    # Run as root, a tool that replaced /dev/null would break everything
    # after it.
    if [[ ! -c /dev/null ]]; then
        echo "FAIL: /dev/null is no longer a device after ${command} ${params[*]}"
        exit 1
    fi
}

# ------------------------------------------------------------------- fmt
begin "fmt: a formatted module passes"
run fmt "working_dir=${CLEAN}"
check "succeeds" succeeded
check "checks the files go ./... covers" said "Checking the formatting of 5 Go files with"
check "says they are formatted" said "Passed: 5 Go files are formatted with gofmt."
check "lists nothing" test ! -s "${OUT}/gofmt.txt"
check "writes JUnit with one passing case" file_has "${OUT}/junit/gofmt.xml" 'name="no findings"'

begin "fmt: an unformatted file is a finding"
run fmt "working_dir=${DIRTY}"
check "fails" failed
check "names the file" said "not formatted: parse/parse.go"
check "lists it" grep -qx parse/parse.go "${OUT}/gofmt.txt"
check "writes the change gofmt would make" file_has "${OUT}/gofmt.diff" "+	if len(s) >= 4"
check "writes a failing JUnit case for it" file_has "${OUT}/junit/gofmt.xml" 'name="parse/parse.go"><failure message="parse/parse.go is not formatted with gofmt"'
check "says how to fix it" said "ERROR: 1 Go file is not formatted with gofmt. Run gofmt -w on them."
run fmt "working_dir=${DIRTY}" report_only=true
check "report_only: passes" succeeded
check "report_only: still reports it" said "WARN: 1 Go file is not formatted with gofmt."
run fmt "working_dir=${DIRTY}" junit=false
check "junit false: writes no JUnit" absent "${OUT}/junit/gofmt.xml"

begin "fmt: what go ./... skips is skipped, and exclude skips more"
mkdir -p "${CLEAN}/vendor/v" "${CLEAN}/testdata" "${CLEAN}/.hidden" "${CLEAN}/_skip" "${CLEAN}/third_party/x"
for dir in vendor/v testdata .hidden _skip third_party/x; do
    printf 'package x\nfunc  F() {}\n' > "${CLEAN}/${dir}/x.go"
done
run fmt "working_dir=${CLEAN}" exclude=./third_party/
check "fails only for the directory not excluded" succeeded
check "checks 5 files" said "Checking the formatting of 5 Go files"
run fmt "working_dir=${CLEAN}"
check "without exclude, finds third_party" said "not formatted: third_party/x/x.go"
check "and nothing go ./... skips" not_said "vendor/v/x.go"
printf 'package x\nfunc  F() {}\n' > "${CLEAN}/greet/_ignored.go"
cp "${CLEAN}/greet/_ignored.go" "${CLEAN}/greet/.hidden.go"
run fmt "working_dir=${CLEAN}" exclude=third_party
check "files the go command ignores (_x.go, .x.go) are skipped" succeeded
mkdir -p "${WORK}/nogo"
run fmt "working_dir=${WORK}/nogo"
check "a directory without Go files passes" succeeded
check "saying it checked none" said "Checking the formatting of 0 Go files"
run fmt "working_dir=${CLEAN}" "exclude=../elsewhere"
check "refuses an exclude outside working_dir" failed
check "saying so" said "exclude must name directories inside the working directory"
reset_repo

begin "fmt: simplify, and gofumpt"
printf 'package greet\n\nvar pairs = [][]int{[]int{1, 2}}\n' > "${CLEAN}/greet/pairs.go"
run fmt "working_dir=${CLEAN}"
check "a simplifiable literal passes without simplify" succeeded
run fmt "working_dir=${CLEAN}" simplify=true
check "and is a finding with it" said "not formatted: greet/pairs.go"
check "saying to run gofmt -s" said "Run gofmt -w -s on them."
run fmt "working_dir=${CLEAN}" formatter=gofumpt
check "gofumpt runs instead of gofmt" called_with gofumpt -l ./greet/pairs.go
check "naming its version" said "v0.12.0 (go1.27.1)"
run fmt "working_dir=${CLEAN}" formatter=gofumpt simplify=true
check "simplify passes nothing to gofumpt, which always simplifies" not_called_with gofumpt -s
check "saying so" said "gofumpt always simplifies"
reset_repo
run fmt "working_dir=${CLEAN}" formatter=gofumpt -- "PATH=${WORK}/nopath"
OUTPUT=$(PATH="${REAL_GO_DIR}:/usr/bin:/bin" PARAM_FORMATTER=gofumpt PARAM_SIMPLIFY=false PARAM_EXCLUDE="" PARAM_JUNIT=false \
    PARAM_REPORT_ONLY=false PARAM_OUTPUT_DIR="${OUT}" PARAM_REPORT_NAME=gofmt SCRIPT_GO_QUALITY_LIB="$(cat "${ROOT}/src/scripts/lib/go_quality.sh")" \
    bash -c "cd '${CLEAN}' && bash '${ROOT}/src/scripts/fmt.sh'" 2>&1) && RC=0 || RC=$?
check "without gofumpt, fails" failed
check "saying how to install it" said "install_gofumpt"

begin "fmt: a file that doesn't parse fails the step, even with report_only"
printf 'package greet\nfunc (\n' > "${CLEAN}/greet/broken.go"
printf 'package greet\n' > "${CLEAN}/greet/-dash.go"
run fmt "working_dir=${CLEAN}" report_only=true
check "fails" failed
check "shows gofmt's error" said "greet/broken.go:"
check "saying the syntax must be fixed first" said "fix the syntax error first"
rm -f "${CLEAN}/greet/broken.go"
run fmt "working_dir=${CLEAN}"
check "a file whose name starts with - is checked as a file, not a flag" succeeded
reset_repo

# -------------------------------------------------------------- mod_tidy
begin "mod_tidy: a tidy module passes, an untidy one is a finding"
run mod_tidy "working_dir=${CLEAN}"
check "the tidy module passes" succeeded
check "says it is tidy" said "Passed: go.mod and go.sum are tidy in example.com/clean."
run mod_tidy "working_dir=${DIRTY}"
check "the untidy one fails" failed
check "shows the diff" said "-golang.org/x/sync v0.10.0 h1:"
check "writes it" file_has "${OUT}/go-mod-tidy.diff" "diff current/go.sum tidy/go.sum"
check "names the module" said "ERROR: go.mod or go.sum is not tidy in example.com/dirty."
check "writes a failing JUnit case" file_has "${OUT}/junit/go-mod-tidy.xml" 'message="./go.mod or go.sum is not tidy"'
check "changes nothing" test -z "$(git -C "${REPO}" status --porcelain)"
run mod_tidy "working_dir=${DIRTY}" report_only=true
check "report_only passes" succeeded

begin "mod_tidy: several modules, or all of them"
run mod_tidy "working_dir=${REPO}" "modules=clean,dirty"
check "fails for the untidy one" failed
check "names only it" said "not tidy in example.com/dirty (dirty)."
check "checks both" file_has "${OUT}/junit/go-mod-tidy.xml" 'name="clean"'
mkdir -p "${REPO}/dirty/testdata/m" "${REPO}/vendor/m"
printf 'module example.com/skipped\n' | tee "${REPO}/dirty/testdata/m/go.mod" > "${REPO}/vendor/m/go.mod"
run mod_tidy "working_dir=${REPO}" modules=all
check "all finds both modules" file_has "${OUT}/junit/go-mod-tidy.xml" 'name="dirty"'
check "and skips testdata and vendor" not_file_has "${OUT}/junit/go-mod-tidy.xml" '/m"'
reset_repo
run mod_tidy "working_dir=${REPO}" "modules=clean nothere"
check "a directory without go.mod fails" failed
check "naming it" said "modules names nothere, which has no go.mod"
check "with no hint about the top of the repository" not_said "set modules to all"
run mod_tidy "working_dir=${REPO}"
check "the default, ., without a go.mod fails" said "modules names ., which has no go.mod"
check "saying to set modules to all or list the modules" said "set modules to all, or list the module directories"
run mod_tidy "working_dir=${REPO}" "modules=../repo/clean"
check "a module outside working_dir fails" said "without '..'"
run mod_tidy "working_dir=${WORK}/calls" modules=all
check "all with no module below fails" said "there is no go.mod"

begin "mod_tidy: Go before 1.23 has no go mod tidy -diff"
run mod_tidy "working_dir=${CLEAN}" -- "PATH=${WORK}/go122:${STUBS}:${PATH}"
check "fails" failed
check "saying it needs Go 1.23" said "mod_tidy needs Go 1.23 or newer, for go mod tidy -diff, and example.com/clean runs go1.22.12."
check "before running go mod tidy" not_said "flag provided but not defined"

begin "mod_tidy: a go mod tidy that can't complete fails, even with report_only"
mkdir -p "${CLEAN}/needs"
printf 'package needs\n\nimport _ "example.com/not/available"\n' > "${CLEAN}/needs/needs.go"
run mod_tidy "working_dir=${CLEAN}" report_only=true
check "fails" failed
check "saying it could not complete" said "go mod tidy -diff could not complete in example.com/clean"
check "with go's error" said "example.com/not/available"
check "and no workspace hint outside a workspace" not_said "ignores the workspace"
reset_repo

begin "mod_tidy: go mod tidy ignores go.work"
# a finds b only through the workspace, with no replace directive.
mkdir -p "${WORK}/workspace/a" "${WORK}/workspace/b"
printf 'go 1.24\n\nuse (\n\t./a\n\t./b\n)\n' > "${WORK}/workspace/go.work"
printf 'module example.com/a\n\ngo 1.24\n\nrequire example.com/b v0.0.0\n' > "${WORK}/workspace/a/go.mod"
printf 'package a\n\nimport "example.com/b"\n\nvar V = b.V\n' > "${WORK}/workspace/a/a.go"
printf 'module example.com/b\n\ngo 1.24\n' > "${WORK}/workspace/b/go.mod"
printf 'package b\n\nvar V = 1\n' > "${WORK}/workspace/b/b.go"
run vet "working_dir=${WORK}/workspace" modules=all
check "vet sees the workspace's other modules" succeeded
run mod_tidy "working_dir=${WORK}/workspace" modules=all
check "but a module that needs the workspace can't be tidied" said "go mod tidy -diff could not complete in example.com/a (a)"
check "and the step says why" said "go mod tidy ignores the workspace in ${WORK}/workspace/go.work"
check "and what to do" said "needs a replace directive in its go.mod"
run mod_tidy "working_dir=${CLEAN}" "extra_args=-compat=1.24 -diff"
check "extra_args can't hold -diff" said "extra_args can't hold -diff"

# ------------------------------------------------------------------- vet
begin "vet: findings, from stdout (Go 1.26 and later) or stderr"
run vet "working_dir=${CLEAN}"
check "a clean module passes" succeeded
run vet "working_dir=${DIRTY}"
check "a problem fails the step" failed
check "names it, with a path relative to working_dir" said "parse/parse.go:24:2: self-assignment of s (assign)"
check "writes it as JSON" json_is "${OUT}/go-vet.json" '.[0] | "\(.position) \(.analyzer) \(.package)"' "parse/parse.go:24:2 assign example.com/dirty/parse"
check "writes a failing JUnit case" file_has "${OUT}/junit/go-vet.xml" 'classname="assign" name="parse/parse.go:24:2"'
run vet "working_dir=${DIRTY}" -- "PATH=${WORK}/go125:${STUBS}:${PATH}"
check "reads the report from stderr too" json_is "${OUT}/go-vet.json" '.[0].message' "self-assignment of s"
run vet "working_dir=${REPO}" modules=all report_only=true
check "report_only passes" succeeded
check "positions are relative to working_dir in every module" json_is "${OUT}/go-vet.json" '.[0].position' "dirty/parse/parse.go:24:2"
run vet "working_dir=${DIRTY}" "extra_args=-assign=false"
check "extra_args reach go vet" succeeded

begin "vet: code that doesn't compile fails the step, even with report_only"
printf 'package greet\n\nfunc broken() int { return "x" }\n' > "${CLEAN}/greet/broken.go"
run vet "working_dir=${CLEAN}" report_only=true
check "fails" failed
check "says go vet could not complete" said "go vet could not complete in example.com/clean"
reset_repo
run vet "working_dir=${CLEAN}" "packages=-race"
check "a package pattern that is a flag is refused" said "which the go command would read as a flag"

# ------------------------------------------------------------------ lint
begin "lint: issues, and their reports"
run lint "working_dir=${CLEAN}" -- STUB_LINT=clean
check "no issues passes" succeeded
check "runs golangci-lint run with its outputs" called_with golangci-lint run --output.text.path=stdout --output.text.colors=false ./...
check "asks for absolute paths" called_with golangci-lint --path-mode=abs
run lint "working_dir=${DIRTY}" -- STUB_LINT=issues
check "issues fail the step" failed
check "count them" said "ERROR: golangci-lint found 2 issues in example.com/dirty."
check "write them as JSON, with the module" json_is "${OUT}/golangci-lint.json" '[.[] | .FromLinter + ":" + .module] | join(" ")' "errcheck:. govet:."
check "with paths relative to working_dir" json_is "${OUT}/golangci-lint.json" '[.[].Pos.Filename] | unique | join(" ")' "parse/parse.go"
check "write SARIF" json_is "${OUT}/golangci-lint.sarif" '.version + " " + (.runs | length | tostring)' "2.1.0 1"
check "with the same paths" json_is "${OUT}/golangci-lint.sarif" '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "parse/parse.go"
check "write a JUnit case per issue" file_has "${OUT}/junit/golangci-lint.xml" 'classname="errcheck" name="parse/parse.go:30:11"'
run lint "working_dir=${DIRTY}" report_only=true sarif=false -- STUB_LINT=issues
check "report_only passes" succeeded
check "sarif false writes no SARIF" absent "${OUT}/golangci-lint.sarif"
run lint "working_dir=${DIRTY}" report_only=true -- STUB_LINT=issues STUB_LINT_ISSUES_EXIT=2
check "a config's issues-exit-code doesn't make issues an error" succeeded
check "since the exit code for issues is set" called_with golangci-lint --issues-exit-code=1
check "and the issues are still reported" json_is "${OUT}/golangci-lint.json" 'length' "2"

begin "lint: several modules"
run lint "working_dir=${REPO}" modules=all -- STUB_LINT=bymodule
check "fails for the module with issues" failed
check "with paths relative to working_dir" json_is "${OUT}/golangci-lint.json" '.[0].Pos.Filename' "dirty/parse/parse.go"
check "and merges the SARIF runs" json_is "${OUT}/golangci-lint.sarif" '.runs | length' "2"
check "with the same paths" json_is "${OUT}/golangci-lint.sarif" '[.runs[].results[].locations[].physicalLocation.artifactLocation.uri] | join(" ")' "dirty/parse/parse.go"

begin "lint: a module whose config is above it"
# golangci-lint 2 writes paths relative to its config's directory.
rm "${DIRTY}/.golangci.yml"
printf 'version: "2"\n' > "${REPO}/.golangci.yml"
run lint "working_dir=${REPO}" modules=dirty -- STUB_LINT=issues
check "paths are still relative to working_dir" json_is "${OUT}/golangci-lint.json" '[.[].Pos.Filename] | unique | join(" ")' "dirty/parse/parse.go"
check "in SARIF too" json_is "${OUT}/golangci-lint.sarif" '.runs[0].results[0].locations[0].physicalLocation.artifactLocation.uri' "dirty/parse/parse.go"
check "and in JUnit" file_has "${OUT}/junit/golangci-lint.xml" 'name="dirty/parse/parse.go:30:11"'
reset_repo

begin "lint: a golangci-lint that can't complete fails, even with report_only"
for mode in typecheck logged config goversion nojson nofiles nopathmode; do
    run lint "working_dir=${CLEAN}" report_only=true -- "STUB_LINT=${mode}"
    check "${mode}: fails" failed
done
run lint "working_dir=${CLEAN}" -- STUB_LINT=typecheck
check "typecheck: says the code doesn't compile" said "doesn't compile (golangci-lint's typecheck issues above)"
run lint "working_dir=${CLEAN}" -- STUB_LINT=logged
check "an error it only logs: says so" said "logged an error in example.com/clean (level=error above)"
run lint "working_dir=${CLEAN}" -- STUB_LINT=config
check "a version 1 config: says how to migrate it" said "golangci-lint migrate converts a version 1 one"
run lint "working_dir=${CLEAN}" -- STUB_LINT=goversion
check "built with an older Go: says to install a newer golangci-lint" said "This golangci-lint was built with an older Go"
run lint "working_dir=${CLEAN}" -- STUB_LINT=nopathmode
check "a release without --path-mode: says to install a newer one" said "This golangci-lint has no --path-mode option"
run lint "working_dir=${CLEAN}" -- STUB_LINT_VERSION=1.64.8
check "golangci-lint 1 is refused" said "lint needs golangci-lint 2 or newer"
check "before it runs" not_called_with golangci-lint run
run lint "working_dir=${CLEAN}" -- "STUB_LINT_VERSION=(devel)"
check "a build that doesn't say its version is taken to be 2" succeeded

begin "lint: parameters"
mkdir -p "${REPO}/config"
printf 'version: "2"\n' > "${REPO}/config/lint.yml"
run lint "working_dir=${REPO}" modules=clean config=config/lint.yml new_from_rev=origin/main timeout=5m "extra_args=--max-issues-per-linter=0 --fix" -- STUB_LINT=clean
check "succeeds" succeeded
check "passes config as an absolute path" called_with golangci-lint "--config=${REPO}/config/lint.yml"
check "passes new_from_rev, timeout and extra_args" called_with golangci-lint --new-from-rev=origin/main --timeout=5m --max-issues-per-linter=0 --fix
run lint "working_dir=${REPO}" modules=clean config=config/missing.yml
check "a missing config fails" said "config config/missing.yml does not exist"
run lint "working_dir=${REPO}" modules=clean timeout=soon
check "a timeout that isn't a duration fails" said "timeout must be a Go duration"
run lint "working_dir=${REPO}" modules=clean "extra_args=--output.json.path=/tmp/x"
check "extra_args can't set the outputs" said "extra_args can't hold --output.json.path=/tmp/x"
run lint "working_dir=${REPO}" modules=clean "extra_args=--path-prefix=x"
check "or the path prefix" said "extra_args can't hold --path-prefix=x"
# shellcheck disable=SC2016 # the command substitution is for the script to refuse
run lint "working_dir=${REPO}" modules=clean 'extra_args=$(touch pwned)'
check "extra_args runs nothing" said "has a \$(...) or backtick outside quotes"
reset_repo

# -------------------------------------------------------- generate_check
begin "generate_check: up-to-date generated code passes"
run generate_check "working_dir=${CLEAN}"
check "succeeds" succeeded
check "even though go generate rewrote the file" said "go generate changed nothing in example.com/clean."
check "lists nothing" test ! -s "${OUT}/go-generate.txt"

begin "generate_check: out-of-date generated code is a finding"
run generate_check "working_dir=${DIRTY}"
check "fails" failed
check "names the file, relative to the checkout" said "changed: dirty/parse/version_gen.go"
check "writes the change" file_has "${OUT}/go-generate.diff" '+const Version = "2.0.0"'
check "writes a failing JUnit case" file_has "${OUT}/junit/go-generate.xml" 'name="dirty/parse/version_gen.go"'
check "says how to fix it" said "Run go generate and commit the result."
reset_repo
run generate_check "working_dir=${DIRTY}" report_only=true
check "report_only passes" succeeded
reset_repo
run generate_check "working_dir=${DIRTY}" run=nothing-matches
check "run limits the directives" succeeded

begin "generate_check: what was already changed doesn't count"
printf '\n// edited before the step\n' >> "${CLEAN}/greet/greet.go"
printf 'notes\n' > "${CLEAN}/notes.txt"
run generate_check "working_dir=${CLEAN}"
check "passes" succeeded
check "saying files already differed" said "2 files already differ from git's index"
reset_repo
printf 'package greet\n\n//go:generate sh -c "echo package greet > extra_gen.go"\n' > "${CLEAN}/greet/extra.go"
git -C "${REPO}" add -A && git -C "${REPO}" -c user.name=test -c user.email=test@example.com commit -q -m extra
run generate_check "working_dir=${CLEAN}"
check "a new file go generate adds is a finding" said "added: clean/greet/extra_gen.go"
git -C "${REPO}" reset -q --hard HEAD~1
reset_repo

begin "generate_check: an output_dir in the checkout"
run generate_check "working_dir=${CLEAN}" "output_dir=${CLEAN}/reports"
check "the reports aren't counted as changes" succeeded
check "and are written" exists "${CLEAN}/reports/go-generate.log"
reset_repo
run generate_check "working_dir=${DIRTY}" "output_dir=${DIRTY}/reports" report_only=true
check "only what go generate changed is listed" test "$(cat "${DIRTY}/reports/go-generate.txt")" == dirty/parse/version_gen.go
reset_repo

begin "generate_check: a module in a git submodule"
cp -R "${ROOT}/tests/fixtures/dirty" "${WORK}/submodule"
git -C "${WORK}/submodule" init -q
git -C "${WORK}/submodule" add -A
git -C "${WORK}/submodule" -c user.name=test -c user.email=test@example.com commit -q -m dirty
git -C "${REPO}" -c protocol.file.allow=always submodule --quiet add "${WORK}/submodule" vendored
git -C "${REPO}" -c user.name=test -c user.email=test@example.com commit -q -m submodule
run generate_check "working_dir=${REPO}" modules=vendored
check "is compared with its own repository" failed
check "naming the file relative to the checkout" said "changed: vendored/parse/version_gen.go"
check "with a diff that applies at the checkout's top" file_has "${OUT}/go-generate.diff" "+++ b/vendored/parse/version_gen.go"
git -C "${REPO}/vendored" checkout -q -- .
run generate_check "working_dir=${REPO}" modules=clean
check "while other modules are still compared with the checkout" succeeded
git -C "${REPO}" reset -q --hard HEAD~1
rm -rf "${REPO:?}/vendored" "${REPO:?}/.git/modules"
reset_repo

begin "generate_check: failures"
printf 'package greet\n\n//go:generate false\n' > "${CLEAN}/greet/fails.go"
run generate_check "working_dir=${CLEAN}" report_only=true
check "a failing generator fails the step, even with report_only" failed
check "saying so" said "go generate failed in example.com/clean"
check "and writing its output" file_has "${OUT}/go-generate.log" "exit status 1"
reset_repo
mkdir -p "${WORK}/nogit"
cp -R "${ROOT}/tests/fixtures/clean" "${WORK}/nogit/"
run generate_check "working_dir=${WORK}/nogit/clean" -- GIT_CEILING_DIRECTORIES="${WORK}"
check "a directory outside a git checkout fails" said "is not in a git checkout"

# ------------------------------------------------------------------ test
begin "test: passing tests, and the arguments gotestsum gets"
run test "working_dir=${CLEAN}"
check "succeeds" succeeded
check "runs gotestsum with its outputs" called_with gotestsum --format pkgname-and-test-fails --jsonfile "${OUT}/go-test/events.json" \
    --junitfile "${OUT}/junit/go-test/junit.xml" --packages ./... -- -count=1 "-coverprofile=${OUT}/go-test/coverage.out"
check "writes go test's events" file_has "${OUT}/go-test/events.json" '"Action":"pass"'
check "writes coverage" file_has "${OUT}/go-test/coverage.txt" "total:"
check "writes the HTML view" exists "${OUT}/go-test/coverage.html"
check "prints the total" said "Total coverage: 36.4% of statements (4 of 11)."
run test "working_dir=${CLEAN}" race=true shuffle=on count=2 timeout=5m tags=extra run=TestHello skip=Empty short=true \
    covermode=atomic coverpkg=./... rerun_fails=2 format=testname "extra_args=-v -parallel=2" junit=false
check "with every option, succeeds" succeeded
check "passes them" called_with gotestsum --format testname --rerun-fails=2 -- -count=2 -race -shuffle=on -timeout=5m -tags=extra \
    -run=TestHello -skip=Empty -short -covermode=atomic -coverpkg=./... -v -parallel=2
check "junit false: no --junitfile" not_called_with gotestsum --junitfile "${OUT}/junit/go-test/junit.xml"
check "rerun_fails: notes the coverage profile is replaced" said "a rerun's coverage profile replaces the first run's"
run test "working_dir=${CLEAN}" coverage=false
check "coverage false: no profile" not_said "Total coverage"

begin "test: failures"
run test "working_dir=${DIRTY}" tags=failing
check "a failing test fails the step" failed
check "naming the module" said "Tests failed, or packages didn't build, in example.com/dirty."
printf 'package greet\n\nfunc broken() int { return "x" }\n' > "${CLEAN}/greet/broken.go"
run test "working_dir=${CLEAN}"
check "a package that doesn't build fails it" failed
reset_repo
run test "working_dir=${CLEAN}" -- STUB_GOTESTSUM=crash
check "a gotestsum that fails fails it" failed

begin "test: coverage_min"
run test "working_dir=${CLEAN}" coverage_min=30
check "coverage above it passes" succeeded
check "saying so" said "Passed: coverage is at least 30%."
run test "working_dir=${CLEAN}" coverage_min=50
check "coverage below it fails" failed
check "saying by how much" said "Total coverage is 36.4% (4 of 11 statements), below coverage_min (50%)."
run test "working_dir=${CLEAN}" coverage_min=36.4
check "the exact share counts, not the rounded one (4 of 11 is 36.36%)" failed
run test "working_dir=${CLEAN}" coverage_min=36.36
check "so a coverage_min it meets passes" succeeded
run test "working_dir=${REPO}" modules=all coverage_min=1
check "the total covers every module" said "Total coverage: "
check "and each module has its own reports" exists "${OUT}/go-test/dirty/coverage.out"
run test "working_dir=${CLEAN}" coverage_min=101
check "a coverage_min over 100 fails" said "coverage_min must be a percentage from 0 to 100"
run test "working_dir=${CLEAN}" coverage=false coverage_min=50
check "coverage_min needs coverage" said "coverage_min needs coverage to be true"

begin "test: split_tests"
run test "working_dir=${CLEAN}" split_tests=true -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=1
check "succeeds" succeeded
check "splits the packages by timing" called_with circleci tests split --split-by=timings --timings-type=classname
check "runs only this node's share" said "Node 2 of 2 runs 1 of the 3 packages in example.com/clean."
check "and passes them to gotestsum" called_with gotestsum --packages example.com/clean/greet
run test "working_dir=${CLEAN}" split_tests=true -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=0
check "the other node runs the rest" called_with gotestsum --packages "example.com/clean/cmd/hello example.com/clean/internal/gen"
run test "working_dir=${CLEAN}" split_tests=true coverage_min=10 -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=0
check "coverage_min can't be checked across nodes" said "coverage_min can't be checked when split_tests splits the tests"
run test "working_dir=${CLEAN}" split_tests=true -- CIRCLE_NODE_TOTAL=1
check "a parallelism of 1 doesn't split" not_called_with circleci tests split
run test "working_dir=${CLEAN}" split_tests=true -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=0 STUB_SPLIT=crash
check "a splitter that fails fails the step" failed
check "saying so" said "circleci tests split could not split the packages of example.com/clean"
check "rather than run nothing" not_called_with gotestsum --format
mkdir -p "${CLEAN}/raceonly"
printf '//go:build race || splitonly\n\npackage raceonly\n' > "${CLEAN}/raceonly/raceonly.go"
run test "working_dir=${CLEAN}" split_tests=true race=true -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=1
check "with race, splits the packages that build with -race" said "Node 2 of 2 runs 2 of the 4 packages in example.com/clean."
# go list refuses go test's own flags, such as -failfast.
run test "working_dir=${CLEAN}" split_tests=true "extra_args=-race -failfast" -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=1
check "and with -race in extra_args, which go list gets alone" said "Node 2 of 2 runs 2 of the 4 packages in example.com/clean."
check "while the tests get all of extra_args" called_with gotestsum -race -failfast
run test "working_dir=${CLEAN}" split_tests=true "extra_args=-tags splitonly -count=1" -- CIRCLE_NODE_TOTAL=2 CIRCLE_NODE_INDEX=1
check "and with tags in extra_args, as two words" said "Node 2 of 2 runs 2 of the 4 packages in example.com/clean."
reset_repo

begin "test: parameters"
run test "working_dir=${CLEAN}" race=true -- CGO_ENABLED=0
check "race without cgo fails" said "race needs cgo, and CGO_ENABLED is 0"
run test "working_dir=${CLEAN}" race=true -- CC=no-such-compiler
check "race without a C compiler fails" said "race needs a C compiler, and no-such-compiler"
for setting in shuffle=sometimes count=0 rerun_fails=-1 covermode=sometimes "format=Not A Format" timeout=forever; do
    run test "working_dir=${CLEAN}" "${setting}"
    check "${setting} is refused" failed
    check "before gotestsum runs" not_called_with gotestsum --format
done
run test "working_dir=${CLEAN}" "extra_args=-coverprofile=x.out"
check "extra_args can't set the coverage profile" said "extra_args can't hold -coverprofile=x.out"

# ------------------------------------------------------------------ fuzz
begin "fuzz: fuzz tests that pass"
run fuzz "working_dir=${CLEAN}" fuzz_time=200x
check "succeeds" succeeded
check "fuzzes each fuzz test on its own" said "Fuzzing example.com/clean/greet FuzzParse for 200x..."
check "and says how many" said "Passed: 1 fuzz test ran for 200x each without failing."
check "writes its log" exists "${OUT}/go-fuzz/greet/FuzzParse.log"
check "writes a JUnit case" file_has "${OUT}/junit/go-fuzz.xml" 'classname="example.com/clean/greet" name="FuzzParse"'
run fuzz "working_dir=${CLEAN}" targets=Nothing
check "targets that match nothing pass" succeeded
check "saying there is nothing to fuzz" said "There are no fuzz tests matching Nothing"
printf '//go:build race\n\npackage greet\n\nimport "testing"\n\nfunc FuzzRace(f *testing.F) {\n\tf.Fuzz(func(t *testing.T, s string) {})\n}\n' \
    > "${CLEAN}/greet/race_fuzz_test.go"
run fuzz "working_dir=${CLEAN}" targets=FuzzRace fuzz_time=20x "extra_args=-race"
check "build flags in extra_args also pick the fuzz tests" said "Fuzzing example.com/clean/greet FuzzRace for 20x..."
check "and they pass" said "Passed: 1 fuzz test ran for 20x each without failing."
reset_repo
printf 'package greet\n\nimport "testing"\n\nfunc Fuzz\303\211(f *testing.F) {\n\tf.Fuzz(func(t *testing.T, s string) {})\n}\n' \
    > "${CLEAN}/greet/unicode_fuzz_test.go"
run fuzz "working_dir=${CLEAN}" "targets=^Fuzz[^P]" fuzz_time=20x
check "a fuzz test whose name isn't ASCII is fuzzed too" said "Fuzzing example.com/clean/greet Fuzz$(printf '\303\211') for 20x..."
reset_repo

begin "fuzz: a failing input is a finding"
mkdir -p "${DIRTY}/parse/testdata/fuzz/FuzzParse"
printf 'go test fuzz v1\nstring("FUZZING")\n' > "${DIRTY}/parse/testdata/fuzz/FuzzParse/seed"
run fuzz "working_dir=${DIRTY}" fuzz_time=200x
check "fails" failed
check "names the fuzz test" said "Fuzzing found failing inputs for example.com/dirty/parse.FuzzParse."
check "writes a failing JUnit case" file_has "${OUT}/junit/go-fuzz.xml" 'message="FuzzParse failed"'
run fuzz "working_dir=${DIRTY}" fuzz_time=200x report_only=true
check "report_only passes" succeeded
reset_repo
# A stand-in go test that writes a new failing input, as fuzzing does.
mkdir -p "${WORK}/gofuzz"
cat > "${WORK}/gofuzz/go" << 'EOF'
#!/usr/bin/env bash
if [[ "$1" == test && " $* " == *" -fuzz "* ]]; then
    dir=$("${REAL_GO}" list -f '{{.Dir}}' "${@: -1}")
    mkdir -p "${dir}/testdata/fuzz/FuzzParse"
    printf 'go test fuzz v1\nstring("FUZZ")\n' > "${dir}/testdata/fuzz/FuzzParse/0123456789abcdef"
    echo "--- FAIL: FuzzParse (0.01s)"
    echo "    Failing input written to testdata/fuzz/FuzzParse/0123456789abcdef"
    exit 1
fi
exec "${REAL_GO}" "$@"
EOF
chmod +x "${WORK}/gofuzz/go"
run fuzz "working_dir=${DIRTY}" -- "PATH=${WORK}/gofuzz:${STUBS}:${PATH}"
check "a new failing input is copied to the reports" exists "${OUT}/go-fuzz/parse/testdata/fuzz/FuzzParse/0123456789abcdef"
check "saying where to add it" said "Add it to parse/testdata/fuzz/FuzzParse/ in the repository"
reset_repo

begin "fuzz: failures"
printf 'package greet\n\nfunc broken() int { return "x" }\n' > "${CLEAN}/greet/broken.go"
run fuzz "working_dir=${CLEAN}" report_only=true
check "a package that doesn't build fails the step, even with report_only" failed
check "saying the fuzz tests could not be listed" said "could not list the fuzz tests of example.com/clean"
reset_repo
run fuzz "working_dir=${CLEAN}" fuzz_time=soon
check "a fuzz_time that isn't a duration fails" said "fuzz_time must be a Go duration"
run fuzz "working_dir=${CLEAN}" "targets=(unclosed"
check "targets that don't compile fail" said "targets is not a valid regular expression"
run fuzz "working_dir=${CLEAN}" "extra_args=-fuzztime=1h"
check "extra_args can't set -fuzztime" said "extra_args can't hold -fuzztime=1h"
run fuzz "working_dir=${CLEAN}" "extra_args=-list=."
check "or -list" said "extra_args can't hold -list=."

# ----------------------------------------------------------------- bench
begin "bench: this commit only"
run bench "working_dir=${CLEAN}" count=2 benchtime=100x -- "PATH=${STUBS}:${PATH}"
check "succeeds" succeeded
check "writes the results" file_has "${OUT}/go-bench.txt" "BenchmarkHello"
check "runs each benchmark count times" test "$(grep -c '^BenchmarkHello' "${OUT}/go-bench.txt")" -eq 2
check "summarizes them with benchstat" called_with benchstat "results=${OUT}/go-bench.txt"
rm -f "${STUBS}/benchstat.off"
mv "${STUBS}/benchstat" "${STUBS}/benchstat.off"
run bench "working_dir=${CLEAN}" count=1 benchtime=10x -- "PATH=${STUBS}:${REAL_GO_DIR}:/usr/bin:/bin"
check "without benchstat, still succeeds" succeeded
check "saying the results aren't summarized" said "benchstat is not on the PATH, so the results are not summarized"
mv "${STUBS}/benchstat.off" "${STUBS}/benchstat"
run bench "working_dir=${CLEAN}" bench=NoSuchBenchmark count=1
check "no matching benchmark passes" succeeded
check "saying so" said "No benchmarks matched NoSuchBenchmark"

begin "bench: compared with base_ref"
cat > "${WORK}/regressed.csv" << 'EOF'
goos: linux
pkg: example.com/clean/greet
,base,,head,,,
,sec/op,CI,sec/op,CI,vs base,P
Hello-4,2.0e-08,5%,2.5e-08,4%,+25.00%,p=0.002 n=6
Quiet-4,2.0e-08,5%,2.1e-08,4%,~,p=0.300 n=6
Faster-4,2.0e-08,5%,1.0e-08,4%,-50.00%,p=0.002 n=6
geomean,2.0e-08,,2.5e-08,,+25.00%,

,base,,head,,,
,B/op,CI,B/op,CI,vs base,P
Hello-4,0,0%,320,0%,?,p=0.002 n=6
Steady-4,0,0%,0,0%,~,p=1.000 n=6

,base,,head,,,
,B/s,CI,B/s,CI,vs base,P
Throughput-4,100,1%,150,1%,+50.00%,p=0.002 n=6
EOF
run bench "working_dir=${CLEAN}" base_ref=HEAD count=2 benchtime=100x max_regression=10 -- "STUB_BENCHSTAT_CSV=${WORK}/regressed.csv"
check "a significant slowdown over max_regression fails" failed
check "runs the benchmarks on base_ref too" file_has "${OUT}/go-bench.base.txt" "BenchmarkHello"
check "alternately, count times each" test "$(grep -c '^BenchmarkHello' "${OUT}/go-bench.base.txt")" -eq 2
check "compares the two with benchstat" called_with benchstat "base=${OUT}/go-bench.base.txt" "head=${OUT}/go-bench.txt"
check "names the slowdown" file_has "${OUT}/go-bench.regressions.txt" "Hello-4 sec/op +25.00%"
check "and a significant rise from 0" file_has "${OUT}/go-bench.regressions.txt" "Hello-4 B/op from 0 to 320"
check "but not a change benchstat calls noise" not_file_has "${OUT}/go-bench.regressions.txt" "Quiet-4"
check "nor an improvement" not_file_has "${OUT}/go-bench.regressions.txt" "Faster-4"
check "nor more of a unit where more is better" not_file_has "${OUT}/go-bench.regressions.txt" "Throughput-4"
check "nor the geomean" not_file_has "${OUT}/go-bench.regressions.txt" "geomean"
check "removes its git worktree" test "$(git -C "${REPO}" worktree list | wc -l)" -eq 1
run bench "working_dir=${CLEAN}" base_ref=HEAD count=1 benchtime=10x max_regression=30 -- "STUB_BENCHSTAT_CSV=${WORK}/regressed.csv"
check "a slowdown under max_regression passes, but a rise from 0 still counts" failed
check "naming only that" test "$(wc -l < "${OUT}/go-bench.regressions.txt")" -eq 1
run bench "working_dir=${CLEAN}" base_ref=HEAD count=1 benchtime=10x -- "STUB_BENCHSTAT_CSV=${WORK}/regressed.csv"
check "without max_regression, only reports" succeeded
run bench "working_dir=${CLEAN}" base_ref=HEAD count=1 benchtime=10x max_regression=10 report_only=true -- "STUB_BENCHSTAT_CSV=${WORK}/regressed.csv"
check "report_only passes" succeeded

begin "bench: failures and parameters"
run bench "working_dir=${CLEAN}" base_ref=no-such-ref count=1
check "a base_ref that isn't a commit fails" said "base_ref no-such-ref is not a commit in this checkout"
run bench "working_dir=${CLEAN}" "base_ref=--output=x" count=1
check "a base_ref that is an option fails" said "base_ref must name a commit"
run bench "working_dir=${CLEAN}" max_regression=10 count=1
check "max_regression needs base_ref" said "max_regression compares against base_ref, which is empty"
mkdir -p "${REPO}/newmod/b"
printf 'module example.com/newmod\n\ngo 1.24\n' > "${REPO}/newmod/go.mod"
printf 'package b\n\nimport "testing"\n\nfunc BenchmarkB(b *testing.B) {\n\tfor i := 0; i < b.N; i++ {\n\t}\n}\n' > "${REPO}/newmod/b/b_test.go"
run bench "working_dir=${REPO}" modules=newmod base_ref=HEAD count=1 benchtime=10x
check "a module that base_ref doesn't have runs without a comparison" succeeded
check "with a warning" said "has no go.mod at HEAD, so its benchmarks are run without a comparison"
reset_repo
printf 'package greet\n\nimport "testing"\n\nfunc BenchmarkFails(b *testing.B) { b.Fatal("no") }\n' > "${CLEAN}/greet/fails_test.go"
run bench "working_dir=${CLEAN}" count=1 report_only=true
check "a benchmark that fails fails the step, even with report_only" failed
check "saying so" said "The benchmarks failed in example.com/clean"
reset_repo
run bench "working_dir=${CLEAN}" base_ref=HEAD count=1 benchtime=10x -- STUB_BENCHSTAT=crash
check "a benchstat that fails fails the step" said "benchstat could not read the results"
for setting in count=0 max_regression=ten cpu=all benchtime=long bench=; do
    run bench "working_dir=${CLEAN}" "${setting}"
    check "${setting} is refused" failed
done
run bench "working_dir=${CLEAN}" "extra_args=-count=5"
check "extra_args can't set -count" said "extra_args can't hold -count=5"

# ----------------------------------------------------------------- build
begin "build: platforms"
run build "working_dir=${CLEAN}" "platforms=linux/amd64 darwin/arm64,windows/amd64"
check "a module that builds everywhere passes" succeeded
check "for each platform" said "example.com/clean: builds for darwin/arm64"
check "writes a JUnit case per platform" file_has "${OUT}/junit/go-build.xml" 'classname="." name="windows/amd64"'
run build "working_dir=${DIRTY}" "platforms=linux/amd64 windows/amd64"
check "a platform it doesn't build for fails" failed
check "naming it" said "The code doesn't build: example.com/dirty for windows/amd64."
check "with the compiler's error" said "cannot use name (untyped int constant 42) as string value"
check "logging every build" file_has "${OUT}/go-build.log" "GOOS=windows GOARCH=amd64 CGO_ENABLED=0"
run build "working_dir=${DIRTY}" platforms=linux/amd64
check "it passes for the platforms it builds for" succeeded
run build "working_dir=${DIRTY}" "platforms=windows/amd64" report_only=true
check "report_only passes" succeeded
run build "working_dir=${CLEAN}" "platforms=linux/amd64 plan10/x"
check "a platform this Go doesn't know fails" said "platforms names plan10/x, which"
check "before building anything" not_said "builds for linux/amd64"
run build "working_dir=${CLEAN}" platforms=
check "no platforms fails" said "platforms names no platform"
run build "working_dir=${CLEAN}" platforms=linux/amd64 cgo=true tags=extra "extra_args=-trimpath"
check "cgo, tags and extra_args reach go build" file_has "${OUT}/go-build.log" "CGO_ENABLED=1 go build -o /dev/null -tags=extra -trimpath ./..."
run build "working_dir=${CLEAN}" platforms=linux/amd64 "extra_args=-o out"
check "extra_args can't set -o" said "extra_args can't hold -o"
check "nothing is left in the module" test -z "$(git -C "${REPO}" status --porcelain)"

# ------------------------------------------------------------ the shared helpers
begin "every command checks output_dir and report_name"
for command in fmt mod_tidy vet lint generate_check test fuzz bench build; do
    run "${command}" "working_dir=${CLEAN}" output_dir=relative
    check "${command}: refuses a relative output_dir" said "output_dir must be an absolute path"
    run "${command}" "working_dir=${CLEAN}" report_name=../x
    check "${command}: refuses a report_name that is a path" said "report_name must be letters, digits"
done

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} failure(s)"
    exit 1
fi
echo "All command tests passed."
