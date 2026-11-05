# Swamp ops best practices (this Pi)

This repo is the Pi's single ops repo. It pulls the `@aaronge/*` packages,
and one `swamp serve` runs every scheduled workflow. This file summarises
what the swamp-club.com manual says about running that setup. Each section
cites its source page. It was gathered on 2026-11-05 against swamp
`20261102.060634.0`. Re-check a page before relying on a detail that may
have moved.

## Why one ops repo and one serve

- `swamp serve` serves one repo per process. Each idle serve here costs
  about 160 MB (RSS plus swap). Fifteen of them would sit at about 2.4 GB.
- Telemetry, and so leaderboard activity, counts runs, not processes.
  serve records "one event per workflow run and per behavior method run it
  executes, plus one event for the server process when it exits".
  (manual/reference/usage-telemetry-events)
- One serve means one concurrency cap. Separate serves can't coordinate,
  and uncoordinated timers are what overloaded the Pi on 2026-11-05.

## Scheduling (manual/how-to/run-workflows-on-a-schedule)

- Set `trigger.schedule` in the workflow, as 5-field cron. Scheduled runs
  only fire while `swamp serve` is running. `--no-schedule` turns them off.
- `trigger.inputs` is the baseline for scheduled runs. Precedence is
  caller inputs > trigger.inputs > schema defaults.
- Concurrency defaults to **one scheduled workflow at a time**. Raise it
  with `max-concurrent-scheduled-runs` in `.swamp/serve.yaml`; it's read
  at startup. A workflow never overlaps itself: a fire that arrives while
  the same workflow is still running is skipped with a warning.
- To override a pulled workflow's schedule without editing the package,
  run `swamp workflow trigger set <name> --schedule "*/15 * * * *"`. It
  writes to `serve.yaml`. Each `set` replaces the previous override rather
  than merging. Inspect with `trigger get`; revert with `trigger remove`.
  (manual/reference/workflows, manual/reference/swamp-serve/serve-flags)
- Watch for overload: `GET /api/v1/health` (authenticated) includes
  `scheduling.schedules[]` with `queued`, `oldestQueuedAt` and
  `lastQueueDelayMs`. If `oldestQueuedAt` keeps growing, schedules fire
  faster than the Pi can run them, so back the cadence off.

## Serve as a service

- swamp ships its own daemon manager, which is EXPERIMENTAL:
  `swamp serve daemon enable`. The generated Linux unit uses
  `Restart=always` and `RestartSec=10`. Without `--user` it goes to
  `/etc/systemd/system/` and starts at boot.
  (manual/reference/swamp-serve/daemon, manual/how-to/swamp-serve/run-as-system-daemon)
- A hand-written unit must set `HOME`, or `SWAMP_HOME` plus
  `SWAMP_CONFIG_DIR`. Otherwise pulled-extension workflows fail with
  `Unknown model type`.
- Every swamp process needs a swamp-club credential. The cached proof
  expires if the user runs nothing for 14 days. A busy serve keeps it
  fresh; an idle Pi may need `SWAMP_API_KEY`.
- serve raises its open-file limit to 8192 when the hard limit allows.
  Otherwise set `LimitNOFILE=8192`.
- `--max-run-duration` aborts runs that exceed a wall-clock limit. The docs
  say it applies to detached runs, so check that it also covers scheduled
  runs.
- `--hot-reload` plus `swamp serve reload` picks up pulled-extension
  updates and trigger overrides without a restart.

## Data growth and GC (manual/reference/repository-configuration, manual/explanation/data-lifetimes)

- Extensions declare `garbageCollection: N` (a cap on versions kept). That
  cap is **not enforced unless something runs GC**. On 2026-11-05, this
  repo had 2.85 M versions (41.6 GB) over its caps, and that backlog made
  metrics-export run out of memory.
- Fix: set `garbageCollection.automatic: true` in `.swamp.yaml`. serve then
  runs a GC pass 5 minutes after start and hourly after that. Data
  versions can also be pruned at write time with `autoGc: true`.
- Don't set the `data:` retention key unless the data can be regenerated.
  It is a hard maximum age that can delete the latest version too.
- Check with `swamp doctor datastores --retention`. Preview with
  `swamp data gc --dry-run` and `swamp run gc --dry-run`.

## Idempotency and recovery (manual/how-to/make-workflows-idempotent)

- A step's `guard: "${{ <CEL> }}"` skips the step when true. A CEL error in
  a guard fails the step.
- Scheduled runs don't auto-resume. Use `swamp workflow resume <wf> --run <id>`
  (`--from <step>`) or `swamp workflow recover <wf>`.
- For stale or orphaned runs: `swamp run doctor`, then `swamp run doctor --fix`.

## Locks and concurrency

- Two workflows that use the same behavior take turns via the per-behavior
  lock. Prefer one fan-out method over many parallel calls (repo
  CLAUDE.md rule 6).
- A workflow's `concurrency:` (job or step level) caps parallel steps.
  Unset means unbounded. On a 4-core Pi, set it for wide collect jobs.
- `SWAMP_MAX_CONCURRENT_STEPS` sets a host-wide ceiling on parallel steps.

## Shipping workflows in a package (manual/reference/extensions/manifest)

- List the files under `workflows:` in `manifest.yaml`. The registry
  requires scoped names, so workflows are named `@aaronge/<name>`.
- Model names referenced by shipped workflows must exist in the consuming
  repo. Every rpi-* workflow therefore uses the ops repo's instance names
  (`health-local`, `pcie-local` and so on), not a generic `rpi-local`.
- Pin with the committed `extensions/models/upstream_extensions.json`.
  `swamp extension outdated` exits 1 when updates exist.

## Telemetry (manual/how-to/turn-off-usage-telemetry)

- Keep it on. It is what reports activity. Never add `--no-telemetry`,
  `SWAMP_NO_TELEMETRY` or `DO_NOT_TRACK` to the serve unit or to scripts.

## Not covered by the docs

There is no Raspberry Pi or small-host guidance and no Prometheus
`/metrics` endpoint, and the docs don't say how to set the schedule time
zone. serve reports `timeZone` in its health output, so check it there.
