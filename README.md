# Jellyfin Helm Chart

This chart deploys Jellyfin using the shared dependency `lib-chart` (`0.0.13`).

## Installation

```bash
helm install jellyfin . --namespace media-center
```

## Dependencies

- `lib-chart` (`0.0.13`) from `oci://ghcr.io/orhayoun-eevee`

Update dependencies from chart root:

```bash
helm dependency build
```

## Validation and Testing

This chart follows the same reusable 5-layer validation pipeline used by `helm-common-lib`:

1. Syntax and structure (`yamllint`, `helm lint --strict`)
2. Kubernetes schema validation (`kubeconform`) on rendered scenarios
3. Metadata and version checks (`ct lint` + version bump policy)
4. Unit and regression checks (`helm-unittest` + scenario snapshots)
5. Policy checks (`checkov`, `kube-linter`)

### CI Workflows

- Required gate: `.github/workflows/pr-required-checks.yaml` (thin wrapper around centralized `pr-required-checks-chart.yaml` in `build-workflow`; this is the only automatic PR gate)
- Release: `.github/workflows/on-tag.yaml` -> `build-workflow/.github/workflows/release-chart.yaml` (includes keyless signing/attestation)
- Renovate snapshot updates: `.github/workflows/renovate-snapshot-update.yaml` (Renovate PRs touching `values.yaml`)
- Renovate config validation: `.github/workflows/renovate-config.yaml` (automatic on matching config changes; supports `workflow_dispatch`)

### Local Docker Validation

```bash
make docker-build
make deps
make snapshot-update
make ci
```

If you use the shared image directly (`DOCKER_IMAGE=ghcr.io/orhayoun-eevee/helm-validate:vX.Y.Z`), keep the tag aligned with your pinned `build-workflow` release and authenticate Docker first:

```bash
echo <TOKEN> | docker login ghcr.io -u <USER> --password-stdin
```

### Snapshot Drift Behavior

Snapshots in `tests/snapshots/*.yaml` are part of CI contract.
If rendered output changes and snapshots are not updated (or are updated incorrectly), Layer 4 fails the PR.

Schema-negative fixtures in `tests/schema-fail-cases/*.yaml` are also validated in Layer 4 and must fail schema validation for the expected reason.

### Test Assets

- `tests/jellyfin_contract_test.yaml`
- `tests/scenarios/full.yaml`
- `tests/scenarios/minimal.yaml`
- `tests/snapshots/*.yaml`

## Version Bump Automation

```bash
make bump VERSION=x.y.z
```

This updates `Chart.yaml`, refreshes `Chart.lock`, and regenerates snapshots.

## App-Specific Notes

- Namespace: `media-center`
- Main container runs as UID/GID `20031/20031`
- Config PVC claim: `jellyfin-config` (RWO)
- Image tag is pinned by digest for immutable deploys
- Default service port: `8096`
- Health probes: TCP socket probe on port `8096`
- Default writable mounts: `/config`, `/cache`, and `/tmp`

## Known Limitations

- Media library mounts are intentionally left to user overrides (`persistence.volumes` + matching `workload.spec.containers.jellyfin.volumeMounts`) to keep the base chart simple.
- Metrics integration is intentionally deferred.

## TODOs

- Implement Jellyfin metrics stack (exporter + `ServiceMonitor` + `PrometheusRule` + dashboard wiring).
- Add documented media library mount examples for common NAS layouts.
- Revisit `podSecurityContext.supplementalGroups` and confirm whether Jellyfin should keep both `1010` and `1003` or use a single group.

## References

- https://github.com/jellyfin/jellyfin
- https://jellyfin.org/docs/general/installation/container
- `Chart.yaml`
- `values.yaml`

## Dependency Automation Policy

This repo uses Renovate scoped automerge for low-risk updates only:

- `github-actions`: `digest`, `pin`, `pinDigest`, `patch`, `minor`
- `helmv3` dependencies: `digest`, `pin`, `pinDigest`, `patch`, `minor`
- container image updates (`custom.regex` in `values.yaml`): `digest`, `pin`, `pinDigest`, `patch`, `minor`
- `major` updates are not automerged

Branch protection on `main` is expected to require only the aggregate `ci-required` status before merge.
Recommended contexts:

- `PR Required Checks / ci-required / ci-required (pull_request)`
- `PR Required Checks / ci-required / ci-required (merge_group)`

For Renovate PRs that change `values.yaml`, `.github/workflows/renovate-snapshot-update.yaml` runs `make snapshot-update` and commits updated `tests/snapshots/*` back to the PR branch so strict snapshot checks remain enforced.
