## Gosu based Board Game known as 1010!

[1010!] is a single player, tile-based, puzzle game produced by [Gram] Games, played on a square grid of 10x10 cells. The player is presented with a random selection of tile patterns of various shapes, 3 at a time, which are to be placed on the board, one by one. If the tiles consume an entire row (or column), without any empty cells in between, the row (or column) is cleared up so that more tiles can be placed. Each cell consumed by the tile counts towards the score of the game. The aim is to place as many tiles as possible to increase the score. In its most simplest form, each cell adds 1 point to the score. A variation of the game can be to assign different points for each color.

## Installation:

The game logic is written in [Ruby] (3.0 or newer) and the window uses the [Gosu] gem. Clone the code and install the gems:

```sh
$ git clone git@github.com:shanko/1010.git
$ cd 1010
$ bundle install
```

Gosu in turn has more dependencies and will require you to compile/install them as described [here]. Needs [gcc] or similar compiler.

**macOS with Homebrew:** Homebrew now installs `sdl2-compat` in place of `sdl2`, and its `sdl2-config` doesn't support the `--static-libs` option that gosu's build uses. Gosu then installs without errors but fails to load (`symbol not found ... _OBJC_CLASS_$_NSScreen` or `_SDL_GameControllerClose`). Pass the link flags yourself:

```sh
$ gem install gosu -v 1.4.6 -- --with-ldflags="-L/usr/local/lib -lSDL2 -framework Cocoa -framework AppKit"
```

