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
* `game_log.rb`: writes compact move and undo events to one file per game in `logs/`
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
