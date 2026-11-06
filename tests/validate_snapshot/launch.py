#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Category: Test
Module: tests/validate_snapshot/launch.py
Purpose: Start a command in the background with SIGINT/SIGQUIT at their defaults, in its own session.
"""
# Usage: python3 launch.py COMMAND [ARGS...] &   ($! is the command's PID: this process execs it)
# A background job of a non-interactive shell starts with SIGINT ignored, and bash cannot trap a
# signal that was ignored on entry, so "kill -INT" would silently do nothing. This resets them,
# moves the command into its own session/process group (so a test can signal the whole group, as a
# terminal's Ctrl-C does) and execs it.

import os
import signal
import sys

if len(sys.argv) < 2:
    sys.exit("usage: launch.py COMMAND [ARGS...]")
for sig in (signal.SIGINT, signal.SIGQUIT, signal.SIGTERM, signal.SIGHUP, signal.SIGPIPE):
    signal.signal(sig, signal.SIG_DFL)
try:
    os.setsid()
except OSError:
    pass
os.execvp(sys.argv[1], sys.argv[1:])
