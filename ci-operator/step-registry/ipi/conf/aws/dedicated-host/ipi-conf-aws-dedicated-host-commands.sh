#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"
REGION=${LEASED_RESOURCE}
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

zones=$(yq-v4 '.controlPlane.platform.aws.zones'[] "${CONFIG}")
compute_node_type=$(yq-v4 '.compute[0].platform.aws.type // ""' "${CONFIG}")
control_plane_node_type=$(yq-v4 '.controlPlane.platform.aws.type // ""' "${CONFIG}")

if [ "$zones" == "" ]; then
  echo "ERROR: No zones found in install-config.yaml, exit now."
  exit 1
fi

if [ "$compute_node_type" == "" ] || [ "$control_plane_node_type" == "" ]; then
  echo "ERROR: instance type must be set for compute and control plane nodes."
  exit 1
fi

if [ "$compute_node_type" != "$control_plane_node_type" ]; then
  echo "ERROR: compute and control plane instance types must be the same."
  exit 1
fi


PATCH=/tmp/dedicated_host_patch.yaml
rm -f "$PATCH"
touch "$PATCH"

EXPIRATION_DATE=$(date -d '12 hours' --iso=minutes --utc)
for zone in $zones;
do

  tag_spec=$(mktemp)
  cat <<EOF > "$tag_spec"
[
  {
    "ResourceType": "dedicated-host",
    "Tags": [
      {"Key": "Name", "Value": "${CLUSTER_NAME}-${zone}"},
      {"Key": "CI-JOB", "Value": "${JOB_NAME_SAFE}"},
      {"Key": "expirationDate", "Value": "${EXPIRATION_DATE}"},
      {"Key": "ci-build-info", "Value": "${BUILD_ID}_${JOB_NAME}"}
    ]
  }
]
EOF

  echo "Allocating host in $zone ..."
  out=${SHARED_DIR}/allocated_dedicated_host_${zone}.json
  aws --region "$REGION" ec2 allocate-hosts \
    --instance-type "$compute_node_type" \
    --availability-zone "$zone" \
    --quantity "1" \
    --tag-specifications file://${tag_spec} > "$out"

  cat $out

  # PATCH format:
  # - id: h-0ae4c4056dcfb790e
  #   zone: us-east-1a
  # - id: h-09329ee98c6902ca7
  #   zone: us-east-1d
  h=$(jq -r '.HostIds[]' "$out") z="$zone" yq-v4 -i eval '. += [{"id": env(h), "zone": env(z)}]' "$PATCH"

done

echo "dedicatedHost PATCH:"
cat "$PATCH"

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
  echo "Patching dedicatedHost on compute node:"
  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.dedicatedHost = load("/tmp/dedicated_host_patch.yaml")' "$CONFIG"
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
  echo "Patching dedicatedHost on controlPlane node:"
  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.dedicatedHost = load("/tmp/dedicated_host_patch.yaml")' "$CONFIG"
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
  echo "Patching dedicatedHost on defaultMachinePlatform:"
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.dedicatedHost = load("/tmp/dedicated_host_patch.yaml")' "$CONFIG"
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"
