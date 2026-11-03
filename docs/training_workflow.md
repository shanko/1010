# Repeated training and model improvement

Run these commands from the repository root after `bundle install`. Training
and search run headlessly; they do not belong in the graphical update loop.
See [the evaluation report](learning_evaluation.md) for the measured results
and [the objective](learning_objective.md) for scoring and seed definitions.
Run long collection, training and benchmark commands on the designated compute
machine, detached and logged as described in `agent_instructions.md` section 8.
Do not run them locally as a fallback if remote access fails.

More training is an experiment: promotion depends on tuning performance, not
on the amount of compute spent or the best single game.

## Keep three separate decisions

1. Collect lessons and update weights using training seeds `1000000..1099999`.
2. Compare settings and select checkpoints using tuning seeds
   `2000000..2001999`.
3. Freeze the chosen models, then use untouched evaluation seeds for a final
   report. The November 1 report consumes `3000000..3001999` for reporting;
   do not repeatedly use those scores to choose future training settings.

Keep lessons, models, checkpoint directories and command summaries under the
ignored `learning_data/` directory. Preserve prior models and record the code
revision, seed lists, feature version, learning rate, temperature, baseline
settings and checkpoint interval for each experiment. The benchmark reports
include source and model fingerprints. Back up local artifacts separately if
needed: Git intentionally does not preserve them.

## 1. Collect more complete, improved lessons

Choose another unused range within the training split. For example:

```sh
mkdir -p learning_data/runs learning_data/models
bundle exec ruby scripts/learn.rb collect-training --seeds 1000020..1000039 --strategy codex_sam --max-states 2000 --max-rollouts 8 --beam-width 4 --budget 30 > learning_data/runs/collect-1000020-1000039.json
```

Use `codex_sam` as the lesson baseline and rollout strategy: the #33 experiment
produced a stronger model this way without changing action features. See
[the experiment log](issue33_experiments.md) for its fixed settings and results.

The output reports episodes, improvements found, complete improvements and
lessons saved. Only complete, validated improvements are saved as training
lessons. A low yield means more episodes, a stronger search budget, or both
may be needed. To explore a stronger search on another batch, try
`--max-states 10000 --max-rollouts 32 --beam-width 8 --budget 120`.
The state/rollout limits are reproducible work budgets; the wall-clock budget
is a safety cap and can change the result when it interrupts the search.

After training a model, collect corrections from states that model visits:

```sh
bundle exec ruby scripts/learn.rb correct --model learning_data/models/imitation-round-02.json --seeds 1000040..1000049 --max-states 2000 --max-rollouts 1 --stride 5 > learning_data/runs/correct-1000040-1000049.json
```

Run that command after creating the model in the next section, then train a
new imitation version from the expanded lesson store. `analyze GAME.moves`
also produces lessons from completed replayable games, but imitation training
only accepts lessons whose source seeds belong to the training split.

## 2. Retrain imitation into a new file

```sh
bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data --seed 17 --epochs 20 --learning-rate 0.1 --output learning_data/models/imitation-round-02.json > learning_data/runs/imitation-round-02.json
```

Inspect `episodes_used`, `examples_seen` and `excluded` in the command summary.
The command trains a new ranker from the valid lessons; it does not resume an
old imitation optimizer. Repeating it with exactly the same lessons and
settings produces the same model. New lessons, search corrections, or
settings selected on tuning seeds are needed to explore a different result.
Use a new filename for each round. Current code requires action feature
version 2; version 1 models must be retrained.

## 3. Start an RL experiment

Use a fresh checkpoint directory per experiment. These explicit settings
match the November 1 learning rate and exploration configuration:

```sh
mkdir -p learning_data/experiments/round-02
bundle exec ruby scripts/learn.rb train-rl --model learning_data/models/imitation-round-02.json --episodes 10 --seed 17 --learning-rate 0.0001 --temperature 1 --baseline-decay 0.9 --checkpoint-interval 10 --tuning-seeds 2000000..2000019 --checkpoints learning_data/experiments/round-02 > learning_data/experiments/round-02/session-001.json
```

