#!/bin/sh

MARATHON=http://33.33.33.32:8080

echo "Removing sample application from marathon..."
curl -H 'Content-type: application/json' \
  -X DELETE $MARATHON/v2/apps/app1 > /dev/null
echo -n "done"

echo
