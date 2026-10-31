# Learning objective and evaluation protocol

## Objective

The primary objective is to maximize the final score of a complete game, starting from a fresh board and ending at Game Over. A successful placement adds one point per filled square in that tile. Clearing rows or columns gives no direct points; it can improve the final score by making room for future tiles.

For every episode, the score invariant is:

```text
final score - starting score = sum(area of every placement still retained after undo)
```

Normal auto-player episodes contain no undo events, so this is simply the sum of the areas of all successfully placed tiles. Clears do not add to that sum.

## Metrics

Report final score as the primary metric. Also report:

- **Placed tiles:** successful placements still retained after undo events. For auto-player games, count every successful placement.
- **Cleared lines:** total rows plus columns cleared. A row and a column cleared by the same move count as two lines.
- **Option batches reached:** number of batches actually offered, including the initial batch and the final batch that may have no legal move.
- **Score distribution:** across the full evaluation seed list, report mean, median, standard deviation, minimum, maximum, and the 10th and 90th percentiles. Keep per-seed scores so policy differences can be paired by seed.

## Fair comparisons

For normal policy evaluation, run each policy on the same list of initial seeds under the unchanged game rules. Each policy gets the same underlying seeded random stream. The game may replace the first randomly dealt tile with a small tile that fits when none of the three random tiles fit; because this fallback depends on the board, the effective offer batches can differ after policies create different boards. Record those actual batches and report that distinction.

Benchmark score summaries include a normal-approximation 95% confidence interval for the mean, plus per-seed scores and paired differences. Use a sufficiently large held-out sample before drawing conclusions about a learned policy.

For a counterfactual analysis of one recorded episode, freeze the exact observed option batches and compare alternative legal placement sequences against those same offers. Label this result **fixed-offer counterfactual**; it measures a different setup from normal seeded policy evaluation.

Use the repository's disjoint seed sets for learning and comparisons:

- Baseline report: `1..100`
- Training: `1_000_000..1_099_999`
- Tuning: `2_000_000..2_001_999`
- Held-out evaluation: `3_000_000..3_001_999`

Use tuning seeds to choose settings and checkpoints. Do not inspect held-out scores until a policy/checkpoint is selected. The held-out set is for the final comparison only. The exact seed lists are exposed by `learning_seed_sets.rb` and can be selected by the benchmark runner.

Do not treat failure to find a higher score within a search budget as proof that no higher-scoring sequence exists. Report the best score found, the baseline score, the search budget, and whether an improvement was found.
