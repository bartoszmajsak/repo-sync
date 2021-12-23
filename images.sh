#!/bin/bash

docker build -t quay.io/bmajsak/prow-patch-validator:latest \
    -f Dockerfile.validate src/

docker push quay.io/bmajsak/prow-patch-validator:latest  

docker build -t quay.io/bmajsak/prow-patch-verifier:latest \
    -f Dockerfile.verify src/

docker push quay.io/bmajsak/prow-patch-verifier:latest


docker build -t quay.io/bmajsak/prow-patch-updater:latest \
    -f Dockerfile.create src/

docker push quay.io/bmajsak/prow-patch-updater:latest
