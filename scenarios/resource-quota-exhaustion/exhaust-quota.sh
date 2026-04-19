#!/usr/bin/env bash
# No-op: fault injection is no longer needed.
# The deployment manifest itself requests 3 replicas × 256Mi which exceeds
# the 512Mi ResourceQuota from the start. This file is kept for backwards
# compatibility with any tooling that references it.
echo "No fault injection needed -- deployment was created over quota."
