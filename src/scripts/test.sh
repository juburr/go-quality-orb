#!/bin/bash
#
# Runs the tests of each module with gotestsum, for the test command, and
# writes JUnit XML, go test's JSON events and a coverage profile. A failing
# test or a package that doesn't build fails the step, as does total
# coverage below coverage_min. With split_tests and a job parallelism above
# 1, each node runs its share of the packages, split by the timings of
# earlier JUnit results.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

RACE=$(gq_bool race "${PARAM_RACE}")
JUNIT=$(gq_bool junit "${PARAM_JUNIT}")
SHORT=$(gq_bool short "${PARAM_SHORT}")
COVERAGE=$(gq_bool coverage "${PARAM_COVERAGE}")
SPLIT=$(gq_bool split_tests "${PARAM_SPLIT_TESTS}")
SHUFFLE=$(gq_subst "${PARAM_SHUFFLE}")
COUNT=$(gq_subst "${PARAM_COUNT}")
TIMEOUT=$(gq_subst "${PARAM_TIMEOUT}")
TAGS=$(gq_subst "${PARAM_TAGS}")
RUN=$(gq_subst "${PARAM_RUN}")
SKIP=$(gq_subst "${PARAM_SKIP}")
COVERMODE=${PARAM_COVERMODE}
COVERPKG=$(gq_subst "${PARAM_COVERPKG}")
COVERAGE_MIN=$(gq_subst "${PARAM_COVERAGE_MIN}")
RERUN_FAILS=$(gq_subst "${PARAM_RERUN_FAILS}")
FORMAT=${PARAM_FORMAT}
gq_output "${PARAM_OUTPUT_DIR}" "${PARAM_REPORT_NAME}"
gq_go
gq_tool gotestsum install_gotestsum
GOTESTSUM=${GQ_TOOL}
gq_modules "${PARAM_MODULES}"
gq_packages "${PARAM_PACKAGES}"
gq_words extra_args "$(gq_subst "${PARAM_EXTRA_ARGS}")"
EXTRA=(${GQ_WORDS[@]+"${GQ_WORDS[@]}"})
# The build flags in extra_args that decide which packages and files build,
# for split_tests' go list, which can't take go test's own flags.
LIST_FLAGS=()
take_value=false
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    if [[ "${take_value}" == true ]]; then
        LIST_FLAGS+=("${word}")
        take_value=false
        continue
    fi
    case "${word}" in
        -race | --race | -race=* | --race=* | -msan | --msan | -msan=* | --msan=* | -asan | --asan | -asan=* | --asan=* \
            | -tags=* | --tags=* | -mod=* | --mod=* | -modfile=* | --modfile=* | -overlay=* | --overlay=*)
            LIST_FLAGS+=("${word}")
            ;;
        -tags | --tags | -mod | --mod | -modfile | --modfile | -overlay | --overlay)
            LIST_FLAGS+=("${word}")
            take_value=true
            ;;
    esac
done

gq_uint count "${COUNT}" 1
gq_uint rerun_fails "${RERUN_FAILS}"
gq_regex run "${RUN}"
gq_regex skip "${SKIP}"
if ! gq_match "${SHUFFLE}" '^(off|on|[0-9]{1,19})$'; then
    echo "ERROR: shuffle must be off, on, or a seed (a whole number), not '${SHUFFLE}'." >&2
    exit 1
fi
case "${COVERMODE}" in
    "" | set | count | atomic) ;;
    *)
        echo "ERROR: covermode must be set, count or atomic, or empty for go test's default, not '${COVERMODE}'." >&2
        exit 1
        ;;
esac
if [[ -n "${COVERAGE_MIN}" ]]; then
    if ! gq_match "${COVERAGE_MIN}" '^(100(\.0+)?|[0-9]{1,2}(\.[0-9]+)?)$'; then
        echo "ERROR: coverage_min must be a percentage from 0 to 100, such as 80 or 72.5, not '${COVERAGE_MIN}'." >&2
        exit 1
    fi
    if [[ "${COVERAGE}" != true ]]; then
        echo "ERROR: coverage_min needs coverage to be true." >&2
        exit 1
    fi
fi
if ! gq_match "${FORMAT}" '^[a-z][a-z0-9-]*$'; then
    echo "ERROR: format must name a gotestsum format, such as pkgname or testname, not '${FORMAT}'." >&2
    exit 1
fi
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        -json | -json=* | --json | --json=* | -coverprofile | -coverprofile=* | --coverprofile | --coverprofile=*)
            echo "ERROR: extra_args can't hold ${word}: gotestsum reads go test's JSON, and coverage sets the profile." >&2
            exit 1
            ;;
    esac
done

GO_ARGS=("-count=${COUNT}")
if [[ "${RACE}" == true ]]; then
    GO_ARGS+=(-race)
