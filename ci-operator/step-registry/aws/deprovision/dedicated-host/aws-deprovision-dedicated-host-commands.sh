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

ret=0

dedicated_host_json="$SHARED_DIR"/selected_dedicated_hosts.json

if [ ! -f "$dedicated_host_json" ]; then
  echo "ERROR: selected_dedicated_hosts.json was not found."
  exit 1
fi

# shellcheck disable=SC2046
aws --region "$REGION" ec2 release-hosts --host-ids $(jq -r '[.Hosts[].HostId] | join(" ")'  "$dedicated_host_json") | tee /tmp/out.json
if [ "$(jq -r '.Unsuccessful|length' /tmp/out.json)" != "0" ]; then
  ret=$((ret+1))
fi

exit $ret
