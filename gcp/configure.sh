#!/bin/bash

readonly logger="/configure_redis.log"
log_info() { printf '%s %s\n' "$(date -u +'%Y-%m-%d %H:%M:%S')" "$*" >> "$logger"; }

command -v jq >/dev/null || dnf install -y jq || exit 1
credentials=$(cat <<'CREDENTIALS'
${jsonencode({username = cluster_admin_username, password = cluster_admin_password})}
CREDENTIALS
)
auth=$(jq -r '.username + ":" + .password' <<< "$credentials")
IFS=' ' read -r -a node_internal_ips <<< "${node_internal_ips_joined}"
IFS=' ' read -r -a node_external_ips <<< "${node_external_ips_joined}"

# Wait for installation before POST, or for asynchronous bootstrap after POST.
wait_for_bootstrap() {
  local ip="$1" expected="$2" attempt resp
  for ((attempt=0; attempt<120; attempt++)); do
    if resp=$(curl -fsSk --connect-timeout 5 --max-time 15 -u "$auth" "https://$ip:9443/v1/bootstrap"); then
      bootstrap_state=$(jq -r '.bootstrap_status.state // empty' <<< "$resp")
      [[ "$bootstrap_state" == completed ]] && return 0
      if [[ "$expected" == idle && ( "$bootstrap_state" == idle || "$bootstrap_state" == error ) ]]; then
        if jq -e --arg ip "$ip" '(.local_node_info.available_addrs // .local_node_info.available_addresses // []) | any(.address == $ip)' <<< "$resp" >/dev/null; then
          return 0
        fi
      elif [[ "$bootstrap_state" == error ]]; then
        log_info "Bootstrap failed on $ip: $(jq -c '.bootstrap_status' <<< "$resp")"
        return 1
      fi
    fi
    sleep 5
  done
  log_info "Timed out waiting for bootstrap $expected on $ip."
  return 1
}

create() {
  local ip="$1" external_ip="$2" cluster_name="$3" payload
  wait_for_bootstrap "$ip" idle || return 1
  [[ "$bootstrap_state" == completed ]] && return 0
  payload=$(jq -n --arg name "$cluster_name" --arg ip "$ip" --arg external "$external_ip" \
    --argjson credentials "$credentials" \
    '{action:"create_cluster", cluster:{nodes:[], name:$name}, node:{identity:{addr:$ip, external_addr:[$external]}}, credentials:$credentials}')
  log_info "Creating Redis cluster on $ip."
  if ! curl --fail-with-body -sSk --connect-timeout 5 --max-time 60 -u "$auth" \
    -H 'Content-Type: application/json' -X POST "https://$ip:9443/v1/bootstrap/create_cluster" \
    -d "$payload"; then
    log_info "Create request failed on $ip."
    return 1
  fi
  wait_for_bootstrap "$ip" completed
}

join() {
  local i ip payload
  for ((i=1; i<${no_of_nodes_per_cluster}; i++)); do
    ip="$${node_internal_ips[i]}"
    wait_for_bootstrap "$ip" idle || return 1
    [[ "$bootstrap_state" == completed ]] && continue
    payload=$(jq -n --arg seed "$${node_internal_ips[0]}" --arg ip "$ip" \
      --arg external "$${node_external_ips[i]}" --argjson credentials "$credentials" \
      '{action:"join_cluster", cluster:{nodes:[$seed]}, node:{identity:{addr:$ip, external_addr:[$external]}}, credentials:$credentials}')
    log_info "Joining $ip to $${node_internal_ips[0]}."
    if ! curl --fail-with-body -sSk --connect-timeout 5 --max-time 60 -u "$auth" \
      -H 'Content-Type: application/json' -X POST "https://$ip:9443/v1/bootstrap/join_cluster" \
      -d "$payload"; then
      log_info "Join request failed on $ip."
      return 1
    fi
    wait_for_bootstrap "$ip" completed || return 1
    log_info "Node $ip joined successfully."
  done
}

configure_cluster() {
  create "$${node_internal_ips[0]}" "$${node_external_ips[0]}" "${cluster_name}" || return 1
  join || return 1
  log_info "Redis cluster configuration completed successfully."
}

configure_cluster || exit 1
