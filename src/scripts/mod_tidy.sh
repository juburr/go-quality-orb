#!/bin/bash
#
# Checks that go.mod and go.sum are tidy in each module, with go mod tidy
# -diff, for the mod_tidy command. go mod tidy -diff changes nothing and
# prints the changes go mod tidy would make, exiting 1 when there are any,
# which are the findings. It arrived in Go 1.23, so an older Go fails the
# step before anything runs, as does a go mod tidy that can't complete, such
# as one that can't download a module, whatever report_only says.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq
gq_go
gq_modules "${PARAM_MODULES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"})
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        -diff | -diff=* | --diff | --diff=*)
            echo "ERROR: extra_args can't hold ${word}: this command always runs go mod tidy -diff." >&2
            exit 1
            ;;
    esac
done

# go mod tidy -diff arrived in Go 1.23. Every module is checked before any
# runs, since go.mod's toolchain line can pick a release per module.
for module in "${GQ_MODULES[@]}"; do
    gq_go_version "${module}"
    if [[ "${GQ_GO_MINOR}" -lt 23 ]]; then
        echo "ERROR: mod_tidy needs Go 1.23 or newer, for go mod tidy -diff, and $(gq_label "${module}") runs ${GQ_GO_VERSION}." >&2
        echo "  Use a newer Go: an image such as cimg/go:1.27, or this orb's install_go command." >&2
        exit 1
    fi
done

DIFF="${GQ_BASE}.diff"
WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
: > "${DIFF}"
CASES="[]"
UNTIDY=()
ERRORS=()
for module in "${GQ_MODULES[@]}"; do
    echo "Checking $(gq_label "${module}") with go mod tidy -diff..."
    rc=0
    (cd "${module}" && go mod tidy -diff ${EXTRA[@]+"${EXTRA[@]}"}) > "${WORK}/out" 2> "${WORK}/err" || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        echo "  tidy"
        CASES=$(jq -c --arg mod "${module}" '. + [{classname: "go mod tidy", name: $mod, status: "passed"}]' <<< "${CASES}")
        continue
    fi
    # Changes come as a unified diff on stdout; an error has none.
    if [[ "${rc}" -eq 1 ]] && head -n 1 "${WORK}/out" | grep -q '^diff '; then
        UNTIDY+=("${module}")
        echo "  not tidy:"
        sed 's/^/    /' "${WORK}/out"
        {
            printf '# go mod tidy -diff in %s\n' "${module}"
            cat "${WORK}/out"
        } >> "${DIFF}"
        CASES=$(jq -c --arg mod "${module}" --rawfile diff "${WORK}/out" \
            '. + [{classname: "go mod tidy", name: $mod, status: "failed", message: "\($mod)/go.mod or go.sum is not tidy", detail: $diff}]' <<< "${CASES}")
        continue
    fi
    ERRORS+=("${module}")
    echo "ERROR: go mod tidy -diff could not complete in $(gq_label "${module}") (exit code ${rc}). Its output:" >&2
    gq_tail "${WORK}/err"
    CASES=$(jq -c --arg mod "${module}" --rawfile log "${WORK}/err" \
        '. + [{classname: "go mod tidy", name: $mod, status: "failed", message: "go mod tidy -diff could not complete", detail: $log}]' <<< "${CASES}")
done
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go mod tidy" "${CASES}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: go mod tidy -diff could not check $(gq_labels "${ERRORS[@]}"), so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ ${#UNTIDY[@]} -gt 0 ]]; then
    echo "The changes go mod tidy would make are in ${DIFF}."
    gq_gate true "${REPORT_ONLY}" "go.mod or go.sum is not tidy in $(gq_labels "${UNTIDY[@]}"). Run go mod tidy there and commit the result."
fi
gq_gate false "${REPORT_ONLY}" "go.mod and go.sum are tidy in $(gq_labels "${GQ_MODULES[@]}")."
