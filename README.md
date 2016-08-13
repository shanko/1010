## Gosu based Board Game known as 1010!

1010! is a single player, tile-based, board game played on a square grid of 10x10 cells. The player is presented with a random selection of tile patterns of various shapes, 3 at a time, which are to be placed on the board, one by one. If the tiles consume an entire row (or column), without any empty cells in between, the row (or column) is cleared up so that more tiles can be placed. Each cell consumed by the tile counts towards the score of the game. The aim is to place as many tiles as possible to increase the score. In its most simplest form, each cell adds 1 point to the score. A variation of the game can be to assign colors to the tile patterns and different points for each color. 

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

* Drag-n-drop of the tiles
* Leader Board
* History
* Improve the auto-play algorithm to maximize the score
* Weighted scoring based on color or shapes
* Machine learning

[//]: # (These are reference links used in the body of this note and get stripped out when the markdown processor does its job. There is no need to format nicely because it shouldn't be seen. Thanks SO - http://stackoverflow.com/questions/4823468/store-comments-in-markdown-syntax)

  [Ruby]: <http://ruby-lang.org>
  [here]: <http://libgosu.org>
  [gcc]: <http://gcc.gnu.org>

