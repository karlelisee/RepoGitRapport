#!/bin/bash
if [ -z "$HEARTBEATSTEP" ]; then
    echo "La variable d'environnement HEARTBEATSTEP doit être valuée"
    exit
fi
while true;
do
    echo $1 - $(hostname) - \($(date +%H:%M:%S)\);
    sleep "$HEARTBEATSTEP";
done
