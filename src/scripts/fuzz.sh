#!/bin/bash
#
# Fuzzes each fuzz test in each module for fuzz_time, for the fuzz command.
# go test -fuzz runs one fuzz test of one package at a time, so the fuzz
# tests are listed first (go test -list), then each gets its own run. A fuzz
# test that fails, on a new input or one already in its corpus, is a
# finding; the input it failed on, which go writes to the package's
# testdata/fuzz/<test> directory, is copied to the reports, so it can be
# added to the repository as a regression test. A package that doesn't
# build, or a run that ends another way, fails the step whatever report_only
# says.

set -euo pipefail

if [[ -z "${SCRIPT_GO_QUALITY_LIB:-}" ]]; then
    echo "ERROR: The shared helpers were not loaded: SCRIPT_GO_QUALITY_LIB is empty." >&2
    exit 1
fi
eval "${SCRIPT_GO_QUALITY_LIB}"

TARGETS=$(gq_subst "${PARAM_TARGETS}")
FUZZ_TIME=$(gq_subst "${PARAM_FUZZ_TIME}")
PARALLEL=$(gq_subst "${PARAM_PARALLEL}")
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
gq_duration fuzz_time "${FUZZ_TIME}"
gq_regex targets "${TARGETS}"
if [[ -n "${PARALLEL}" ]]; then
    gq_uint parallel "${PARALLEL}" 1
fi
if [[ -n "${TARGETS}" ]]; then
    # grep -E returns 2 for a pattern it can't compile.
    rc=0
    grep -qE -- "${TARGETS}" <<< "" || rc=$?
    if [[ "${rc}" -eq 2 ]]; then
        echo "ERROR: targets is not a valid regular expression: ${TARGETS}" >&2
        exit 1
    fi
fi
for word in ${EXTRA[@]+"${EXTRA[@]}"}; do
    case "${word}" in
        -fuzz | -fuzz=* | --fuzz | --fuzz=* | -run | -run=* | --run | --run=* | -fuzztime | -fuzztime=* | --fuzztime | --fuzztime=*)
            echo "ERROR: extra_args can't hold ${word}: this command runs each fuzz test with -run, -fuzz and -fuzztime." >&2
            exit 1
            ;;
    esac
done
BUILD_ARGS=()
if [[ -n "${TAGS}" ]]; then
    BUILD_ARGS+=("-tags=${TAGS}")
fi
FUZZ_ARGS=(-run '^$' "-fuzztime=${FUZZ_TIME}")
if [[ -n "${PARALLEL}" ]]; then
    FUZZ_ARGS+=("-parallel=${PARALLEL}")
fi

