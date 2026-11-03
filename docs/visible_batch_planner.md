# Planning with only the visible batch

`visible_batch` is an opt-in experimental player. It may use every tile in the
current offer, but cannot access the actual next offer, dealer RNG, seed, or a
recorded continuation. The approved `learned` default and O hint are unchanged.

```sh
./1010 auto visible_batch --seed 42
./1010 --headless visible_batch --games 10 --seed 42
```

The normal learned player already uses visible information at decision time.
Its earlier search teachers could use known future deals; learned weights do
not give the live player access to those deals. Existing deep/improvement tools
remain offline optimizers, not evidence of performance without future knowledge.

## Information boundary

`AutoPlayer` constructs an immutable `VisiblePosition` containing only occupancy,
score, and remaining visible tile identities. The planner receives this value,
not the real `Board1010` object or a clone of its RNG. Candidate transitions reuse
the board's pure placement/clearing geometry with no dealer. Completing the
batch is a leaf; an empty offer is not interpreted as actual Game Over and never
triggers generation of another batch. The real game reveals new tiles only after
the chosen real move exhausts the offer; the next decision receives that newly
visible offer.

The planner explores placement order and positions for up to three visible tiles,
returns the first action only, then replans. No actual or hypothetical future
batches are generated. All nineteen known tile shapes are used only to measure
how flexible the resulting board is, not to predict a particular next offer.

## Fixed experimental algorithm

Version 1 uses beam width 8 and a maximum of 5,000 attempted transitions per
choice, counting duplicate states toward that work budget. Exact ties use stable
option/row/column order rather than the game or player RNG. Deduplication includes
occupancy, remaining visible options and score. No optimality is claimed.

At each depth, rank first by the number of currently fitting remaining tiles,
then by a board-space score plus `log(1 + remaining placement count)`. A tile that
does not currently fit is still allowed to become playable after another tile
clears a line. The space score is:

```text
empty cells + 0.1 * largest empty region
            - 2 * empty region count - 4 * isolated empty cells
```

Empty regions use four-neighbor connectivity; isolation uses eight neighbors,
matching the existing geometry features. Keep the best eight frontier states. For batch-complete leaves, add
`sum(log(1 + legal placement count))` across the known shape catalog, and choose
the highest value. If the budget or a dead end prevents completion, return the
best legal partial prefix found, prioritizing attained score. This is a bounded
heuristic and can miss a better arrangement. The strategy is deterministic for a
visible state and fixed work settings; its latency depends on the machine.

## Reporting and training

Live benchmark reports carry `information_mode: visible_batch`. Offline
`ImprovementSearch`, improvement reports and new lesson search metadata carry
`information_mode: known_future`, including when visible policies supply their
rollouts. This labels the teacher's information, not just the rollout policy.
Old artifacts without the field have unspecified information mode; do not
silently relabel them. Additive metadata does not alter trace/lesson schemas.

This work does not retrain or replace the bundled model. Recollecting lessons
from an observation-restricted teacher would be a separate experiment. Existing
heuristics remain in the default benchmark list; add `visible_batch` explicitly.

## Preregistered evaluation protocol (completed)

Initial implementation smoke checks used tuning seeds `2000000..2000004` only.
Before a final evaluation, freeze the implementation/settings and post its
revision and source fingerprint on issue #45. Development comparison uses
`2000000..2000099`; a timing sample uses early/middle/late positions from tuning
games. Compare against the unchanged bundled learned player on paired complete
games and report mean differences, 95% intervals, and latency distributions.

Reserve fresh test range `6000000..6001999` for this experiment before inspecting
it. The single final run will use `6000000..6000499` (500 paired games), with
`codex_sam`, `learned`, and the frozen `visible_batch` policy. Conservatively retire
the whole reserved block once used; do not tune or rerun based on final results.
The next free block is `7000000..7001999`. Earlier held-out/test ranges, including
`3000000..3001999` and `4000000..4001999`, are excluded. The unconsumed block
`5000000..5001999` retains its earlier reservation rather than being reassigned.

Long comparisons run in an isolated branch worktree on the compute machine;
artifacts stay under ignored `learning_data/issue45/`. A new versioned baseline
will include the experimental strategy on seeds 1..100; every established
heuristic must still match baseline v4, and learned must match baseline v6.
Report strength and latency honestly, including negative results. No default or
hint promotion is part of this branch.

Manual check after review: run `./1010 auto visible_batch --seed 42` and observe
legal placements, Game Over and automatic restart. The existing O hint remains Sam.

## Development and latency results

Frozen implementation: `20c0d31099e0da8e32aa85dcecda3e43630d80fc`.
Source SHA-256: `30bf1e143745e08d93ee9c0b6d33da5648e02870ab54d6a38335ebebae5bd913`.
The exact source-file list is recorded in the reports. The learned comparator's
resolved SHA-256 remains
`4a06731303861400f195484161d1d974a077bc75e2f439aed19b23114f371203`.

