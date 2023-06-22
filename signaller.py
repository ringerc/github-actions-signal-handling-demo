#!/usr/bin/env python3

import sys
import os
import time
import signal

signaller_log = open("signaller.log", "w")

fatal_sigs = [signal.SIGINT, signal.SIGTERM, signal.SIGQUIT, signal.SIGHUP, signal.SIGPIPE, signal.SIGABRT]
continue_on_sigs=[]

def print_msg(msg):
    for f in (sys.stderr, signaller_log):
        f.write('signaller: ' + msg + "\n")
        f.flush()

def handler(signum, frame):
  signame = signal.Signals(signum).name
  print_msg(f'signal handler called with signal {signame} ({signum}) at {time.time()}')
  sys.stderr.flush()
  signaller_log.flush()
  if signum not in continue_on_sigs:
      print_msg(f'exiting on {signal.Signals(signum).name}')
      sys.exit(1)


def main(args):
    global continue_on_sigs
    continue_args_list = args[1:]
    if not continue_args_list:
        # by default, mask SIGINT
        continue_args_list = ['SIGINT']
    continue_on_sigs = [ signal.Signals[signame.upper()] for signame in continue_args_list if signame != "" ]
    print_msg(f"continue on sigs: {continue_on_sigs}")
    for sig in fatal_sigs:
        signal.signal(sig, handler)

    print_msg(f"my pid is {os.getpid()}")
    while True:
      print_msg(f"tick {time.time()}")
      sys.stderr.flush()
      signaller_log.flush()
      time.sleep(1);

if __name__ == '__main__':
    main(sys.argv)