WORK=$(mktemp -d)
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${GQ_BASE}"
CASES="[]"
FAILED=()
ERRORS=()
TOTAL=0
for module in "${GQ_MODULES[@]}"; do
    # Each fuzz test, as "<package>\t<name>". -list runs no tests.
    if ! (cd "${module}" && go test ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -list '^Fuzz' -json "${GQ_PACKAGES[@]}") \
        > "${WORK}/list.json" 2> "${WORK}/list.err"; then
        ERRORS+=("${module}")
        echo "ERROR: go test -list could not list the fuzz tests of $(gq_label "${module}"). Its output:" >&2
        jq -r 'select(.Output) | .Output' "${WORK}/list.json" 2> /dev/null | tail -n 30 | sed 's/^/  /' >&2 || true
        gq_tail "${WORK}/list.err" 20
        continue
    fi
    jq -r 'select(.Action == "output" and (.Output | test("^Fuzz[A-Za-z0-9_]*\n$"))) | "\(.Package)\t\(.Output | rtrimstr("\n"))"' \
        "${WORK}/list.json" > "${WORK}/targets"
    while IFS=$'\t' read -r package name; do
        if [[ -n "${TARGETS}" ]] && ! LC_ALL=C grep -qE -- "${TARGETS}" <<< "${name}"; then
            continue
        fi
        TOTAL=$((TOTAL + 1))
        if ! dir=$(cd "${module}" && go list ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} -f '{{.Dir}}' "${package}" 2> "${WORK}/dir.err"); then
            ERRORS+=("${package}.${name}")
            echo "ERROR: go list could not find the directory of ${package}: $(head -c 300 "${WORK}/dir.err")" >&2
            continue
        fi
        corpus="${dir}/testdata/fuzz/${name}"
        # Where the package is, relative to the working directory, for the
        # copy of its new corpus files.
        relative=${dir#"$(pwd -P)/"}
        relative=${relative#"$(pwd)/"}
        if [[ "${relative}" == /* ]]; then
            relative=${package}
        fi
        find "${corpus}" -type f -print 2> /dev/null | LC_ALL=C sort > "${WORK}/before" || true
        log="${GQ_BASE}/${relative}/${name}.log"
        mkdir -p "${log%/*}"
        echo "Fuzzing ${package} ${name} for ${FUZZ_TIME}..."
        rc=0
        (cd "${module}" && go test ${BUILD_ARGS[@]+"${BUILD_ARGS[@]}"} "${FUZZ_ARGS[@]}" -fuzz "^${name}\$" \
            ${EXTRA[@]+"${EXTRA[@]}"} "${package}") > "${log}" 2>&1 || rc=$?
        if [[ "${rc}" -eq 0 ]]; then
            echo "  passed: $(grep -E '^fuzz: elapsed' "${log}" | tail -n 1 || true)"
            CASES=$(jq -c --arg package "${package}" --arg name "${name}" \
                '. + [{classname: $package, name: $name, status: "passed"}]' <<< "${CASES}")
            continue
        fi
        if ! grep -qE -- "^--- FAIL: ${name} " "${log}"; then
            ERRORS+=("${package}.${name}")
            echo "ERROR: Fuzzing ${package} ${name} ended without a result (exit code ${rc}). Its output:" >&2
            gq_tail "${log}" 30
            CASES=$(jq -c --arg package "${package}" --arg name "${name}" --arg log "$(tail -n 60 "${log}")" \
                '. + [{classname: $package, name: $name, status: "failed", message: "fuzzing did not complete", detail: $log}]' <<< "${CASES}")
            continue
        fi
        FAILED+=("${package}.${name}")
        echo "  FAILED. The end of its output:"
        tail -n 30 "${log}" | sed 's/^/    /'
        find "${corpus}" -type f -print 2> /dev/null | LC_ALL=C sort > "${WORK}/after" || true
        while IFS= read -r input; do
            [[ -n "${input}" ]] || continue
            mkdir -p "${GQ_BASE}/${relative}/testdata/fuzz/${name}"
            cp "${input}" "${GQ_BASE}/${relative}/testdata/fuzz/${name}/"
            echo "  The failing input is saved as ${GQ_BASE}/${relative}/testdata/fuzz/${name}/${input##*/}."
            echo "  Add it to ${relative}/testdata/fuzz/${name}/ in the repository to keep it as a regression test."
        done < <(LC_ALL=C comm -13 "${WORK}/before" "${WORK}/after")
        CASES=$(jq -c --arg package "${package}" --arg name "${name}" --arg log "$(tail -n 60 "${log}")" \
            '. + [{classname: $package, name: $name, status: "failed", message: "\($name) failed", detail: $log}]' <<< "${CASES}")
    done < "${WORK}/targets"
done
if [[ "${JUNIT}" == true ]]; then
    gq_junit "${GQ_OUT}/junit/${PARAM_REPORT_NAME}.xml" "go fuzz" "${CASES}"
fi

if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: Could not fuzz ${ERRORS[*]}, so the step fails whatever report_only says." >&2
    exit 1
fi
if [[ "${TOTAL}" -eq 0 ]]; then
    echo "There are no fuzz tests${TARGETS:+ matching ${TARGETS}} in $(gq_labels "${GQ_MODULES[@]}")."
fi
if [[ ${#FAILED[@]} -gt 0 ]]; then
    gq_gate true "${REPORT_ONLY}" "Fuzzing found failing inputs for ${FAILED[*]}."
fi
gq_gate false "${REPORT_ONLY}" "$(gq_plural "${TOTAL}" "fuzz test" "fuzz tests") ran for ${FUZZ_TIME} each without failing."
