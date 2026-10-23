#!/bin/bash
#
# Runs go vet in each module, for the vet command, and reports what its
# analyzers find. go vet -json reports the diagnostics as JSON and exits 0
# when they are all it found, so a non-zero exit means go vet couldn't
# complete, such as for code that doesn't compile, which fails the step
# whatever report_only says. The JSON goes to stdout from Go 1.26 and to
# stderr before, between "# package" comment lines, so both are read.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
TAGS=$(gq_subst "${PARAM_TAGS}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq
gq_go
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
ARGS=(vet -json)
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
ARGS+=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"} "${GQ_PACKAGES[@]}")

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
REPORT="${GQ_BASE}.json"
echo '[]' > "${WORK}/all.json"
ERRORS=()
for module in "${GQ_MODULES[@]}"; do
    echo "Running go ${ARGS[*]} in $(gq_label "${module}")..."
    rc=0
    (cd "${module}" && go "${ARGS[@]}") > "${WORK}/out" 2> "${WORK}/err" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        ERRORS+=("${module}")
        echo "ERROR: go vet could not complete in $(gq_label "${module}") (exit code ${rc}). Its output:" >&2
        gq_tail "${WORK}/err"
        continue
    fi
    # Only the JSON objects' lines: they start with a brace or a tab, and
    # go's "# package" and "go: downloading" lines don't.
    cat "${WORK}/out" "${WORK}/err" | grep -E $'^([{}]|\t)' > "${WORK}/json" || true
    # Positions are absolute paths, made relative to the working directory.
    # shellcheck disable=SC2016 # jq program, not shell
    if ! jq -s -c --arg module "${module}" --arg prefix "$(gq_join "${module}" "")" \
        --arg root "$(cd "${module}" && pwd)/" --arg physical "$(cd "${module}" && pwd -P)/" '
        def relative: if startswith($root) then $prefix + .[($root | length):]
            elif startswith($physical) then $prefix + .[($physical | length):] else . end;
        [.[] | to_entries[] | .key as $package | .value | to_entries[] | .key as $analyzer | .value
         | if type == "array" then .[] | {module: $module, package: $package, analyzer: $analyzer,
               position: ((.posn // "") | relative), message: (.message // "")}
           else {module: $module, package: $package, analyzer: $analyzer, error: (.error // tostring)} end]' \
        "${WORK}/json" > "${WORK}/found.json" 2> "${WORK}/jq.err"; then
        ERRORS+=("${module}")
        echo "ERROR: go vet's JSON report in $(gq_label "${module}") could not be read: $(head -c 300 "${WORK}/jq.err")" >&2
        continue
    fi
    jq -s -c '.[0] + .[1]' "${WORK}/all.json" "${WORK}/found.json" > "${WORK}/next.json"
    mv "${WORK}/next.json" "${WORK}/all.json"
done
# An analyzer that failed reports an error instead of diagnostics.
if [[ "$(jq '[.[] | select(has("error"))] | length' "${WORK}/all.json")" -gt 0 ]]; then
    jq -r '.[] | select(has("error")) | "ERROR: the \(.analyzer) analyzer of go vet failed on \(.package): \(.error)"' "${WORK}/all.json" >&2
    ERRORS+=("$(jq -r '[.[] | select(has("error")) | .module] | unique | join(" ")' "${WORK}/all.json")")
fi
jq '[.[] | select(has("error") | not)]' "${WORK}/all.json" > "${REPORT}"
COUNT=$(jq length "${REPORT}")
jq -r '.[] | "  \(.position): \(.message) (\(.analyzer))"' "${REPORT}"
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go vet" \
        "$(jq -c '[.[] | {classname: .analyzer, name: .position, status: "failed", message: .message, detail: "\(.position): \(.message) (\(.package))"}]' "${REPORT}")"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: go vet could not check ${ERRORS[*]}, so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${COUNT}" -gt 0 ]]; then
    gq_gate true "${REPORT_ONLY}" "go vet found $(gq_plural "${COUNT}" problem problems) in $(gq_labels "${GQ_MODULES[@]}")."
fi
gq_gate false "${REPORT_ONLY}" "go vet found nothing in $(gq_labels "${GQ_MODULES[@]}")."
