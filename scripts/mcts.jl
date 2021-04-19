using AlphaZero

gspec = Examples.games["bonbon-rectangle"]
mcts = MCTS.Env(gspec, MCTS.RolloutOracle(gspec))
computer = MctsPlayer(mcts, niters=10, timeout=15.0, τ=ConstSchedule(0.5))

interactive!(gspec, computer, Human())
#explore(computer, gspec)