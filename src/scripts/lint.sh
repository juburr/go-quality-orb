#!/bin/bash
#
# Runs golangci-lint in each module, for the lint command, and writes its
# issues as JSON, SARIF and JUnit. golangci-lint exits 1 when it finds
# issues, which are the findings, and with another code when it can't
# complete (a config it can't load, a Go release newer than the one it was
# built with, no Go files). Two more cases count as not completing, whatever
# report_only says: typecheck issues, which mean the code doesn't compile so
# the linters couldn't analyze it, and an error golangci-lint only logs
# (level=error) before exiting 0, as it does for a package it can't load.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

CONFIG=$(gq_subst "${PARAM_CONFIG}")
NEW_FROM_REV=$(gq_subst "${PARAM_NEW_FROM_REV}")
TIMEOUT=$(gq_subst "${PARAM_TIMEOUT}")
SARIF=$(gq_bool sarif "${PARAM_SARIF}")
JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq
gq_go
gq_tool golangci-lint install_golangci_lint
LINTER=${GQ_TOOL}
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"})
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        --output.* | --path-prefix | --path-prefix=* | --path-mode | --path-mode=* | --issues-exit-code | --issues-exit-code=*)
            echo "ERROR: extra_args can't hold ${word}: this command sets the outputs, paths and exit code it reads." >&2
            exit 1
            ;;
    esac
done

# golangci-lint 1 has other output flags. A build that doesn't say its
# version (one from a local checkout says "(devel)") is taken to be 2.
VERSION=$("${LINTER}" version 2>&1 || true)
if gq_match "${VERSION}" 'has version v?([0-9]+)\.' && [[ "${BASH_REMATCH[1]}" -lt 2 ]]; then
    echo "ERROR: lint needs golangci-lint 2 or newer, and ${LINTER} is: ${VERSION}" >&2
    echo "  Install golangci-lint 2 with this orb's install_golangci_lint command." >&2
    exit 1
fi
echo "${VERSION}"

# A config's run.issues-exit-code would change what exit code means issues.
ARGS=(run --output.text.path=stdout --output.text.colors=false --issues-exit-code=1)
if [[ -n "${CONFIG}" ]]; then
    if [[ ! -f "${CONFIG}" ]]; then
        echo "ERROR: config ${CONFIG} does not exist (in $(pwd))." >&2
        exit 1
    fi
    # Absolute, since golangci-lint runs in each module's directory.
    ARGS+=("--config=$(cd "$(dirname "${CONFIG}")" && pwd)/$(basename "${CONFIG}")")
fi
if [[ -n "${NEW_FROM_REV}" ]]; then
    ARGS+=("--new-from-rev=${NEW_FROM_REV}")
fi
if [[ -n "${TIMEOUT}" ]]; then
    gq_duration timeout "${TIMEOUT}"
    ARGS+=("--timeout=${TIMEOUT}")
fi

