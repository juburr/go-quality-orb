#!/bin/bash
#
# Checks that each module builds for every platform in platforms, for the
# build command: go build -o /dev/null for each GOOS/GOARCH pair, which
# compiles every package and keeps nothing. Code behind build tags or
# _<os>.go file names for one platform only is checked this way without a
# machine for it. A platform the module doesn't build for is a finding; a
# platform this Go doesn't support stops the step before anything is built.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

CGO=$(gq_bool cgo "${PARAM_CGO}")
TAGS=$(gq_subst "${PARAM_TAGS}")
JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq
gq_go
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"})
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        -o | -o=* | --o | --o=*)
            echo "ERROR: extra_args can't hold ${word}: this command keeps nothing it builds (-o /dev/null)." >&2
            exit 1
            ;;
    esac
done
gq_list platforms "${PARAM_PLATFORMS}"
PLATFORMS=(${GQ_LIST[@]+"${GQ_LIST[@]}"})
if [[ ${#PLATFORMS[@]} -eq 0 ]]; then
    echo "ERROR: platforms names no platform. Name GOOS/GOARCH pairs, such as linux/amd64 darwin/arm64." >&2
    exit 1
fi
if ! SUPPORTED=$(go tool dist list 2>&1); then
    echo "ERROR: go tool dist list failed: ${SUPPORTED}" >&2
    exit 1
fi
for platform in "${PLATFORMS[@]}"; do
    if ! grep -qxF -- "${platform}" <<< "${SUPPORTED}"; then
        echo "ERROR: platforms names ${platform}, which $(go env GOVERSION) can't build for. Platforms are GOOS/GOARCH" >&2
        echo "  pairs that go tool dist list prints, such as linux/amd64, linux/arm64, darwin/arm64 and windows/amd64." >&2
        exit 1
    fi
done
ARGS=(build -o /dev/null)
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
ARGS+=(${EXTRA[@]+"${EXTRA[@]}"} "${GQ_PACKAGES[@]}")
CGO_ENABLED_VALUE=0
if [[ "${CGO}" == true ]]; then
    CGO_ENABLED_VALUE=1
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
LOG="${GQ_BASE}.log"
: > "${LOG}"
CASES="[]"
FAILED=()
for module in "${GQ_MODULES[@]}"; do
    for platform in "${PLATFORMS[@]}"; do
        rc=0
        (cd "${module}" && env GOOS="${platform%/*}" GOARCH="${platform#*/}" CGO_ENABLED="${CGO_ENABLED_VALUE}" \
            go "${ARGS[@]}") > "${WORK}/out" 2>&1 || rc=$?
        {
            printf '# %s, %s: GOOS=%s GOARCH=%s CGO_ENABLED=%s go %s (exit code %s)\n' "${module}" "${platform}" \
                "${platform%/*}" "${platform#*/}" "${CGO_ENABLED_VALUE}" "${ARGS[*]}" "${rc}"
            cat "${WORK}/out"
        } >> "${LOG}"
        if [[ "${rc}" -eq 0 ]]; then
            echo "  $(gq_label "${module}"): builds for ${platform}"
            CASES=$(jq -c --arg mod "${module}" --arg platform "${platform}" \
                '. + [{classname: $mod, name: $platform, status: "passed"}]' <<< "${CASES}")
            continue
        fi
        FAILED+=("$(gq_label "${module}") for ${platform}")
        echo "  $(gq_label "${module}"): does NOT build for ${platform}:"
        tail -n 30 "${WORK}/out" | sed 's/^/    /'
        CASES=$(jq -c --arg mod "${module}" --arg platform "${platform}" --rawfile log "${WORK}/out" \
            '. + [{classname: $mod, name: $platform, status: "failed", message: "\($mod) does not build for \($platform)", detail: $log}]' <<< "${CASES}")
    done
done
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go build" "${CASES}"
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    gq_gate true "${REPORT_ONLY}" "The code doesn't build: $(printf '%s, ' "${FAILED[@]}" | sed 's/, $//'). The compiler's output is in ${LOG}."
fi
gq_gate false "${REPORT_ONLY}" "$(gq_labels "${GQ_MODULES[@]}") build for ${PLATFORMS[*]}."
