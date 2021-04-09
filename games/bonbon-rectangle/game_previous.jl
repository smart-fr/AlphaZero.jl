import AlphaZero.GI

using Crayons
using StaticArrays

const BOARD_SIDE = 16
const NUM_CELLS = Int(BOARD_SIDE) ^ 2
const TO_CONQUER = 0.875
# Initial board as a list of bonbon notations
const INITIAL_BOARD_SIZE_16_LIST = [
  "00037", "0083B", "04073", "08CBF", "0C4F7", "0C8FF",
  "10C7F", "144BB", "180F3"
]

const Player = UInt8
const WHITE = 0x01
const BLACK = 0x02
other_player(p::Player) = 0x03 - p

const Cell = UInt8
const EMPTY_BOARD = @SMatrix zeros(Cell, BOARD_SIDE, BOARD_SIDE)
const Board = typeof(EMPTY_BOARD)
const EMPTY_ACTIONS_HOOK = @SMatrix [(-1, -1) for row in 1:BOARD_SIDE, column in 1:BOARD_SIDE]
const ActionsHook = typeof(EMPTY_ACTIONS_HOOK)
const EMPTY_STATE = (board=EMPTY_BOARD, actions_hook=EMPTY_ACTIONS_HOOK, curplayer=WHITE)

mutable struct Game <: GI.AbstractGame
  board :: Board
  curplayer :: Player
  finished :: Bool
  winner :: Player
  # Actions mask where each flagged action is attached to a bonbon's NW corner
  amask :: Vector{Bool}
  amask_white :: Vector{Bool}
  amask_black :: Vector{Bool}
  # Cell indices of NW corner of bonbon where current cell belongs,
  # where all legal actions for the bonbon are flagged in Game.amask
  actions_hook :: ActionsHook
  # Actions history, which uniquely identifies the current board position
  # Used by external solvers and to trigger expansions through turns count
  history :: Union{Nothing, Vector{Int}}
end

GI.State(::Type{Game}) = typeof(EMPTY_STATE)

###################################
# CELLS                           #
###################################
#
# Cell values are encoded as 0-127 integers with bits set according to:
# Bit 6: set if the cell belongs to a former attacking or defending bonbon
const CELL_FORMER_FIGHTER = 0x40
# Bit 5: set if cell's W side is a vertical limit 
const CELL_V_BORDER_WEST = 0x20
# Bit 4: set if cell's S side is a horizontal limit
const CELL_H_BORDER_SOUTH = 0x10
# Bit 3: set if cell's E side is a vertictal limit
const CELL_V_BORDER_EAST = 0x08
# Bit 2: set if cell's N side is a horizontal limit
const CELL_H_BORDER_NORTH = 0x04
# Bit 1: set if the cell is black
# Bit 0: set if the cell is white
# --------------------
# FF We So Ea No Bl Wh
#  4  2  1  8  4  2  1
# --------------------
#        1           1
#     2           2
#     3  3        3  3
#  4           4
#  5     5     5     5
#  6  6        6  6
#  7     7     7     7
#           8
#           9        9
#           A     A
#           B     B  B
#           C  C
#           D        D
#           E     E  E
#           F  F  F  F
# --------------------
#  4  2  1  8  4  2  1
# FF We So Ea No Bl Wh
# --------------------
#
###
# Convert between 1-based cell indices and 0-based (column, row) tuples.
###
# To iterate cells from left to right, top to bottom :
# cell_index = 0xRC+1 -> cell CR in bonbon notation.
# cell_index_to_column_row(cell_index::Int) = ((cell_index - 1) % BOARD_SIDE, (cell_index - 1) ÷ BOARD_SIDE)
# colum_row_to_cell_index((column, row)) = column + (row * BOARD_SIDE) + 1
# To iterate cells from top to bottom, left to right :
# cell_index = 0xCR+1 -> cell CR in bonbon notation.
index_to_column_row(cell_index::Int) = ((cell_index - 1) ÷ BOARD_SIDE, (cell_index - 1) % BOARD_SIDE)
column_row_to_index((column, row)) = row + (column * BOARD_SIDE) + 1
#
# Cell tests
#
# Test for cell properties from its value
cell_value_is_former_fighter(cell_value::Cell) = (cell_value & CELL_FORMER_FIGHTER) == CELL_FORMER_FIGHTER
cell_value_has_N_border(cell_value::Cell) = (cell_value & CELL_H_BORDER_NORTH) == CELL_H_BORDER_NORTH
cell_value_has_S_border(cell_value::Cell) = (cell_value & CELL_H_BORDER_SOUTH) == CELL_H_BORDER_SOUTH
cell_value_has_W_border(cell_value::Cell) = (cell_value & CELL_V_BORDER_WEST) == CELL_V_BORDER_WEST
cell_value_has_E_border(cell_value::Cell) = (cell_value & CELL_V_BORDER_EAST) == CELL_V_BORDER_EAST
cell_value_is_white(cell_value::Cell) = (cell_value & WHITE) == WHITE
cell_value_is_black(cell_value::Cell) = (cell_value & BLACK) == BLACK
cell_value_is_empty(cell_value::Cell) = !cell_value_is_white(cell_value) && !cell_value_is_black(cell_value)
#
# Test for board cell properties BloWhits coordinates
#
# Generic test: return a function accepting a board and coordinates as arguments, which
# returns the return of "test_function applied" to the corresponding cell value in the board.
test_board_column_row(test_function) = (board, column, row) -> (0 <= column < BOARD_SIDE) && (0 <= row < BOARD_SIDE) && test_function(board[row + 1, column + 1])
test_out_or_board_column_row(test_function) = (board, column, row) -> !(0 <= column < BOARD_SIDE) || !(0 <= row < BOARD_SIDE) || test_function(board[row + 1, column + 1])
# function test_board_column_row(test_function)
#   return function(board, column, row)
#     return (0 <= column < BOARD_SIDE) && (0 <= row < BOARD_SIDE) && test_function(board[row + 1, column + 1])
#   end
# end
#
# Applications
is_former_fighter = test_board_column_row(cell_value_is_former_fighter)
#function has_N_border(board::Board, column, row)
#  return cell_value_has_N_border(board[row + 1, column + 1])
#end
has_N_border = test_board_column_row(cell_value_has_N_border)
has_S_border = test_board_column_row(cell_value_has_S_border)
has_W_border = test_board_column_row(cell_value_has_W_border)
has_E_border = test_board_column_row(cell_value_has_E_border)
is_white = test_board_column_row(cell_value_is_white)
is_black = test_board_column_row(cell_value_is_black)
is_empty = test_out_or_board_column_row(cell_value_is_empty)
#
# Converts a boolean array to an integer by interpreting the array as its binary representation,
# from the least (1st array element) to the most (last array element) significant bits.
function booleans_to_integer(array::Array)
  if length(array) == 0
    return 0
  else
    return 2 * booleans_to_integer(array[2:end]) + (array[1] ? 1 : 0)
  end
end
# Converts a boolean array to a string by concatenating the hexadecimal representations of the
# return of booleans_to_integer for each group of 4 (or less for the last ones) elements.
function booleans_to_string(array::Array)
  try
    result = ""
    if 0 < length(array) <= 4
      return string(booleans_to_integer(reverse(array)), base=16)
    elseif length(array) > 4
      return string(booleans_to_integer(reverse(array[1:4])), base=16) * booleans_to_string(array[5:end])
    end
    return result
  catch
    return nothing
  end
end
#
# Convert a String to a boolean array by interpreting the string as the hexadecimal representation of bits
# representing the boolean values.
function string_to_booleans(s::String)
  try
    s == "" ? [] : map(!=('0'), [(map(x -> bitstring(x)[5:8], map(c -> parse(UInt8, c, base=16), collect(s)))...)...])
  catch
    return nothing
  end
end
#
# Cell modifiers
#
# Change properties to cell and reflect them in cell value
# Set bits
cell_value_set_former_fighter(cell_value::Cell) = cell_value_is_former_fighter(cell_value) ? cell_value : cell_value + CELL_FORMER_FIGHTER
cell_value_add_N_border(cell_value::Cell) = cell_value_has_N_border(cell_value) ? cell_value : cell_value + CELL_H_BORDER_NORTH
cell_value_add_S_border(cell_value::Cell) = cell_value_has_S_border(cell_value) ? cell_value : cell_value + CELL_H_BORDER_SOUTH
cell_value_add_W_border(cell_value::Cell) = cell_value_has_W_border(cell_value) ? cell_value : cell_value + CELL_V_BORDER_WEST
cell_value_add_E_border(cell_value::Cell) = cell_value_has_E_border(cell_value) ? cell_value : cell_value + CELL_V_BORDER_EAST
function cell_value_set_empty(cell_value::Cell)
  v = cell_value_is_black(cell_value) ? cell_value - BLACK : cell_value
  return cell_value_is_white(v) ? v - WHITE : v
