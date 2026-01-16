#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EXPIRATION_DATE=$(date -d '12 hours' --iso=minutes --utc)

if [ "${CONTROL_PLANE_INSTANCE_TYPE}" != "${COMPUTE_NODE_TYPE}" ];then
  echo "ERROR: CONTROL_PLANE_INSTANCE_TYPE and COMPUTE_NODE_TYPE must be identical."
  exit 1
fi

dedicated_host_instance_type="${CONTROL_PLANE_INSTANCE_TYPE:-}"

# We just have quotas for a few instance types, so ensure these types meet the requirements.
if [ "$dedicated_host_instance_type" != "" ]; then
  
  case "$dedicated_host_instance_type" in
    m6i.*|m6a.*|m6g.*)
        echo "Instance type for Dedicated Host: $dedicated_host_instance_type"
        ;;
    *)
        echo "ERROR: Unsupported instance type $dedicated_host_instance_type for Dedicated Host."
        echo "Valid instance type family: m6i.*, m6a.* and m6g.*"
        exit 1
        ;;
  esac
else
  # random select one
  declare -a candidate_types
  if [ "${OCP_ARCH}" == "amd64" ]; then
    candidate_types=("m6a.xlarge" "m6i.xlarge")
  elif [ "${OCP_ARCH}" == "arm64" ]; then
    candidate_types=("m6g.xlarge")
  fi
  dedicated_host_instance_type=${candidate_types[$RANDOM % ${#candidate_types[@]}]}
fi

echo "$dedicated_host_instance_type" > "$SHARED_DIR"/dedicated_host_instance_type

successful_allocations=0
dedicated_host_out="$SHARED_DIR"/dedicated_host.yaml
dedicated_host_az_out="$SHARED_DIR"/dedicated_host_azs.yaml


if [ -f "${SHARED_DIR}"/vpc_info.json ]; then
    # BYO-VPC, ensure one DH is available in each AZ
    echo "BYO-VPC is configured"
    mapfile -t azs < <(jq -r '.subnets[].az' "${SHARED_DIR}"/vpc_info.json)
    max_allocations=$(jq -r '[.subnets[].az] | length' "${SHARED_DIR}"/vpc_info.json)
    min_requirement=$max_allocations
else
    mapfile -t azs < <(aws --region "$REGION" ec2 describe-availability-zones --filter Name=zone-type,Values=availability-zone --query 'AvailabilityZones[?State==`available`].ZoneName' | jq -r '.[]')
    max_allocations=2
    min_requirement=1
fi

echo "Found ${#azs[@]} availability zones in $REGION: ${azs[*]}"
echo "Max allocations: $max_allocations Dedicated Hosts"
echo "Min requirement: $min_requirement Dedicated Hosts"

declare -a host_ids
declare -a host_zones

for zone in "${azs[@]}"; do
    if [ "$successful_allocations" -ge "$max_allocations" ]; then
        echo "Successfully allocated $successful_allocations Dedicated Hosts. Exiting."
        break
    fi

    echo "Attempting to allocate Dedicated Host in $zone..."

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

    response=$(aws --region "$REGION" ec2 allocate-hosts \
        --instance-type "$dedicated_host_instance_type" \
        --availability-zone "$zone" \
        --tag-specifications file://${tag_spec} \
        --quantity "1" 2>&1 || true)

    echo $response

    host_id=$(echo "$response" | jq -r '.HostIds[0]? // ""' || true)

    if [ -n "$host_id" ]; then
        host_ids+=("$host_id")
        host_zones+=("$zone")
        successful_allocations=$((successful_allocations + 1))
        echo "Successfully allocated Dedicated Host $host_id in $zone (Total: $successful_allocations/$max_allocations)"
    else
        echo "Failed to allocate Dedicated Host in $zone. Trying next AZ..."
        echo "$response" | grep -i "error" || true
    fi
done

# Create patch for install-config.yaml
if [ "$successful_allocations" -gt 0 ]; then

    # Initialize empty YAML array
    echo "[]" | yq-v4 eval '.' > "$dedicated_host_out"

    # Dedicate Host
    #
    # Format:
    # - id: h-01ebe7dd847bff5b3
    #   zone: us-west-1a
    # - id: h-014e3c9b07eaf2d0c
    #   zone: us-west-1c
    for i in "${!host_ids[@]}"; do
        yq-v4 eval ".[$i].id = \"${host_ids[$i]}\"" -i "$dedicated_host_out"
        yq-v4 eval ".[$i].zone = \"${host_zones[$i]}\"" -i "$dedicated_host_out"
    done

    echo "Dedicate Host:"
    cat "$dedicated_host_out"

    # AZs
    # Format:
    # - us-west-1a
    # - us-west-1c
    echo "[]" | yq-v4 eval '.' > "$dedicated_host_az_out"

    for i in "${!host_zones[@]}"; do
        yq-v4 eval ".[$i] = \"${host_zones[$i]}\"" -i "$dedicated_host_az_out"
    done

    echo "AZs:"
    cat "$dedicated_host_az_out"
fi

echo ""
if [ "$successful_allocations" -lt "$min_requirement" ]; then
    echo "Error: The minimum DH requirement is $min_requirement, but we only got $successful_allocations DHs."
    exit 1
else
    echo "Success: $successful_allocations Dedicated Hosts allocated successfully!"
    exit 0
fi