The trainer saves an initial checkpoint and later evaluated checkpoints. It
retains every checkpoint and updates the directory's `selected.json` only
when tuning mean improves. A failed training experiment therefore does not
replace a stronger selection. Training reward is tile area per placement,
and complete episode return equals final game score, with no line-clear bonus.

The JSON summary's `checkpoints` array lists saved checkpoints in order.
`best_checkpoint` and `selected_pointer` identify tuning selections; they
may refer to an earlier step. The trainer records policy parameters, the
rolling baseline, global step, seeds, rewards and tuning evaluations. Its
SGD optimizer has no separate momentum state.

## 4. Continue from the latest training state

Resume the last checkpoint in the previous session's `checkpoints` array.
Do not automatically resume `selected.json`: a better older model can remain
selected while the latest training state has progressed further. In the
November 1 experiment, selection stayed at step 0 even though step 10 was saved.

```sh
RL_CHECKPOINT=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("checkpoints").last.fetch("path")' learning_data/experiments/round-02/session-001.json)
bundle exec ruby scripts/learn.rb train-rl --resume "$RL_CHECKPOINT" --episodes 10 --seed 17 --learning-rate 0.0001 --temperature 1 --baseline-decay 0.9 --checkpoint-interval 10 --tuning-seeds 2000000..2000019 --checkpoints learning_data/experiments/round-02 > learning_data/experiments/round-02/session-002.json
```

Without `--seeds`, an initial run starts at training seed 1000000. Resuming at
global step 10 continues at 1000010. Each session advances this position and
preserves the baseline and accumulated training history. The training split
contains 100,000 seeds; eventually a fresh experiment or an explicitly chosen
training seed schedule is required. If you supply `--seeds`, provide exactly
as many training seeds as `--episodes`; managing reuse is then your decision.

Keep the same `--seed` when resuming: a different exploration seed is rejected.
Also repeat learning rate, temperature, baseline decay and checkpoint interval
explicitly. The CLI has defaults and does not restore all those options for
you merely because a checkpoint records them. The default learning rate is
0.01, which differs from this experiment's 0.0001.

For several additional sessions in Bash or Zsh, starting from session 002:

```sh
(
  set -e
  previous=learning_data/experiments/round-02/session-002.json
  for session in 003 004 005; do
    checkpoint=$(ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("checkpoints").last.fetch("path")' "$previous")
    next=learning_data/experiments/round-02/session-$session.json
    test ! -e "$next"
    bundle exec ruby scripts/learn.rb train-rl --resume "$checkpoint" --episodes 10 --seed 17 --learning-rate 0.0001 --temperature 1 --baseline-decay 0.9 --checkpoint-interval 10 --tuning-seeds 2000000..2000019 --checkpoints learning_data/experiments/round-02 > "$next"
    previous=$next
  done
)
```

This adds 30 episodes, stops if a session fails or its output filename already
exists, and leaves the shell's error handling unchanged outside the subshell.
Continue with new session numbers and the last successful summary as `previous`.

## 5. Decide whether a new round helped

Check tuning means across checkpoints, rather than training rewards alone.
For a paired report of two chosen models plus every heuristic, use tuning
seeds while developing:

```sh
bundle exec ruby scripts/benchmark.rb --seeds 2000000..2000199 --workers 4 --strategies first_fit,last_fit,random_fit,shanko,jc,sam,codex_1,codex_sam,learned --model learning_data/experiments/round-02/selected.json --comparison-model previous=learning_data/checkpoints/selected.json --output learning_data/runs/round-02-tuning-200.json
```

The first 20 tuning seeds provide inexpensive checkpoint feedback. Before
settling on a training recipe, compare finalists on the same larger tuning
sample, such as the 200 seeds above. Read mean score, uncertainty, score
spread, game length and paired differences. A new best individual game does
not establish a better policy. Repeatedly searching the same small tuning
sample can overfit it, so reserve additional tuning seeds for finalist checks.

Explore one change at a time in a separate experiment directory: for example,
learning rates 0.00001, 0.0001 and 0.001, or temperatures 0.5, 1 and 2. These
are experiments, not proven improvements. Keep episode budgets, training
seeds and tuning seeds comparable. More lessons or better search corrections
may help imitation more than simply extending an RL run. The November 1
10-episode RL run did not beat its initial imitation model on tuning seeds.

