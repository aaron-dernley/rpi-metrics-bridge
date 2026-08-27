# rpi-metrics-bridge

A [Swamp](https://github.com/swamp-club/swamp) workflow that turns the
`@aaronge/rpi-*`/`@aaronge/host-health`/`@aaronge/apt-inventory` extension
family into a Grafana dashboard. This repo publishes no extension of its
own — it exists purely to pull the 10 already-published extensions, read
their latest data every minute, and write it as a Prometheus
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
instance you might already be running elsewhere (e.g. `apt-local` also
exists standalone in the `apt-inventory` repo as a `swamp serve` daemon;
the two don't interact).

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
| `apt_autoremove_pending` | apt-inventory | |
| `apt_upgrades_pending{arch,origin}` | apt-inventory | labeled per repo origin |
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
  collides with `apt-inventory`'s own persistent `swamp serve` daemon on
  this machine. See `/etc/prometheus/prometheus.yml`.
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

Every minute via `systemd.timer`, not a persistent `swamp serve` daemon —
same reasoning as the rest of this family (~400MB resident per idle daemon
vs. ~0MB between runs for a oneshot timer):

```
# /etc/systemd/system/swamp-workflow-rpi-metrics-bridge.service
[Unit]
Description=swamp workflow run metrics-export (rpi-metrics-bridge)

[Service]
Type=oneshot
User=aaronge
Group=aaronge
Environment=HOME=/home/aaronge
Environment=XDG_RUNTIME_DIR=/run/user/1000
WorkingDirectory=/home/aaronge/Repositories/rpi-metrics-bridge
ExecStart=/usr/local/bin/swamp workflow run metrics-export --repo-dir /home/aaronge/Repositories/rpi-metrics-bridge
```

```
# /etc/systemd/system/swamp-workflow-rpi-metrics-bridge.timer
[Unit]
Description=Timer for swamp workflow run metrics-export (rpi-metrics-bridge)

[Timer]
OnCalendar=*-*-* *:*:00
# No Persistent=true: a missed minute's sample isn't worth backfilling the
# way a missed assertion check is.

[Install]
WantedBy=timers.target
```

**`XDG_RUNTIME_DIR` is required** — `readConnect` (`rpi-connect status`)
talks to `rpi-connectd` over a per-user runtime socket; without this env
var it fails with "Raspberry Pi Connect is not running" on a system-level
unit even when the service is genuinely up, since such units don't inherit
a login session's environment. Same gotcha documented in the `rpi-connect`
repo's own README, hit again here and now fixed the same way.

No `--fail-on` flag needed on `ExecStart` — unlike `rpi-workflows`' assert-
based workflows, `metrics-export` has no `assert` steps, so `allowFailure:
true` on a plain step genuinely keeps `swamp workflow run`'s exit code at
0 even when a source fails. Confirmed both by deliberately breaking a
source's binary path during development and by a real `readConnect`
failure caught on the first live timer run — both times the workflow
still exited 0 and the `.prom` file still got written.

`systemctl enable --now swamp-workflow-rpi-metrics-bridge.timer`. Verify
with `systemctl list-timers 'swamp-workflow-rpi-metrics-bridge*'` and
`journalctl -u swamp-workflow-rpi-metrics-bridge.service`.

## License

MIT — see LICENSE for details.
