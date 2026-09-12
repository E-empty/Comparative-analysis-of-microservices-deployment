#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

REPO_URL=""
NEW_TAG=""
NEW_VERSION="1.1.0"
REMOTE="origin"
RUN_SCOPE="both"
ARGOCD_BRANCH="study-argocd"
FLUXCD_BRANCH="study-fluxcd"
CLUSTER_NAME="gitops-thesis"
KUBE_CONTEXT="kind-gitops-thesis"
SCENARIO_ITERATIONS=30
GIT_ITERATIONS=10
RESOURCE_SAMPLES=30
SAMPLE_INTERVAL=15
WARMUP_SECONDS=300
TIMEOUT_SECONDS=300
POLL_INTERVAL=1
SETTLE_SECONDS=5
PHASE_WINDOW_SECONDS=60
DELAY_SEED=20260905
RESULTS_DIR=""
RUN_LOG=""

usage() {
  cat <<'EOF'
Usage: experiments/run-controlled-comparison.sh \
  --repo-url URL --new-tag TAG [options]

Creates a fresh Kind cluster for each selected controller and runs the complete
controlled benchmark suite. With the default --tool both, Argo CD is measured
first, then the cluster is recreated and Flux CD is measured.

Required:
  --repo-url URL              Public Git repository watched by both controllers
  --new-tag TAG               Pre-published alternate image tag

Options:
  --tool both|argocd|fluxcd   Controllers to test (default: both)
  --new-version VERSION       Version paired with --new-tag (default: 1.1.0)
  --remote NAME               Git remote used by mutation tests (default: origin)
  --argocd-branch NAME        Argo CD experiment branch (default: study-argocd)
  --fluxcd-branch NAME        Flux CD experiment branch (default: study-fluxcd)
  --cluster-name NAME         Kind cluster name (default: gitops-thesis)
  --context NAME              kube-context (default: kind-gitops-thesis)
  --scenario-iterations N     Repetitions of each non-Git scenario (default: 30)
  --git-iterations N          Repetitions of each Git scenario (default: 10)
  --resource-samples N        Idle resource samples (default: 30)
  --sample-interval SEC       Delay between resource samples (default: 15)
  --warmup-seconds SEC        Delay after smoke test (default: 300)
  --timeout SEC               Maximum wait per measured phase (default: 300)
  --poll-interval SEC         Observation interval (default: 1)
  --settle-seconds SEC        Minimum pre-mutation delay (default: 5)
  --phase-window SEC          Deterministic delay window (default: 60)
  --delay-seed N              Delay seed shared by both tools (default: 20260905)
  --results-dir PATH          Results root (default: timestamped directory)
  -h, --help                  Show this help

The script stops on the first failed command and leaves the current cluster in
place for diagnosis. Run it in tmux or another persistent terminal session.
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"
  [[ -n "${value}" && "${value}" != --* ]] || fail "${option} requires a value"
}

