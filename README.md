# Handling github job cancellation signals

Demos for github job cancellation signal handling to show exactly how
it behaves. (Spoiler: badly).

Why is this needed? Because the github actions docs for this appear to be
nonexistent at time of writing, and the answer on the relevant [github
"community" forum post](https://github.com/orgs/community/discussions/26311)
are nowhere near clear or detailed enough. (It's always possible I'm just bad
at searching, but you'd think the post above would link to the docs if that
were the case).

I was having issues with Terraform runs leaving lock files lying around on S3
state storage buckets when github jobs were cancelled. This shouldn't be
happening, because terraform will try to clean up and remove its lock file when
gracefully killed. Given the lack of usable github docs, I had to write a demo
to find out what exactly happens when a github actions job is cancelled.

**TL;DR**: unless special care is taken, child processes don't get any signal
delivered to them before they're hard-destroyed when a github actions job is
cancelled. As a workaround, `if: always()` blocks can be used to do necessary
cleanup steps as they run on cancel. Or for simple cases you can `exec` your
process, so it becomes the top-level process for a step and does receive
signals on cancel.

## The demo code

Five github actions demonstrate how github job cancellation signal handling
works. To try them you must run them via github actions, then cancel them
using the github actions UI.

* [`cancel-test-exec-child-ignore-sigquit.yaml`](.github/workflows/cancel-test-exec-child-ignore-sigquit.yaml):
  `exec`'s [a script](./signaller.py) that ignores `SIGINT`, `SIGQUIT` and
  `SIGTERM`. It shows that github delivers a `SIGINT`, waits 7.5s, delivers a
  `SIGTERM`, waits 2.5s, then presumably sends a `SIGKILL`. It then runs any
  `if: always()` steps after destroying all processes running in the killed
  step.

* [`cancel-test-exec-child.yaml`](.github/workflows/cancel-test-exec-child.yaml):
  `exec`'s the same script, but only ignores `SIGINT`, so the child process
  will terminate on the subsequent `SIGTERM`. This is more realistic, and the
  subsequent test cases do the same thing.

  Since it checks the process tree in the `if: always()` cleanup step, this
  test also shows that github destroys all processes under the step recursively
  before it begins any cleanup steps. It must be keeping track of all
  processes.
  
* [`cancel-test-shell-plain.yaml`](.github/workflows/cancel-test-shell-plain.yaml):
  Represents the "normal" case of a github actions step using a bash shell that
  runs a child process as a blocking command within the shell. You will see that
  the child process (the same script as the above demo) *does not* receive any
  `SIGINT` or `SIGTERM`. The bash leader process does, but you can't see that because
  bash defers `trap` execution until child process exit when blocking waiting for
  a child process, and the whole lot gets `SIGKILL`'d before the child process exits
  to return control to bash.

  This means that the workload running in the inner script got no chance to clean up
  its work.

* [`cancel-test-shell-sigfwd.yaml`](.github/workflows/cancel-test-shell-sigfwd.yaml):
  Demonstrates that it is possible to use a top-level shell with job control
  enabled as a process-group leader that forwards signals to its child
  processes. It's *ugly* though. Because of deferred traps, every subcommand
  that needs a chance to handle signals must be run as a background job with
  `&` then `wait`ed for, and there's plenty of fiddling about to make it work.

  See comments in
  [`signal_forwarding_wrapper.sh`](./signal_forwarding_wrapper.sh) for details.

* [`cancel-test-long-running-if-always.yaml`](.github/workflows/cancel-test-long-running-if-always.yaml):
  Explores what happens when an `if: always()` step takes too long or
  refuses to exit.

  It seems like github will let the cleanup run for about 4 minutes then kill
  it, initially with a `SIGINT`.

  Repeated cancels sent during the `if: always()` run appear to have no effect.

  Interestingly, it the job won't retain logs if the cleanup job doesn't exit
  within the overall job timeout, you can only see the logs if you were
  streaming them during the run.

## Why child-process tasks don't get a chance to clean up on job cancel

Consider a simple job step like:

```
   - name: whatever
     shell: bash
     run: |
       my-long-running-task
```

You might expect that if the actions run is cancelled, `my-long-running-task`
would get some kind of signal to give it a chance to clean up before the whole
actions runner is destroyed. As if you'd pressed `Ctrl-C` in the shell, then
waited a bit, then pressed `Ctrl-\` (break).

In reality, it exits (presumably on `SIGKILL`) without any chance to clean up.

**On cancel, github actions delivers a `SIGINT` only to the top-level process
for the current step of each active job**. Then 7.5s later it delivers a
`SIGTERM`, again to the top-level process only. 2.5s later it sends a `SIGKILL`
(presumably to everything in the process tree).

You'd think that's fine. But **signals don't propagate down process trees**,
so child processes running under the top-level step process won't see a signal
unless the top-level process explicit forwards it.

A typical Github actions job will be a `run` step with `shell: bash` that
invokes some task as a child process of the step's top-level shell. If you
cancel a job with this, github actions will signal the top pid (the shell) with
`SIGINT`. 

Bash will [behave as documented](https://www.gnu.org/software/bash/manual/html_node/Signals.html):

> When Bash is running without job control enabled and receives SIGINT while
> waiting for a foreground command, it waits until that foreground command
> terminates and then decides what to do about the SIGINT [...]

The process will never get that `SIGINT`, so it'll never exit and bash never
gets to do anything. And you can't use a trap on `SIGINT` to forward signals
to the child process(es) either, because:

> If Bash is waiting for a command to complete and receives a signal for which
> a trap has been set, the trap will not be executed until the command
> completes.

This issue isn't specific to bash, it's just a useful demo because it's the
widely used default for github actions.

## What github actions should be doing

Instead of signalling the parent process, github actions should at least offer
the option of signalling *all processes* running under the current step.

A simple albeit imperfect way to do this is to spawn the `bash` shell *as a
process group leader* by setting the `-m` flag. Github actions would then
signal *the whole process group* for each active step when a job cancel request
is sent by sending a kill signal to the negated pid of the leader shell. This
works well for simple cases, but process groups aren't nestable, so if some
workload under the step creates its own process group it'll be orphaned and
won't receive the process-group signal unless its parent notices and propagates
it explicitly.

It'd be better still if it used linux sessions, pid namespaces, or other
suitable constructs that can properly contain all processes in the step and
signal them all at once.

While bash's usual awful-ness contributes to making this hard to get right,
GitHub's lack of docs or any means to configure the job signal handling to
deliver to a process group certainly makes it much worse.

## Workarounds

Until/unless github improves their actions runners with configurable cancel
timeouts and the option to signal the whole process tree, there are a few
possible workarounds:

* `exec` any long-running tasks that might need a chance to respond to `SIGINT`
  or `SIGTERM` with cleanup steps before termination, so they become the top-level
  process in a `step`. Split series of such tasks into separate github actions
  steps instead of a single step with multiple sub-commands called by a shell.

  This'll work ok if your job can respond to `SIGINT` and clean up within 7.5s,
  or to `SIGTERM` and clean up within 2.5s. But if it's relying on network
  resources that's going to be iffy - and it probably is, since the runner
  itself is usually stateless.

* Have your command or the controlling shell write a state file to the runner
  working directory and remove it on clean exit. Then use an `if: always()` action
  to check for the state file and perform the cleanup actions if found.

  There is going to be a race between the task completing its work and deleting the
  state file, so you'll need to ensure that the cleanup action is idempotent.
  In other words, it must be safe to run the cleanup steps twice.
  
  For example, if you're unlocking something you should write a unique
  lock-instance-id to your state file. Then when you unlock it, you can ensure
  the unlock request gets silently ignored if the lock is currently locked with
  a different lock-instance-id. Handily, this is how Terraform `force-unlock`
  works.

  It's unclear what the rules for `if: always()` actions are during github
  actions cancellation. From a quick experiment it looks like you've got about
  4 minutes to complete cleanup, and `if: always()` steps ignore cancel
  requests.

* Hope that steps inside Docker containers work better?

  I haven't tested this yet but maybe github has saner cancel behaviour when
  a job runs in a user-defined container?

## To investigate further

* How github behaves with jobs using containers
* Why github actions, which is a *job control system*, doesn't document
  fundamental and basic properties of job cancellation behaviour.

## See also

* [bash signal handling](https://www.gnu.org/software/bash/manual/html_node/Signals.html)
* [How to propagate a signal to child processes from a Bash script](https://linuxconfig.org/how-to-propagate-a-signal-to-child-processes-from-a-bash-script)
