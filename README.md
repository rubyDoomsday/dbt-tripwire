# dbt-tripwire (State-Aware Orchestration)

**Status: proof of concept.** This package implements the v1 POC scope of the
full State-Aware Orchestration design: both `sao_table` and
`sao_incremental`. It exists to prove the core skip mechanism works
end-to-end against real Snowflake, not to be adopted as-is into a production
dbt project.

## Development setup

```bash
make bootstrap   # first-time only: pyenv/venv/dbt deps + prompts to add a
                 # dbt_tripwire_poc profile block (never overwrites an existing
                 # profiles.yml, since that file is commonly shared with other
                 # dbt projects on the same machine)
make update      # refresh integration_tests' dbt package dependencies
make destroy     # tear down the local dev environment
```

dbt commands for this package are run from `integration_tests/` (that's
where `packages.yml`, the `dbt_tripwire_poc` profile, and the fixture models
live) — e.g. `activate!` then `cd integration_tests && dbt debug`.

## What it does

Most dbt projects have no way to skip rebuilding an expensive `table` model when
nothing meaningful upstream has changed since its last successful run. This
package fills that gap for scheduled, periodic runs between merges (dbt's own
`state:modified+` selection already handles code-change detection at merge
time; this package handles *data*-change detection between merges).

`sao_table` and `sao_incremental` wrap the real, **unmodified**
`materialization_table_snowflake()` / `materialization_incremental_snowflake()`
respectively. Their decision logic is identical — Tier 1/2 checks in this
design only ever run against upstream *source* tables, never against a
model's own compiled SQL, so `sao_incremental` needs no special handling of
its own incremental predicate. Before doing anything else, both evaluate a
`should_run` decision:

0. **Missing-relation guard** — if the model's target relation doesn't
   actually exist (dropped, schema rebuild, cloned env), treat this exactly
   like `first_run` regardless of what `SAO_MODEL_STATE` says. Otherwise the
   skip path would hand dbt a `none` relation and downstream refs would
   face-plant on a row that only *looks* like it's already there.
1. **Tier 0 (business rules)** — no data check at all. Fires immediately if:
   this is the model's first-ever run, its previous real build errored (see
   "Errored builds force a retry" below), `always_build` is set, the
   configured time window has elapsed since the last real run, or
   `max_skips` has been reached.
2. **Ancestor inheritance + Tier 1/2 source-anchored checks, combined** — walk
   upstream (through any non-SAO-managed pass-through nodes, e.g. plain
   views) looking for an SAO-managed ancestor that's part of this
   invocation's selection, **and separately** walk further up to every true
   dbt source this model can reach (through the ancestor or otherwise) and
   check each one: Tier 1 is `SYSTEM$LAST_CHANGE_COMMIT_TIME()` (no scan);
   Tier 2 (only if Tier 1 found no signal) is `COUNT(*)` and, if a watermark
   column is configured for that source, `MIN`/`MAX(watermark_col)` (requires
   a scan). The model rebuilds if **either** the ancestor ran **or** any
   reachable source shows a signal at either tier. This model's own source
   check runs even when a qualifying ancestor was found — inheriting the
   ancestor's decision alone would miss a change signal on a source this
   model refs directly (or through a pass-through node the ancestor doesn't
   cover) whenever the ancestor happened to skip. Any source already
   "owned" by the ancestor is a per-invocation cache hit
   (`SAO_SOURCE_CHECK_LOG`), so this costs a metadata lookup, not a re-scan.

If `should_run` is false, the model's existing relation is returned untouched
and no SQL against the model's own target table runs at all. If true,
execution falls straight through into the real materialization — no staging
table, no swap.

A **global kill switch** (`sao_disable` var or `DBT_SAO_DISABLE` env var)
forces every SAO-managed model to build regardless of state, for
debugging. ⚠️ Never set `sao_disable` in a project's `vars:` block — not even
to `false` — see "Kill-switch footgun" below.

### Errored builds force a retry

If a model's real materialization errors after `should_run` evaluated true,
`SAO_MODEL_STATE.LAST_ERROR_AT` is stamped for that model at `on-run-end`
(its `LAST_RUN_AT`/`SKIP_COUNT` are left completely untouched — an errored
run is still never counted as a legitimate skip). Tier 0 then fires
unconditionally on that model's very next invocation
(`reason: previous_run_errored`), regardless of the interval or of what the
*shared, source-level* Tier 1/2 baseline looks like.

