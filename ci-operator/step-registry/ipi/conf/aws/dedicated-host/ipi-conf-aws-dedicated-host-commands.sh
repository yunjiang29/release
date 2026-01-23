#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"
dedicated_hosts_info=${SHARED_DIR}/selected_dedicated_hosts.json

if [ ! -f "$dedicated_hosts_info" ]; then
  echo "ERROR: Required DH configuration files don't exist: $dedicated_hosts_info"
  exit 1
fi

dedicated_host_out=/tmp/ic_dh.yaml
jq -r '.Hosts[] | "- id: \(.HostId)\n  zone: \(.AvailabilityZone)"' "$dedicated_hosts_info" > "$dedicated_host_out"

dedicated_host_az_out=/tmp/ic_dh_az.yaml
jq -r '.Hosts[] | "- \(.AvailabilityZone)"' "$dedicated_hosts_info" > "$dedicated_host_az_out"

echo "======================================================================"
echo "WARNINNG: AWS Dedicated Host will overide the following configuration:"
echo "platform.aws.zones for compute and controlPlane"
echo "platform.aws.type for compute and controlPlane"
echo "======================================================================"

export dedicated_host_out
export dedicated_host_az_out
instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' "$dedicated_hosts_info")
export instance_type

echo "Overiding zones to:"
cat $dedicated_host_az_out

yq-v4 -i eval '.compute[0].platform.aws.zones = load(env(dedicated_host_az_out))' ${CONFIG}
yq-v4 -i eval '.controlPlane.platform.aws.zones = load(env(dedicated_host_az_out))' ${CONFIG}

echo "Overiding instance type to $instance_type"

yq-v4 -i eval '.compute[0].platform.aws.type = env(instance_type)' ${CONFIG}
yq-v4 -i eval '.controlPlane.platform.aws.type = env(instance_type)' ${CONFIG}

echo "Dedicated Host configuration:"
cat $dedicated_host_out

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
  echo "Patching dedicatedHost on compute node ..."
  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.dedicatedHost = load(env(dedicated_host_out))' "$CONFIG"
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
  echo "Patching dedicatedHost on controlPlane node ..."
  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.dedicatedHost = load(env(dedicated_host_out))' "$CONFIG"
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
  echo "Patching dedicatedHost on defaultMachinePlatform ..."
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.dedicatedHost = load(env(dedicated_host_out))' "$CONFIG"
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"