is_positive_integer() {
  [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_number() {
  [[ "$1" =~ ^[0-9]+([.][0-9]+)?$ ]]
}

is_branch_name() {
  git check-ref-format --branch "$1" >/dev/null 2>&1
}

while (($# > 0)); do
  case "$1" in
    --repo-url)
      require_value "$1" "${2:-}"
      REPO_URL="$2"
      shift 2
      ;;
    --new-tag)
      require_value "$1" "${2:-}"
      NEW_TAG="$2"
      shift 2
      ;;
    --new-version)
      require_value "$1" "${2:-}"
      NEW_VERSION="$2"
      shift 2
      ;;
    --remote)
      require_value "$1" "${2:-}"
      REMOTE="$2"
      shift 2
      ;;
    --tool)
      require_value "$1" "${2:-}"
      RUN_SCOPE="$2"
      shift 2
      ;;
    --argocd-branch)
      require_value "$1" "${2:-}"
      ARGOCD_BRANCH="$2"
      shift 2
      ;;
    --fluxcd-branch)
      require_value "$1" "${2:-}"
      FLUXCD_BRANCH="$2"
      shift 2
      ;;
    --cluster-name)
      require_value "$1" "${2:-}"
      CLUSTER_NAME="$2"
      shift 2
      ;;
    --context)
      require_value "$1" "${2:-}"
      KUBE_CONTEXT="$2"
      shift 2
      ;;
    --scenario-iterations)
      require_value "$1" "${2:-}"
      SCENARIO_ITERATIONS="$2"
      shift 2
      ;;
    --git-iterations)
      require_value "$1" "${2:-}"
      GIT_ITERATIONS="$2"
      shift 2
      ;;
    --resource-samples)
      require_value "$1" "${2:-}"
      RESOURCE_SAMPLES="$2"
      shift 2
      ;;
    --sample-interval)
      require_value "$1" "${2:-}"
      SAMPLE_INTERVAL="$2"
      shift 2
      ;;
    --warmup-seconds)
      require_value "$1" "${2:-}"
      WARMUP_SECONDS="$2"
      shift 2
      ;;
    --timeout)
      require_value "$1" "${2:-}"
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    --poll-interval)
      require_value "$1" "${2:-}"
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --settle-seconds)
      require_value "$1" "${2:-}"
      SETTLE_SECONDS="$2"
      shift 2
      ;;
    --phase-window)
      require_value "$1" "${2:-}"
      PHASE_WINDOW_SECONDS="$2"
      shift 2
      ;;
    --delay-seed)
      require_value "$1" "${2:-}"
      DELAY_SEED="$2"
      shift 2
      ;;
    --results-dir)
      require_value "$1" "${2:-}"
      RESULTS_DIR="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown option: $1"
      ;;
  esac
done

[[ -n "${REPO_URL}" ]] || fail "--repo-url is required"
[[ -n "${NEW_TAG}" ]] || fail "--new-tag is required"
[[ "${RUN_SCOPE}" == "both" || "${RUN_SCOPE}" == "argocd" || "${RUN_SCOPE}" == "fluxcd" ]] || \
  fail "--tool must be both, argocd or fluxcd"
[[ "${NEW_TAG}" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]{0,127}$ ]] || \
  fail "--new-tag must be a valid container image tag"