This matters because `SAO_SOURCE_STATE` (see below) advances unconditionally,
independent of any one model's build outcome. Without this, a model whose
build failed right after a real source signal fired would find, on its next
run, that the baseline had already moved to reflect that signal — no further
diff, `no_signal` — and stay silently skipped until the source changed again
or the interval elapsed. `LAST_ERROR_AT` is cleared the next time the model
actually rebuilds successfully.

Decisions and source checks are cached per-invocation (`SAO_RUN_LOG`,
`SAO_SOURCE_CHECK_LOG`, both genuinely `transient` Snowflake tables) so that
shared ancestors/sources are only evaluated once per run, no matter how many
descendants depend on them. Persistent state (`SAO_MODEL_STATE`,
`SAO_SOURCE_STATE`) is written exactly once per invocation, in a single
batched `on-run-end` hook — this is the only place persistent state is ever
written.

`SAO_RUN_LOG`/`SAO_SOURCE_CHECK_LOG` are append-only with no automatic
retention — call `dbt run-operation sao_purge_transient_logs --args
'{retention_days: 30}'` on your own periodic schedule to bound their growth;
this package can't wire its own maintenance job into a consuming project's
schedule.

### `SAO_SOURCE_STATE` is shared and point-in-time — a known tradeoff, not a bug

`SAO_SOURCE_STATE` is keyed by source only, not by (model, source). This is
deliberate — the top 10 sources in a real rollout are each shared by
200+ candidate models, and a per-model baseline would multiply the
already-mandatory source-check cache into a much larger, per-model-per-source
one, defeating the reason the cache exists. The tradeoff: if model A
observes and reacts to a source change this invocation, and model B (sharing
that source, but not selected this invocation, e.g. a slower cadence or a
different tag-scoped run) next checks that source *after* the baseline has
already advanced, B will see no diff and won't independently rebuild in
response to that same historical change — B's own subsequent check is
comparing against current reality, which is correct from B's point of view,
but B never "replays" the specific delta A reacted to. `build_after_interval`
remains the backstop for B in this scenario, same as for any other
consistently-`no_signal` chain.

## Installing

```yaml
# packages.yml, in the consuming project (e.g. your-dbt-project)
packages:
  - git: "<repo url>"
    revision: <pinned commit sha>
```

```yaml
# dbt_project.yml, in the consuming project
on-run-end:
  - "{{ dbt_tripwire.sao_record_run_results(results) }}"
```

Packages cannot inject project-level hooks automatically — this wiring line
must be added by hand in every project that installs this package.

### ⚠️ Required wiring for `sao_incremental`: override `is_incremental()`

dbt-core's built-in `is_incremental()` (used inside a model's own SQL to
gate an incremental `WHERE` filter) hardcodes a check against
`model.config.materialized == 'incremental'` — literally that string, so it
is never true for a model materialized as `sao_incremental`, even once its
target table already exists. Left unfixed, any `sao_incremental` model using
the standard `{% if is_incremental() %}` pattern would silently never apply
its own incremental filter — every real rebuild would feed an unfiltered,
full-table select into the merge, and because dbt's own incremental
materialization matches on `unique_key`, the merge would then re-write
*every* pre-existing matched row on every rebuild, not just new/changed
ones. This was caught live during POC testing (see `integration_tests/`).

Because dbt's macro resolution for an unqualified call from a model in the
**consuming project** does not pick up a same-named override defined inside
an *installed package's* own macros, this package cannot fix this itself —
every project that uses `sao_incremental` must add its own override, e.g.
(see `integration_tests/macros/is_incremental_override.sql` for the exact,
tested copy):

```jinja
{% macro is_incremental() %}
    {% if not execute %}
        {{ return(False) }}
    {% else %}
        {% set relation = adapter.get_relation(this.database, this.schema, this.table) %}
        {{ return(relation is not none
                  and relation.type == 'table'
                  and model.config.materialized in ['incremental', 'sao_incremental']
                  and not should_full_refresh()) }}
    {% endif %}
{% endmacro %}
```

