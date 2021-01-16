# Race Condition bug

## Replicating

To replicate the race condition bug, you can run of of the following two commands:

```sh
bash race/rep.sh
julia --project -t 6 --color=yes race/rep.jl
```

We suggest the first method though as the problem tends to replicate quicker when
restarting Julia between each run.