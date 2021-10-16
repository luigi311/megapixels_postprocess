#!/bin/bash

podman pull docker.io/luigi311/low-power-image-processing:latest
podman image prune -f
