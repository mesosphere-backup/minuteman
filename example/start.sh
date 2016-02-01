#!/bin/sh

MARATHON=http://33.33.33.32:8080

echo "Initializing sample application in marathon..."
curl -H 'Content-type: application/json' \
  -X POST -d @app.json $MARATHON/v2/apps > /dev/null
echo -n "done"

echo
