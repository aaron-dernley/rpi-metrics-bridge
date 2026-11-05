# rpi-metrics-bridge

This Pi's single [Swamp](https://github.com/swamp-club/swamp) ops repo.
One `swamp serve` here runs every scheduled `@aaronge/*` workflow (see
[Scheduling](#scheduling)), and its own `metrics-export` workflow turns
the `@aaronge/rpi-*`/`@aaronge/host-health`/`@aaronge/apt-inventory`
extension family into a Grafana dashboard. This repo publishes no
extension of its own. It pulls the published extensions, reads their
latest data every 5 minutes, and writes it as a Prometheus
textfile-collector `.prom` file for `node_exporter` to serve. Prometheus
scrapes `node_exporter`; Grafana queries Prometheus. No Pushgateway: a
long-running textfile collector gets Prometheus's native staleness/
target-down detection for free, which a push-based approach would give up.

## Pulled extensions and model instances

| Instance           | Type                        |
| ------------------- | ------------------------------ |
| `health-local`      | `@aaronge/rpi-health`          |
| `host-local`        | `@aaronge/host-health`         |
| `bootconfig-local`  | `@aaronge/rpi-boot-config`     |
| `cooling-local`     | `@aaronge/rpi-cooling`         |
| `pcie-local`        | `@aaronge/rpi-pcie`            |
| `apt-local`         | `@aaronge/apt-inventory`       |
| `rtc-local`         | `@aaronge/rpi-rtc`             |
| `connect-local`     | `@aaronge/rpi-connect`         |
| `gpio-local`        | `@aaronge/rpi-gpio-inventory`  |
| `camera-local`      | `@aaronge/rpi-camera`          |

Set up via `swamp extension pull @aaronge/<name>` +
`swamp model create @aaronge/<name> <instance>` for each row above — this
repo has its own independent instances, separate from any same-named
instance in the extensions' own source repos.

The other pulled packages' workflows need these instances too:
`washing`, `anchor` (plus the `news-secrets` vault, copied over by
`scripts/migrate-secrets.sh`), `daily`, `my-location`, `my-host`, `loki`,
`prom` and `unit-swamp-serve`.

## Metric naming scheme

Prefix identifies the source extension, not the local instance name:
`rpi_` for Pi-specific data, `host_`/`apt_` for data that isn't
Pi-specific. Unit suffixes match the field's actual unit (`_celsius`,
`_volts`, `_watts`, `_hertz`, `_bytes`, `_seconds`, `_percent`); bare
counts get no suffix.

**Percent fields stay native 0–100** (`_percent`), not converted to a 0–1
`_ratio` — matches every source field's own range.

**Booleans are named so `1` reads as the alarming/notable state** —
`_stalled`, `_degraded`, `_since_boot` — not `_ok`/`_healthy`, so
`sum(rpi_cooling_fan_stalled) > 0` is directly usable as an alert
expression. The one deliberate exception is `rpi_health_throttle_healthy`,
which mirrors the source field's own polarity because inverting a field
called `healthy` would be more confusing than useful.

## Exported metrics

| Metric | Source | Notes |
| -------- | -------- | ------- |
| `rpi_health_core_temp_celsius` | rpi-health | |
| `rpi_health_core_volts` | rpi-health | |
| `rpi_health_arm_hertz` | rpi-health | |
| `rpi_health_supply_volts` | rpi-health | nullable |
| `rpi_health_pmic_battery_volts` | rpi-health | nullable |
| `rpi_health_estimated_total_watts` | rpi-health | |
| `rpi_health_throttle_healthy` | rpi-health | 1 = no fault now or since boot |
| `rpi_health_undervoltage_since_boot` | rpi-health | sticky fault bit |
| `rpi_health_throttled_since_boot` | rpi-health | sticky fault bit |
| `rpi_health_arm_freq_capped_since_boot` | rpi-health | sticky fault bit |
| `rpi_health_soft_temp_limit_reached_since_boot` | rpi-health | sticky fault bit |
| `rpi_cooling_fan_rpm` | rpi-cooling | |
| `rpi_cooling_fan_pwm_percent` | rpi-cooling | |
| `rpi_cooling_fan_stalled` | rpi-cooling | |
| `rpi_cooling_state` / `rpi_cooling_max_state` | rpi-cooling | nullable |
| `rpi_pcie_link_degraded` | rpi-pcie | per-device detail deferred |
| `rpi_boot_config_eeprom_content_hash` | rpi-boot-config | first 32 bits of `sha256(config fields)`; `changes(...[24h]) > 0` detects drift |
| `host_root_used_percent` / `host_worst_used_percent` | host-health | |
| `host_memory_used_percent` / `host_swap_used_bytes` | host-health | |
| `host_max_thermal_celsius` | host-health | nullable |
| `host_load1` / `host_load5` / `host_load15` | host-health | unitless, matches `node_load1` convention |
| `host_load5_per_core_ratio` | host-health | |
| `host_runnable_procs` / `host_total_procs` | host-health | |
| `apt_installed_packages` | apt-inventory | |
| `apt_upgradable_packages` / `apt_security_upgradable_packages` | apt-inventory | |
| `apt_vulnerabilities_total` / `apt_vulnerabilities_actionable` / `apt_vulnerabilities_false_positive` | apt-inventory | debsecan-based CVE scan; only `actionable` (fixAvailableInSuite && !actuallyFixed) is a real, currently-fixable count — see apt-inventory's own `actuallyFixed` doc for why `false_positive` is usually nonzero |
| `rpi_rtc_drift_seconds` | rpi-rtc | |
| `rpi_rtc_battery_volts` | rpi-rtc | nullable |
| `rpi_rtc_system_clock_synchronized` | rpi-rtc | nullable |
| `rpi_connect_signed_in` | rpi-connect | nullable |
| `rpi_gpio_pin_count` | rpi-gpio-inventory | |
| `rpi_camera_count` | rpi-camera | |
| `rpi_camera_output_recognized` | rpi-camera | nullable |
| `rpi_metrics_bridge_capture_age_seconds{source}` | this bridge | see Staleness below |

Every array/per-item field (per-mount, per-rail, per-clock-domain,
per-PCI-device, per-GPIO-pin, per-package) and every free-text field
(`raw*`, `firmwareVersion`, config dumps) is deferred to a v2 — v1 covers
scalar gauges and the handful of hoisted array aggregates only.

**Nullable fields produce an absent series when null**, never a sentinel
0/false — matches this whole extension family's "null means unknown"
convention. A blank line in Prometheus text-exposition format is legal and
ignored, so the metric simply doesn't appear that scrape.

## Staleness handling

Two layers:

1. **Free** — `node_exporter`'s textfile collector emits
   `node_textfile_mtime_seconds{file=".../rpi_metrics.prom"}` automatically.
   Since the export step atomically renames the file only on a completed
   run, `time() - node_textfile_mtime_seconds{...} > 300` is a correct
   bridge-liveness alert with zero extra work.
2. **Custom** — file mtime alone can't tell "the whole bridge is stuck"
   apart from "the export ran fine but one source's `readXxx` failed, so
   that source's fields are silently repeating an old value."
   `rpi_metrics_bridge_capture_age_seconds{source="<instance>"}` = `now -
   capturedAt` for every one of the 10 sources — `max(...) > N` covers all
   of them with one alert rule.

## Workflow

`workflows/workflow-metrics-export.yaml` — two jobs, no `assert` steps
anywhere:

- **`collect`** — runs the read method on all 10 instances in parallel.
  Every step has `allowFailure: true`: one dead sensor must not blank the
  whole metrics file, it should just leave that source's fields stale
  (visible via `capture_age_seconds`).
- **`export`** — `dependsOn: [job: collect, condition: completed]` (not
  `succeeded`), so it always runs even if a `collect` step failed. One
  `command/shell` step interpolates every field via CEL, writes to a
  `mktemp` temp file in the destination directory, `chmod 644`s it (the
  `prometheus` system user needs to read it, and `mktemp` defaults to
  0600), then atomically `mv -f`s it into place. Same-directory temp file
  is required for the `mv` to be an atomic same-filesystem rename —
  `node_exporter` globs and parses every `.prom` file on each scrape, and
  a write caught mid-flight would fail to parse *entirely*, not just the
  affected lines.

Run by hand: `swamp workflow run metrics-export`.

## Infra

- `prometheus` + `prometheus-node-exporter` (`apt install`).
  `node_exporter`'s `--collector.textfile.directory` is set to
  `/var/lib/prometheus/node-exporter` in
  `/etc/default/prometheus-node-exporter` — this is Debian's own
  `prometheus-node-exporter-collectors` package convention (it drops
  `apt.prom`/`nvme.prom`/etc there too), reused rather than inventing a
  separate directory, since `node_exporter` only supports one textfile
  directory.
- **Prometheus listens on `127.0.0.1:9099`, not the default 9090** — 9090
  is this repo's own `swamp serve`. See `/etc/prometheus/prometheus.yml`.
- `grafana` (own APT repo — not in default Debian repos):
  `apt.grafana.com`. The Prometheus datasource is provisioned as code at
  `/etc/grafana/provisioning/datasources/prometheus.yaml`, pointed at
  `http://localhost:9099`.
- The starter dashboard (`dashboards/rpi-metrics-bridge.json`, committed
  here) is provisioned directly from this repo's path via
  `/etc/grafana/provisioning/dashboards/rpi-metrics-bridge.yaml` — the
  committed JSON is the single source of truth, no separate copy to keep
  in sync. Debian's `grafana-server.service` hardens with
  `ProtectHome=true` by default, which makes `/home` invisible to the
  process regardless of file permissions; a drop-in at
  `/etc/systemd/system/grafana-server.service.d/override.conf` narrows
  this to `ProtectHome=read-only` (Grafana only ever reads the dashboard
  file, never writes into `/home`).

## Scheduling

One persistent `swamp serve` for this repo runs every workflow below on
its `trigger.schedule`. It replaced 16 per-repo `swamp-workflow-*`
systemd timers on 2026-11-05. Those timers started a fresh swamp process
for every run (15–30 s of CPU and 250–450 MB each) and overloaded the Pi.
Under serve a typical run takes 1–2 s. See
`docs/swamp-ops-best-practices.md` for the reasoning and the swamp-club
manual references.

- **Service:** installed by
  `swamp serve daemon enable --repo-dir <this repo> --config serve.yaml`
  as the user unit `swamp-serve.service`, with
  `loginctl enable-linger aaronge` so it starts at boot. As a user unit it
  gets `XDG_RUNTIME_DIR` from the user manager, which `readConnect` needs
  (`rpi-connect status` talks to `rpi-connectd` over a per-user socket).
  Manage it with `systemctl --user {status,restart} swamp-serve` and
  `journalctl --user -u swamp-serve`.
- **`serve.yaml`** (repo root, version-controlled): port 9090, one
  scheduled run at a time, a 15-minute `max-run-duration` and hot-reload.
  A `triggers:` block there overrides a pulled workflow's schedule or
  inputs without republishing it. Today it turns off rpi-rtc's battery
  assert (`lowBatteryVolts: 0`, because no coin cell is fitted; its drift
  check still runs), runs the three daily inventories hourly, and runs
  fleet-health every 5 minutes.
- **GC:** `.swamp.yaml` sets `autoGc: true`, which applies each
  extension's declared version caps at write time, and
  `garbageCollection.automatic`, which runs an hourly retention pass.
  Before this, 2.85M stale versions (41.6 GB) built up until
  `metrics-export` ran out of memory.

| Workflow | Schedule | Source |
| --- | --- | --- |
| `metrics-export` | `*/5 * * * *` | this repo |
| `apt-vulnerability-scan` | `*/15 * * * *` | this repo |
| `thermal-integrity`, `power-integrity`, `link-integrity` | `*/5 * * * *` | this repo (moved from `rpi-workflows`) |
| `@aaronge/rpi-health`, `rpi-connect`, `rpi-cooling`, `rpi-pcie`, `rpi-rtc`, `host-health` | `*/5 * * * *` | pulled packages (rpi-rtc's battery assert off via `serve.yaml`) |
| `@aaronge/rpi-boot-config`, `rpi-camera`, `rpi-gpio-inventory` | hourly at :17 / :51 / :43 | pulled packages (daily by default; hourly via `serve.yaml`) |
| `@aaronge/apt-report` | `0 6,12,20 * * *` | pulled package |
| `@aaronge/fleet-health` | every 5 min at :03, :08, … | pulled package (every 10 min by default; `serve.yaml` override; watches `unit-swamp-serve`) |
| `@aaronge/iss-tracker` | `3-59/5 * * * *` | pulled package |
| `@aaronge/washing-forecast` | `0 6,9,12,17 * * *` | pulled package |
| `@aaronge/github-trending` | `20 */3 * * *` | pulled package |
| `@aaronge/package-archaeology` | `15 7 * * *` | pulled package |
| `@aaronge/morning-broadcast` | `0 8 * * *` | pulled package |

Schedules don't need staggering: serve queues fires that coincide and runs
them one at a time. The :00 batch of 11 workflows finishes in about 40 s.
If `/api/v1/health` ever shows `oldestQueuedAt` growing, back a cadence
off with `swamp workflow trigger set <name> --schedule ...`.

`metrics-export` has no `assert` steps, so `allowFailure: true` on its
collect steps keeps the run successful even when a source fails, and the
`.prom` file still gets written.

## License

MIT — see LICENSE for details.
