# librescoot-events (event-service)

## Description

event-service turns existing Redis traffic into a normalised event bus and
runs user-defined rules against it. It has two halves:

- An **adapter** that watches a fixed set of hashes and channels other
  services already write to, and derives `topic`/`from`/`to` events from the
  transitions it sees there (vehicle state, seatbox, kickstand, handlebar
  lock, blinkers, battery presence and charge, alarm status, power state,
  OTA status, keycard auth, motion detection, incoming SMS, dashboard
  readiness, and button gestures). It writes nothing to those hashes and
  derives no state of its own; it only observes and republishes.
- A **rules engine** that lets a user attach one or more actions, run in
  sequence, to any event topic, entirely from TOML files, with no service of
  their own to write or deploy.

With no rule files present, event-service subscribes to nothing beyond what
the adapter itself needs, so a scooter carrying no extensions pays no cost
for the rules engine at all.

## Version

Tracks `main` on `github.com/librescoot/event-service`.

## Command-Line Options

```
--redis <addr>               Datastore address (default: localhost:6379)
--log-level <level>          debug, info, warn, error (default: info)
--rules-dir <path>           Directory of rule TOML files (default: /data/extensions)
--workers <n>                Action worker count (default: 2)
--queue <n>                  Action queue depth (default: 256)
--replay-window <duration>   How far past due a recorded step may be and still
                              run at start (default: 5m). Zero or less replays
                              only steps still in the future.
--stats-interval <duration>  How often the extensions hash counters are
                              refreshed (default: 10s). A non-positive value
                              logs a warning and falls back to the default.
```

`--log-level` is parsed and printed at startup but does not currently gate
anything: every log line, including the ones prefixed `debug:`, is written
regardless of the flag's value.

A missing `--rules-dir` is not an error; it is the normal state of a scooter
with no extensions installed.

## Redis Operations

### Stream: `events`

Every event the adapter derives is appended here. Rules do not publish new
events; they only act on the ones already on the bus. Capped stream, newest
2000 entries kept. Each entry is the JSON form of the event envelope below.

```bash
redis-cli xrevrange events + - COUNT 10
```

### Pub/Sub: `ev:<topic>`

Every event on the stream is also published on a channel named `ev:` plus
its topic, so a consumer can subscribe to exactly the topics it needs instead
of tailing the whole stream.

```bash
redis-cli psubscribe 'ev:*'
redis-cli psubscribe 'ev:alarm.*'
```

event-service itself subscribes only to the `ev:` patterns at least one
loaded, enabled rule's `on` or `cancel-on` actually names. Rules are read
once, at startup, and the subscription set is computed from them there and
then; there is no reload and no signal that rereads them, so a change under
`--rules-dir` takes effect at the next service restart. With zero rules
loaded there is no subscription at all.

### Hash: `extensions`

Rule-engine counters, refreshed at `--stats-interval` and written once in
full at startup so every field, including `version`, is present from the
first read. After that, only fields whose value changed are written.

| Field | Meaning |
|---|---|
| `rules` | how many rules compiled and are currently live |
| `dispatched` | actions handed to a worker since start |
| `dropped` | actions the worker pool refused because its queue was full or it was shutting down; the operator's lever is `--workers` / `--queue` |
| `refused` | triggers a `queue`-concurrency rule turned away because that rule's own backlog (capped at 8) was already full; the lever is that rule's own sequence, not the worker pool |
| `failed` | actions that ran and returned an error |
| `pending` | timers armed right now: steps waiting out an `after`, gaps between `repeat` passes, and `debounce` quiet windows. Observability only; a fire leaves the count the moment it is claimed, so `0` does not mean nothing is in flight |
| `runs-active` | sequence runs part-way through their steps, including ones parked on a timer. A trigger sitting in a `queue` backlog has not started and is not counted here |
| `version` | build version; constant for the life of the process |

`dropped` and `refused` are two different failure modes and are kept as
separate fields on purpose: one is the shared worker pool running out of
room, the other is one rule's own backlog filling up, and they point at
different fixes.

### Hash: `extensions:pending`