(On Apple Silicon, Homebrew's libraries are in `/opt/homebrew/lib` instead of `/usr/local/lib`.)

## Version:

1.0

## To play the game: 

```sh
$ bundle exec ruby game_1010.rb
```

Click on one of the tiles presented on the right side of the 10x10 grid (or press 1, 2 or 3). The tile will turn yellow indicating selection. Then click on one of the empty cells in the grid where you want to place the tile, or drag the tile there. Keep on adding tiles to the grid till one or more rows or columns fill up. Filled up rows and columns get emptied again making space for more tiles to be placed. The idea is to try and keep as many tiles as possible to increase the score. 

# Hints:

* Press and hold the H key to see help.
* Press and hold O to see where the computer would put the selected tile.

| Key | Action |
|---|---|
| 1 / 2 / 3 | select a tile |
| O (hold) | show the best position for the selected tile |
| U | undo the last move |
| N | new game |
| A | auto mode on/off |
| E | let the computer make one move |
| S | save the game (to `1010game.txt`; it is loaded again at the next start) |
| Q | save and quit |
| R | record a new game (press R again to stop) |
| P | play back the last recording |
| C | print where each tile fits (in the terminal) |
| ESC | quit without saving, and delete the saved game so the next start is a new game |

## To play in the terminal:

```sh
$ ruby terminal_game.rb
```

## To let the computer play the game:

```sh
$ bundle exec ruby game_1010.rb auto
$ bundle exec ruby game_1010.rb auto sam            # choose the strategy
$ bundle exec ruby game_1010.rb auto jc --seed 42   # the same games every time
$ bundle exec ruby game_1010.rb logs/20261030-123456-1234-567.moves # replay a logged game
```

Run all current auto strategies headlessly against the same seed list and save
a reproducible JSON benchmark report:

```sh
$ bundle exec ruby scripts/benchmark.rb --seeds 1..100 --output benchmarks/baseline-v1.json
```

Analyze a completed, replayable `.moves` trace and save a search lesson locally:

```sh
$ bundle exec ruby scripts/learn.rb analyze logs/<game>.moves --budget 2 --beam-width 8
```

Lessons are stored under the ignored `learning_data/` directory by default.
The command reports actual and candidate scores, the first action divergence,
and whether the search found an improvement. Search results are best-found
candidates, not proofs of an optimal sequence.

Train a deterministic imitation model from completed, improved lessons whose
source seeds are in the training range. The trainer rejects held-out lessons,
and ignores incomplete or non-improving search results:

```sh
$ bundle exec ruby scripts/learn.rb train-imitation --lessons learning_data --seed 17 --epochs 20
```

Evaluate a learned policy headlessly (a model is required):

```sh
$ bundle exec ruby scripts/benchmark.rb --seed-set held_out --strategies first_fit,last_fit,random_fit,shanko,jc,sam,learned --model learning_data/models/imitation-v1.json --output learning_data/held-out.json
```

For a full learned-versus-heuristics report, include all six heuristic strategies
and `learned`. The report records per-seed results, pairwise score differences,
95% confidence intervals, and the strongest heuristic by mean score. The held-out
seed set is for final reporting only; choose models with tuning seeds.

Start the graphical learned auto-player with the tuning-selected checkpoint:

```sh
$ bundle exec ruby game_1010.rb auto learned --model learning_data/checkpoints/selected.json --seed 42
```

The simulator and benchmark support learned models now. To collect search
corrections from states visited by the learned policy, use training seeds only:

```sh
$ bundle exec ruby scripts/learn.rb correct --model learning_data/models/imitation-v1.json --seeds 1000000,1000001 --budget 0.1 --stride 5
```

Fine-tune an imitation model with REINFORCE on complete training-seed games.
The default tuning sample uses the first 20 tuning seeds. Each evaluated
checkpoint is retained; `selected.json` points to the candidate with the best
tuning mean. Resume from a checkpoint to continue its training state:

```sh
$ bundle exec ruby scripts/learn.rb train-rl --model learning_data/models/imitation-v1.json --episodes 10 --seed 17
$ bundle exec ruby scripts/learn.rb train-rl --resume learning_data/checkpoints/selected.json --episodes 10 --seed 17
```

Use the selected checkpoint pointer directly for headless evaluation with
`scripts/benchmark.rb --model learning_data/checkpoints/selected.json`.
To reselect a retained checkpoint, evaluate it on tuning seeds first:

```sh
$ bundle exec ruby scripts/learn.rb select --checkpoint learning_data/checkpoints/reinforce-step-100.json
```

Action feature version 1 records tile area and one-hot tile type, rows and
columns cleared, remaining legal placements, largest four-neighbor empty
region, empty-region count, isolated eight-neighbor empty cells, filled
neighbors, touched edges, and resulting occupied fraction. For every legal
candidate, the extractor combines its tile and anchor context with simulated
post-placement board features. The linear scorer uses deterministic seeded
tie-breaking.

Pass a `.moves` file as the command line argument to replay it. Moves are shown
in order, with 0.5 seconds between successive moves by default. Set another
interval in seconds with `--delay` (for example, `--delay 2`):

```sh
$ bundle exec ruby game_1010.rb --delay 2 logs/<game>.moves
```

Try defeating the computer (it is very hard) by taking turns and comparing the score AND time required to play it.

The strategies are in `auto_player.rb`: `first_fit`, `last_fit`, `random_fit`, `shanko`, `jc` (the default) and `sam`. With `--seed` the computer gets the same tiles and makes the same choices every run, so strategies can be compared fairly.

## Code:

* `board.rb`: the rules (placing tiles, clearing lines, dealing, saving), with no input or output
* `auto_player.rb`: the computer player and its strategies
* `move_animation.rb`: shows a move square by square without pausing the window
* `game_log.rb` / `game_trace.rb`: write, validate and replay versioned game traces with initial state, exact offers, moves, undos and final score
* `game_simulator.rb`: runs full games without Gosu for policy evaluation
* `improvement_search.rb`: searches for better legal game sequences under explicit time, state, and beam limits
* `lesson_analyzer.rb` / `lesson_store.rb`: analyze completed traces and persist reproducible, versioned lessons
* `learned_player.rb`: versioned action features, linear policy, and deterministic imitation training
* `policy_corrector.rb`: searches continuations from states visited by a learned policy
* `reinforcement_trainer.rb`: REINFORCE training, resumable checkpoints, and tuning-based selection
* `learning_seed_sets.rb` / `scripts/benchmark.rb`: define disjoint seed sets and generate reproducible strategy benchmarks
* `game_1010.rb`: the Gosu window (drawing and input)
* `terminal_game.rb`: the terminal version

## Tests:

```sh
$ bundle exec rake test
```

## License: 

MIT

## Screen shot:

![Game Board](/game-1010.png?raw=true "Screen Shot")

## To Do:

* Rewrite using [graphics] gem
* ~~Make "auto" mode repeatable by passing a seed to random num generator~~ (`--seed`)
* Save History (games can be recorded and played back with R and P, but recordings aren't saved to a file yet)
* Use repeatable history to compare "auto" mode algorithms
* Improve "auto" mode algorithms to maximize score
* Port to use [mruby]
* Machine learning
* Weighted scoring based on color or shapes
* Leader Board

[//]: # (These are reference links used in the body of this note and get stripped out when the markdown processor does its job. There is no need to format nicely because it shouldn't be seen. Thanks SO - http://stackoverflow.com/questions/4823468/store-comments-in-markdown-syntax)

  [1010!]: <http://web.eecs.umich.edu/~gameprof/gamewiki/index.php/1010!>
  [Ruby]: <http://ruby-lang.org>
  [Gosu]: <https://www.libgosu.org>
  [here]: <http://libgosu.org>
  [gcc]: <http://gcc.gnu.org>
  [Gram]: <http://gram.gs/game-detail-1010.html>
  [mruby]: <http://mruby.org>
  [graphics]: <https://github.com/seattlerb/graphics>
