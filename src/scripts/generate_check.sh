#!/bin/bash
#
# Checks that generated code is up to date, for the generate_check command:
# runs go generate in each module and reports every file it changed, added
# or deleted, as git sees them (ignored files don't count, since they aren't
# committed). The files changed before the step don't count either: their
# contents are recorded first, and only what go generate changed is
# reported. A go generate that fails stops the step whatever report_only
# says; the generators it runs (protoc, mockgen, sqlc...) must be installed
# first.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

RUN=$(gq_subst "${PARAM_RUN}")
SKIP=$(gq_subst "${PARAM_SKIP}")
TAGS=$(gq_subst "${PARAM_TAGS}")
JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_require_jq
gq_go
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_regex run "${RUN}"
gq_regex skip "${SKIP}"
if ! command -v git > /dev/null 2>&1 || ! TOP=$(git rev-parse --show-toplevel 2> /dev/null); then
    echo "ERROR: generate_check compares the files go generate writes with git, and $(pwd) is not in a git checkout." >&2
    exit 1
fi
ARGS=(generate)
if [[ -n "${RUN}" ]]; then
    ARGS+=("-run=${RUN}")
fi
if [[ -n "${SKIP}" ]]; then
    ARGS+=("-skip=${SKIP}")
fi
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
ARGS+=("${GQ_PACKAGES[@]}")

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT

# snapshot FILE: writes "<path>\t<content hash or -deleted->", sorted, for
# every file git status reports (modified, added, deleted or untracked, not
# ignored), with paths relative to the top of the checkout. git status
# compares contents, so a file rewritten as it was doesn't count, and with
# GIT_OPTIONAL_LOCKS=0 it doesn't rewrite the index as it does so.
snapshot() {
    local entry path hash
    : > "$1.unsorted"
    while IFS= read -r -d '' entry; do
        path=${entry:3}
        if [[ -L "${TOP}/${path}" ]]; then
            hash="link:$(readlink "${TOP}/${path}")"
        elif [[ -f "${TOP}/${path}" ]]; then
            hash=$(git -C "${TOP}" hash-object --no-filters -- "${path}")
        else
            hash="-deleted-"
        fi
        printf '%s\t%s\n' "${path}" "${hash}" >> "$1.unsorted"
    done < <(GIT_OPTIONAL_LOCKS=0 git -C "${TOP}" status --porcelain=v1 -z --untracked-files=all --no-renames \
        --ignore-submodules=all)
    LC_ALL=C sort -u "$1.unsorted" > "$1"
}

snapshot "${WORK}/before"
if [[ -s "${WORK}/before" ]]; then
    echo "Note: $(gq_plural "$(wc -l < "${WORK}/before")" "file already differs" "files already differ") from git's index; only what go generate changes in them is reported."
fi
LOG="${GQ_BASE}.log"
: > "${LOG}"
ERRORS=()
for module in "${GQ_MODULES[@]}"; do
    echo "Running go ${ARGS[*]} in $(gq_label "${module}")..."
    rc=0
    (cd "${module}" && go "${ARGS[@]}") >> "${LOG}" 2>&1 || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        ERRORS+=("${module}")
        echo "ERROR: go generate failed in $(gq_label "${module}") (exit code ${rc}). Its output:" >&2
        gq_tail "${LOG}"
    fi
done
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: go generate could not run in $(gq_labels "${ERRORS[@]}"), so the step fails whatever report_only says." >&2
    echo "  Install the generators it runs in an earlier step." >&2
    exit 1
fi
snapshot "${WORK}/after"

# A path changed when its line differs: new, gone, or another hash.
CHANGED=()
while IFS= read -r path; do
    CHANGED+=("${path}")
done < <(LC_ALL=C comm -3 "${WORK}/before" "${WORK}/after" | sed 's/^\t//' | cut -f1 | LC_ALL=C sort -u)

DIFF="${GQ_BASE}.diff"
: > "${DIFF}"
CASES="[]"
for path in ${CHANGED[@]+"${CHANGED[@]}"}; do
    if git -C "${TOP}" ls-files --error-unmatch -- "${path}" > /dev/null 2>&1; then
        state="changed"
        [[ -e "${TOP}/${path}" || -L "${TOP}/${path}" ]] || state="deleted"
        patch=$(git -C "${TOP}" diff --no-ext-diff --no-color -- "${path}" || true)
    else
        state="added"
        [[ -e "${TOP}/${path}" || -L "${TOP}/${path}" ]] || state="deleted"
        # git diff --no-index exits 1 when the files differ.
        patch=$(git -C "${TOP}" diff --no-ext-diff --no-color --no-index -- /dev/null "${path}" 2> /dev/null || true)
    fi
    echo "  ${state}: ${path}"
    printf '%s\n' "${patch}" >> "${DIFF}"
    CASES=$(jq -c --arg path "${path}" --arg state "${state}" --arg patch "${patch}" \
        '. + [{classname: "go generate", name: $path, status: "failed", message: "go generate \($state) \($path)", detail: $patch}]' <<< "${CASES}")
done
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go generate" "${CASES}"
fi
printf '%s\n' ${CHANGED[@]+"${CHANGED[@]}"} > "${GQ_BASE}.txt"

if [[ ${#CHANGED[@]} -gt 0 ]]; then
    echo "What go generate changed is in ${DIFF} (paths are relative to ${TOP})."
    gq_gate true "${REPORT_ONLY}" "go generate changed $(gq_plural "${#CHANGED[@]}" file files), so the generated code in this commit is out of date. Run go generate and commit the result."
fi
gq_gate false "${REPORT_ONLY}" "go generate changed nothing in $(gq_labels "${GQ_MODULES[@]}")."
