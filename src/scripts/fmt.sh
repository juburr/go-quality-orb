#!/bin/bash
#
# Checks that the Go files under the working directory are formatted, with
# gofmt or gofumpt, for the fmt command. It lists the files go ./... patterns
# cover (skipping vendor, testdata, and directories whose names start with
# "." or "_"), so formatting is checked whatever the build tags. Unformatted
# files are findings; a file the formatter can't parse fails the step
# whatever report_only says.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

FORMATTER=${PARAM_FORMATTER}
SIMPLIFY=$(gq_bool simplify "${PARAM_SIMPLIFY}")
JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq

case "${FORMATTER}" in
    gofmt)
        if ! GQ_TOOL=$(command -v gofmt); then
            echo "ERROR: gofmt is not on the PATH. It comes with Go: use an image with Go, such as cimg/go," >&2
            echo "  or install it in an earlier step with this orb's install_go command." >&2
            exit 1
        fi
        ;;
    gofumpt) gq_tool gofumpt install_gofumpt ;;
    *)
        echo "ERROR: formatter must be gofmt or gofumpt, not '${FORMATTER}'." >&2
        exit 1
        ;;
esac
FLAGS=()
if [[ "${SIMPLIFY}" == true ]]; then
    if [[ "${FORMATTER}" == gofumpt ]]; then
        echo "Note: gofumpt always simplifies, so simplify changes nothing."
    else
        FLAGS+=(-s)
    fi
fi

# Directories to skip, as find -path patterns.
PRUNE=()
gq_list exclude "${PARAM_EXCLUDE}"
for entry in ${GQ_LIST[@]+"${GQ_LIST[@]}"}; do
    dir=${entry}
    while [[ "${dir}" == */ && "${dir}" != / ]]; do
        dir=${dir%/}
    done
    while [[ "${dir}" == ./* ]]; do
        dir=${dir#./}
    done
    if [[ -z "${dir}" || "${dir}" == . || "${dir}" == /* || "/${dir}/" == */../* || "${dir}" == *[*?[]* ]]; then
        echo "ERROR: exclude must name directories inside the working directory, without '..' or wildcards, not '${entry}'." >&2
        exit 1
    fi
    PRUNE+=(-o -path "./${dir}")
done

# The go command also ignores files whose names start with "." or "_". Each
# file is passed as ./<path>, so a name that starts with "-" is never read as
# a flag.
FILES=()
while IFS= read -r -d '' file; do
    FILES+=("${file}")
done < <(find . -mindepth 1 \( -type d \( -name vendor -o -name testdata -o -name '.*' -o -name '_*' \) \
    ${PRUNE[@]+"${PRUNE[@]}"} \) -prune -o -type f -name '*.go' ! -name '.*' ! -name '_*' -print0 | LC_ALL=C sort -z)
# gofmt has no version option; it is the gofmt of the Go release it came with.
VERSION=""
if [[ "${FORMATTER}" == gofumpt ]]; then
    VERSION=$("${GQ_TOOL}" --version 2> /dev/null || true)
fi
echo "Checking the formatting of $(gq_plural "${#FILES[@]}" "Go file" "Go files") with ${GQ_TOOL}${VERSION:+ ${VERSION}}${FLAGS[*]:+ (${FLAGS[*]})}..."

LIST="${GQ_BASE}.txt"
DIFF="${GQ_BASE}.diff"
LOG="${GQ_BASE}.log"
: > "${LIST}.tmp"
: > "${DIFF}"
rc=0
if [[ ${#FILES[@]} -gt 0 ]]; then
    printf '%s\0' "${FILES[@]}" | xargs -0 "${GQ_TOOL}" -l ${FLAGS[@]+"${FLAGS[@]}"} > "${LIST}.tmp" 2> "${LOG}" || rc=$?
fi
if [[ "${rc}" -ne 0 ]]; then
    echo "ERROR: ${FORMATTER} could not check every file (exit code ${rc}). Its output:" >&2
    gq_tail "${LOG}"
    echo "  A file that doesn't parse can't be formatted: fix the syntax error first." >&2
    rm -f "${LIST}.tmp"
    exit 1
fi
rm -f "${LOG}"
sed 's|^\./||' "${LIST}.tmp" > "${LIST}"
rm -f "${LIST}.tmp"

CASES="[]"
COUNT=0
while IFS= read -r file; do
    [[ -n "${file}" ]] || continue
    COUNT=$((COUNT + 1))
    echo "  not formatted: ${file}"
    # gofmt -d exits 1 when it shows a difference.
    patch=$("${GQ_TOOL}" -d ${FLAGS[@]+"${FLAGS[@]}"} "./${file}" 2>&1 || true)
    printf '%s\n' "${patch}" >> "${DIFF}"
    CASES=$(jq -c --arg file "${file}" --arg formatter "${FORMATTER}" --arg patch "${patch}" \
        '. + [{classname: $formatter, name: $file, status: "failed", message: "\($file) is not formatted with \($formatter)", detail: $patch}]' <<< "${CASES}")
done < "${LIST}"
if [[ "${COUNT}" -gt 0 ]]; then
    echo "The changes ${FORMATTER} would make are in ${DIFF}."
fi
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "${FORMATTER}" "${CASES}"
fi

if [[ "${COUNT}" -gt 0 ]]; then
    gq_gate true "${REPORT_ONLY}" "$(gq_plural "${COUNT}" "Go file is" "Go files are") not formatted with ${FORMATTER}. Run ${FORMATTER} -w${FLAGS[*]:+ ${FLAGS[*]}} on them."
fi
gq_gate false "${REPORT_ONLY}" "$(gq_plural "${#FILES[@]}" "Go file is" "Go files are") formatted with ${FORMATTER}."
