#!/usr/bin/env bash
echo Hello $NAME
for f in $(ls); do
  echo "$f"
done