[[ ${#NEW_VERSION} -le 63 && "${NEW_VERSION}" =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]] || \
  fail "--new-version must be a valid Kubernetes label value"
[[ "${CLUSTER_NAME}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || \
  fail "--cluster-name must be a valid DNS label"
[[ "${KUBE_CONTEXT}" == "kind-${CLUSTER_NAME}" ]] || \
  fail "--context must match the Kind cluster name: kind-${CLUSTER_NAME}"
is_branch_name "${ARGOCD_BRANCH}" || fail "invalid Argo CD branch: ${ARGOCD_BRANCH}"
is_branch_name "${FLUXCD_BRANCH}" || fail "invalid Flux CD branch: ${FLUXCD_BRANCH}"
is_positive_integer "${SCENARIO_ITERATIONS}" || fail "--scenario-iterations must be positive"
is_positive_integer "${GIT_ITERATIONS}" || fail "--git-iterations must be positive"
is_positive_integer "${RESOURCE_SAMPLES}" || fail "--resource-samples must be positive"
is_nonnegative_number "${SAMPLE_INTERVAL}" || fail "--sample-interval must be non-negative"
is_nonnegative_number "${WARMUP_SECONDS}" || fail "--warmup-seconds must be non-negative"
is_positive_integer "${TIMEOUT_SECONDS}" || fail "--timeout must be positive"
is_nonnegative_number "${POLL_INTERVAL}" || fail "--poll-interval must be non-negative"
is_nonnegative_number "${SETTLE_SECONDS}" || fail "--settle-seconds must be non-negative"
is_nonnegative_number "${PHASE_WINDOW_SECONDS}" || fail "--phase-window must be non-negative"
[[ "${DELAY_SEED}" =~ ^[0-9]+$ ]] || fail "--delay-seed must be a non-negative integer"

for command_name in bash git docker kind kubectl helm python3 awk find tee; do
  command -v "${command_name}" >/dev/null 2>&1 || fail "required command not found: ${command_name}"
done

git -C "${REPO_ROOT}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || \
  fail "repository root is not a Git worktree"
REMOTE_URL="$(git -C "${REPO_ROOT}" remote get-url "${REMOTE}" 2>/dev/null)" || \
  fail "Git remote not found: ${REMOTE}"
[[ "${REPO_URL}" != *$'\n'* \
  && "${REPO_URL}" != *$'\r'* \
  && "${REPO_URL}" != *$'\t'* \
  && "${REPO_URL}" != *' '* \
  && "${REPO_URL}" != *'\\'* ]] || fail "--repo-url contains invalid characters"
[[ ! "${REPO_URL}" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]] || \
  fail "--repo-url must not contain embedded credentials"
[[ "${REMOTE_URL%/}" == "${REPO_URL%/}" \
  || "${REMOTE_URL%.git}" == "${REPO_URL%.git}" ]] || \
  fail "${REMOTE} points to ${REMOTE_URL}, but the controller would watch ${REPO_URL}"

if [[ -z "${RESULTS_DIR}" ]]; then
  RESULTS_DIR="${REPO_ROOT}/results/controlled-$(date -u +%Y%m%dT%H%M%SZ)"
elif [[ "${RESULTS_DIR}" != /* ]]; then
  RESULTS_DIR="${REPO_ROOT}/${RESULTS_DIR}"
fi

mkdir -p "${RESULTS_DIR}/logs" "${RESULTS_DIR}/metadata"
RUN_LOG="${RESULTS_DIR}/logs/controlled-comparison-$(date -u +%Y%m%dT%H%M%SZ).log"
exec > >(tee -a "${RUN_LOG}") 2>&1

on_exit() {
  local status=$?
  trap - EXIT
  if ((status == 0)); then
    printf '\n[%s] Controlled comparison completed successfully.\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Results: %s\n' "${RESULTS_DIR}"
    printf 'Run log: %s\n' "${RUN_LOG}"
    printf 'The final Kind cluster was left running for inspection.\n'
  else
    printf '\n[%s] Controlled comparison stopped with exit code %s.\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${status}" >&2
    printf 'The cluster was left running for diagnosis. Log: %s\n' "${RUN_LOG}" >&2
  fi
  exit "${status}"
}
trap on_exit EXIT

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

run_step() {
  printf '\n[%s] Running:' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf ' %q' "$@"
  printf '\n'
  "$@"
}

require_clean_worktree() {
  local status
  status="$(git -C "${REPO_ROOT}" status --porcelain --untracked-files=normal)"
  [[ -z "${status}" ]] || fail "Git worktree is not clean:\n${status}"
}

prepare_branch() {
  local branch="$1"
  local local_head remote_head remote_line

  require_clean_worktree
  run_step git -C "${REPO_ROOT}" fetch "${REMOTE}" \
    "+refs/heads/${branch}:refs/remotes/${REMOTE}/${branch}"
  if git -C "${REPO_ROOT}" show-ref --verify --quiet "refs/heads/${branch}"; then
    run_step git -C "${REPO_ROOT}" switch "${branch}"
  else
    run_step git -C "${REPO_ROOT}" switch --track -c "${branch}" "${REMOTE}/${branch}"
  fi
  run_step git -C "${REPO_ROOT}" merge --ff-only "${REMOTE}/${branch}"
  require_clean_worktree

  local_head="$(git -C "${REPO_ROOT}" rev-parse HEAD)"
  remote_line="$(git -C "${REPO_ROOT}" ls-remote --exit-code --heads \
    "${REMOTE}" "refs/heads/${branch}")" || fail "cannot resolve ${REMOTE}/${branch}"
  read -r remote_head _ <<<"${remote_line}"
  [[ "${local_head}" == "${remote_head}" ]] || \
    fail "local ${branch} differs from ${REMOTE}/${branch}"
}

ensure_new_results_series() {
  local tool="$1"
  local tool_dir="${RESULTS_DIR}/${tool}"
  if [[ -d "${tool_dir}" && -n "$(find "${tool_dir}" -mindepth 1 -print -quit)" ]]; then
    fail "results already exist for ${tool}: ${tool_dir}"
  fi
}

write_environment_metadata() {
  local metadata_file="${RESULTS_DIR}/metadata/environment.txt"
  {
    printf 'started_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'repo_url=%s\n' "${REPO_URL}"
    printf 'run_scope=%s\n' "${RUN_SCOPE}"
    printf 'argocd_branch=%s\n' "${ARGOCD_BRANCH}"
    printf 'fluxcd_branch=%s\n' "${FLUXCD_BRANCH}"
    printf 'new_tag=%s\n' "${NEW_TAG}"
    printf 'new_version=%s\n' "${NEW_VERSION}"
    printf 'scenario_iterations=%s\n' "${SCENARIO_ITERATIONS}"
    printf 'git_iterations=%s\n' "${GIT_ITERATIONS}"
    printf 'resource_samples=%s\n' "${RESOURCE_SAMPLES}"
    printf 'sample_interval=%s\n' "${SAMPLE_INTERVAL}"
    printf 'warmup_seconds=%s\n' "${WARMUP_SECONDS}"
    printf 'timeout_seconds=%s\n' "${TIMEOUT_SECONDS}"
    printf 'poll_interval=%s\n' "${POLL_INTERVAL}"
    printf 'settle_seconds=%s\n' "${SETTLE_SECONDS}"
    printf 'phase_window_seconds=%s\n' "${PHASE_WINDOW_SECONDS}"
    printf 'delay_seed=%s\n' "${DELAY_SEED}"
    printf '\n'
    git --version || true
    python3 --version || true
    docker version || true
    kind version || true
    kubectl version --client -o yaml || true
    helm version --short || true
  } >"${metadata_file}" 2>&1
}

capture_tool_metadata() {
  local tool="$1"
  local phase="$2"
  local branch="$3"
  local prefix="${RESULTS_DIR}/metadata/${tool}-${phase}"

  git -C "${REPO_ROOT}" rev-parse HEAD >"${prefix}-git-sha.txt"
  kubectl --context "${KUBE_CONTEXT}" get nodes -o wide >"${prefix}-nodes.txt" 2>&1 || true
  kubectl --context "${KUBE_CONTEXT}" get pods -A -o wide >"${prefix}-pods.txt" 2>&1 || true
  git -C "${REPO_ROOT}" log --oneline --decorate -n 20 "${branch}" \
    >"${prefix}-git-log.txt" 2>&1 || true
}

run_quality_checks() {
  log "Running local quality checks"
  run_step bash "${REPO_ROOT}/scripts/check-requirements.sh"
  run_step python3 -m pytest "${REPO_ROOT}/tests" "${REPO_ROOT}/analysis"
  run_step helm lint "${REPO_ROOT}/helm/microservices-app"
  run_step bash -c \
    'helm template microservices-app "$1" --namespace test-render >/dev/null' \
    _ "${REPO_ROOT}/helm/microservices-app"
}

run_tool_suite() {
  local tool="$1"
  local branch="$2"
  local -a common_args git_args

  ensure_new_results_series "${tool}"
  log "Preparing ${tool} series on branch ${branch}"
  prepare_branch "${branch}"

  run_step bash "${REPO_ROOT}/scripts/delete-cluster.sh" --name "${CLUSTER_NAME}"
  run_step bash "${REPO_ROOT}/scripts/create-cluster.sh" --name "${CLUSTER_NAME}"
  run_step bash "${REPO_ROOT}/scripts/install-metrics-server.sh" --context "${KUBE_CONTEXT}"

  if [[ "${tool}" == "argocd" ]]; then
    run_step bash "${REPO_ROOT}/scripts/install-argocd.sh" \
      --repo-url "${REPO_URL}" --revision "${branch}" --context "${KUBE_CONTEXT}"
  else
    run_step bash "${REPO_ROOT}/scripts/install-fluxcd.sh" \
      --repo-url "${REPO_URL}" --revision "${branch}" --context "${KUBE_CONTEXT}"
  fi

  run_step bash "${REPO_ROOT}/experiments/smoke-test.sh" \
    --tool "${tool}" --context "${KUBE_CONTEXT}"
  capture_tool_metadata "${tool}" start "${branch}"

  if [[ "${WARMUP_SECONDS}" != "0" ]]; then
    log "Waiting ${WARMUP_SECONDS}s before the ${tool} resource baseline"
    run_step sleep "${WARMUP_SECONDS}"
  fi

  common_args=(
    --tool "${tool}"
    --context "${KUBE_CONTEXT}"
    --results-dir "${RESULTS_DIR}"
    --timeout "${TIMEOUT_SECONDS}"
    --poll-interval "${POLL_INTERVAL}"
    --settle-seconds "${SETTLE_SECONDS}"
    --phase-window "${PHASE_WINDOW_SECONDS}"
    --delay-seed "${DELAY_SEED}"
  )
  git_args=(--remote "${REMOTE}" --branch "${branch}")

  run_step bash "${REPO_ROOT}/experiments/resource-usage.sh" \
    "${common_args[@]}" --phase idle --iterations "${RESOURCE_SAMPLES}" \
    --sample-interval "${SAMPLE_INTERVAL}"
  run_step bash "${REPO_ROOT}/experiments/drift-scale.sh" \
    "${common_args[@]}" --iterations "${SCENARIO_ITERATIONS}"
  run_step bash "${REPO_ROOT}/experiments/drift-image.sh" \
    "${common_args[@]}" --iterations "${SCENARIO_ITERATIONS}"
  run_step bash "${REPO_ROOT}/experiments/delete-deployment.sh" \
    "${common_args[@]}" --iterations "${SCENARIO_ITERATIONS}"
  run_step bash "${REPO_ROOT}/experiments/restart-gitops-controller.sh" \
    "${common_args[@]}" --iterations "${SCENARIO_ITERATIONS}"
  run_step bash "${REPO_ROOT}/experiments/deploy-new-version.sh" \
    "${common_args[@]}" "${git_args[@]}" --iterations "${GIT_ITERATIONS}" \
    --new-tag "${NEW_TAG}" --new-version "${NEW_VERSION}"
  run_step bash "${REPO_ROOT}/experiments/change-config.sh" \
    "${common_args[@]}" "${git_args[@]}" --iterations "${GIT_ITERATIONS}"
  run_step bash "${REPO_ROOT}/experiments/rollback.sh" \
    "${common_args[@]}" "${git_args[@]}" --iterations "${GIT_ITERATIONS}"

  require_clean_worktree
  capture_tool_metadata "${tool}" final "${branch}"
  log "Completed ${tool} series"
}

write_environment_metadata
require_clean_worktree
run_quality_checks

case "${RUN_SCOPE}" in
  both)
    run_tool_suite argocd "${ARGOCD_BRANCH}"
    run_tool_suite fluxcd "${FLUXCD_BRANCH}"
    ;;
  argocd)
    run_tool_suite argocd "${ARGOCD_BRANCH}"
    ;;
  fluxcd)
    run_tool_suite fluxcd "${FLUXCD_BRANCH}"
    ;;
esac

log "Generating summary tables"
run_step python3 "${REPO_ROOT}/analysis/analyze_results.py" \
  --input-dir "${RESULTS_DIR}" --output-dir "${RESULTS_DIR}/analysis"
