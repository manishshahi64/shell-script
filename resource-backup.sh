#!/usr/bin/env bash

##############################################
#Dependant On : kubectl,jq,yq

# This script will backup all the required yaml resources from the required namespace.
# $chmod +x resource-backup.sh
# $./resource-backup.sh --help

# Install dependency
# Ubuntu
# sudo snap install yq jq
##############################################

set -e
# Log Messages
log () {
  printf '%s [%s] %s\n' "$(date '+%Y/%m/%d %H:%M:%S')" "$1" "${@:2}"
}
msg-start () {
   if [ -t 1 ]; then
    printf '\e[1;33m%-15s\e[m%-30s%s\n' 'Processing' "$1" "${@:2}"
  else log INFO "Processing Backup $*"; fi
}
msg-end () {
   if [ -t 1 ]; then
    printf '\e[1A\e[1;32m%-15s\e[m%-30s%s\n' 'Success' "$1" "${@:2}"
  else log INFO "Backup Successful $*"; fi
}
msg-fail () {
   if [ -t 1 ]; then
    printf '\e[1A\e[1;31m%-15s\e[m%-30s%s\n' 'Fail' "$1" "${@:2}"
  else log WARNING "Failed Backup $*"; fi
}
success () {
   if [ -t 1 ]; then
    printf '%s \e[1;36m%s\e[m %s\n' "$1" "$2" "${@:3}"
  else log INFO "$*"; fi
  score=$((score+1))
}
heading () {
   if [ -t 1 ]; then
  printf '%s \e[1;34m%s\e[m %s\n%-15s%-30s%s\n' \
         "$1" "$2" 'started' 'STATE' 'RESOURCE' 'NAME'
  else log INFO "$*"; fi
}
warn () {
  if [ -t 1 ]; then
    >&2 printf '\e[1;31m%-10s\e[m%s\n' 'Warning:' "$*"
  else log WARNING "$*"; fi
}
fail () {
  if [ -t 1 ]; then
    >&2 printf '\n\e[1;31m%-10s\e[m%s\n' 'Error:' "$*"; exit 1
  else log ERROR "$*"; exit 1; fi
}

# Check command is exist
require () {
  for command in "$@"; do
    if ! [ -x "$(command -v "$command")" ]; then
      fail "'$command' util not found, please install it first"
    fi
  done
}

# Usage message
usage () {
  cat <<-EOF
Backup kubernetes yaml resources based on namespaces

Usage:
  ${0##*/} [command] [[flags]]

Available Commands:
  ns                            Backup namespaced kubernetes resources 

Flags:
  -h, --help                    This help
  -n, --namespaces              List of kubernetes namespaces

Examples:
${0##*/} ns                     Backup all the yaml resources from all the namespace present in the cluster
${0##*/} ns -n foo            Backup yaml resources within foo namespace
${0##*/} ns -n foo,default    Backup yaml resources within foo and default namespace

EOF
  exit 0
}

# Set common vars
working_dir="$PWD"
timestamp_date="$(date '+%Y.%m.%d')"

# Parse args commands
if [[ "${1:-$MODE}" =~ ^(ns)$ ]]; then
  mode="${1:-$MODE}"; else usage; fi

# Parse args flags
args=$(
  getopt \
    -l "namespaces:" \
    -l "help,force-remove" \
    -o "n:,f" -- "${@:2}"
)
eval set -- "$args"
while [ $# -ge 1 ]; do
  case "$1" in
# Resources
    -n|--namespaces)            namespaces+="$2,";                shift; shift;;
    -h|--help)                  usage;;
    -f|--force-remove)          force_remove='true';                     shift;;
# Final
       --)                                                        shift; break;;
       -*)                      fail "invalid option $1";;
  esac
done

if [[ -n "$*" && "$OSTYPE" != "darwin"* ]]; then
  fail "extra arguments $*"
fi

# Check dependency
require kubectl jq yq

# Set namespaces list
if [ -z "${namespaces:-$NAMESPACES}" ]; then
  if ! namespaces=$(kubectl get namespaces \
      --output=jsonpath=\{.items[*].metadata.name\} "${k_args[@]}")
  then
    fail 'Cant get namespaces from cluster'
  fi
else
  namespaces=${namespaces:-$NAMESPACES}
fi

# Namespace resources to take backup