On the 100 tuning games, visible_batch averaged **706.35**, versus **385.42**
for learned. The paired gain was **+320.93**, 95% CI **+207.75 to +434.11**.
These reused tuning seeds are development evidence, not the final comparison.
No parameter or model tuning followed these results.

On 120 matching tuning positions, decision times on the compute machine were:

| Player | Median ms | P90 ms | P95 ms | Maximum ms |
| --- | ---: | ---: | ---: | ---: |
| learned | 1.977 | 7.226 | 7.688 | 9.554 |
| visible_batch | 4.852 | 37.094 | 39.260 | 48.201 |

With three tiles remaining (51 cases), visible_batch's median was 15.991 ms;
with two tiles (24 cases), 5.321 ms; with one tile (45 cases), 1.077 ms.
The snapshot adapter is included, model/player construction is outside timing,
and measurement order alternates. These are whole-offer choices, not selected-
tile hints or cached frames. The policy is slower, particularly at the start
of a batch; these observations are not a universal latency guarantee or grounds
for silently replacing the default/hint policy.

`baseline-v7.json` preserves every old heuristic and learned per-seed result.
Its committed copy normalizes model paths; the original report is retained with
the ignored experiment artifacts. One development launch skipped the baseline
stage and was stopped/restarted before publishing results; its launch-error log
and marker were retained. It did not use final seeds or change selected settings.

## Single frozen final evaluation

The one final run used all 500 preregistered fresh seeds `6000000..6000499`.
The source/settings and learned model fingerprints matched the posted freeze.
Each policy played normal complete games with the unchanged board-dependent
dealer; there was no retrospective selection of a trajectory or settings.

| Player | Mean | 95% CI for mean | Median | P10 / P90 | Maximum |
| --- | ---: | --- | ---: | --- | ---: |
| codex_sam | 331.854 | 317.619 to 346.089 | 293 | 174 / 541 | 1210 |
| learned | 418.856 | 398.812 to 438.900 | 363 | 209 / 685 | 1744 |
| visible_batch | 688.362 | 645.468 to 731.256 | 573 | 215 / 1365 | 3171 |

| Paired difference | Mean | 95% CI | Wins / ties / losses |
| --- | ---: | --- | --- |
| visible_batch minus learned | +269.506 | +222.710 to +316.302 | 320 / 30 / 150 |
| visible_batch minus codex_sam | +356.508 | +313.475 to +399.541 | 381 / 29 / 90 |

The mean gain over learned is about **64.3%**. Intervals use the benchmark’s
paired normal approximation. This is evidence of an average gain on these
seeds, not a guarantee of winning every game or an optimality claim.
The strategy remains opt-in because it has a higher decision-latency cost;
the approved default, hint strategy, game rules and bundled model are unchanged.

The 500 final seeds are now consumed. The rest of reserved block
`6000500..6001999` is retired without inspection, so the whole block stays out
of future tuning or selection. The next unreserved range is `7000000..7001999`.
No new policy settings or decision code were chosen after inspecting these final
results. The later run-line move counter changes reporting only, outside the
frozen benchmark source fingerprint.

## Verification and retained artifacts

The implementation passed 209 tests and 1,182 assertions, clean lint, and CI
on Ruby 3.4 and 4.0. Focused boundary tests cover forbidden live-board access,
hidden-RNG invariance, frozen observations, simultaneous line clearing, initially
unplayable tiles made playable by a clear, empty batches/dead ends, work caps,
selected-tile placement and repeated complete-game replay. A headless CLI smoke
run (`./1010 --headless visible_batch --games 1 --seed 42`) scored 2,086 over
542 moves, exactly matching baseline v7 for that illustrative baseline seed.
Graphical verification for this experimental strategy remains a maintainer step;
the earlier 76-run window confirmation covered learned. Existing heuristic
per-seed results match baseline v4 and learned matches v6 exactly.

`learning_data/issue45/` on both machines retains `evaluate.rb`, `develop.sh`,
the raw `baseline-v7.json`, `development.json`, `latency.json`,
`freeze-posted.json`, `final.json`, logs and started markers (including the
aborted development-launch records). The runner records its own checksum
alongside source/model fingerprints. Published baseline model paths are relative;
ignored raw reports retain their original provenance.

Recorded phase commands on the compute worktree:

```sh
bundle exec ruby learning_data/issue45/evaluate.rb development
bundle exec ruby learning_data/issue45/evaluate.rb final
```

These are the recorded commands, not instructions to repeat the experiment:
the started markers deliberately reject a second execution of either phase.
Use the retained reports to inspect results; a new experiment needs a new
protocol and an untouched test range.
