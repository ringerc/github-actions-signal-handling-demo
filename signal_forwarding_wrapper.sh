#!/bin/bash
#
# Trying to make a bash wrapper reliably propagate signals to child processes
# then wait for them to exit and exit itself, behaving to the parent proc as if
# the child had been 'exec'd (but with the ability to run subsequent steps).
#
# This should not be necessary in sane environments, because job control
# systems should preferably signal the *process group* when terminating a job,
# or at least offer control over whether the group or just leader is signalled.
# Unfortunately, as usual, GitHub Actions is not a sensible job control system.
# It doesn't document its signal handling on job cancellation at all, and
# observationally speaking it appears that they signal only the leader process.
#
# It's impossible to do this perfectly - in particular, child process exit
# codes greater than 127 cannot be forwarded, nor can the wrapper sensibly fake
# exiting with a fatal signal with potential side-effects like SIGABRT or
# SIGSEGV if the child exited with that signal.
#
# But this script at least ensures that when the bash process is signalled, any
# background jobs it's running will be waited for, then the script will exit
# with the exit code of the last background job to exit.
#
# For it to work, all child processes for which signal handling delegation is
# required MUST run as background jobs using & then be waited for with the
# 'wait' built-in. That's because bash defers signal traps when it's blocked on
# foreground child process, so we have no way to forward the signal received by
# bash to the child process.
#
# You should NOT send the signals using foreground terminal keyboard strokes like
# Ctrl-C or CTRL-\ because a foreground shell session will deliver these to the
# whole process group. Use the kill command on this shell's pid instead.
#

# enable set -m for job control
set -e -E -u -o pipefail

child_pid=
last_signal=

# If you want to ignore CTRL-C (SIGINT)
declare -a trapped_signals=(SIGINT)

# if you also want to ignore CTRL-\ a.k.a. CTRL-Break (SIGQUIT)
# and a direct SIGTERM:
#trapped_signals+=(SIGTERM SIGQUIT)

# block until child proces exits, changes status or signal
# received.
#
# Per bash docs:
#    "When Bash receives a SIGINT, it breaks out of any executing loops"
# so we can't return control from a SIGINT handler and continue here,
# instead we must loop inside the handler.
#
function wait_for_child_exit() {
  if [ -z "${child_pid}" ];
  then
    echo 1>&2 "wrapper: nothing to wait for in wait_for_child_exit(), ending"
    return
  fi
  echo 1>&2 "wrapper: waiting for child ${child_pid} to exit"
  while : ; do
    echo 1>&2 "wrapper: wait -n"
    wait_exit=0
    wait -n "$child_pid" || wait_exit=$?
    echo 1>&2 "wrapper: wait exited with ${wait_exit}"
    if [ "$wait_exit" -eq 127 ]; then
      # If the fatal signal delivered to the shell was sent to the process
      # group, or the child proc exited normally between when the shell was
      # signalled and the wait began:
      echo 1>&2 "wrapper: nothing to wait on, pid ${child_pid} must be gone"
      break
    elif [ "$wait_exit" -gt 128 ]; then
      # FIXME: Cannot easily tell if child exited with a signal or wait was
      # interrupted by a signal. Should really test for child pid existence
      # here, and break out if child pid is gone, that way we could better
      # propagate child signal exit code. But for now, just re-enter wait loop.
      echo 1>&2 "wrapper: wait interrupted by or child exited with signal $((wait_exit-128))"
      echo 1>&2 "wrapper: will propagate signals then continue"
    else
      echo 1>&2 "wrapper: child proc died with $wait_exit"
      break
    fi
  done
  echo 1>&2 "wait_for_child_exit() ending"
}

# This signal handler is called from a trap. If bash is blocked
# on a child process, it only invokes signal traps once the child
# process returns. So this'll only work if job control is used to
# run the child process in the background then wait on it.
#
handle_signal() {
  signame=$1
  last_signal=$signame
  printf "wrapper handle_signal $signame: got signal\n"
  # When signal next delivered, this trap will be re-entrantly invoked.
  # We want to skip signalling the process group again, otherwise there
  # would be an infinite loop.
  # If we just set the signal handler to a no-op temporarily (like SIG_IGN) we
  # might ignore another signal delivery that comes in at the same time we're
  # signalling the process group.
  # Unfortunately bash doesn't seem to play nice here - whether using an associative
  # array or a ${!varname} and printf -v style dynamic var, bash tends to crash with
  #   malloc(): unaligned fastbin chunk detected 3
  # after a few invocations of the handler. So we're stuck with the small race
  # that might cause a signal to get inadvertently ignored.
  trap "echo 1>&2 'wrapper handle_signal $signame: ignoring signal'" $signame
  # When the pid passed to kill is 0, all the processes in the current process
  # group are signaled, so this is a shortcut for kill -$$ (if this shell is
  # the process group leader).
  echo 1>&2 "wrapper handle_signal $signame: signalling process group"
  kill "-${signame}" 0
  # signal re-delivery was handled, so reinstall signal handler in case of
  # repeat signal. A repeat counter could be used to limit this.
  #
  # There's a race here where a rapid signal re-delivery will terminate the
  # script. It could be defended against by leaving this handler in place, and
  # 
  # 
  trap "handle_signal $signame" "$signame"
  # Return control to the outer loop to continue waiting for the child process
  # to exit.
  echo 1>&2 "wrapper hande_signal $signame: exiting trap"
}

# Install signal handlers for the fatal signals we want to intercept and forward
# to the child process, then wait for exit on.
#
# Signals not listed here will get default bash behaviour; see
# https://www.gnu.org/software/bash/manual/html_node/Signals.html
#
for trapped_signal in "${trapped_signals[@]}"; do
  trap "handle_signal '${trapped_signal}'" "${trapped_signal}"
done

# This handler should never run, it's here to detect mistakes in the script.
function unclean_exit() {
  echo 1>&2 "wrapper: exiting unexpectedly before end of script or signal handler"
}
trap 'unclean_exit' EXIT

# Do the script's real work.
# 
# In a nontrivial script you may need to do a series of commands for which you
# require signal handling and forwarding. Just run each command with & then
# wait_for_child_exit .
#
# It's also possible to adapt the script to run multiple jobs at once, then
# loop in 'wait' without the -n flag until it returns 127 to indicate all
# child processes are exited.
#
# If you prefer, you could also omit the outer wait_for_child_exit loop,
# instead using a bare 'wait' or 'wait -n'; in this case, you will need
# to add the wait_for_child_exit loop in the signal handler instead,
# then ensure the signal handler explicitly exits.
#
echo 1>&2 "wrapper: my pid is $$"
echo $$ > wrapperpid
python3 signaller.py "${trapped_signals[@]}" &
child_pid=$!
echo 1>&2 "wrapper: forked signaller.py with pid ${child_pid}"
echo "${child_pid}" > childpid
wait_for_child_exit

echo 1>&2 "wrapper: outside wait loop at top level"

rm -f wrapperpid childpid >&/dev/null || true

trap EXIT
if [ -z "${last_signal}" ]; then
  # Propagate child proc exit code
  exit $wait_exit
else
  # got fatal signal. To ensure correct signal exit code, uninstall signal
  # handlers and self-signal. This assumes all the signals we might have
  # trapped are fatal signals.
  for trapped_signal in "${trapped_signals[@]}"; do
    trap "${trapped_signal}"
  done
  trap EXIT
  echo 1>&2 "Re-delivering fatal signal ${last_signal} to self"
  kill "-$last_signal" "$$"
  echo 1>&2 "wrapper: unreachable, should've died on fatal signal" && exit 127
fi

# vim: ts=2 sw=2 et ai
