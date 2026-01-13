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

ls "$SHARED_DIR"/allocated_dedicated_host_* > /tmp/dh_out_list

while IFS= read -r allocated_dh_json; do
  host_id=$(jq -r '.HostIds[]' "$allocated_dh_json")
  aws --region "$REGION" ec2 release-hosts --host-ids "$host_id" | tee /tmp/out.json

  if [ "$(jq -r '.Unsuccessful|length' /tmp/out.json)" != "0" ]; then
    ret=$((ret+1))
  fi
done < /tmp/dh_out_list

exit $ret