# Makes an absolute path below the working directory relative to it, by its
# logical or physical path; any other path is left as it is.
ROOT=$(pwd)
PHYSICAL=$(pwd -P)
# shellcheck disable=SC2016 # jq program, not shell
RELATIVE='def relative: if startswith($root) then .[($root | length):]
    elif startswith($physical) then .[($physical | length):] else . end;'

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
LOG="${GQ_BASE}.log"
: > "${LOG}"
echo '[]' > "${WORK}/issues.json"
echo '[]' > "${WORK}/runs.json"
ERRORS=()
for module in "${GQ_MODULES[@]}"; do
    echo "Running golangci-lint in $(gq_label "${module}")..."
    run=(${ARGS[@]+"${ARGS[@]}"} "--output.json.path=${WORK}/out.json")
    if [[ "${SARIF}" == true ]]; then
        run+=("--output.sarif.path=${WORK}/out.sarif")
    fi
    # golangci-lint 2 writes paths relative to the directory of the config
    # it uses (run.relative-path-mode), which can be above the module, so a
    # path prefix can't make them relative to working_dir. Absolute paths
    # are made relative below.
    run+=(--path-mode=abs ${EXTRA[@]+"${EXTRA[@]}"} "${GQ_PACKAGES[@]}")
    rm -f "${WORK}/out.json" "${WORK}/out.sarif"
    rc=0
    (cd "${module}" && "${LINTER}" "${run[@]}") 2> "${WORK}/err" || rc=$?
    cat "${WORK}/err" >&2
    {
        printf '# golangci-lint in %s (exit code %s)\n' "${module}" "${rc}"
        cat "${WORK}/err"
    } >> "${LOG}"
    if [[ "${rc}" -ne 0 && "${rc}" -ne 1 ]]; then
        ERRORS+=("${module}")
        echo "ERROR: golangci-lint could not complete in $(gq_label "${module}") (exit code ${rc}); its messages are above." >&2
        if grep -q 'used to build golangci-lint is lower than the targeted Go version' "${WORK}/err"; then
            echo "  This golangci-lint was built with an older Go than the go line of ${module}/go.mod asks for." >&2
            echo "  Install a newer golangci-lint with install_golangci_lint: its version output names the Go it was built with." >&2
        elif grep -q 'unsupported version of the configuration' "${WORK}/err"; then
            echo "  golangci-lint 2 needs a version: \"2\" configuration; golangci-lint migrate converts a version 1 one." >&2
        elif grep -q 'unknown flag: --path-mode' "${WORK}/err"; then
            echo "  This golangci-lint has no --path-mode option, which lint needs. Install a newer one with install_golangci_lint." >&2
        fi
        continue
    fi
    if grep -q 'level=error' "${WORK}/err"; then
        ERRORS+=("${module}")
        echo "ERROR: golangci-lint logged an error in $(gq_label "${module}") (level=error above), so it did not check everything." >&2
        continue
    fi
    # shellcheck disable=SC2016 # jq program, not shell
    if [[ ! -s "${WORK}/out.json" ]] || ! jq -c --arg mod "${module}" --arg root "${ROOT}/" --arg physical "${PHYSICAL}/" \
        "${RELATIVE}"' [(.Issues // [])[] | . + {module: $mod}
         | if (.Pos.Filename | type) == "string" then .Pos.Filename |= relative else . end]' \
        "${WORK}/out.json" > "${WORK}/found.json" 2> /dev/null; then
        ERRORS+=("${module}")
        echo "ERROR: golangci-lint wrote no JSON report in $(gq_label "${module}")." >&2
        continue
    fi
    if [[ "$(jq '[.[] | select(.FromLinter == "typecheck")] | length' "${WORK}/found.json")" -gt 0 ]]; then
        ERRORS+=("${module}")
        echo "ERROR: The code in $(gq_label "${module}") doesn't compile (golangci-lint's typecheck issues above), so the linters could not analyze it." >&2
    fi
    jq -s -c '.[0] + .[1]' "${WORK}/issues.json" "${WORK}/found.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/issues.json"
    if [[ "${SARIF}" == true && -s "${WORK}/out.sarif" ]]; then
        # shellcheck disable=SC2016 # jq program, not shell
        jq -s -c --arg root "${ROOT}/" --arg physical "${PHYSICAL}/" "${RELATIVE}"' .[0] + ((.[1].runs // [])
            | reduce (paths(type == "string") | select(length > 1 and .[-1] == "uri" and .[-2] == "artifactLocation")) as $p
                (.; setpath($p; getpath($p) | relative)))' "${WORK}/runs.json" "${WORK}/out.sarif" > "${WORK}/next.json"
        mv "${WORK}/next.json" "${WORK}/runs.json"
    fi
done

cp "${WORK}/issues.json" "${GQ_BASE}.json"
# One SARIF file, with a run per module.
if [[ "${SARIF}" == true ]]; then
    jq '{"$schema": "https://json.schemastore.org/sarif-2.1.0.json", version: "2.1.0", runs: .}' "${WORK}/runs.json" > "${GQ_BASE}.sarif"
fi
COUNT=$(jq length "${GQ_BASE}.json")
if [[ "${JUNIT}" == true ]]; then
    # shellcheck disable=SC2016 # jq program, not shell
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" golangci-lint "$(jq -c '[.[] | {classname: .FromLinter,
        name: "\(.Pos.Filename):\(.Pos.Line):\(.Pos.Column)", status: "failed", message: .Text,
        detail: ("\(.Pos.Filename):\(.Pos.Line):\(.Pos.Column): \(.Text) (\(.FromLinter))\n" + ((.SourceLines // []) | join("\n")))}]' "${GQ_BASE}.json")"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: golangci-lint could not check $(gq_labels "${ERRORS[@]}"), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    gq_gate true "${REPORT_ONLY}" "golangci-lint found $(gq_plural "${COUNT}" issue issues) in $(gq_labels "${GQ_MODULES[@]}")."
fi
gq_gate false "${REPORT_ONLY}" "golangci-lint found no issues in $(gq_labels "${GQ_MODULES[@]}")."
