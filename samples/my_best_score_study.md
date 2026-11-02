# Improving my-best-score

Applied the prefix-and-tail search from commit `cfb9b1e` to
`logs/my-best-score.moves` on November 2, 2026.

| Trace | Score | Final moves | Offer sets |
| --- | ---: | ---: | ---: |
| `manual_score_1184.moves` | 1,184 | 320 | 107 |
| `improved_score_19524.moves` | 19,524 | 4,946 | 1,649 |

The gain is 18,340 points (16.49 times the original score). Both games use
dealer seed `1009413778`. The improved game preserves the first 260 final
moves and all 107 original offer sets, then continues the same seeded dealer.
Move counts exclude undone moves.

The original sample retains the source records, including undos, with one
empty line removed because `GameTrace.read` rejects blank records. The source
under `logs/` was left unchanged.

## Search

1. Ran `scripts/deep_improve.rb` with prefix 260, a 60-second cap, beam 8,
   1,000,000 states, 4,000 rollouts, four rollouts per step, and `sam` rollouts.
   This raised the score to 2,842.
2. Ran `scripts/iterate_improve.rb` for eight rounds, keeping 90% of the current
   best game, with a 45-second cap per round and its default work budgets.
   All eight rounds improved, reaching 9,285.
3. Ran 20 further searches with a 25-second cap per round and the same deep
   search defaults as step 1. Each splice kept `floor(final_moves * fraction)`
   moves. The fraction started at 0.97 and decreased by 0.015 per consecutive
   failure, resetting after an improvement. Three failures at 13,906 were
   followed by a gain at fraction 0.925. The final round reached 19,524.

This is the best result of this bounded study, not a proven maximum. Most
rounds hit their time caps, so exact results depend on machine speed.

## Verification and replay

Both samples passed legal replay, actual Game Over, declared score, and
`GameImprover#validate_seed` checks. The full original offer prefix and the
first 260 final moves were also compared directly.

```sh
bundle exec ruby scripts/verify_trace.rb samples/manual_score_1184.moves samples/improved_score_19524.moves
./1010 --delay 0.05 samples/improved_score_19524.moves
```

To search further from the current best:

```sh
bundle exec ruby scripts/deep_improve.rb samples/improved_score_19524.moves --prefix 4797 --time 120 --output logs/my-best-score-next.moves
```