namespaced_resources="configmaps persistentvolumeclaims persistentvolumes pods resourcequotas secrets serviceaccounts services daemonsets.apps deployments.apps statefulsets.apps ingresses.networking.k8s.io networkpolicies.networking.k8s.io rolebindings.rbac.authorization.k8s.io roles.rbac.authorization.k8s.io"

# default jq filter removes detailed fiends from namespaced resources
namespaced_jq_filter=$(cat <<-END
  del(
    .metadata.annotations."autoscaling.alpha.kubernetes.io/conditions",
    .metadata.annotations."autoscaling.alpha.kubernetes.io/current-metrics",
    .metadata.annotations."control-plane.alpha.kubernetes.io/leader",
    .metadata.annotations."deployment.kubernetes.io/revision",
    .metadata.annotations."kubectl.kubernetes.io/last-applied-configuration",
    .metadata.annotations."kubernetes.io/service-account.uid",
    .metadata.annotations."pv.kubernetes.io/bind-completed",
    .metadata.annotations."pv.kubernetes.io/bound-by-controller",
    .metadata.managedFields,
    .metadata.creationTimestamp,
    .metadata.generation,
    .metadata.resourceVersion,
    .metadata.selfLink,
    .metadata.uid,
    .spec.clusterIP,
    .spec.progressDeadlineSeconds,
    .spec.revisionHistoryLimit,
    .spec.template.metadata.annotations."kubectl.kubernetes.io/restartedAt",
    .spec.template.metadata.creationTimestamp,
    .spec.volumeMode,
    .status
  )
END
)

# Backup dir
destination_dir="${destination_dir:-${DESTINATION_DIR:-$working_dir/kube-backup-$timestamp_date}}"
destination_dir="$(realpath "$destination_dir" --canonicalize-missing)"
if [ ! -d "$destination_dir" ]; then
  mkdir -p "$destination_dir"
  success 'Backup directory' "$destination_dir" 'created'
fi
success 'Backup data in' "$destination_dir" 'directory' ''
score=0

# Backup namespaced resources
if [[ "$mode" =~ ^(ns)$ ]]; then

  for ns in ${namespaces//,/ }; do

    # Check namespace exist
    if ! kubectl get ns "$ns" "${k_args[@]}" >/dev/null 2>&1; then
      warn "Namespace \"$ns\" not found"
      continue
    fi

    # Create namespace dir
    destination_namespace_dir="$destination_dir/$ns"
    [ -d "$destination_namespace_dir" ] || mkdir -p "$destination_namespace_dir"
    heading 'Backup namespace' "$ns"

    # Iterate over resources
    for resource in ${namespaced_resources//,/ }; do

      # By default, output all resources in the same namespace dir
      destination_resource_dir="$destination_namespace_dir"

      # create resource dir
      destination_resource_dir="$destination_resource_dir/$resource"
      [ -d "$destination_resource_dir" ] || mkdir -p "$destination_resource_dir"
      #   destination_suffix="_$resource"
      destination_suffix="" # resource suffix was moved to dir

        # Iterate over only accessible resources
      while read -r name; do
        [ -z "$name" ] && continue

        # Skip service-account-token secrets
        if [ "$resource" == 'secret' ]; then
        type=$(
            kubectl get --namespace="${ns}" --output=jsonpath="{.type}" \
            secret "$name" "${k_args[@]}"
            )
        [ "$type" == 'kubernetes.io/service-account-token' ] && continue
        unset type
        fi

        msg-start "$resource" "$name"

        destination_resource_name="${name//:/-}${destination_suffix}.yaml"

        # Save resource to file
        kubectl --namespace="${ns}" get \
        --output='json' "$resource" "$name" "${k_args[@]}" 2>/dev/null | \
        jq --exit-status --compact-output --monochrome-output \
        --raw-output --sort-keys 2>/dev/null \
        "$namespaced_jq_filter" | \
        yq eval --prettyPrint --no-colors --exit-status - \
        >"$destination_resource_dir/$destination_resource_name" 2>/dev/null && \
        msg-end "$resource" "$name" || msg-fail "$resource" "$name"

      done < <(
        kubectl --namespace="${ns}" get "$resource" \
        --output='custom-columns=NAME:.metadata.name' \
        --no-headers "${k_args[@]}" 2>/dev/null
        )
      # Finished with resource
    done
    success 'Namespace' "$ns" 'resources backup completed' ''
  done
fi

# Done
if [ "$score" -ge 0 ]; then
  success 'Done!' "$score" 'task completed'
  exit 0
else
  fail 'No task has been completed'
fi
