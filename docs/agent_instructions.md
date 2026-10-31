# Instructions for coding agents

Read this file before working on any GitHub issue in this repository.

## 1. Pick the next issue from the roadmap

The order of work is set by the pinned roadmap issue, **#27**
(`gh issue view 27`). Do not work in issue-number or creation order.

- Take the **first unchecked issue** in #27 whose "Needs" issues are all closed.
- Work on **one issue at a time**, and finish it (or record why you stopped) before starting the next.
- If the order looks wrong, or an issue turns out to depend on another one,
  comment on #27 explaining why, update its list, and continue in the new order.

## 2. Before changing code

1. Read the whole issue, **including its comments**. Later comments can change the scope.
2. Reproduce the problem on the current `master` using the issue's own steps.
3. If it is **already fixed or no longer relevant**, don't change code. Close the
   issue with a comment showing the evidence (the commands you ran and their
   output). Its box in #27 is then ticked automatically.

## 3. While changing code

- Meet the issue's **acceptance criteria**. They are the definition of done.
- Match the surrounding code: its naming, comment density and idiom.
  `game_1010.rb` only reads input, updates state and draws; the rules live in `board.rb`.
- Add or update tests in `test/` for each acceptance criterion. Tests must not
  need a real Gosu window.
- Keep long-running work (simulation, search, training) independent of Gosu.
- Never commit `logs/`, `learning_data/`, trained models or `1010game.txt`.
- Keep the seed sets in `learning_seed_sets.rb` disjoint. Never use `held_out`
  seeds for training, tuning or model selection.

## 4. Check before committing

Always run the full suite:

```sh
bundle exec rake test
```

**Phases 1–3 of #27 must not change how the game plays.** After any change in
those phases that touches the board, strategies, simulator, search or learned
player, check that the results still match the committed baseline exactly:

```sh
bundle exec ruby scripts/benchmark.rb --seeds 1..100 --output learning_data/parity.json
ruby -rjson -e 'a, b = ARGV.map {|f| JSON.parse(File.read(f))["strategies"] }; diffs = b.keys.flat_map {|s| a[s]["per_seed"].zip(b[s]["per_seed"]).reject {|x, y| x == y }.map {|x, _| "#{s} seed #{x["seed"]}" } }; puts diffs.empty? ? "PARITY OK: per-seed results match baseline-v1" : "PARITY FAILED: #{diffs.first(10).join(", ")}"; exit(diffs.empty? ? 0 : 1)' learning_data/parity.json benchmarks/baseline-v1.json
```

This takes about 25 seconds and must print `PARITY OK`. A performance issue
that fails parity is not done.

**Phase 4 issues (#24 onwards) change play on purpose.** They must record the
new results in a new versioned file (e.g. `benchmarks/baseline-v2.json`),
leave `baseline-v1.json` unchanged, and report paired before/after numbers
(mean difference and 95% interval) in the issue.

For performance issues, report before/after timings measured on the same
machine with the same command, and put those numbers in the issue comment.

## 5. Commit and close

- **One issue per commit.** Start the commit message with a short summary and
  include `Fixes #N` in the body. GitHub then closes the issue when the commit
  reaches `master`, and the box in #27 is ticked.
- If only part of an issue is done, use `Refs #N` instead, and comment on the
  issue saying what is done and what remains.
- After pushing, comment on the issue: what changed, the commands you ran to
  verify it, and their results (test summary, parity output, timings or scores).
- Behavior you can only see in the game window can't be fully checked by you.
  Write the exact manual steps and the expected result in the issue comment so
  the maintainer can confirm.

## 6. Problems found along the way

- If you find a new bug or a needed change, open a new issue with steps to
  reproduce, the cause (with `file:line`), a suggested fix and acceptance
  criteria. Then add it to the right phase in #27.
- Don't widen the current issue's scope to fix unrelated problems.