One field per waiting durable step, keyed by an internal run id, JSON-encoded.
There is no sweep and no expiry: a record is written when a durable step is
scheduled and removed the moment it fires or is cancelled, so a scooter with
nothing running writes nothing here at all. See [Durability](#durability)
below for what ends up in it and when it is dropped instead of replayed.

## Event Envelope

```json
{
  "id": "1712345678901-0",
  "ts": 1712345678901,
  "topic": "battery.charge.changed",
  "src": "adapter",
  "from": "52",
  "to": "51",
  "data": {"slot": 0}
}
```

`id` is assigned by the datastore when the event is appended to the stream
and is empty on events a rule only sees through the channel. `from`/`to` are
pulled out of `data` because "changed from X to Y" is the shape most rules
match on. `src` is `adapter` for everything event-service derives itself.

## Rules

TOML files under `--rules-dir`, one or more `[[rule]]` blocks per file,
loaded and compiled at startup. A file that fails to parse, or that contains
a key nothing recognises, is rejected file by file: the rest still load,
because losing every rule over one typo in one file is worse than running a
subset.

```toml
[[rule]]
name        = "hazards-on-alarm"
on          = ["alarm.triggered"]
concurrency = "restart"
cancel-on   = ["alarm.disarmed"]

  [[rule.step]]
  do   = "redis"
  list = "scooter:blinker"
  push = "both"

  [[rule.step]]
  after = "30s"
  do    = "redis"
  list  = "scooter:blinker"
  push  = "off"
```

On the alarm, the hazards go on immediately; thirty seconds later the second
step turns them off, unless `alarm.disarmed` cancels the run first.

`on` matches a topic exactly, with `*` for everything or `prefix.*` for
anything starting with `prefix.`. Mid-pattern globs are not supported: a
pattern matches literally or not at all, so a typo in a topic name fires
nothing rather than something unintended. `when`, at rule level or step
level, is an `expr` expression compiled once at load, evaluated against
`topic`, `src`, `from`, `to`, `data`, and `state("hash", "field")` for the
last value event-service's own shadow store observed for a hash field the
event itself does not carry. A rule with no `when` fires on every event `on`
matches; a step with no `when` always runs once it is reached.

### Step sequences

A rule can carry several `[[rule.step]]` blocks. They run strictly in order:
a step is submitted only once the one before it finished, and a step that
fails ends the run, with the remaining steps not run. A sequence is a recipe,
so carrying on past a failed step would act on a state that step never
established.

A step may carry `after`, a duration that delays it relative to the step
before it finishing. A step waiting out `after` holds no worker thread; it
sits on a scheduler timer, so a rule can say "and thirty seconds later, turn
it off" without occupying anything for the wait.

### Durability

A step with `after` is `durable` by default. The waiting step is written to
the `extensions:pending` hash the moment it is scheduled and removed when it
fires or is cancelled, so a service restart between "hazards on" and
"hazards off thirty seconds later" does not leave the vehicle half-changed.
On the next start, a recorded step whose delay already ran out fires
immediately; one still in the future waits out what is left, both before the
bus subscription reopens. A rule with `repeat` resumes on the pass it was on.

A record is dropped instead of replayed, with a log line saying why, if its
rule is no longer loaded, if that rule no longer has a step at the recorded
index, if the step at that index was reconfigured while the service was
down, if it is more than `--replay-window` (default 5 minutes) past due, or
if it is dated further ahead than the step's own `after` could ever put it,
which is what a clock that ran backwards over the restart leaves behind.
Editing rule files while the service is down is expected: a record
identifies its step by what that step was configured to do, not just its
position, so reordering or rewriting steps drops the stale record instead of
firing whatever now sits at the same index. A replay window of zero or less
replays only what is still in the future, so a scooter that was off for a
week does not come back up acting on what it was doing when it went down.

Records go through the rule's `concurrency` policy the same way a live
trigger does, so a rule that ends up with two records resumes one run rather
than two. A step that comes due while the action pool has no room for it
keeps its record: the step provably did not run, so the next start is what
runs it, and the same holds for a step still queued in the pool when the
service is stopped.

Write `durable = false` on a step to opt out. `durable` on a step with no
`after` is a load error: there is no wait for it to mean anything about.
Nothing is recorded for the gap between `repeat` passes or for a trigger
sitting in a `queue` backlog; neither has acted on the vehicle yet, so
neither needs to survive a restart.

### Concurrency and cancellation

`concurrency` decides what a fresh trigger does to a run of the same rule
that has not finished:

- `restart` (default): drop the pending tail of the live run and start over.
- `drop`: ignore the trigger while a run is live; the rule fires normally
  again once that run ends.
- `queue`: hold the trigger and run the sequence again once the live run has
  finished, so runs go back to back rather than side by side. The backlog is
  capped at 8 per rule; anything past that is refused, counted in `refused`,
  and logged.

`cancel-on` takes topics in the same form as `on`. A matching event drops
every live run of that rule: pending timers are cancelled, the queued
backlog is thrown away, and no further step is submitted. It is applied
before matching, so one event can cancel one rule and fire another in the
same pass.

A step already handed to the worker pool when the cancel arrives is **not**
interrupted, whether a worker is already running it or it is still waiting
its turn in the pool's queue. A `redis` push or `exec` command already
accepted completes. What cancelling guarantees is that no step after it
runs.

### Repeat

`repeat = { count = 3, every = "700ms" }` at rule level runs the whole step
sequence again once it finishes, `count` times total, waiting `every`
between one pass ending and the next starting. With no `repeat` key, or
`count = 1`, a rule runs a single pass. `every` only has to be set, and only
has to be positive, once `count` is greater than 1. The gap between passes is
not durable, only a step's own `after` is: a restart during the gap simply
ends the run on the pass it had reached.

### Cooldown and debounce

`cooldown` (a duration) is a leading-edge suppressor: the first event of a
burst fires the rule immediately, and any further match within the window is
ignored outright.

`debounce` (a duration) is a trailing edge: nothing fires while matching
events keep arriving, each one restarting the window, and once the window
elapses without another match the rule fires exactly once, carrying the most
recent event seen rather than the one that opened the window.

They compose rather than conflict. With both set, `cooldown` is checked
against the debounced dispatch itself, not against each event that only
restarted the quiet window, so a burst that never goes quiet long enough to
satisfy `debounce` never reaches `cooldown` at all.

### Naming and load errors

A rule's `name` must be unique across every file in the directory: it is the
handle a rule's runs, concurrency policy and `cancel-on` list are grouped
under, so two rules sharing one name would fight over all three. The second
definition of a name fails to load with an error naming both files; the
rest of both files still load. A disabled rule (`enabled = false`) claims no
name, and neither does a rule that fails to compile, so an old copy kept
around under `enabled = false` while a variant is tried, or a fix landing
under the name a broken rule already failed to claim, both work as expected.

`can`, `lua` and `http` step kinds are not supported yet; a rule naming one
fails to load. An unrecognised `concurrency` value is rejected the same way,
naming the rule, the file, and the three accepted values.

## Actions

- `redis`: `LPUSH` a fixed value (`push`) onto an existing list (`list`).
  One datastore round trip, no process spawned; the default choice for
  anything that stays on the vehicle.
- `exec`: run `command` with a `timeout` (default `10s`). The event is on
  stdin as JSON, plus environment variables `LS_TOPIC`, `LS_SRC`, `LS_FROM`,
  `LS_TO`, `LS_ID`, and one `LS_DATA_<KEY>` per scalar `data` field, so a
  short shell script needs no JSON parser. The command runs in its own
  process group; the hard timeout kills the whole group, not just the
  direct child.
- `can`, `lua`, `http`: designed, not built. See `EVENT-SERVICE-DESIGN.md`.

## Safety

There is no allowlist, no rate limit, and no interlock on what a rule can
do. A `redis` step can push onto `scooter:state`, `scooter:horn`,
`scooter:blinker`, `scooter:seatbox`, or any other command queue, exactly as
freely as vehicle-service's own legitimate callers can. Two rules can watch
each other's output topics and cycle a command back and forth indefinitely,
including through the steering lock; nothing here detects or breaks that
loop. The extension subsystem is a power-user feature by design, and it is
deliberately not event-service's job to second-guess what a rule tells the
vehicle to do.

Durability extends the same stance across a restart. A step with `after`
survives the service going down and finishes on the next start, so a rule
nobody retriggered this session, left waiting from before the restart, can
still push to a command queue once the service is back up, with nothing in
between that the rider watching the vehicle now would connect to it. That is
intentional: durability exists so a sequence that already told the vehicle
to do half of something finishes the other half, and there is no separate
check asking whether it still should. Do not write an `after` step onto a
command queue that should not fire from something that happened before the
current rider ever saw the vehicle.

## Installation

**Unit file:** `librescoot-events.service`

```ini
[Unit]
Description=Librescoot Event Service
After=valkey.service
Wants=valkey.service

[Service]
Type=simple
ExecStart=/usr/bin/event-service \
    --redis=localhost:6379 \
    --log-level=info
Restart=always
RestartSec=5
User=root

Nice=5
CPUWeight=20
MemoryMax=48M
TasksMax=64

StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

The resource caps (`Nice`, `CPUWeight`, `MemoryMax`, `TasksMax`) are meant to
make the extension subsystem structurally incapable of starving
vehicle-service, regardless of what a rule set does. `--rules-dir` is not
passed, so the compiled-in default (`/data/extensions`) applies.

## Dependencies

- **Redis (valkey)** - for the event stream, the `ev:*` channels, the
  `extensions` and `extensions:pending` hashes, and reading the hashes the
  adapter watches.
- **Whatever hash or command queue a rule's `redis` step targets** - the
  rules engine does not own those queues; it pushes onto them the same way
  any other client would.

## Related Documentation

- [Redis Operations](../redis/README.md) - datastore conventions this
  service follows
- [Librescoot Services](README.md) - service overview
