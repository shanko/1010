## Gosu based Board Game known as 1010!

[1010!] is a single player, tile-based, puzzle game produced by [Gram] Games, played on a square grid of 10x10 cells. The player is presented with a random selection of tile patterns of various shapes, 3 at a time, which are to be placed on the board, one by one. If the tiles consume an entire row (or column), without any empty cells in between, the row (or column) is cleared up so that more tiles can be placed. Each cell consumed by the tile counts towards the score of the game. The aim is to place as many tiles as possible to increase the score. In its most simplest form, each cell adds 1 point to the score. A variation of the game can be to assign different points for each color.

## Installation:

The game logic is written in [Ruby] and has only one dependency which can be installed by:

```sh
$ gem install gosu
```

This in turn has more dependencies and will require you to compile/install them as described [here].  Needs [gcc] or similar compiler.

After successful installation of gosu, you can simply clone the code for the game:

```sh
$ git clone git@github.com:shanko/1010.git
```

## Version:

1.0

## To play the game: 

```sh
$ ruby game_1010.rb
```

Click on one of the tiles presented on the right side of the 10x10 grid. The tile will turn yellow indicating selection. Then click on one of the empty cells in the grid where you want to place the tile. Keep on adding tiles to the grid till one or more rows or columns fill up. Filled up rows and columns get emptied again making space for more tiles to be placed. The idea is to try and keep as many tiles as possible to increase the score. 

# Hints:

* Press and hold the H key to see help.

## To let the computer play the game:

```sh
$ ruby game_1010.rb auto
```

Try defeating the computer (it is very hard) by taking turns and comparing the score AND time required to play it.

## License: 

MIT

## Screen shot:

![Game Board](/game-1010.png?raw=true "Screen Shot")

## To Do:

* Rewrite using [graphics] gem
* Make "auto" mode repeatable by passing a seed to random num generator
* Save History
* Use repeatable history to compare "auto" mode algorithms
* Improve "auto" mode algorithms to maximize score
* Port to use [mruby]
* Machine learning
* Weighted scoring based on color or shapes
* Leader Board

[//]: # (These are reference links used in the body of this note and get stripped out when the markdown processor does its job. There is no need to format nicely because it shouldn't be seen. Thanks SO - http://stackoverflow.com/questions/4823468/store-comments-in-markdown-syntax)

  [1010!]: <http://web.eecs.umich.edu/~gameprof/gamewiki/index.php/1010!>
  [Ruby]: <http://ruby-lang.org>
  [here]: <http://libgosu.org>
  [gcc]: <http://gcc.gnu.org>
  [Gram]: <http://gram.gs/game-detail-1010.html>
  [mruby]: <http://mruby.org>
  [graphics]: <https://github.com/seattlerb/graphics>