fi
if [[ "${SHUFFLE}" != off ]]; then
    GO_ARGS+=("-shuffle=${SHUFFLE}")
fi
if [[ -n "${TIMEOUT}" ]]; then
    gq_duration timeout "${TIMEOUT}"
    GO_ARGS+=("-timeout=${TIMEOUT}")
fi
if [[ -n "${TAGS}" ]]; then
    GO_ARGS+=("-tags=${TAGS}")
fi
if [[ -n "${RUN}" ]]; then
    GO_ARGS+=("-run=${RUN}")
fi
if [[ -n "${SKIP}" ]]; then
    GO_ARGS+=("-skip=${SKIP}")
fi
if [[ "${SHORT}" == true ]]; then
    GO_ARGS+=(-short)
fi
if [[ "${COVERAGE}" == true && -n "${COVERMODE}" ]]; then
    GO_ARGS+=("-covermode=${COVERMODE}")
fi
if [[ "${COVERAGE}" == true && -n "${COVERPKG}" ]]; then
    GO_ARGS+=("-coverpkg=${COVERPKG}")
fi
if [[ "${COVERAGE}" == true && "${RERUN_FAILS}" -gt 0 ]]; then
    echo "Note: gotestsum reruns failed tests with the same go test flags, so a rerun's coverage profile replaces the first run's."
fi
NODES=${CIRCLE_NODE_TOTAL:-1}
if ! gq_match "${NODES}" '^[0-9]{1,4}$'; then
    NODES=1
