#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

CONFIG="${SHARED_DIR}/install-config.yaml"

dedicated_host_out="$SHARED_DIR"/dedicated_host.yaml
dedicated_host_az_out="$SHARED_DIR"/dedicated_host_azs.yaml
dedicated_host_instance_type="$SHARED_DIR"/dedicated_host_instance_type

if [ ! -f "$dedicated_host_out" ] || [ ! -f "$dedicated_host_az_out" ] || [ ! -f "$dedicated_host_instance_type" ]; then
  echo "ERROR: Required DH configuration files don't exist: $dedicated_host_out or $dedicated_host_az_out or $dedicated_host_instance_type"
  exit 1
fi

export dedicated_host_out
export dedicated_host_az_out
instance_type=$(<"$SHARED_DIR"/dedicated_host_instance_type)
export instance_type

echo "Overiding zones to:"
cat $dedicated_host_az_out

yq-v4 -i eval '.compute[0].platform.aws.zones = load(env(dedicated_host_az_out))' ${CONFIG}
yq-v4 -i eval '.controlPlane.platform.aws.zones = load(env(dedicated_host_az_out))' ${CONFIG}

echo "Overiding instance type to:"
cat $dedicated_host_instance_type

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
