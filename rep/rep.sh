#!/bin/bash

BLUE='\033[1;34m'
NC='\033[0m' # No Color

mkdir rep/out

for i in {1..100}
do
  echo -e "${BLUE}Running experiment #$i${NC}"
  rm -rf sessions
  julia --project --color=yes -t 6 scripts/alphazero.jl --game tictactoe train 2>&1 | tee rep/out/$i.log
done