fi
if [[ "${SPLIT}" == true && "${NODES}" -gt 1 ]]; then
    if ! command -v circleci > /dev/null 2>&1; then
        echo "ERROR: split_tests needs the CircleCI CLI (circleci tests split), which CircleCI jobs have." >&2
        exit 1
    fi
    # Each node would see only its own share of the coverage.
    if [[ -n "${COVERAGE_MIN}" ]]; then
        echo "ERROR: coverage_min can't be checked when split_tests splits the tests across ${NODES} nodes, since each" >&2
        echo "  node writes the coverage of its own packages only. Leave it empty, and check merged profiles in a later job." >&2
        exit 1
    fi
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
FAILED=()
PROFILES=()
RAN=0
for module in "${GQ_MODULES[@]}"; do
    out="${GQ_BASE}"
    junit="${GQ_OUT}/junit/${PARAM_REPORT_NAME}"
    if [[ "${module}" != . ]]; then
        out="${out}/${module}"
        junit="${junit}/${module}"
    fi
    mkdir -p "${out}"
    if [[ "${JUNIT}" == true ]]; then
        mkdir -p "${junit}"
    fi
    if [[ "${RACE}" == true ]]; then
        cgo=$(cd "${module}" && go env CGO_ENABLED)
        cc=$(cd "${module}" && go env CC)
        if [[ "${cgo}" != 1 ]]; then
            echo "ERROR: race needs cgo, and CGO_ENABLED is ${cgo:-empty} in $(gq_label "${module}"). Set CGO_ENABLED=1, or set race to false." >&2
            exit 1
        fi
        if ! command -v "${cc%% *}" > /dev/null 2>&1; then
            echo "ERROR: race needs a C compiler, and ${cc:-gcc} (go env CC) is not on the PATH. cimg/go has gcc." >&2
            exit 1
        fi
    fi
    packages=("${GQ_PACKAGES[@]}")
    if [[ "${SPLIT}" == true && "${NODES}" -gt 1 ]]; then
        # The same build settings as the tests, in the same order, since
        # -race and tags decide which packages have files to build.
        list_args=(list)
        if [[ "${RACE}" == true ]]; then
            list_args+=(-race)
        fi
        if [[ -n "${TAGS}" ]]; then
            list_args+=("-tags=${TAGS}")
        fi
        list_args+=(${LIST_FLAGS[@]+"${LIST_FLAGS[@]}"})
        if ! (cd "${module}" && go "${list_args[@]}" "${GQ_PACKAGES[@]}") > "${WORK}/packages" 2> "${WORK}/list.err"; then
            echo "ERROR: go list could not list the packages of $(gq_label "${module}"):" >&2
            gq_tail "${WORK}/list.err"
            exit 1
        fi
        # Read from a file, since a process substitution would hide a
        # splitter that fails, and its empty output would skip the tests.
        if ! circleci tests split --split-by=timings --timings-type=classname < "${WORK}/packages" > "${WORK}/share"; then
            echo "ERROR: circleci tests split could not split the packages of $(gq_label "${module}"); its messages are above." >&2
            exit 1
        fi
        packages=()
        while IFS= read -r package; do
            [[ -n "${package}" ]] && packages+=("${package}")
        done < "${WORK}/share"
        echo "Node $((${CIRCLE_NODE_INDEX:-0} + 1)) of ${NODES} runs ${#packages[@]} of the $(wc -l < "${WORK}/packages") packages in $(gq_label "${module}")."
        if [[ ${#packages[@]} -eq 0 ]]; then
            continue
        fi
    fi
    args=(--format "${FORMAT}" --jsonfile "${out}/events.json")
    if [[ "${JUNIT}" == true ]]; then
        args+=(--junitfile "${junit}/junit.xml")
    fi
    if [[ "${RERUN_FAILS}" -gt 0 ]]; then
        args+=("--rerun-fails=${RERUN_FAILS}" --rerun-fails-report "${out}/rerun-fails.txt")
    fi
    args+=(--packages "${packages[*]}" --)
    module_go_args=(${GO_ARGS[@]+"${GO_ARGS[@]}"})
    if [[ "${COVERAGE}" == true ]]; then
        rm -f "${out}/coverage.out"
        module_go_args+=("-coverprofile=${out}/coverage.out")
    fi
    module_go_args+=(${EXTRA[@]+"${EXTRA[@]}"})
    echo "Running go test ${module_go_args[*]} ${packages[*]} in $(gq_label "${module}"), with gotestsum..."
    RAN=$((RAN + 1))
    rc=0
    (cd "${module}" && "${GOTESTSUM}" "${args[@]}" "${module_go_args[@]}") || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        FAILED+=("${module}")
    fi
    if [[ "${COVERAGE}" == true && -s "${out}/coverage.out" ]]; then
        PROFILES+=("${out}/coverage.out")
        if (cd "${module}" && go tool cover -func="${out}/coverage.out") > "${out}/coverage.txt" 2> "${WORK}/cover.err"; then
            echo "Coverage of $(gq_label "${module}"): $(awk '/^total:/ { print $NF }' "${out}/coverage.txt")"
            (cd "${module}" && go tool cover -html="${out}/coverage.out" -o "${out}/coverage.html") 2> /dev/null || true
        else
            echo "WARN: go tool cover could not read the coverage profile of $(gq_label "${module}"): $(head -c 300 "${WORK}/cover.err")" >&2
        fi
    fi
done

if [[ "${RAN}" -eq 0 ]]; then
    echo "This node has no packages to test."
    exit 0
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo "ERROR: Tests failed, or packages didn't build, in $(gq_labels "${FAILED[@]}"). The go test events are in ${GQ_BASE}." >&2
    exit 1
fi
if [[ "${COVERAGE}" == true && ${#PROFILES[@]} -gt 0 ]]; then
    # The share of statements covered, over every module's profile. A block
    # that several test binaries report (with coverpkg) counts once, as
    # covered if any of them ran it, as go tool cover counts it. Prints the
    # statements covered and in all.
    COUNTS=$(awk 'FNR == 1 && /^mode:/ { next }
        NF == 3 {
            if (!($1 in statements)) { statements[$1] = $2; covered[$1] = 0 }
            if ($3 > 0) { covered[$1] = 1 }
        }
        END {
            for (block in statements) { all += statements[block]; if (covered[block]) { hit += statements[block] } }
            printf "%.0f %.0f\n", hit, all
        }' "${PROFILES[@]}")
    read -r HIT ALL <<< "${COUNTS}"
    TOTAL=none
    if [[ "${ALL}" -gt 0 ]]; then
        TOTAL=$(awk -v hit="${HIT}" -v all="${ALL}" 'BEGIN { printf "%.1f\n", 100 * hit / all }')
        echo "Total coverage: ${TOTAL}% of statements (${HIT} of ${ALL})."
    else
        echo "Total coverage: none, since the coverage profiles hold no statements."
    fi
    printf '%s\n' "${TOTAL}" > "${GQ_BASE}/coverage-total.txt"
    if [[ -n "${COVERAGE_MIN}" ]]; then
        # The exact share, not the rounded one: 1999 of 2000 is 100.0%.
        if [[ "${ALL}" -eq 0 ]] || awk -v hit="${HIT}" -v all="${ALL}" -v min="${COVERAGE_MIN}" 'BEGIN { exit !(100 * hit < min * all) }'; then
            echo "ERROR: Total coverage is ${TOTAL}% (${HIT} of ${ALL} statements), below coverage_min (${COVERAGE_MIN}%)." >&2
            exit 1
        fi
        echo "Passed: coverage is at least ${COVERAGE_MIN}%."
    fi
elif [[ -n "${COVERAGE_MIN}" ]]; then
    echo "ERROR: coverage_min is ${COVERAGE_MIN}%, but the tests wrote no coverage profile." >&2
    exit 1
fi
echo "Passed: the tests of $(gq_labels "${GQ_MODULES[@]}") pass."
