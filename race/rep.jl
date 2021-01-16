# This is a quick script to replicate a race condition that only seems to occur
# with Julia 1.5 (not on 1.4.2 or on 1.6.0 nightly)

using AlphaZero

@assert Threads.nthreads() > 1

function sim(i)
  session = Session(Examples.experiments["tictactoe"])
  UserInterface.Log.section(session.logger, 1, "Iteration $i")
  UserInterface.run_benchmark(session)
end

for i in 1:1000
  sim(i)
end