To explicitly select a retained finalist after tuning evaluation:

```sh
bundle exec ruby scripts/learn.rb select --checkpoint PATH_TO_CHECKPOINT --tuning-seeds 2000000..2000199
```

This command deliberately overrides the automatic selection and writes
`selected.json` beside that checkpoint. It does not compare against every
other candidate for you. Automatic training selection rescans an older
selection when the tuning seed list changes so the comparison uses the same
seeds. Continue using consistent tuning lists within an experiment.

## 6. Freeze, evaluate once, then play

The best-score study has consumed `4000000..4001999` for its frozen final
evaluation. Keep those seeds out of future training and settings selection.

Choose models and settings using tuning results before inspecting new test
results. For future experiments, reserve a new test-only range in advance;
for example `5000000..5001999` is outside all current training and tuning
ranges. Record that reservation and keep it out of all learning decisions.
Run the final comparison with `--seeds 5000000..5001999` instead of the tuning
range in the preceding benchmark command. Use a new output filename and
retain the report with its model/source fingerprints. That custom range is
supplied with `--seeds`; the predefined `--seed-set held_out` still denotes
the original November 1 range.

Document the resulting score distributions and paired intervals even if
training did not help. Use another untouched test range for a later final
experiment rather than choosing future settings by repeatedly consulting
the same held-out report.

```sh
./1010 auto learned --model learning_data/experiments/round-02/selected.json --seed 42
./1010 auto codex_sam --seed 42
```

Changing `--model` reverts to any retained learned checkpoint. Selecting a
heuristic strategy needs no local model. Training continues offline, and the
graphical game loads its chosen policy once at startup.

## Explicit learned models outside gameplay

Gameplay (`./1010`, `./1010 auto`, and `./1010 auto learned`) intentionally
uses the bundled release when no model is supplied. Training and search must
not silently choose that release. `GameSimulator.run` requires an explicit
`model:` for learned simulation; `ImprovementSearch` requires explicit learned
baseline and rollout models. Deep trace search requires both `--rollout learned`
and `--model FILE`.

`collect-training` and `analyze` require `--model FILE` with `--strategy learned`.
They resolve the model once and record its SHA-256 in search metadata and lesson
provenance; the fingerprint hashes the resolved model JSON, not a path or pointer.
Use `correct --model FILE` for learned policy correction. `improve` uses Sam; `benchmark.rb` already requires an
explicit learned model. The heuristic lesson format and gameplay default are
unchanged. These optional provenance fields avoid an extra lesson schema change before
the versioning work in #40.

## Trace and lesson compatibility

New traces use `1010-moves-v4` and an `r1` rule header after the mode header.
`GameRules::VERSION` changes only when placement, scoring, clearing, tile geometry,
or dealer behavior changes. Unknown rule versions are rejected with instructions
to use matching rules or regenerate the trace. Legacy v2 (tile names) and v3
(compact tile IDs) still replay; `format_version` identifies their format and
`rule_version` is explicitly nil because they did not record one.

New lessons use schema v2. `versions` records the analysis rule version, simulator
version and source trace format (nil for simulator-generated lessons); existing
`search.version` records the search implementation version. Analysis of a legacy
trace records its actual source format, without pretending the trace recorded
rules. Mismatched or missing current lesson versions fail before training and
must be recollected or processed with matching historical tooling. Version
metadata participates in deduplication, preventing cross-version merging.

Historical schema-v1 lessons remain readable with `LessonStore.read` for replay.
Training rejects their unrecorded versions by default. To reproduce an existing
experiment explicitly, use:

```sh
bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data/historical --allow-legacy-lessons --output learning_data/reproduced.json
```

The API equivalent is `allow_legacy_lessons: true`; this opt-in is recorded in
training metadata and does not change the weighting or learned weights. It does
not bypass mismatches in schema-v2 lessons. Prefer recollecting lessons for new
experiments. The committed v1 fixture is retained unchanged alongside a new v2
fixture. Bundled model bytes, game rules and existing baselines are unchanged.
