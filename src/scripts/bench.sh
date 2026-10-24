#!/bin/bash
#
# Runs the benchmarks of each module, for the bench command, and summarizes
# them with benchstat. With base_ref, it also runs them on that commit, in a
# git worktree on the same machine, alternating one run of each at a time so
# both see the same load, and compares the two with benchstat. Benchmarks
# are noisy on shared CI machines, so this only reports, unless
# max_regression is set: then a statistically significant slowdown, or growth
# in memory or allocations per operation, of more than that percentage is a
# finding. A benchmark that fails, or a package that doesn't build, fails the
# step whatever report_only says.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

BENCH=$(gq_subst "${PARAM_BENCH}")
COUNT=$(gq_subst "${PARAM_COUNT}")
BENCHTIME=$(gq_subst "${PARAM_BENCHTIME}")
BENCHMEM=$(gq_bool benchmem "${PARAM_BENCHMEM}")
CPU=$(gq_subst "${PARAM_CPU}")
TAGS=$(gq_subst "${PARAM_TAGS}")
TIMEOUT=$(gq_subst "${PARAM_TIMEOUT}")
BASE_REF=$(gq_subst "${PARAM_BASE_REF}")
MAX_REGRESSION=$(gq_subst "${PARAM_MAX_REGRESSION}")
REPORT_ONLY=$(gq_bool report_only "${PARAM_REPORT_ONLY}")
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_go
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"})
gq_uint count "${COUNT}" 1
gq_regex bench "${BENCH}"
if [[ -z "${BENCH}" ]]; then
    echo "ERROR: bench must be a regular expression matching the benchmarks to run, such as . for all of them." >&2
    exit 1
fi
if [[ -n "${MAX_REGRESSION}" ]]; then
    if ! gq_match "${MAX_REGRESSION}" '^[0-9]{1,6}(\.[0-9]+)?$'; then
        echo "ERROR: max_regression must be a percentage, such as 10 or 7.5, not '${MAX_REGRESSION}'." >&2
        exit 1
    fi
    if [[ -z "${BASE_REF}" ]]; then
        echo "ERROR: max_regression compares against base_ref, which is empty." >&2
        exit 1
    fi
fi
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        -bench | -bench=* | --bench | --bench=* | -count | -count=* | --count | --count=* | -run | -run=* | --run | --run=* | -json | -json=* | --json | --json=*)
            echo "ERROR: extra_args can't hold ${word}: use bench and count; this command runs no tests (-run '^\$') and reads go test's text output." >&2
            exit 1
            ;;
    esac
done
BENCHSTAT=""
if [[ -n "${BASE_REF}" ]]; then
    gq_tool benchstat install_benchstat
    BENCHSTAT=${GQ_TOOL}
elif command -v benchstat > /dev/null 2>&1; then
    BENCHSTAT=$(command -v benchstat)
fi

ARGS=(test -run '^$' "-bench=${BENCH}")
if [[ "${BENCHMEM}" == true ]]; then
    ARGS+=(-benchmem)
fi
if [[ -n "${BENCHTIME}" ]]; then
    gq_duration benchtime "${BENCHTIME}"
    ARGS+=("-benchtime=${BENCHTIME}")
fi
if [[ -n "${CPU}" ]]; then
    if ! gq_match "${CPU}" '^[0-9]+(,[0-9]+)*$'; then
        echo "ERROR: cpu must be GOMAXPROCS values separated by commas, such as 1,4, not '${CPU}'." >&2
        exit 1
    fi
    ARGS+=("-cpu=${CPU}")
fi
if [[ -n "${TAGS}" ]]; then
    ARGS+=("-tags=${TAGS}")
fi
if [[ -n "${TIMEOUT}" ]]; then
    gq_duration timeout "${TIMEOUT}"
    ARGS+=("-timeout=${TIMEOUT}")
fi
ARGS+=(${EXTRA[@]+"${EXTRA[@]}"})

