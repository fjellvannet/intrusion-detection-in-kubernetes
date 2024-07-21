#!/bin/bash

# Replace <name> with your DaemonSet's name
DAEMONSET_NAME="falco"

# Find the index of the 'containerd-socket' volume
INDEX=$(kubectl -n falco get daemonset "$DAEMONSET_NAME" -o json | jq '.spec.template.spec.volumes | map(.name) | index("containerd-socket")')

# Check if the volume was found
if [ "$INDEX" = "null" ]; then
    echo "Volume 'containerd-socket' not found."
    exit 1
fi

# Construct the JSON Patch
PATCH="[{\"op\": \"replace\", \"path\": \"/spec/template/spec/volumes/$INDEX/hostPath/path\", \"value\": \"/var/snap/microk8s/common/run\"}]"

# Apply the patch
kubectl -n falco patch daemonset "$DAEMONSET_NAME" --type='json' -p="$PATCH"