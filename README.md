# Jellyfin Helm Chart

This chart deploys Jellyfin using the shared dependency `lib-chart` (`0.0.14`).

## Installation

```bash
helm install jellyfin . --namespace media-center
```

## Dependencies

- `lib-chart` (`0.0.14`) from `oci://ghcr.io/orhayoun-eevee`

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
- Default writable mounts: `/config`, `/config/data/backups`, `/cache`, and `/tmp`

## Backup Strategy

- Backup scope for this chart is Jellyfin app-state archives only (not source media files).
- Default backup storage is mounted at Jellyfin's native backup path: `/config/data/backups`.
- The chart mounts `backup` NFS volume `snorlax.orhayoun.com:/mnt/vol1/k8s/media-center/jellyfin` at that path.
- Jellyfin restore only reads archives from its backup directory, so mounting `/backup` separately is intentionally avoided.
- Jellyfin Dashboard backup creation includes database content by design; this chart accepts that, while authoritative DB recovery remains out of scope for this chart's backup policy.

### Sonarr/Radarr Comparison

- `sonarr-helm` and `radarr-helm` mount dedicated `/backup` paths.
- `jellyfin-helm` mounts storage directly where Jellyfin creates and restores backups (`/config/data/backups`) to match native behavior.

## Observability

- `metrics.enabled=true` by default and renders:
  - `ServiceMonitor` (native Jellyfin `/metrics` endpoint)
  - `PrometheusRule` (native + platform alerts)
  - `GrafanaDashboard` (`dashboards/app.json`)
- Native Jellyfin metrics are enabled by the chart via container lifecycle hook that updates `EnableMetrics=true` in `/config/config/system.xml` when needed.
- Dashboard and alerts intentionally combine:
  - Jellyfin native Prometheus metrics (`/metrics`)
  - Platform metrics (Istio, cAdvisor, kube-state-metrics, kubelet)
- Prometheus scrape access is allowed via dedicated Istio `ALLOW` policy.
- `deny-metrics-gateway` is disabled by default for ambient mesh compatibility. Enable it only in environments where HTTP-path-aware `DENY` enforcement is available.

## Known Limitations

- Media library mounts are intentionally left to user overrides (`persistence.volumes` + matching `workload.spec.containers.jellyfin.volumeMounts`) to keep the base chart simple.
- Default `workload.spec.podSecurityContext.supplementalGroups` is `1010` (eevee-download-clients). If your environment requires a different media group (for example `1003`), override it in your values.
- In Istio ambient mode, ztunnel cannot enforce HTTP-path-aware `DENY` rules. A `DENY` policy intended only for `/metrics` can become broader than intended.

## Ambient Mesh L7 Guidance

If you need to enforce "deny `/metrics` from gateway, allow Prometheus only" with path-level precision:

1. Move Jellyfin traffic enforcement to an L7-capable data plane (Istio waypoint for the workload).
2. Keep the Prometheus `ALLOW` policy scoped to `/metrics`.
3. Re-enable `network.istio.authorizationPolicy.items.deny-metrics-gateway.enabled=true` only after L7 enforcement is active and verified.

## Media Library Mount Examples

Important behavior: `persistence.volumes` and `workload.spec.containers.jellyfin.volumeMounts` are list fields.
When overriding with Helm values, lists replace defaults, so include the default `config`, `backup`, `cache`, and `tmp` entries in your override.
Use `readOnly: true` for media library mounts.

### Example 1: Single NAS share with subfolders

```yaml
persistence:
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: jellyfin-config
    - name: backup
      nfs:
        server: snorlax.orhayoun.com
        path: /mnt/vol1/k8s/media-center/jellyfin
    - name: cache
      emptyDir:
        sizeLimit: 4Gi
    - name: tmp
      emptyDir:
        sizeLimit: 1Gi
    - name: media
      persistentVolumeClaim:
        claimName: nas-media

workload:
  spec:
    containers:
      jellyfin:
        volumeMounts:
          - name: config
            mountPath: /config
          - name: backup
            mountPath: /config/data/backups
          - name: cache
            mountPath: /cache
          - name: tmp
            mountPath: /tmp
          - name: media
            mountPath: /media/movies
            subPath: Movies
            readOnly: true
          - name: media
            mountPath: /media/tv
            subPath: TV
            readOnly: true
          - name: media
            mountPath: /media/music
            subPath: Music
            readOnly: true
```

### Example 2: Separate PVC per media library

```yaml
persistence:
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: jellyfin-config
    - name: backup
      nfs:
        server: snorlax.orhayoun.com
        path: /mnt/vol1/k8s/media-center/jellyfin
    - name: cache
      emptyDir:
        sizeLimit: 4Gi
    - name: tmp
      emptyDir:
        sizeLimit: 1Gi
    - name: movies
      persistentVolumeClaim:
        claimName: nas-movies
    - name: tv
      persistentVolumeClaim:
        claimName: nas-tv
    - name: music
      persistentVolumeClaim:
        claimName: nas-music

workload:
  spec:
    containers:
      jellyfin:
        volumeMounts:
          - name: config
            mountPath: /config
          - name: backup
            mountPath: /config/data/backups
          - name: cache
            mountPath: /cache
          - name: tmp
            mountPath: /tmp
          - name: movies
            mountPath: /media/movies
            readOnly: true
          - name: tv
            mountPath: /media/tv
            readOnly: true
          - name: music
            mountPath: /media/music
            readOnly: true
```

### Example 3: SMB/CIFS-backed PVC with subfolders

```yaml
persistence:
  volumes:
    - name: config
      persistentVolumeClaim:
        claimName: jellyfin-config
    - name: backup
      nfs:
        server: snorlax.orhayoun.com
        path: /mnt/vol1/k8s/media-center/jellyfin
    - name: cache
      emptyDir:
        sizeLimit: 4Gi
    - name: tmp
      emptyDir:
        sizeLimit: 1Gi
    - name: media-cifs
      persistentVolumeClaim:
        claimName: nas-cifs-media

workload:
  spec:
    containers:
      jellyfin:
        volumeMounts:
          - name: config
            mountPath: /config
          - name: backup
            mountPath: /config/data/backups
          - name: cache
            mountPath: /cache
          - name: tmp
            mountPath: /tmp
          - name: media-cifs
            mountPath: /media/movies
            subPath: Movies
            readOnly: true
          - name: media-cifs
            mountPath: /media/tv
            subPath: TV
            readOnly: true
```

## References

- https://github.com/jellyfin/jellyfin
- https://jellyfin.org/docs/general/installation/container
- https://jellyfin.org/docs/general/server/backups
- https://jellyfin.org/docs/general/administration/migrate
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

For same-repo Renovate PRs that change render inputs such as `Chart.yaml`, `Chart.lock`, `values.yaml`, `templates/**`, `charts/**`, or `tests/scenarios/**`, `.github/workflows/renovate-snapshot-update.yaml` runs `make snapshot-update` and writes updated `tests/snapshots/*` back to the same PR branch so strict snapshot checks remain enforced without opening a second PR.