WORK=$(mktemp -d)
BASE_TREE=""
cleanup() {
    if [[ -n "${BASE_TREE}" ]]; then
        git -C "${TOP}" worktree remove --force "${BASE_TREE}" > /dev/null 2>&1 || true
        git -C "${TOP}" worktree prune > /dev/null 2>&1 || true
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT

if [[ -n "${BASE_REF}" ]]; then
    if [[ "${BASE_REF}" == -* || "${BASE_REF}" == *[[:space:]]* ]]; then
        echo "ERROR: base_ref must name a commit, such as origin/main, not '${BASE_REF}'." >&2
        exit 1
    fi
    if ! command -v git > /dev/null 2>&1 || ! TOP=$(git rev-parse --show-toplevel 2> /dev/null); then
        echo "ERROR: base_ref needs a git checkout, and $(pwd) is not in one." >&2
        exit 1
    fi
    if ! BASE_COMMIT=$(git rev-parse --verify --quiet "${BASE_REF}^{commit}"); then
        echo "ERROR: base_ref ${BASE_REF} is not a commit in this checkout. Fetch it in an earlier step, such as" >&2
        echo "  git fetch origin main, and name it as origin/main." >&2
        exit 1
    fi
    BASE_TREE="${WORK}/base"
    if ! git -C "${TOP}" worktree add --detach --quiet "${BASE_TREE}" "${BASE_COMMIT}" > "${WORK}/worktree.log" 2>&1; then
        BASE_TREE=""
        echo "ERROR: Could not check out ${BASE_REF} in a git worktree:" >&2
        gq_tail "${WORK}/worktree.log"
        exit 1
    fi
    # The working directory, inside the base checkout.
    BASE_DIR="${BASE_TREE}/$(git rev-parse --show-prefix)"
    echo "Comparing with ${BASE_REF} (${BASE_COMMIT})."
fi

HEAD_OUT="${GQ_BASE}.txt"
BASE_OUT="${GQ_BASE}.base.txt"
LOG="${GQ_BASE}.log"
: > "${HEAD_OUT}"
: > "${LOG}"
rm -f "${BASE_OUT}"
COMPARED=()

# run_bench DIR OUT LABEL COUNT: runs the benchmarks in DIR COUNT times,
# adding their results to OUT, or stops the step.
run_bench() {
    local rc=0
    (cd "$1" && go "${ARGS[@]}" "-count=$4" "${GQ_PACKAGES[@]}") > "${WORK}/run.out" 2> "${WORK}/run.err" || rc=$?
    cat "${WORK}/run.out" >> "$2"
    {
        printf '# %s: go %s -count=%s %s (exit code %s)\n' "$3" "${ARGS[*]}" "$4" "${GQ_PACKAGES[*]}" "${rc}"
        cat "${WORK}/run.err"
    } >> "${LOG}"
    if [[ "${rc}" -ne 0 ]]; then
        echo "ERROR: The benchmarks failed in $3 (exit code ${rc}), so the step fails whatever report_only says. Their output:" >&2
        tail -n 30 "${WORK}/run.out" | sed 's/^/  /' >&2
        gq_tail "${WORK}/run.err" 20
        exit 1
    fi
}

for module in "${GQ_MODULES[@]}"; do
    if [[ -z "${BASE_REF}" ]]; then
        echo "Running the benchmarks of $(gq_label "${module}") ${COUNT} times..."
        run_bench "${module}" "${HEAD_OUT}" "$(gq_label "${module}")" "${COUNT}"
        continue
    fi
    base_module="${BASE_DIR%/}/${module}"
    if [[ ! -f "${base_module}/go.mod" ]]; then
        echo "WARN: $(gq_label "${module}") has no go.mod at ${BASE_REF}, so its benchmarks are run without a comparison." >&2
        run_bench "${module}" "${HEAD_OUT}" "$(gq_label "${module}")" "${COUNT}"
        continue
    fi
    COMPARED+=("${module}")
    : >> "${BASE_OUT}"
    echo "Running the benchmarks of $(gq_label "${module}") ${COUNT} times on this commit and on ${BASE_REF}, alternately..."
    for ((round = 1; round <= COUNT; round++)); do
        run_bench "${base_module}" "${BASE_OUT}" "$(gq_label "${module}") at ${BASE_REF}" 1
        run_bench "${module}" "${HEAD_OUT}" "$(gq_label "${module}")" 1
    done
done
if ! grep -q '^Benchmark' "${HEAD_OUT}"; then
    echo "No benchmarks matched ${BENCH} in $(gq_labels "${GQ_MODULES[@]}")."
    gq_gate false "${REPORT_ONLY}" "there were no benchmarks to run."
fi

if [[ -z "${BENCHSTAT}" ]]; then
    echo "benchstat is not on the PATH, so the results are not summarized. They are in ${HEAD_OUT}."
    gq_gate false "${REPORT_ONLY}" "the benchmarks ran."
fi
if [[ ${#COMPARED[@]} -gt 0 ]]; then
    INPUTS=("base=${BASE_OUT}" "head=${HEAD_OUT}")
else
    INPUTS=("results=${HEAD_OUT}")
fi
if ! "${BENCHSTAT}" "${INPUTS[@]}" > "${GQ_BASE}.benchstat.txt" 2> "${WORK}/benchstat.err" \
    || ! "${BENCHSTAT}" -format csv "${INPUTS[@]}" > "${GQ_BASE}.benchstat.csv" 2>> "${WORK}/benchstat.err"; then
    echo "ERROR: benchstat could not read the results:" >&2
    gq_tail "${WORK}/benchstat.err"
    exit 1
fi
cat "${GQ_BASE}.benchstat.txt"

if [[ -z "${MAX_REGRESSION}" || ${#COMPARED[@]} -eq 0 ]]; then
    gq_gate false "${REPORT_ONLY}" "the benchmarks ran; the comparison is in ${GQ_BASE}.benchstat.txt."
fi
# benchstat -format csv writes one table per unit, after the configuration
# lines (pkg: ..., cpu: ...) it belongs to: a row naming the inputs, a row
# naming the unit of each column (",sec/op,CI,sec/op,CI,vs base,P"), then a
# row per benchmark ending in the change ("+12.34%", "~" when it isn't
# significant, "?" when it can't be a percentage, as from 0) and the p-value
# ("p=0.002 n=6"), and a geomean row. Units where more is worse count, and so
# does a significant rise from 0, such as a first allocation per operation.
REGRESSIONS=$(awk -F, -v max="${MAX_REGRESSION}" '
    /^,/ { if ($(NF - 1) == "vs base") { unit = $2 } next }
    NF < 7 || $1 == "geomean" { next }
    unit != "sec/op" && unit != "B/op" && unit != "allocs/op" { next }
    {
        change = $(NF - 1)
        worse = 0
        if (change ~ /^\+[0-9.]+%$/) {
            worse = substr(change, 2, length(change) - 2) + 0 > max + 0
        } else if (change == "?" && $(NF - 5) + 0 == 0 && $(NF - 3) + 0 > 0 && match($NF, /^p=[0-9.]+/)) {
            worse = substr($NF, 3, RLENGTH - 2) + 0 < 0.05
            change = "from 0 to " $(NF - 3)
        }
        if (worse) {
            name = $1
            for (i = 2; i <= NF - 6; i++) { name = name "," $i }
            gsub(/^"|"$/, "", name)
            printf "%s %s %s\n", name, unit, change
        }
    }' "${GQ_BASE}.benchstat.csv")
if [[ -n "${REGRESSIONS}" ]]; then
    printf '%s\n' "${REGRESSIONS}" > "${GQ_BASE}.regressions.txt"
    echo "Significant changes of more than +${MAX_REGRESSION}%:"
    sed 's/^/  /' "${GQ_BASE}.regressions.txt"
    gq_gate true "${REPORT_ONLY}" "$(gq_plural "$(wc -l < "${GQ_BASE}.regressions.txt")" "benchmark measurement is" "benchmark measurements are") significantly worse than at ${BASE_REF} by more than ${MAX_REGRESSION}%."
fi
gq_gate false "${REPORT_ONLY}" "no benchmark is significantly worse than at ${BASE_REF} by more than ${MAX_REGRESSION}%."
