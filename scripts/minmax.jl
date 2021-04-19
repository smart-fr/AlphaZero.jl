using AlphaZero

depth = 3
gspec = Examples.games["bonbon-rectangle"]
computer = MinMax.Player(depth=depth, amplify_rewards=true, τ=0.2)
interactive!(gspec, computer, Human())