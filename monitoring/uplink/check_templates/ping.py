#!/usr/bin/env python3

from __future__ import print_function

import re
import subprocess
import sys

PINGS=20

def fatal(return_code, *args, **kwargs):
    print(*args, file=sys.stderr, **kwargs)
    sys.exit(return_code)

# Split target from application name
delim = -1
try:
  delim = sys.argv[0].index('_')
  if delim >= len(sys.argv[0]):
    raise ValueError()
except:
  fatal(1, "usage: ping_<target>")

target = sys.argv[0][delim + 1:]

# Run ping binary
stdout = ''
try:
  res = subprocess.run(['ping', '-nqc', str(PINGS), '-w', str(PINGS + 1), target], encoding='utf-8', capture_output=True)
  if res.returncode != 0:
    fatal(3, "ping failed: ", res.stderr)
  stdout = res.stdout

except Exception:
  fatal(1, "ping execution failed: ", sys.exc_info()[0])

re_statistics = re.compile('(?P<sent>[0-9]+).+?,.+?(?P<received>[0-9]+)')

# Print connection quality as percentage of answered echo requests
lines = stdout.split('\n')
lines.reverse()
for line in lines:
  statistics_match = re_statistics.match(line)

  if not statistics_match:
    continue

  try:
    tx = int(statistics_match.group('sent'))
    rx = int(statistics_match.group('received'))
    print(int(rx * 100 / tx))
    sys.exit(0)

  except Exception as ex:
    print(ex)
    pass

fatal(1, "Failed to parse output of ping: ", stdout)
