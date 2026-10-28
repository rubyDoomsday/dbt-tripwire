# dbt-tripwire (State-Aware Orchestration)

This package adds two skip-aware materializations, `sao_table` and
`sao_incremental`, that skip rebuilding a model when nothing meaningful
upstream has changed since its last successful run.

The latest version is on the
[releases page](https://github.com/rubyDoomsday/dbt-tripwire/releases/latest).

### Table of Contents

* [Quickstart](#quickstart)
* [Upgrading](#upgrading)
* [Configuration](#configuration)
* [How it works](#how-it-works)
* [Known limitations](#known-limitations)
* [Development](#development)
* [Versioning](#versioning)

## Supported Data Warehouses

- Snowflake only. Both materializations are declared `adapter='snowflake'`
  and wrap dbt-snowflake's own `materialization_table_snowflake()` /
  `materialization_incremental_snowflake()` directly.

## Objects included

Materializations:

```
sao_table
sao_incremental
```

State tables (see "Configuration" below for where these live, and
`models/sao/*.sql` for their definitions):

```
sao_model_state           -> SAO_MODEL_STATE
sao_source_state          -> SAO_SOURCE_STATE
sao_run_log               -> SAO_RUN_LOG
sao_source_check_log      -> SAO_SOURCE_CHECK_LOG
```

See "How it works" below for how the tables are used. There's no
generated docs site for this package. `dbt docs generate` in a project that
installs it picks up the four state-table models directly.

## Quickstart

1. Add this package to your `packages.yml`:

    ```yaml
    packages:
      - git: "https://github.com/rubyDoomsday/dbt-tripwire.git"
        revision: vX.Y.Z # pin to a release tag, see the releases page
    ```

2. Run `dbt deps` to install the package.

3. Add an on-run-end hook to your `dbt_project.yml`:

    ```yaml
    on-run-end:
      - "{{ dbt_tripwire.sao_record_run_results(results) }}"
    ```

    No conditional needed: `sao_record_run_results` checks the same
    enable/disable state `sao_should_run()` does as its own first statement,
    so it's already a no-op in an environment where SAO is off. Packages
    cannot inject project-level hooks automatically, this line must be added
    by hand in every project that installs this package.

4. If you're using `sao_incremental` anywhere, add the required
   `is_incremental()` override to your own project (not this package), see
   "Required wiring for `sao_incremental`" below. Skip this step if you're
   only using `sao_table`.

5. Run the tables:

    ```bash
    dbt run --select dbt_tripwire
    ```

    This is required, once per environment/schema, before enabling SAO
    there. The four `SAO_*` tables are real dbt models (`models/sao/*.sql`);
    like any other model, something has to actually select and run them
    before anything else, a hand-written insert, or `sao_should_run()`'s
    own logging, can reference them.

    If your project runs narrowly `--select`-scoped per-job invocations
    (rather than a full `dbt build` that would sweep these up incidentally),
    make sure whatever wires up `DBT_ENABLE_SAO=true` for an environment also
    includes `dbt_tripwire` in that job's selection at least once, or these
    four models never get built there and the on-run-end hook (or any
    `sao_should_run()` call) fails with "object does not exist."

6. Turn it on: `export DBT_ENABLE_SAO=true` in whichever environment should
   actually run SAO's skip logic. See "Environment Variables" below: SAO is
   disabled by default everywhere else.

## Upgrading

1. Read the [release notes](https://github.com/rubyDoomsday/dbt-tripwire/releases)
   for every version between the one you're on and the one you want. A major
   release has an "Upgrade steps" section. Do those steps.
2. Change `revision` in your `packages.yml` to the new tag.
3. Run `dbt deps`.

Rolling back is the same thing in reverse: pin the old tag and run `dbt deps`.

### Required wiring for `sao_incremental`: override `is_incremental()`

dbt-core's built-in `is_incremental()` (used inside a model's own SQL to gate
an incremental `WHERE` filter) hardcodes a check against
`model.config.materialized == 'incremental'`, literally that string, so it's
never true for a model materialized as `sao_incremental`, even once its
target table already exists. Left unfixed, any `sao_incremental` model using
the standard `{% if is_incremental() %}` pattern would silently never apply
its own incremental filter: every real rebuild would feed an unfiltered,
full-table select into the merge, and because dbt's own incremental
materialization matches on `unique_key`, the merge would then re-write
*every* pre-existing matched row on every rebuild, not just new/changed ones.

Because dbt's macro resolution for an unqualified call from a model in the
**consuming project** does not pick up a same-named override defined inside
an *installed package's* own macros, this package cannot fix this itself.
Every project that uses `sao_incremental` must add its own override, e.g.
(see `integration_tests/macros/is_incremental_override.sql` for the exact,
tested copy):

```jinja
{% macro is_incremental() %}
    {% if model.config.materialized == 'sao_incremental' %}
        {% if not execute %}
            {{ return(False) }}
        {% else %}
            {% set relation = adapter.get_relation(this.database, this.schema, this.table) %}
            {{ return(relation is not none
                      and relation.type == 'table'
                      and not should_full_refresh()) }}
        {% endif %}
    {% else %}
        {{ return(dbt.is_incremental()) }}
    {% endif %}
{% endmacro %}
```

This is checked at compile time: `sao_incremental.sql` fails loudly if the
override is missing, rather than relying on everyone reading this README.

## Configuration

### Where state tables live (optional)

By default the four `SAO_*` tables land wherever your project's
`generate_schema_name` puts a model with no explicit schema override, same as
any other model. We recommend a dedicated schema, the same way `dbt_artifacts`
does it (for example, `SAO_STATE`):

```yaml
models:
  dbt_tripwire:
    +database: your_destination_database # optional, default is your target database
    +schema: your_destination_schema      # optional, default is your target schema
```

### Environment Variables

| Variable | Also settable via | Default | Effect |
|---|---|---|---|
| `DBT_ENABLE_SAO` | `var('sao_enable', ...)` | `false` | When `true`, `sao_table`/`sao_incremental` actually run Tier 0/1/2 skip logic and read/write the four `SAO_*` tables. When `false` (the default), they behave exactly like the standard `table`/`incremental` materialization: always build, zero `SAO_*` read or write. |
| `DBT_SAO_DISABLE` | `var('sao_disable', ...)` | `false` | Separate, higher-priority kill switch: forces every SAO-managed model to always build even in an environment that has `DBT_ENABLE_SAO=true`, for ad-hoc debugging, without touching that environment's main flag. |

SAO is **disabled by default**. An earlier version of this switch defaulted
to enabled, which made it far too easy to turn on by accident; only an
environment that explicitly sets `DBT_ENABLE_SAO=true` opts in. Both
`sao_should_run()` and the `on-run-end` hook (`sao_record_run_results`) call
the same `sao_is_globally_disabled()` check as their own first statement,
there's exactly one implementation of "is SAO on," not two that could drift
out of sync; that's also why the Quickstart hook wiring needs no conditional
of its own.

⚠️ **Kill-switch footgun**: `var('sao_enable', env_var('DBT_ENABLE_SAO', 'false'))`
(and identically for `sao_disable`/`DBT_SAO_DISABLE`) only falls through to
the env var when the corresponding key is **entirely absent** from a
project's `vars:` block. `var()`'s default argument is not consulted once the
var is set to *anything*, including `false`. A project that adds
`vars: { sao_enable: false }` "for clarity" silently and permanently shadows
the env var for every invocation, breaking the per-environment on/off switch.
Leave both unset in a project's `vars:` block, set the env var instead.

This is specifically about a **permanent** `vars:` block entry. A one-off
CLI override for a single invocation is fine, and works as expected, dbt
resolves CLI `--vars` after a project's `vars:` block, so it takes
precedence for that run only:

```bash
dbt run --vars '{sao_enable: false}'
```

### Per-model config

Set under `meta.sao` on any model materialized as `sao_table` or
`sao_incremental` (or as a project-level `+meta.sao` default on a `models:`
path in `dbt_project.yml`, dbt's normal config resolution/inheritance
applies):

```yaml
config:
  materialized: sao_table   # or sao_incremental
  meta:
    sao:
      build_after_interval_value: 1        # positive integer, validated
      build_after_interval_unit: hour       # hour|hours|h, minute|minutes|min,
                                             # day|days|d, validated against an
                                             # allowlist, mapped to the exact
                                             # Snowflake DATEADD token
      always_build: false        # default false; true = always build (state
                                  # still recorded), skip logic bypassed
      build_interval_check: true # default true; false = elapsed time never
                                  # triggers a run
      build_source_check: true   # default true; false = source-tier signals
                                  # never trigger a run for this model (it
                                  # relies on Tier 0 / ancestor inheritance only)
      max_skips: 20               # optional, no default (unlimited); forces
                                   # a run once SKIP_COUNT reaches this value
```

⚠️ The package defaults to `build_after_interval_value: 1` /
`build_after_interval_unit: hour`. Any model that doesn't override this and
is scheduled less often than hourly will have Tier 0's `window_elapsed` rule
fire on effectively every invocation, rebuilding via Tier 0 regardless of any
source signal, the skip mechanism never gets a chance to apply. Real
per-model intervals (set to something meaningfully longer than the model's
actual run cadence) are required for this feature to do anything.

⚠️ **Config-merge caveat (read this before overriding one key)**: dbt's
`meta` merge across project- and model-level config is **shallow**, a
model-level `meta.sao` block **fully replaces** a project-level `sao` block,
it does not merge key-by-key. If a project sets defaults via `+meta.sao` on a
models path and a model only wants to override, say, `max_skips`, that model
must restate the **entire** `sao` block, not just the one key it's changing,
otherwise every other key silently reverts to this package's hardcoded
defaults (see `sao_config_defaults()` in `macros/sao/sao_config.sql`), not
the project-level ones.

### Source watermark configuration (optional)

Tier 2's `MIN`/`MAX(watermark_col)` check is opt-in per source, via
`meta.sao_watermark_col` on the source table in `sources.yml`:

```yaml
sources:
  - name: my_source
    tables:
      - name: my_table
        meta:
          sao_watermark_col: updated_at
```

Sources without this key fall back to `COUNT(*)`-only Tier 2, same as before.
`sao_watermark_col` is validated against a bare-identifier allowlist
(`sao_validate_identifier()` in `macros/sao/sao_config.sql`) before it's
interpolated into SQL, it goes straight into an unquoted `min()`/`max()`
expression, so it gets the same treatment `build_after_interval_unit`
already gets.

## How it works

Most dbt projects have no way to skip rebuilding an expensive `table` model when
nothing meaningful upstream has changed since its last successful run. This
package fills that gap for scheduled, periodic runs between merges (dbt's own
`state:modified+` selection already handles code-change detection at merge
time; this package handles *data*-change detection between merges).

`sao_table` and `sao_incremental` wrap the real, **unmodified**
`materialization_table_snowflake()` / `materialization_incremental_snowflake()`
respectively. Their decision logic is identical: Tier 1/2 checks in this
design only ever run against upstream *source* tables, never against a
model's own compiled SQL, so `sao_incremental` needs no special handling of
its own incremental predicate. Before doing anything else, both evaluate a
`should_run` decision:

0. **Global kill switch**: see "Environment Variables" above. Checked
   first, before touching any `SAO_*` table at all.
1. **Missing-relation guard**: if the model's target relation doesn't
   actually exist (dropped, schema rebuild, cloned env), treat this exactly
   like `first_run` regardless of what `SAO_MODEL_STATE` says. Otherwise the
   skip path would hand dbt a `none` relation and downstream refs would
   face-plant on a row that only *looks* like it's already there.
2. **Full refresh**: a `--full-refresh` run (or a model whose
   `full_refresh` config forces one) always builds. Skipping it would report
   success while leaving the old table in place, and for `sao_incremental`
   the next incremental run would then apply new logic to new rows only.
3. **Tier 0 (business rules)**: no data check at all. Fires immediately if:
   this is the model's first-ever run, its previous real build errored (see
   "Errored builds force a retry" below), `always_build` is set, the
   configured time window has elapsed since the last real run, or
   `max_skips` has been reached.
4. **Ancestor inheritance + Tier 1/2 source-anchored checks, combined**:
   walk upstream (through any non-SAO-managed pass-through nodes, e.g. plain
   views) looking for an SAO-managed ancestor that's part of this
   invocation's selection, **and separately** walk further up to every true
   dbt source this model can reach (through the ancestor or otherwise) and
   check each one: Tier 1 is `SYSTEM$LAST_CHANGE_COMMIT_TIME()` (no scan);
   Tier 2 (only if Tier 1 found no signal) is `COUNT(*)` and, if a watermark
   column is configured for that source, `MIN`/`MAX(watermark_col)` (requires
   a scan). The model rebuilds if **either** the ancestor ran **or** any
   reachable source shows a signal at either tier. This model's own source
   check runs even when a qualifying ancestor was found: inheriting the
   ancestor's decision alone would miss a change signal on a source this
   model refs directly (or through a pass-through node the ancestor doesn't
   cover) whenever the ancestor happened to skip. Any source already "owned"
   by the ancestor is a per-invocation cache hit (`SAO_SOURCE_CHECK_LOG`), so
   this costs a metadata lookup, not a re-scan.

If `should_run` is false, the model's existing relation is returned untouched
and no SQL against the model's own target table runs at all. If true,
execution falls straight through into the real materialization, no staging
table, no swap.

### Errored builds force a retry

If a model's real materialization errors after `should_run` evaluated true,
`SAO_MODEL_STATE.LAST_ERROR_AT` is stamped for that model at `on-run-end`
(its `LAST_RUN_AT`/`SKIP_COUNT` are left completely untouched, an errored run
is still never counted as a legitimate skip). Tier 0 then fires
unconditionally on that model's very next invocation
(`reason: previous_run_errored`), regardless of the interval or of what the
*shared, source-level* Tier 1/2 baseline looks like.

This matters because `SAO_SOURCE_STATE` (see below) advances unconditionally,
independent of any one model's build outcome. Without this, a model whose
build failed right after a real source signal fired would find, on its next
run, that the baseline had already moved to reflect that signal, no further
diff, `no_signal`, and stay silently skipped until the source changed again
or the interval elapsed. `LAST_ERROR_AT` is cleared the next time the model
actually rebuilds successfully.

Decisions and source checks are cached per-invocation (`SAO_RUN_LOG`,
`SAO_SOURCE_CHECK_LOG`, both genuinely `transient` Snowflake tables) so that
shared ancestors/sources are only evaluated once per run, no matter how many
descendants depend on them. Persistent state (`SAO_MODEL_STATE`,
`SAO_SOURCE_STATE`) is written exactly once per invocation, in a single
batched `on-run-end` hook, this is the only place persistent state is ever
written.

`SAO_RUN_LOG`/`SAO_SOURCE_CHECK_LOG` are append-only with no automatic
retention, call `dbt run-operation sao_purge_transient_logs --args
'{retention_days: 30}'` on your own periodic schedule to bound their growth;
this package can't wire its own maintenance job into a consuming project's
schedule.

### `SAO_SOURCE_STATE` is shared and point-in-time, a known tradeoff, not a bug

`SAO_SOURCE_STATE` is keyed by source only, not by (model, source). This is
deliberate: the top 10 sources in a real rollout are each shared by
200+ candidate models, and a per-model baseline would multiply the
already-mandatory source-check cache into a much larger, per-model-per-source
one, defeating the reason the cache exists. The tradeoff: if model A observes
and reacts to a source change this invocation, and model B (sharing that
source, but not selected this invocation, e.g. a slower cadence or a
different tag-scoped run) next checks that source *after* the baseline has
already advanced, B will see no diff and won't independently rebuild in
response to that same historical change. B's own subsequent check is
comparing against current reality, which is correct from B's point of view,
but B never "replays" the specific delta A reacted to. `build_after_interval`
remains the backstop for B in this scenario, same as for any other
consistently-`no_signal` chain.

## Known limitations

What's in the package: `sao_table` and `sao_incremental`, the full Tier 0 and
combined ancestor-plus-source-check decision chain, the per-invocation
source-check cache, the batched `on-run-end` persistence hook with its four-way
branch (ran / no-op'd / errored / skipped-untouched), the errored-model forced
retry, the missing-relation guard, and the global kill switch (off by default).
For `sao_incremental`, dbt's own incremental merge logic (temp relation plus
merge on `unique_key`) is called as-is. This package never inspects or rebuilds
a model's incremental predicate. See "Required wiring for `sao_incremental`"
above for the one piece of wiring that still lives in the consuming project.

What's not in it yet:

| Limitation | What to do today |
|---|---|
| SAO is opt-in per model, there's no bulk migration | Move models over one at a time |
| No automatic retention for `SAO_RUN_LOG` / `SAO_SOURCE_CHECK_LOG` | Schedule `dbt run-operation sao_purge_transient_logs` yourself |
| `SAO_SOURCE_STATE` keeps one baseline per source, not per (model, source) | Accepted trade-off, see the section above. Revisit before leaning hard on tag-scoped partial runs |

## Development

### Pre-Requisites

| Item                     | OS  | Version | Notes                    |
| ------------------------ | --- | ------- | ------------------------ |
| Homebrew Package Manager | Mac | latest  | see: https://brew.sh/    |
| Git                      | Mac | latest  | see https://github.com/git-guides/install-git |

### Quickstart

The preferred method to set up the environment is the Makefile. If you have any
issue with it, use the manual steps.

| Make (Preferred & Mac Only)                               | Manual Steps                                                     |
| --------------------------------------------------------- | ---------------------------------------------------------------- |
| `git clone git@github.com:rubyDoomsday/dbt-tripwire.git`  | `git clone git@github.com:rubyDoomsday/dbt-tripwire.git`         |
| CD into the project root directory (e.g. cd dbt-tripwire)   | CD into the project root directory                               |
| `make bootstrap`                                          | `brew bundle install`                                            |
| restart terminal                                          | `pyenv install 3.11.9 && pyenv local 3.11.9`                     |
| `activate!`                                               | `python3 -m venv .venv && source .venv/bin/activate`             |
| code using your editor of choice!                         | `pip install -r requirements.txt`                                |
|                                                           | append `.profiles.template.yml` to `~/.dbt/profiles.yml` and fill it in |
|                                                           | `cd integration_tests && dbt deps && cd ..`                      |
|                                                           | `pre-commit install`                                             |

`make bootstrap` prompts you to add a `dbt_tripwire_poc` profile block to your
`profiles.yml`. It never overwrites the file, since that file is usually shared
with other dbt projects on the same machine. `make update`
refreshes `integration_tests`' dbt packages, and `make destroy` tears the local
environment down.

### Running the integration tests

dbt commands run from `integration_tests/`. That's where `packages.yml`, the
`dbt_tripwire_poc` profile, and the fixture models live. For example, `activate!`
then `cd integration_tests && dbt debug`.

SAO is off by default (see "Environment Variables" above), so
`export DBT_ENABLE_SAO=true` in your shell before running anything here.
Without it, every fixture just always builds and none of the skip logic runs.
Don't set it through `vars:` in `integration_tests/dbt_project.yml`, see the
kill-switch footgun above.

`integration_tests/` has a diamond-shaped fixture plus dedicated fixtures for:

| Fixture | What it proves |
|---|---|
| `zero_source_model.sql` | the zero-source fallback |
| `max_skips_model.sql` | `max_skips` forces a run |
| `error_model.sql` | an errored build keeps its state and forces a retry (two-run manual test, see its comments) |
| `mixed_deps_model.sql` | the OR'd ancestor-plus-direct-source decision |
| `incremental_model.sql` | `sao_incremental` really merges incrementally |

The missing-relation guard is also a manual two-run test: drop the target table
out of band, then re-run.

### Pre-commit

[pre-commit](https://pre-commit.com/) runs the same checks locally and in CI.
`make bootstrap` installs the git hooks.

| Hook | On commit | On push | In CI |
|---|---|---|---|
| `check-yaml`, `requirements-txt-fixer` | ✓ | ✓ | ✓ |
| `end-of-file-fixer`, `trailing-whitespace` | ✓ | ✓ | |
| `codespell` | ✓ | ✓ | ✓ |
| `dbt-parse` (`dbt deps` + `dbt parse` in `integration_tests/`) | | ✓ | ✓ |

To run everything CI runs: `pre-commit run --hook-stage manual --all-files`.
To skip the slow parse on one push: `SKIP=dbt-parse git push`.

### Contributing

1. Branch off `main`. Forks are welcome, but the release-label workflow only
   runs on branches in this repo, so a maintainer will set the label for you.
2. Open a PR. Code Compliance runs pre-commit. It's advisory, not a required check,
   but don't merge it red.
3. The PR gets `release:patch` and a comment explaining the labels. If the
   change is bigger than a patch, add `release:minor` or `release:major` (see
   [Versioning](#versioning)).
4. Merge. The Release workflow cuts a new version on its own.

## Versioning

This package follows [semantic versioning](https://semver.org/). Every merge to
`main` cuts a release: a git tag plus a GitHub Release. There's no other
artifact. GitHub Releases is the changelog.

| Bump | The test: what does someone using the package have to do? | Examples |
|---|---|---|
| Major | They have to change something to upgrade | new required wiring, a renamed or dropped `SAO_*` column, a config key that now means something different, different default skip behavior |
| Minor | Nothing, but there's something new they can opt into | a new config key or macro that's off by default |
| Patch | Nothing, and nothing new is visible | bug fixes, docs, CI |

How the label decides the version:

* Every PR gets `release:patch` automatically.
* Add `release:minor` or `release:major` by hand. The highest label wins.
* A `release:major` PR needs an `## Upgrade steps` section in its description.
  The PR template has one commented out. It's copied into the release notes.
* If several PRs merge close together and land in one release run, they ship as
  one release. The bump is the highest label among them, and every major PR's
  Upgrade steps are included.

`v0.1.0` is the first release. The Release workflow cuts it on the first merge
to `main` when no version tag exists yet.

A published version is never moved or deleted. A bad release is fixed by
cutting a new one.
