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

Keep the best eight frontier states. For batch-complete leaves, add
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

## Evaluation protocol

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
