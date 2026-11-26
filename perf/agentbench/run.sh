#!/bin/sh
# On the Mac mini: run a plan with xbench.py from Ardia's bench (BENCH_DIR), scratch in BENCH_HOME.
#   run.sh PLAN.json RESULTS_DIR [--until ISO]      (use nohup; log on stderr)
set -eu
root="${XB_ROOT:-$HOME/hc/ardia-site-bench/agentbench}"
export BENCH_HOME="$root/home"
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd "$root/plugins/plugins/cli/bench"
exec /usr/bin/python3 -I harness/xbench.py "$@"