end
function cell_value_set_white(cell_value::Cell)
  v = cell_value_is_black(cell_value) ? cell_value - BLACK : cell_value
  return cell_value_is_white(v) ? v : v + WHITE
end
function cell_value_set_black(cell_value::Cell)
  v = cell_value_is_white(cell_value) ? cell_value -  WHITE : cell_value
  return cell_value_is_black(v) ? v : v + BLACK
end
# Unset bits
cell_value_unset_former_fighter(cell_value::Cell) = cell_value_is_former_fighter(cell_value) ? cell_value - CELL_FORMER_FIGHTER : cell_value
cell_value_remove_N_border(cell_value::Cell) = cell_value_has_N_border(cell_value) ? cell_value - CELL_H_BORDER_NORTH : cell_value
cell_value_remove_S_border(cell_value::Cell) = cell_value_has_S_border(cell_value) ? cell_value - CELL_H_BORDER_SOUTH : cell_value
cell_value_remove_W_border(cell_value::Cell) = cell_value_has_W_border(cell_value) ? cell_value - CELL_V_BORDER_WEST : cell_value
cell_value_remove_E_border(cell_value::Cell) = cell_value_has_E_border(cell_value) ? cell_value - CELL_V_BORDER_EAST : cell_value
#
# Change properties to cell and update the board to reflect the changes
#
# Generic modifier: return a function accepting a board and coordinates as arguments,
# which updates the corresponding cell value in the board by application of "modify_function", except
# if coordinates are outside the board.
function set_board_column_row(modify_function)
  return function(board::Array, column, row)
    (height, width) = size(board)
    if 0 <= column < width && 0 <= row < height
      board[row + 1, column + 1] = modify_function(board[row + 1, column + 1])
    end
  end
end
#
# Applications
set_former_fighter = set_board_column_row(cell_value_set_former_fighter)
add_N_border = set_board_column_row(cell_value_add_N_border)
add_S_border = set_board_column_row(cell_value_add_S_border)
add_W_border = set_board_column_row(cell_value_add_W_border)
add_E_border = set_board_column_row(cell_value_add_E_border)
set_white = set_board_column_row(cell_value_set_white)
set_black = set_board_column_row(cell_value_set_black)
set_empty = set_board_column_row(cell_value_set_empty)
unset_former_fighter = set_board_column_row(cell_value_unset_former_fighter)
remove_N_border = set_board_column_row(cell_value_remove_N_border)
remove_S_border = set_board_column_row(cell_value_remove_S_border)
remove_W_border = set_board_column_row(cell_value_remove_W_border)
remove_E_border = set_board_column_row(cell_value_remove_E_border)

###################################
# ACTIONS                         #
###################################
#
# Actions are encoded as 0-2047 integers with bits set according to:
# Bits 10-3: coordinates CR of NW corner of origin bonbon (cell index from top to bottom, left to right)
const NUM_ACTIONS_PER_CELL = 0x8
# Bit 2: move type, 0 for division | 1 for fusion
const ACTION_TYPE_MASK = 0x4 # Bit encoding action type
# Bits 1-0: move direction, 0 for N | 1 for E | 2 for S | 3 for W
const ACTION_DIRECTION_DIV = 0x4
const DIRECTION_NORTH = 0x0
const DIRECTION_EAST = 0x1
const DIRECTION_SOUTH = 0x2
const DIRECTION_WEST = 0x3
#
# Build action value from coordinates of NW corner of bonbon, move type and direction
action_value(column, row, move_type, move_direction) = NUM_ACTIONS_PER_CELL * (BOARD_SIDE * column + row) + ACTION_TYPE_MASK * move_type + move_direction
#
GI.Action(::Type{Game}) = Int
#
const ACTIONS = Vector{Int}(collect(0:NUM_ACTIONS_PER_CELL * NUM_CELLS - 1))
#
GI.actions(::Type{Game}) = ACTIONS
#
###
# Return an array of all potential actions for a given originating bonbon with
# NW corner at provided column and row.
###
# function origin_NW_corner_cell_index_to_potential_actions(cell_index::Int)
#   (column, row) = cell_index_to_column_row(cell_index)
#   if column >= BOARD_SIDE || row >= BOARD_SIDE
#     return nothing
#   end
#   # Set bits 10-3
#   coords::Int = NUM_ACTIONS_PER_CELL * (BOARD_SIDE * Int(column) + Int(row))
#   # Potential actions are all divisions and all fusions
#   # => create an item for all possible values of bits 2-0
#   return [coords + i for i in 0:NUM_ACTIONS_PER_CELL - 1]
# end
#  
# const ACTIONS = [
#     (
#       [
#         origin_NW_corner_cell_index_to_potential_actions(cell_index)
#         for cell_index in 1:NUM_CELLS
#       ]...
#     )...
# ]
#
# Finally potential actions are all integers up to NUM_ACTIONS_PER_CELL * NUM_CELLS
# for each cell and the encoded value of an action is 8 * (originating cell index) + (action code)

###################################
# BOARDS                          #
###################################
#
###
# Create the initial board object based on a list of  bonbons
# described in an array of bonbon notations
###
function bonbons_list_to_state(bonbons::Array, curplayer)
  board = Array(EMPTY_BOARD)
  actions_hook = Array(EMPTY_ACTIONS_HOOK)
  try
    # Iterate on the array of bonbon notations
    for bonbon in bonbons
      if length(bonbon) != 5
        return nothing
      else
        # Parse bonbon notation to get its properties
        west = parse(Int, bonbon[2], base=16)
        north = parse(Int, bonbon[3], base=16)
        east = parse(Int, bonbon[4], base=16)
        south = parse(Int, bonbon[5], base=16)
        # Add corresponding bits to bonbon interior and limit cells
        # NB. Columns and rows are expressed in a 0-based conceptual matrix
        #     whereas board is a 1-based Julia matrix
        for column in west:east
          for row in north:south
            # Add vertical border bits to vertical border cells and their horizontal neighbors
            if column == west
              add_W_border(board, column, row)
              add_E_border(board, column - 1, row)
            end
            if column == east
              add_E_border(board, column, row)
              add_W_border(board, column + 1, row)
            end
            # Add horizontal border bits to horizontal border cells and their vertical neighbors
            if row == north
              add_N_border(board, column, row)
              add_S_border(board, column, row - 1)
            end
            if row == south
              add_S_border(board, column, row)
              add_N_border(board, column, row + 1)
            end
            # Add team bit to bonbon cells
            bonbon[1] == '0' ? set_white(board, column, row) : set_black(board, column, row)
            # Set actions hook of all bonbon cells to bonbon's NW corner
            actions_hook[row + 1, column + 1] = (west, north)
          end
        end
      end
    end
    # Return the State object
    return (board=Board(board), actions_hook=ActionsHook(actions_hook), curplayer=curplayer)
  catch
    return nothing
  end
end
#

