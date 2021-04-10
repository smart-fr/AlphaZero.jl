module Examples

  using ..AlphaZero

  include("../games/tictactoe/main.jl")
  export Tictactoe

  include("../games/connect-four/main.jl")
  export ConnectFour

  include("../games/bonbon-rectangle/main.jl")
  export ConnectFour

  include("../games/grid-world/main.jl")
  export GridWorld

  const games = Dict(
    "grid-world" => GridWorld.GameSpec(),
    "tictactoe" => Tictactoe.GameSpec(),
    "bonbon-rectangle" => BonbonRectangle.GameSpec(),
    "connect-four" => ConnectFour.GameSpec())

  const experiments = Dict(
    "grid-world" => GridWorld.Training.experiment,
    "tictactoe" => Tictactoe.Training.experiment,
    "bonbon-rectangle" => BonbonRectangle.Training.experiment,
    "connect-four" => ConnectFour.Training.experiment)

end