### ⚠️ Kill-switch footgun: never set `sao_disable` in `vars:`

`var('sao_disable', env_var('DBT_SAO_DISABLE', 'false'))` only falls through
to the env var when the `sao_disable` key is **entirely absent** from a
project's `vars:` block — `var()`'s default argument is not consulted once
the var is set to *anything*, including `false`. A project that adds
`vars: { sao_disable: false }` "for clarity" silently and permanently
shadows `DBT_SAO_DISABLE` for every invocation, breaking the env-var kill
switch used for ad-hoc debugging/CI overrides. Leave `sao_disable` unset in
`vars:` — the package default is already `false`. (This POC's own
`integration_tests/dbt_project.yml` used to set this exact footgun; fixed,
see the comment there.)

## Config schema

Set under `meta.sao` on any model materialized as `sao_table` or
`sao_incremental` (or as a project-level `+meta.sao` default on a `models:`
path in `dbt_project.yml` — dbt's normal config resolution/inheritance
applies):

```yaml
config:
  materialized: sao_table   # or sao_incremental
  meta:
    sao:
      build_after_interval_value: 1        # positive integer, validated
      build_after_interval_unit: hour       # hour|hours|h, minute|minutes|min,
                                             # day|days|d — validated against an
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
source signal — the skip mechanism never gets a chance to apply. Real
per-model intervals (set to something meaningfully longer than the model's
actual run cadence) are required for this feature to do anything.

### ⚠️ Config-merge caveat (read this before overriding one key)

dbt's `meta` merge across project- and model-level config is **shallow** — a
model-level `meta.sao` block **fully replaces** a project-level `sao` block,
it does not merge key-by-key. If a project sets defaults via `+meta.sao` on a
models path and a model only wants to override, say, `max_skips`, that model
must restate the **entire** `sao` block, not just the one key it's changing —
otherwise every other key silently reverts to this package's hardcoded
defaults (see `sao_config_defaults()` in `macros/sao/sao_config.sql`), not
the project-level ones.

## Source watermark configuration (optional)

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
interpolated into SQL — it goes straight into an unquoted `min()`/`max()`
expression, so it gets the same treatment `build_after_interval_unit`
already gets.

## Scope of this POC vs. the full design

Implemented: `sao_table` and `sao_incremental`, full Tier 0 / combined
ancestor-inheritance-plus-source-check decision chain, the mandatory
per-invocation source-check cache, the batched `on-run-end` persistence hook
with its four-way branch (ran-for-real / no-op'd / errored /
skipped-untouched), the errored-model forced-retry marker, the
missing-relation guard, and the global kill switch. For `sao_incremental`,
dbt's real, unmodified incremental merge logic (temp relation +
merge-on-`unique_key`) is delegated to verbatim — this package's own decision
logic never inspects or reconstructs a model's incremental predicate; see the
`is_incremental()` override requirement above for the one piece of wiring
this does still require in the consuming project (now backed by a
compile-time guard in `sao_incremental.sql` that fails loudly if that
override is missing, rather than relying on everyone reading this README).

Not implemented (deferred to the real implementation): a dedicated
package-owned schema for state tables (this POC uses the consuming project's
target schema directly), a real Terraform/CI-driven rollout across all 331
`table`/`incremental` candidates in the consuming project, an automated retention job
for the transient log tables (`sao_purge_transient_logs` exists but must be
scheduled by hand), and a per-(model, source) baseline for
`SAO_SOURCE_STATE` (see "known tradeoff" above — accepted for this POC, would
need re-evaluating before a rollout that leans heavily on tag-scoped partial
selections).

See `integration_tests/` for the self-contained test project: a synthetic
diamond-shaped fixture plus dedicated fixtures for the zero-source fallback,
`max_skips`, the errored-node state-preservation-and-forced-retry guarantee
(`error_model.sql`, exercised as a two-invocation manual test — see its
comments), a mixed-ancestor-plus-direct-source fixture
(`mixed_deps_model.sql`) proving the OR'd decision logic, and a
`sao_incremental` fixture proving genuine incremental merge behavior. The
missing-relation guard (drop the target table out-of-band, then re-run) is
also a manual, two-invocation test — not expressible as static model SQL.
See the top-level design doc for the full v1 scope, data model, and known
risks.