###################################
# GAMES                           #
###################################
#
# Constructor 
function Game()
  # s = bonbons_list_to_state(INITIAL_BOARD_SIZE_16_LIST, WHITE)
  s = read_state(["25.00 05.00 05.00 0d.00 25.40 05.40 05.40 0d.40 26.80 06.80 06.80 06.80 06.80 06.80 06.80 0e.80",
    "21.00 01.00 01.00 09.00 21.40 01.40 01.40 09.40 22.80 02.80 02.80 02.80 02.80 02.80 02.80 0a.80",
    "21.00 01.00 01.00 09.00 21.40 01.40 01.40 09.40 22.80 02.80 02.80 02.80 02.80 02.80 02.80 0a.80",
    "21.00 01.00 01.00 09.00 31.40 11.40 11.40 19.40 32.80 12.80 12.80 12.80 12.80 12.80 12.80 1a.80",
    "21.00 01.00 01.00 09.00 26.44 06.44 06.44 06.44 06.44 06.44 06.44 0e.44 25.c4 05.c4 05.c4 0d.c4",
    "21.00 01.00 01.00 09.00 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 21.c4 01.c4 01.c4 09.c4",
    "21.00 01.00 01.00 09.00 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 21.c4 01.c4 01.c4 09.c4",
    "31.00 11.00 11.00 19.00 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 31.c4 11.c4 11.c4 19.c4",
    "25.08 05.08 05.08 0d.08 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 25.c8 05.c8 05.c8 0d.c8",
    "21.08 01.08 01.08 09.08 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 21.c8 01.c8 01.c8 09.c8",
    "21.08 01.08 01.08 09.08 22.44 02.44 02.44 02.44 02.44 02.44 02.44 0a.44 21.c8 01.c8 01.c8 09.c8",
    "31.08 11.08 11.08 19.08 32.44 12.44 12.44 12.44 12.44 12.44 12.44 1a.44 21.c8 01.c8 01.c8 09.c8",
    "26.0c 06.0c 06.0c 06.0c 06.0c 06.0c 06.0c 0e.0c 25.8c 05.8c 05.8c 0d.8c 21.c8 01.c8 01.c8 09.c8",
    "22.0c 02.0c 02.0c 02.0c 02.0c 02.0c 02.0c 0a.0c 21.8c 01.8c 01.8c 09.8c 21.c8 01.c8 01.c8 09.c8",
    "22.0c 02.0c 02.0c 02.0c 02.0c 02.0c 02.0c 0a.0c 21.8c 01.8c 01.8c 09.8c 21.c8 01.c8 01.c8 09.c8",
    "32.0c 12.0c 12.0c 12.0c 12.0c 12.0c 12.0c 1a.0c 31.8c 11.8c 11.8c 19.8c 31.c8 11.c8 11.c8 19.c8"
    ], "Pink")
  board = s.board
  curplayer = s.curplayer
  actions_hook = s.actions_hook
  amask_white = string_to_booleans("62000000000000006e00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000670000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006d000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006b0000006800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  amask_black = string_to_booleans("00000000000000000000000064000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000")
  amask = amask_white
  finished = false
  winner = 0x00
  g = Game(board, curplayer, finished, winner, amask, amask_white, amask_black, actions_hook, nothing)
  return g
end
#
# Constructor from a given state. Consistency is ensured by updating the status.
function Game(s)
  board = s.board
  curplayer = s.curplayer
  actions_hook = s.actions_hook
  amask_white = []
  amask_black = []
  amask = amask_white
  finished = false
  winner = 0x00
  g = Game(board, curplayer, finished, winner, amask, amask_white, amask_black, actions_hook, nothing)
  update_status!(g)
  return g
end
#
GI.actions_mask(g::Game) = g.amask
GI.two_players(::Type{Game}) = true
GI.current_state(g::Game) = (board=g.board, actions_hook=g.actions_hook, curplayer=g.curplayer)
GI.white_playing(::Type{Game}, state) = state.curplayer == WHITE

#
function Base.copy(g::Game)
  history = isnothing(g.history) ? nothing : copy(g.history)
  Game(g.board, g.curplayer, g.finished, g.winner, copy(g.amask), copy(g.amask_white), copy(g.amask_black), copy(g.actions_hook), history)
end
#
###
# Reward shaping
###
#
function GI.game_terminated(g::Game)
  return g.finished
end
#
function GI.white_reward(g::Game)
  if g.finished
    g.winner == WHITE && (return  1.)
    g.winner == BLACK && (return -1.)
    return 0.
  else
    return 0.
  end
end

###################################
# GAME RULES                      #
###################################
#
###
# Return a 8-long boolean array to flag legal actions among all potential ones for
# a given board and originating bonbon with NW corner at provided column and row.
###
# The position of True values in the returned array and the subsequent value of a binary encoding
# of this boolean series are illustrated below.
# -----------------------
# *W *S *E *N /W /S /E /N
#  8  4  2  1  8  4  2  1 (legend for encoding the value of 1 action)
#  8  7  6  5  4  3  2  1 (legend for the binary vector encoding all possible actions for a bonbon)
# -----------------------
#           1           1
#        2           2   
#        3  3        3  3
#     4           4      
#     5     5     5     5
#     6  6        6  6   
#     7  7  7     7  7  7
#  8           8         
#  9        9  9        9
#  A     A     A     A   
#  B     B  B  B     B  B
#  C  C        C  C      
#  D  D     D  D  D     D
#  E  E  E     E  E  E   
#  F  F  F  F  F  F  F  F
# -----------------------
# *W *S *E *N /W /S /E /N
#  8  7  6  5  4  3  2  1 (legend for the binary vector encoding all possible actions for a bonbon)
#  8  4  2  1  8  4  2  1 (legend for encoding the value of 1 action)
# -----------------------
#
function legal_actions_boolean_mask_from_NW_of_origin(board::Board, column, row)
  if !(0 <= column < BOARD_SIDE) || !(0 <= row < BOARD_SIDE)
    return nothing
  end
  # No legal actions for cells either empty or with neither a North border nor a West border.
  if is_empty(board, column, row) || !has_N_border(board, column, row) || !has_W_border(board, column, row)
    return falses(NUM_ACTIONS_PER_CELL)
  end
  # Initialize permissions
  can_fuse_N = can_fuse_E = can_fuse_S = can_fuse_W = true
  can_divide_N = can_divide_E = can_divide_S = can_divide_W = false
  # Is bonbon a former figher?
  bonbon_is_former_fighter = is_former_fighter(board, column, row)
  # Check if bonbon has a North neighbor and both aren't former fighters
  if is_empty(board, column, row - 1) || bonbon_is_former_fighter && is_former_fighter(board, column, row - 1)
    can_fuse_N = false
  end
  # Check the North border of the bonbon until the NE corner is reached
  last_column = column
  while !has_E_border(board, last_column, row)
    last_column += 1
    # If a cell has an vertical border then fusing to the North isn't legal
    if has_W_border(board, last_column, row - 1)
      can_fuse_N = false
    end
  end
  # last_column, row are now coordinates of the NE corner
  # Check if bonbon has a East neighbor and both aren't former fighters
  if is_empty(board, last_column + 1, row) || bonbon_is_former_fighter && is_former_fighter(board, last_column + 1, row)
    can_fuse_E = false
  end
  # Check the East border of the bonbon until the SE corner is reached
  last_row = row
  while !has_S_border(board, last_column, last_row)
    last_row += 1
    # If a cell has an horizontal border then fusing to the East isn't legal
    if has_N_border(board, last_column + 1, last_row)
      can_fuse_E = false
    end
  end
  # last_column, last_row are now coordinates of the SE corner
  # Check if bonbon has a South neighbor and both aren't former fighters
  if is_empty(board, last_column, last_row + 1) || bonbon_is_former_fighter && is_former_fighter(board, last_column, last_row + 1)
    can_fuse_S = false
  else
    # Check the South border of the bonbon
    for i in column + 1:last_column
      # If a cell has an vertical border then fusing to the South isn't legal
      if has_W_border(board, i, last_row + 1)
        can_fuse_S = false
      end
    end
  end
  # Check if bonbon has a West neighbor and both aren't former fighters
  if is_empty(board, column - 1, row) || bonbon_is_former_fighter && is_former_fighter(board, column - 1, row)
    can_fuse_W = false
  else
    # Check the West border of the bonbon
    for i in row + 1:last_row
      # If a cell has an horizontal border then fusing to the West isn't legal
      if has_N_border(board, column - 1, i)
        can_fuse_W = false
      end
    end
  end
  # Check legal division moves
  # Vertical divisions
  if last_row > row
    can_divide_S = true
    # There are 2 possible vertical directions only if there's an odd number of rows
    # ie difference is even
    can_divide_N = (row - last_row) % 2 == 0
  end
  # Horizontal divisions
  if last_column > column
    can_divide_E = true
    # There are 2 possible horizontal directions only if there's an odd number of columns
    # ie difference is even
    can_divide_W = (column - last_column) % 2 == 0
  end
  # Return legal actions mask
  return [can_divide_N, can_divide_E, can_divide_S, can_divide_W, can_fuse_N, can_fuse_E, can_fuse_S, can_fuse_W]
end
  #
function update_players_actions_masks!(g::Game)
  g.amask_white = []
  g.amask_black = []
  try
    # Iterate on cells to merge all legal actions mask
    for column in 0:BOARD_SIDE - 1
      for row in 0:BOARD_SIDE - 1
        cell_amask = legal_actions_boolean_mask_from_NW_of_origin(g.board, column, row)
        if is_white(g.board, column, row)
          append!(g.amask_white, cell_amask)
          append!(g.amask_black, falses(NUM_ACTIONS_PER_CELL))
        else
          append!(g.amask_black, cell_amask)
          append!(g.amask_white, falses(NUM_ACTIONS_PER_CELL))
        end
      end
    end
  catch
    println("Error in update_actions_mask!(g::Game)")
    g.amask_white = nothing
    g.amask_black = nothing
  end
end
#
# Update the game status
function update_status!(g::Game)
  update_players_actions_masks!(g)
  g.amask = (g.curplayer == WHITE ? g.amask_white : g.amask_black)
  if any(g.amask)
    white_ratio = GI.heuristic_value(g)
    if white_ratio >= TO_CONQUER
      g.winner = WHITE
      g.finished = true
    elseif white_ratio <= 1 - TO_CONQUER
      g.winner = BLACK
      g.finished = true
    end
  else
    g.winner = 0
    g.finished = true
  end
end
#

function GI.play!(g::Game, action)
  board = Array(g.board)
  actions_hook = Array(g.actions_hook)
  # Define functions to move a cursor around the board
  step_N = (column, row) -> (column, row - 1)
  step_S = (column, row) -> (column, row + 1)
  step_W = (column, row) -> (column - 1, row)
  step_E = (column, row) -> (column + 1, row)
  # Unset former fighter bit for the whole board
  board = map(cell_value_unset_former_fighter, board)
  # Perform action on g
  if 0 <= action <= 2047
    try
      isnothing(g.history) || push!(g.history, action)
      (column, row) = (NW_column, NW_row) = index_to_column_row(action ÷ NUM_ACTIONS_PER_CELL + 1)
      action = action % NUM_ACTIONS_PER_CELL
      action_type = action & ACTION_TYPE_MASK
      action_direction = action % ACTION_DIRECTION_DIV
      if action_type == 0
        #
        # EXECUTE A DIVISION (add a border inside the bonbon)
        #
        # Select functions and variables to apply to the general division algorithm
        if action_direction in [DIRECTION_NORTH, DIRECTION_SOUTH]
          # Starting on bonbon's NW corner we always step South towards where to cut
          step_in_action_direction = step_S
          # Orthogonal direction relatively to the action direction
          step_in_orthog_direction = step_E
          # Test stopping borders
          has_closing_border_in_action_direction = has_S_border
          has_closing_border_in_orthog_direction = has_E_border
          # Add stopping borders
          add_closing_border_in_action_direction = add_S_border
          add_opening_border_in_action_direction = add_N_border
        else # action_direction in [DIRECTION_WEST, DIRECTION_EAST]
          # Starting on bonbon's NW corner we always step East towards where to cut
          step_in_action_direction = step_E
          # Orthogonal direction relatively to the action direction
          step_in_orthog_direction = step_S
          # Test stopping borders
          has_closing_border_in_action_direction = has_E_border
          has_closing_border_in_orthog_direction = has_S_border
          # Add stopping borders
          add_closing_border_in_action_direction = add_E_border
          add_opening_border_in_action_direction = add_W_border
        end
        # Apply the general division algorithm, starting from NW corner of origin bonbon
        (column, row) = (NW_column, NW_row)
        # Measure bonbon's dimension in the action direction
        dimension_in_action_direction = 1
        while !has_closing_border_in_action_direction(board, column, row)
          dimension_in_action_direction += 1
          (column, row) = step_in_action_direction(column, row)
        end
        # Return to the NW corner
        (column, row) = (NW_column, NW_row)
        # Move half of bonbon's dimension alongside the action direction, to position an
        # orthogonal border at the position rounded according to the the action direction
        # in case bonbon has an odd  dimension.
        for _ in 2:dimension_in_action_direction ÷ 2 + (action_direction in [DIRECTION_NORTH, DIRECTION_WEST] ? dimension_in_action_direction % 2 : 0)
          (column, row) = step_in_action_direction(column, row)
        end
        # Add a separation along the direction orthogonal to the action direction
        add_closing_border_in_action_direction(board, column, row)
        add_opening_border_in_action_direction(board, step_in_action_direction(column, row)...)
        while !has_closing_border_in_orthog_direction(board, column, row)
          (column, row) = step_in_orthog_direction(column, row)
          add_closing_border_in_action_direction(board, column, row)
          add_opening_border_in_action_direction(board, step_in_action_direction(column, row)...)
          # (The last addition won't have any effect if we step out of the board limits)
        end
      else
        #
        # EXECUTE A FUSION
        #
        # Select functions and variables to apply to the general fusion algorithm
        if action_direction == DIRECTION_NORTH
          step_in_action_direction = step_N
          step_in_action_reverse_direction = step_S
          # Does NW corner of origin bonbon touch destination bonbon?
          NW_touches_destination = true
          # Starting on bonbon's NW corner we measure bonbon's dimension in action direction
          # using South direction
          step_in_measured_action_direction = step_S
          # From where we arrived, measure bonbon's dimension in orthog direction
          # using East direction
          step_in_measured_orthog_direction = step_E
          # Orthogonal directions relatively to the action direction
          step_in_orthog_direction = step_E # Direction of 2nd cut
          step_in_orthog_reverse_direction = step_W # Reverse direction of 2nd cut
          # Test borders
          has_closing_border_in_measured_action_direction = has_S_border
          has_closing_border_in_measured_orthog_direction = has_E_border
          has_closing_border_in_action_direction = has_N_border
          has_closing_border_in_orthog_direction = has_E_border
          has_closing_border_in_orthog_reverse_direction = has_W_border
          # Add borders
          add_closing_border_in_action_direction = add_N_border
          add_opening_border_in_action_direction = add_S_border
          add_closing_border_in_orthog_direction = add_E_border
          add_opening_border_in_orthog_direction = add_W_border
          add_closing_border_in_orthog_reverse_direction = add_W_border
          add_opening_border_in_orthog_reverse_direction = add_E_border
          # Remove borders
          remove_closing_border_in_action_direction = remove_N_border
          remove_opening_border_in_action_direction = remove_S_border
        elseif action_direction == DIRECTION_SOUTH
          step_in_action_direction = step_S
          step_in_action_reverse_direction = step_N
          # Does NW corner of origin bonbon touch destination bonbon?
          NW_touches_destination = false
          # Starting on bonbon's NW corner we measure bonbon's dimension in action direction
          # using South direction
          step_in_measured_action_direction = step_S
          # From where we arrived, measure bonbon's dimension in orthog direction
          # using East direction
          step_in_measured_orthog_direction = step_E
          # Orthogonal directions relatively to the action direction
          step_in_orthog_direction = step_W # Direction of 2nd cut
          step_in_orthog_reverse_direction = step_E # Reverse direction of 2nd cut
          # Test borders
          has_closing_border_in_measured_action_direction = has_S_border
          has_closing_border_in_measured_orthog_direction = has_E_border
          has_closing_border_in_action_direction = has_S_border
          has_closing_border_in_orthog_direction = has_W_border
          has_closing_border_in_orthog_reverse_direction = has_E_border
          # Add borders
          add_closing_border_in_action_direction = add_S_border
          add_opening_border_in_action_direction = add_N_border
          add_closing_border_in_orthog_direction = add_W_border
          add_opening_border_in_orthog_direction = add_E_border
          add_closing_border_in_orthog_reverse_direction = add_E_border
          add_opening_border_in_orthog_reverse_direction = add_W_border
          # Remove borders
          remove_closing_border_in_action_direction = remove_S_border
          remove_opening_border_in_action_direction = remove_N_border
        elseif action_direction == DIRECTION_EAST
          step_in_action_direction = step_E
          step_in_action_reverse_direction = step_W
          # Does NW corner of origin bonbon touch destination bonbon?
          NW_touches_destination = false
          # Starting on bonbon's NW corner we measure bonbon's dimension in action direction
          # using East direction
          step_in_measured_action_direction = step_E
          # From where we arrived, measure bonbon's dimension in orthog direction
          # using North direction
          step_in_measured_orthog_direction = step_S
          # Orthogonal directions relatively to the action direction
          step_in_orthog_direction = step_N # Direction of 2nd cut
          step_in_orthog_reverse_direction = step_S # Reverse direction of 2nd cut
          # Test borders
          has_closing_border_in_measured_action_direction = has_E_border
          has_closing_border_in_measured_orthog_direction = has_S_border
          has_closing_border_in_action_direction = has_E_border
          has_closing_border_in_orthog_direction = has_N_border
          has_closing_border_in_orthog_reverse_direction = has_S_border
          # Add borders
          add_closing_border_in_action_direction = add_E_border
          add_opening_border_in_action_direction = add_W_border
          add_closing_border_in_orthog_direction = add_N_border
          add_opening_border_in_orthog_direction = add_S_border
          add_closing_border_in_orthog_reverse_direction = add_S_border
          add_opening_border_in_orthog_reverse_direction = add_N_border
          # Remove borders
          remove_closing_border_in_action_direction = remove_E_border
          remove_opening_border_in_action_direction = remove_W_border
        elseif action_direction == DIRECTION_WEST
          step_in_action_direction = step_W
          step_in_action_reverse_direction = step_E
          # Does NW corner of origin bonbon touch destination bonbon?
          NW_touches_destination = true
          # Starting on bonbon's NW corner we measure bonbon's dimension in action direction
          # using East direction
          step_in_measured_action_direction = step_E
          # From where we arrived, measure bonbon's dimension in orthog direction
          # using South direction
          step_in_measured_orthog_direction = step_S
          # Orthogonal directions relatively to the action direction
          step_in_orthog_direction = step_S # Direction of 2nd cut
          step_in_orthog_reverse_direction = step_N # Reverse direction of 2nd cut
          # Test borders
          has_closing_border_in_measured_action_direction = has_E_border
          has_closing_border_in_measured_orthog_direction = has_S_border
          has_closing_border_in_action_direction = has_W_border
          has_closing_border_in_orthog_direction = has_S_border
          has_closing_border_in_orthog_reverse_direction = has_N_border
          # Add borders
          add_closing_border_in_action_direction = add_W_border
          add_opening_border_in_action_direction = add_E_border
          add_closing_border_in_orthog_direction = add_S_border
          add_opening_border_in_orthog_direction = add_N_border
          add_closing_border_in_orthog_reverse_direction = add_N_border
          add_opening_border_in_orthog_reverse_direction = add_S_border
          # Remove borders
          remove_closing_border_in_action_direction = remove_W_border
          remove_opening_border_in_action_direction = remove_E_border
        end
        # Apply the general fusion algorithm, starting from NW corner of origin bonbon
        # ┼────────────────────────────┼          ┼────────────────────────────┼
        # │                     Corner1│          │                     Corner2│
        # │      Dest                 ^│          │        Dest               ^│
        # │     (up or left)          ^3          │       (down or right)     ^7
        # │                           ^│          │Final                      ^│
        # │<<<<<<<4<<<<<<<<<┼----4-----┼────1─────┼-----8----┼>>>>>>>>6>>>>>>>>│
        # │ProjPiv1    Pivot¦P1<<<<<<<B│NW>>>>>>>>│<<<<<<<<P2¦Pivot    ProjPiv2│
        # │                 5v         │  Origin v2         5^                 │
        # │ProjPiv2    Pivot¦P2>>>>>>>>│        SE│B>>>>>>>P1¦Pivot    ProjPiv1│
        # │<<<<<<<6<<<<<<<<<┼----8-----┼──────────┼-----4----┼>>>>>>>>4>>>>>>>>│
        # │v                      Final│          │v                           │
        # 7v                           │          │v                           │
        # │v                           │          3v                           │
        # │Corner2                     │          │Corner1                     │
        # ┼────────────────────────────┼          ┼────────────────────────────┼
        # This diagram illustrates the following algorithm for both possible horizontal moves.
        # The representation also accounts for both possible vertical moves.
        # Measure origin bonbon's dimension in the action direction (which will be the cut depth)
        # using only East or South directions since the measure is done starting on from NW corner.
        dimension_in_action_direction = 1
        while !has_closing_border_in_measured_action_direction(board, column, row)
          dimension_in_action_direction += 1
          (column, row) = step_in_measured_action_direction(column, row)
        end
        cut_depth = dimension_in_action_direction
        # From where we are, measure origin bonbon's dimension in the orthogonal direction
        # (which will be the cut span).
        dimension_in_orthog_direction = 1
        while !has_closing_border_in_measured_orthog_direction(board, column, row)
          dimension_in_orthog_direction += 1
          (column, row) = step_in_measured_orthog_direction(column, row)
        end
        # Register SE corner of origin bonbon where we have arrived
        (SE_column, SE_row) = (column, row)
        # Define the base position, which is 1 cell away in action direction from either NW corner
        # or SE corner of origin bonbon.
        (column, row) = (base_column, base_row) = step_in_action_direction((NW_touches_destination ? (NW_column, NW_row) : (SE_column, SE_row))...)
        # Store a 1st corner of destination bonbon, which will be used to set the former fighter bit
        # and set actions hooks on its whole area.
        # From base position, look for a border in orthogonal reverse direction.
        while !has_closing_border_in_orthog_reverse_direction(board, column, row)
          (column, row) = step_in_orthog_reverse_direction(column, row)
        end
        (dest_corner1_column, dest_corner1_row) = (column, row)
        #
        # 1st cut
        # Start penetration into destination bonbon from base position
        (column, row) = (base_column, base_row)
        # Traverse whole destination bonbon in action direction and add a separation between the visited
        # cells and the cells located 1 step away in the orthogonal reverse direction.
        # Also define a 1st pivot cell, where the penetrated area has same dimension than origin bonbon
        # in the action direction (or where destination bonbon border is reached in action direction)
        length_cut = 1
        add_closing_border_in_orthog_reverse_direction(board, column, row)
        add_opening_border_in_orthog_reverse_direction(board, step_in_orthog_reverse_direction(column, row)...)
        if length_cut == cut_depth || has_closing_border_in_action_direction(board, column, row)
          (pivot1_column, pivot1_row) = (column, row)
        end
        while !has_closing_border_in_action_direction(board, column, row)
          length_cut +=1
          (column, row) = step_in_action_direction(column, row)
          add_closing_border_in_orthog_reverse_direction(board, column, row)
          add_opening_border_in_orthog_reverse_direction(board, step_in_orthog_reverse_direction(column, row)...)
          # (The last addition won't have any effect if we step out of the board limits)
          if length_cut == cut_depth
            (pivot1_column, pivot1_row) = (column, row)
          end
        end
        # Adjust the cut depth and define 1st pivot position for the case where
        # origin bonbon is > destination bonbon in action dimension
        if length_cut < cut_depth
          cut_depth = length_cut
          (pivot1_column, pivot1_row) = (column, row)
        end
        # Store the projection of pivot1 on the furtherst border of destination bonbon for later use
        (pc1_column, pc1_row) = (column, row)
        #
        # 2nd cut
        # Cut destination bonbon from 1st pivot position in orthogonal direction for the same dimension
        # as origin bonbon in this direction, adding a separation between the visited cells and the cells
        # located 1 step away in the action direction.
        (column, row) = (pivot1_column, pivot1_row)
        for _ in 1:dimension_in_orthog_direction
          # NB Since the action is deemed legal, the destination bonbon is "big enough" to be cut in this
          # dimension for this distance. No risk to reach a border before the end of the loop.
          add_closing_border_in_action_direction(board, column, row)
          add_opening_border_in_action_direction(board, step_in_action_direction(column, row)...)
          (column, row) = step_in_orthog_direction(column, row)
        end
        # Define a 2nd pivot cell where the penetrated area has same dimension than the origin bonbon
        # in the orthogonal direction
        (pivot2_column, pivot2_row) = step_in_orthog_reverse_direction(column, row)
        #
        # 3rd cut
        # From 2nd pivot position
        (column, row) = (pivot2_column, pivot2_row)
        # Traverse whole destination bonbon in action direction and add a separation between the visited
        # cells and the cells located 1 step away in the orthogonal direction.
        add_closing_border_in_orthog_direction(board, column, row)
        add_opening_border_in_orthog_direction(board, step_in_orthog_direction(column, row)...)
        for _ in cut_depth:length_cut - 1
          (column, row) = step_in_action_direction(column, row)
          add_closing_border_in_orthog_direction(board, column, row)
          add_opening_border_in_orthog_direction(board, step_in_orthog_direction(column, row)...)
          # (The last addition won't have any effect if we step out of the board limits)
        end
        # Store the projection of pivot2 on the furtherst border of destination bonbon for later use
        (pc2_column, pc2_row) = (column, row)
        # Store a 2nd corner of destination bonbon, which will be used to set the former fighter bit
        # on its whole area. From the last visited cell, look for a border in orthogonal direction.
        while !has_closing_border_in_orthog_direction(board, column, row)
          step_in_orthog_direction(column, row)
        end
        (dest_corner2_column, dest_corner2_row) = (column, row)
        # 4th cut
        # Back to 2nd pivot position, cut destination bonbon from there in action reverse direction
        # for the cut depth, and add a separation between the visited cells and the cells located
        # 1 step away in the orthogonal direction.
        (column, row) = (pivot2_column, pivot2_row)
        for _ in 1:cut_depth
          add_closing_border_in_orthog_direction(board, column, row)
          add_opening_border_in_orthog_direction(board, step_in_orthog_direction(column, row)...)
          (column, row) = step_in_action_reverse_direction(column, row)
        end
        # Store the final cell reached for later use
        (final_column, final_row) = (column, row)
        #
        # Fuse
        # From base position, remove the separation between origin and destination bonbons
        (column, row) = (base_column, base_row)
        for _ in 1:dimension_in_orthog_direction
          remove_opening_border_in_action_direction(board, column, row)
          remove_closing_border_in_action_direction(board, step_in_action_reverse_direction(column, row)...)
          (column, row) = step_in_orthog_direction(column, row)
        end
        #
        # Register conquest
        # Attribute the conquered area from destination bonbon to origin bonbon's team.
        # Base and 2nd pivot positions form a diagonal of the area to paint.
        for column in min(base_column, pivot2_column):max(base_column, pivot2_column)
          for row in min(base_row, pivot2_row):max(base_row, pivot2_row)
            is_white(board, NW_column, NW_row) ? set_white(board, column, row) : set_black(board, column, row)
          end
        end
        #
        # Ensure a tuple represents coordinates of a cell which isn't out of the board limits
        in_boundaries = x -> max(0, min(BOARD_SIDE - 1, x))
        in_board = (column, row) -> (in_boundaries(column), in_boundaries(row))
        # For the extended origin bonbon and remaining pieces of destination bonbon,
        # update former fighters bit and update actions_hook to point to the right NW corner.
        function update_former_fighter_and_actions_hook((diag1_column, diag1_row), (diag2_column, diag2_row), (new_NW_column, new_NW_row))
          for column in min(diag1_column, diag2_column):max(diag1_column, diag2_column)
            for row in min(diag1_row, diag2_row):max(diag1_row, diag2_row)
              set_former_fighter(board, column, row)
              actions_hook[row + 1, column + 1] = (new_NW_column, new_NW_row)
            end
          end
        end
        # For the extended origin bonbon, use the diagonal between pivot1 and:
        # - SE of origin bonbon, if NW of origin bonbon touches destination bonbon
        # - NW of origin bonbon, otherwise.
        (diag1_column, diag1_row) = (pivot1_column, pivot1_row)
        if NW_touches_destination
          (diag2_column, diag2_row) = (SE_column, SE_row)
          (new_NW_column, new_NW_row) = (pivot1_column, pivot1_row)
        else 
          (diag2_column, diag2_row) = (NW_column, NW_row)
          (new_NW_column, new_NW_row) = (NW_column, NW_row)
        end
        update_former_fighter_and_actions_hook((diag1_column, diag1_row), (diag2_column, diag2_row), (new_NW_column, new_NW_row))
        # For remaining pieces of destination bonbon area, up to 3 parts between previously defined cells
        # 1st part, if corner 1 is distinct from the base position, spans from corner1
        # to (1 step away from) the projection of pivot1 along 1st cut
        if (dest_corner1_column, dest_corner1_row) != (base_column, base_row)
          (diag1_column, diag1_row) = (dest_corner1_column, dest_corner1_row)
          (diag2_column, diag2_row) = in_board(step_in_orthog_reverse_direction(pc1_column, pc1_row)...)
          (new_NW_column, new_NW_row) = (min(diag1_column, diag2_column), min(diag1_row, diag2_row))
          update_former_fighter_and_actions_hook((diag1_column, diag1_row), (diag2_column, diag2_row), (new_NW_column, new_NW_row))
        end
        # 2nd part, if its projection is distinct from pivot1, spans from (1 step away from) pivot1
        # to the projection of pivot2 along 3rd cut
        if (pivot1_column, pivot1_row) != (pc1_column, pc1_row)
          (diag1_column, diag1_row) = in_board(step_in_action_direction(pivot1_column, pivot1_row)...)
          (diag2_column, diag2_row) = (pc2_column, pc2_row)
          (new_NW_column, new_NW_row) = (min(diag1_column, diag2_column), min(diag1_row, diag2_row))
          update_former_fighter_and_actions_hook((diag1_column, diag1_row), (diag2_column, diag2_row), (new_NW_column, new_NW_row))
        end
        # 3nd part, if corner2 is distinct from pivot2, spans from corner 2 to
        # the final cell reached during 4th cut
        if (dest_corner2_column, dest_corner2_row) != (final_column, final_row)
          (diag1_column, diag1_row) = (final_column, final_row)
          (diag2_column, diag2_row) = (dest_corner2_column, dest_corner2_row)
          (new_NW_column, new_NW_row) = (min(diag1_column, diag2_column), min(diag1_row, diag2_row))
          update_former_fighter_and_actions_hook((diag1_column, diag1_row), (diag2_column, diag2_row), (new_NW_column, new_NW_row))
        end
      end
    catch e
      println("Exception in GI.play! while executing action ", action, " on the following board:")
      GI.render(g)
    end
    #
    # Finalize game update
    #
    g.board = Board(board)
    g.actions_hook = ActionsHook(actions_hook)
    g.curplayer = other_player(g.curplayer)
    update_status!(g)
  end
end

###################################
# MINMAX HEURISTIC                #
###################################
#
# Return the fraction of the non-empty board owned by the White player
function GI.heuristic_value(g::Game)
  cells_count = NUM_CELLS - count(cell_value_is_empty, g.board)
  white_count = count(cell_value_is_white, g.board)
  return Float16(white_count / cells_count)
end

###################################
# MACHINE LEARNING API            #
###################################
#
function flip_cell_color(c::Cell)
  if cell_value_is_empty(c)
    return c
  elseif cell_value_is_white(c)
    return cell_value_set_black(c)
  elseif cell_value_is_black(c)
    return cell_value_set_white(c)
  end
end
#
function flip_colors(board)
  return @SMatrix [
    flip_cell_color(board[row + 1, column + 1])
    for column in 0:BOARD_SIDE - 1, row in 0:BOARD_SIDE - 1]
end
#
# Vectorized representation: NUM_CELLS x NUM_CELLS x 6 array.
# Channels: empty, white, black, North border, West border, former fighter.
# The board is represented from the perspective of white (ie as if white were to play next)
function GI.vectorize_state(::Type{Game}, state)
  board = GI.white_playing(Game, state) ? state.board : flip_colors(state.board)
  return Float32[
    property_cell(board, column, row)
    for column in 0:BOARD_SIDE - 1,
      row in 0:BOARD_SIDE - 1,
        property_cell in [is_empty, is_white, is_black,
          has_N_border, has_E_border, has_S_border, has_W_border, is_former_fighter
        ]
  ]
end

###################################
# SYMMETRIES                      #
###################################
#
# Define non-identical symmetries and return an array of couples (cell_sym, action_sym)
function generate_dihedral_symmetries()
  #
  # 90° rotation (anti clockwise)
  rotate_cell(nothing) = nothing
  rotate_cell((column, row)) = (row, BOARD_SIDE - 1 - column)
  rotate_cell(value) = booleans_to_integer([cell_value_is_white(value), cell_value_is_black(value),
    cell_value_has_E_border(value), cell_value_has_S_border(value), cell_value_has_W_border(value), cell_value_has_N_border(value),
    cell_value_is_former_fighter(value)]
  )
  function rotate_action(action::Int)
    # New coordinates of source cell
    (column, row) = rotate_cell(index_to_column_row(action ÷ NUM_ACTIONS_PER_CELL) + 1)
    # Type (unchanged)
    type = (action & ACTION_TYPE_MASK) / ACTION_TYPE_MASK
    # New direction of action
    direction = (action % ACTION_DIRECTION_DIV + 3) % ACTION_DIRECTION_DIV
    return action_value(column, row, type, direction)
  end
  # -90° rotation (clockwise)
  inv_rotate_cell(nothing) = nothing
  inv_rotate_cell((column, row)) = (row, BOARD_SIDE - column)
  inv_rotate_cell(value) = booleans_to_integer([cell_value_is_white(value), cell_value_is_black(value),
    cell_value_has_W_border(value), cell_value_has_N_border(value), cell_value_has_E_border(value), cell_value_has_S_border(value),
    cell_value_is_former_fighter(value)]
  )
  function inv_rotate_action(action::Int)
    # New coordinates of source cell
    (column, row) = inv_rotate_cell(index_to_column_row(action ÷ NUM_ACTIONS_PER_CELL) + 1)
    # Type (unchanged)
    type = (action & ACTION_TYPE_MASK) / ACTION_TYPE_MASK
    # New direction of action
    direction = (action % ACTION_DIRECTION_DIV + 1) % ACTION_DIRECTION_DIV
    return action_value(column, row, type, direction)
  end
  #
  # 180° rotations
  rotate_cell_2 = rotate_cell ∘ rotate_cell
  rotate_action_2 = rotate_action ∘ rotate_action
  #
  # 270° rotations
  rotate_cell_3 = rotate_cell_2 ∘ rotate_cell
  rotate_action_3 = rotate_action_2 ∘ rotate_action
  #
  # flip along horizontal axis
  h_flip_cell(nothing) = nothing
  h_flip_cell((column, row)) = (column, BOARD_SIDE - row)
  h_flip_cell(value) = booleans_to_integer([cell_value_is_white(value), !cell_value_is_white(value),
    cell_value_has_S_border(value), cell_value_has_W_border(value), cell_value_has_N_border(value), cell_value_has_E_border(value),
    cell_value_is_former_fighter(value)]
  )
  function h_flip_action(value::Int)
    # New coordinates of former NW corner (which isn't NW corner any longer)
    (column, row) = h_flip_cell((column, row))
    # Type (unchanged)
    type = value & ACTION_TYPE_MASK = ACTION_TYPE_MASK ? 1 : 0
    # New direction
    direction = (value % ACTION_DIRECTION_DIV + 2) % ACTION_DIRECTION_DIV
    return action_value(column, row, type, direction)
  end
  # Return all tuples of (cell_sym, action_sym, inv_action_sym)
  return [
    (rotate_cell, rotate_action, rotate_action_3), (rotate_cell_2, rotate_action_2, rotate_action_2), (rotate_cell_3, rotate_action_3, rotate_action),
    (h_flip_cell, h_flip_action, h_flip_action), (h_flip_cell ∘ rotate_cell, h_flip_action ∘ rotate_action, rotate_action_3 ∘ h_flip_action),
    (h_flip_cell ∘ rotate_cell_2, h_flip_action ∘ rotate_action_2, rotate_action_2 ∘ h_flip_action), (h_flip_cell ∘ rotate_cell_3, h_flip_action ∘ rotate_action_3, rotate_action ∘ h_flip_action)
  ]
end
#
# Given a state state1 and a symmetry (sym_cell, sym_action(not used here), inv_sym_action) for cells
# and actions, return the pair (state2, σ) where state2 is the image of state1 by the symmetry and
# σ is the associated actions permutations, as an integer vector of size num_actions(Game).
# NB σ = inverse(sym_action) since if actions_mask1 corresponds to state1 and actions_mask2
# corresponds to state2, the following holds:
#   actions_mask2[action_index] == actions_mask1[σ(action_index)] and since
#                               == actions_mask1[j] with action_index == sym_action(j)
#   then j == σ(action_index) == inv_sym_action(action_index)
function apply_symmetry(state, sym_cell, inv_sym_action)
  # Apply the symmetry to the board and the actions hook table
  board = Array(EMPTY_BOARD)
  actions_hook = Array(EMPTY_ACTIONS_HOOK)
  for column in 0:BOARD_SIDE - 1
    for row in 0:BOARD_SIDE - 1
      # sym_cell moves cell (column, row) in the board and its actions hook in the actions hook
      # table to (newColumn, newRow)...
      (newColumn, newRow) = sym_cell(column, row)
      # ...also changing their values
      board[newRow + 1, newColumn + 1] = sym_cell(state.board[row + 1, column + 1])
      actions_hook[newRow + 1, newColumn + 1] = sym_cell(state.actions_hook[row + 1, column + 1])
      # (The new actions hook position won't be on a NW corner any longer)
    end
  end # Symmetry is applied to the board and actions hook table
  # Actions permutations is the inverse of sym_action
  actions_permutations = map(inv_sym_action, collect(0:NUM_ACTIONS_PER_CELL * NUM_CELLS - 1))
  # Update actions_hook so that all cells point to actual NW corners: search the new board for
  # new NW corners and set actions hook to these cells for all cells in their bonbon
  for column in 0:BOARD_SIDE - 1
    for row in 0:BOARD_SIDE - 1
      if has_N_border(board, column, row) && has_W_border(board, column, row)
        # Cell (column, row) is a new NW corner.
        # Store former NW corner's coordinates to be replaced in actions_hook by the new ones.
        (actions_hook_column, actions_hook_row) = actions_hook[row + 1, column + 1]
        # Determine the dimensions of this bonbon for which the new actions hook must be set
        width = height = 1
        while actions_hook[row + 1, column + 1 + width] == (actions_hook_column, actions_hook_row)
          width += 1
        end
        while actions_hook[row + 1 + height, column + 1] == (actions_hook_column, actions_hook_row)
          height += 1
        end
        # Set the actions hook for this bonbon to this NW corner instead of where sym_cell moved
        # the former NW corner
        for c in column:column + width - 1
          for r in row:row + height - 1
            actions_hook[r + 1, c + 1] = (column, row)
          end
        end # Actions hook table is updated
      end # New NW corner is processed
    end
  end # New board has been scanned
  # Return (s, σ)
  return (
    (board=Board(board), actions_hook=ActionsHook(actions_hook), curplayer=state.curplayer),
    Vector{Int}(actions_permutations)
  )
end
#
const SYMMETRIES = generate_dihedral_symmetries()
#
function GI.symmetries(::Type{Game}, s)
  return [apply_symmetry(s, sym_cell, inv_sym_action) for (sym_cell, sym_action, inv_sym_action) in SYMMETRIES]
end

###################################
# USER INTERFACE                  #
###################################
#
GI.action_string(::Type{Game}, a) = string(string(a ÷ NUM_ACTIONS_PER_CELL, base=16), " $(a & ACTION_TYPE_MASK == ACTION_TYPE_MASK ? '*' : '/') $(['N', 'E', 'S', 'W'][a % ACTION_DIRECTION_DIV + 1])")
#
function GI.parse_action(g::Game, str)
  try
    if length(str) == 4
      action_array = [str[1:2], str[3:3], str[4:4]]
    else
      action_array = split(str, ' ')
    end
    if length(action_array) != 3 return "length(action_array) != 3" end
    action_origin = parse(Int, action_array[1], base=16)
    if !(0 <= action_origin < NUM_CELLS) return "!(0 <= action_origin < NUM_CELLS)" end
    action_type = findfirst(isequal(action_array[2]), ["/", "*"]) - 1
    action_direction = findfirst(contains(action_array[3]), ["nN", "eE", "sS", "wW"]) - 1
    return action_origin * NUM_ACTIONS_PER_CELL + action_type * ACTION_TYPE_MASK + action_direction
  catch
    println("Error")
    nothing
  end
end
#
# The board is represented by a "print matrix" in which each cell represents either a piece of a board
# cell or a piece of border. Their encoding model is the same as for board cells (see CELLS section).
# Hence, the functions to test and change board cells values apply to the print matrix cells values.
# There's 1 row of border cells for 2 rows of "pulp" cells, 1 column of border cells for 2 columns of pulp cells.
#=        0  1  2  3  4  5  6  7  8  9  A  B  C  D  E  F 
        BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
      0 BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
      1 BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
        .................................................
        .................................................
        .................................................
      F BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPBPPB
        BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB
=#
const EMPTY_PRINT_MATRIX = @SMatrix zeros(Cell, 3BOARD_SIDE + 1, 3BOARD_SIDE + 1)
const PrintMatrix = typeof(EMPTY_PRINT_MATRIX)
#
column_row_to_print_matrix_pulp_corners(column, row) = (north_west=(row=3row+1, column=3column+1), south_east=(row=3row+2, column=3column+2))
column_row_to_print_matrix_N_border_corners(column, row) = (north_west=(row=3row, column=3column), south_east=(row=3row, column=3column+3))
column_row_to_print_matrix_S_border_corners(column, row) = (north_west=(row=3row+3, column=3column), south_east=(row=3row+3, column=3column+3))
column_row_to_print_matrix_W_border_corners(column, row) = (north_west=(row=3row, column=3column), south_east=(row=3row+3, column=3column))
column_row_to_print_matrix_E_border_corners(column, row) = (north_west=(row=3row, column=3column+3), south_east=(row=3row+3, column=3column+3))
#
# Gives a property of the board cell in (column, row) to the print matrix cells in an area.
# The property modifier is the argument function set_property.
# The corners of the area are provided by the argument function area_corners applied on column, row.
function print_cell_property_to_print_matrix(column, row, print_matrix, area_corners, set_property)
  (northwest, southeast) = area_corners(column, row)
  for r in northwest.row:southeast.row
    for c in northwest.column:southeast.column
      set_property(print_matrix, c, r)
    end
  end
end
#
function build_print_matrix(g::Game)
  board = g.board
  print_matrix = Array(EMPTY_PRINT_MATRIX)
  for column = 0:BOARD_SIDE - 1
    for row = 0:BOARD_SIDE - 1
      cell_value = board[row + 1, column + 1]
      for (test_cell_value, area_corners, set_property) in [
          (cell_value_has_N_border, column_row_to_print_matrix_N_border_corners, add_N_border),
          (cell_value_has_E_border, column_row_to_print_matrix_E_border_corners, add_E_border),
          (cell_value_has_S_border, column_row_to_print_matrix_S_border_corners, add_S_border),
          (cell_value_has_W_border, column_row_to_print_matrix_W_border_corners, add_W_border),
          (cell_value_is_white, column_row_to_print_matrix_pulp_corners, set_white),
          (cell_value_is_black, column_row_to_print_matrix_pulp_corners, set_black),
          (cell_value_is_former_fighter, column_row_to_print_matrix_pulp_corners, set_former_fighter)
      ]
        test_cell_value(cell_value) && print_cell_property_to_print_matrix(column, row, print_matrix, area_corners, set_property)
      end
    end
  end
  return PrintMatrix(print_matrix)
end
#
player_color(p) = p == WHITE ? crayon"fg:white bg:magenta" : crayon"fg:white bg:green"
player_name(p)  = p == WHITE ? "Pink" : "Green"
#
function cell_color(c)
  if cell_value_has_N_border(c) || cell_value_has_E_border(c) || cell_value_has_S_border(c) || cell_value_has_W_border(c)
    return crayon"fg:white bg:black"
  elseif cell_value_is_white(c)
    return cell_value_is_former_fighter(c) ? crayon"fg:black bg:light_magenta" : crayon"fg:white bg:magenta"
  elseif cell_value_is_black(c)
    return cell_value_is_former_fighter(c) ? crayon"fg:black bg:light_green" : crayon"fg:white bg:green"
  else
    return crayon""
  end
end
#
# FOR DEBUG PURPOSE ONLY
# Display a print matrix
function print_print_matrix(print_matrix::PrintMatrix)
  # Print column labels
  print("  ")
  for c in 1:3BOARD_SIDE + 1
    print(" ", string(c, pad=2))
  end
  print("\n")
  # Print board
  for r in 1:3BOARD_SIDE + 1
    # Print row label
    print(string(r, pad=2), " ")
    for c in 1:3BOARD_SIDE + 1
      print_value = print_matrix[r, c]
      print(string(print_value, base=16, pad=2), " ")
    end # Row is completely printed
    print("\n")
  end
end
#
# Print the board
function GI.render(g::Game; with_position_names=true, botmargin=true)
  pname = player_name(g.curplayer)
  pcol = player_color(g.curplayer)
  print(pcol, pname, " plays:", crayon"reset", "\n\n")
  board = g.board
  amask = g.amask
  print_matrix = build_print_matrix(g)
  print(" ")
  # Print column labels
  for c in 0:BOARD_SIDE - 1
    print("    ", string(c, base=16))
  end
  print("\n")
  # Print board
  for r in 1:3BOARD_SIDE + 1
    row = (r - 1) ÷ 3
    if (r - 2) % 3 == 0
      # Print row label
      print(string(row, base=16))
    else
      print(" ")
    end
    print(" ")
    for c in 1:3BOARD_SIDE + 1
      column = (c - 1) ÷ 3
      print_value = print_matrix[r, c]
      # Determine which char to print if not " " (background) :
      # If border cell:  graphic char with horizontal and/or vertical dash
      # If pulp cell: NW coordinates and encoding of legal actions on NW corner
      if cell_value_has_N_border(print_value) || cell_value_has_E_border(print_value) || cell_value_has_S_border(print_value) || cell_value_has_W_border(print_value)
        # Cell is a border cell, convert it to graphical char
        print_mark = ["─", "│", "┼", "─", "─", "┼", "┼", "│", "┼", "│", "┼", "┼", "┼", "┼", "┼"][(print_value % CELL_FORMER_FIGHTER) ÷ CELL_H_BORDER_NORTH]
        if (c - 1) % 3 in [1, 2]
          print_mark = print_mark * print_mark
        end
      elseif print_value == 0 # Cell is empty
        print_mark = " "
        if (c - 1) % 3 in [1, 2]
          print_mark = print_mark * print_mark
        end
      else # Cell is a pulp cell
        if has_N_border(board, column, row) && has_W_border(board, column, row)
          # Corresponding board cell is a NW corner => print coordinates
          if ((r - 1) % 3) == 1
            # North pulp cells of NW board cell => print coordinates
            if ((c - 1) % 3) == 1
              # NW pulp cell of NW board cell => print column
              print_mark = " " * string(column, base=16)
            else
              # NE pulp cell of NW board cell => print row
              print_mark = string(row, base=16) * " "
            end
          elseif ((r - 1) % 3) == 2
            # South pulp cells of NW board cell => print legal actions code
            if ((c - 1) % 3) == 1
              # SW pulp cell of NW board cell => print 1st char of legal actions code (fusions)
              first_action = (column_row_to_index((column, row)) - 1) * NUM_ACTIONS_PER_CELL + 1
              print_mark = " " * string(booleans_to_integer(amask[first_action + 4:first_action + 7]), base=16)
            else
              # SE pulp cell of NW board cell => print 2nd char of legal actions code (divisions)
              first_action = (column_row_to_index((column, row)) - 1) * NUM_ACTIONS_PER_CELL + 1
              print_mark = string(booleans_to_integer(amask[first_action:first_action + 3]), base=16) * " "
            end
          end # Pulp cell of NW corner has its print_mark
        else
          # Pulp cell of non-NW corner
          print_mark = "  "
        end # Pulp cells have their print_mark
      end # All cells have their print_mark
      print(cell_color(print_value), print_mark, crayon"reset")
    end # Row is completely printed
    if (r - 2) % 3 == 1
      # Print row label
      print(" ", string(row, base=16))
    end
    print("\n")
  end
  # Print column labels
  for c in 0:BOARD_SIDE - 1
    print("    ", string(c, base=16))
  end
  print("\n")
  botmargin && print("\n")
end

function read_row!(row::Int, input::String, board::Array, actions_hook::Array)
  cells = split(input[1:length(input)], " ")
  for column in 1:BOARD_SIDE
    values = split(cells[column], ".")
    board[row, column] = parse(Int, values[1], base=16)
    c = parse(Int, values[2][1], base=16)
    r = parse(Int, values[2][2], base=16)
    actions_hook[row, column] = (c, r)
  end
end

function read_state(rows::Array, player::String)
  board = Array(EMPTY_BOARD)
  actions_hook = Array(EMPTY_ACTIONS_HOOK)
  try
    for row in 1:BOARD_SIDE
      input = rows[row]
      read_row!(row, input, board, actions_hook)
    end
    curplayer = player == player_name(BLACK) ? BLACK : WHITE
    return (board=Board(board), actions_hook=ActionsHook(actions_hook), curplayer=curplayer)
  catch e
    return nothing
  end
end

function dump_state(g::Game)
  for row in 1:BOARD_SIDE
    for column in 1:BOARD_SIDE
      cell_value = g.board[row, column]
      actions_hook = g.actions_hook[row, column]
      print(string(cell_value, base=16, pad=2), ".",
        string(actions_hook[1], base=16), string(actions_hook[2], base=16), " ")
    end
    print("\n")
  end
  print(player_name(g.curplayer))
end

function GI.read_state(::Type{Game})
  board = Array(EMPTY_BOARD)
  actions_hook = Array(EMPTY_ACTIONS_HOOK)
  try
    for row in 1:BOARD_SIDE
      input = readline()
      cells = split(input[1:length(input) - 1], " ")
      for column in 1:BOARD_SIDE
        values = split(cells[column], ".")
        board[row, column] = parse(Int, values[1], base=16)
        c = parse(Int, values[2][1], base=16)
        r = parse(Int, values[2][2], base=16)
        actions_hook[row, column] = (c, r)
      end
    end
    curplayer = readline() == player_name(BLACK) ? BLACK : WHITE
    return (board=board, actions_hook=actions_hook, curplayer=curplayer)
  catch e
    return nothing
  end
end
