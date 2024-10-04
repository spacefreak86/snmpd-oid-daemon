#!/bin/bash

while :; do
  echo -n P
  sleep .$(($RANDOM % 3))
  echo -n I
  sleep .$(($RANDOM % 3))
  echo -n "N"
  sleep .$(($RANDOM % 3))
  echo G
  echo GET
  echo .1.3.6.1.4.1.8072.9999.9999.4.2.0
done
