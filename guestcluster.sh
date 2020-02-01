#!/usr/bin/env bash

set -euo pipefail

# Helper script to restart the GCIS infrastructure components (GCM, CAPW, VMOperator)
#  as a means of unwedging an issue with a customer environment.

# Requires root credentials for VCSA.

THISFILE=$(basename "${0}")

GCM_NAMESPACE=vmware-system-gcm
GCM_DEPLOYMENT=vmware-system-gcm-controller-manager

CAPW_NAMESPACE=vmware-system-capw
VMOP_NAMESPACE=vmware-system-vmop

BASE_MANIFEST_PATH="/usr/lib/vmware-wcp/objects/PodVM-GuestCluster/"

VMOP_RESTART_SCRIPT=$(cat <<EOF
    kubectl apply -f ${BASE_MANIFEST_PATH}/30-vmop/vmop.yaml

    kubectl rollout restart -n ${VMOP_NAMESPACE} deployment vmoperator-apiserver
    kubectl rollout restart -n ${VMOP_NAMESPACE} deployment vmoperator-controller

    kubectl rollout status  -n ${VMOP_NAMESPACE} deployment vmoperator-apiserver
    kubectl rollout status  -n ${VMOP_NAMESPACE} deployment vmoperator-controller
EOF
)

# Support both v1a1 and v1a2 CAPW operators for now
CAPW_RESTART_SCRIPT=$(cat <<EOF
    kubectl apply -f ${BASE_MANIFEST_PATH}/20-capw/capw.yaml
    kubectl apply -f ${BASE_MANIFEST_PATH}/20-capw/capw-v1alpha1.yaml
    
    kubectl rollout restart -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-cluster-api-controller-manager
    kubectl rollout restart -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-controller-manager
    kubectl rollout restart -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-v1alpha2-controller-manager
    kubectl rollout restart -n ${CAPW_NAMESPACE} deployment vmware-system-capw-capi-controller-manager
    kubectl rollout restart -n ${CAPW_NAMESPACE} deployment vmware-system-capw-cabpk-controller-manager

    kubectl rollout status -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-cluster-api-controller-manager
    kubectl rollout status -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-controller-manager
    kubectl rollout status -n ${CAPW_NAMESPACE} statefulset vmware-system-capw-v1alpha2-controller-manager
    kubectl rollout status -n ${CAPW_NAMESPACE} deployment vmware-system-capw-capi-controller-manager
    kubectl rollout status -n ${CAPW_NAMESPACE} deployment vmware-system-capw-cabpk-controller-manager
EOF
)

GCM_RESTART_SCRIPT=$(cat <<EOF
    kubectl apply -f ${BASE_MANIFEST_PATH}/10-gcm/gcm.yaml

    kubectl rollout restart -n ${GCM_NAMESPACE} deployment ${GCM_DEPLOYMENT}
    kubectl rollout status  -n ${GCM_NAMESPACE}  deployment ${GCM_DEPLOYMENT}

EOF
)

RESTART_ALL_SCRIPT=$(cat <<EOF
    ${GCM_RESTART_SCRIPT}
    ${CAPW_RESTART_SCRIPT}
    ${VMOP_RESTART_SCRIPT}
EOF
)


function usage() {
    cat <<EOF
Usage: ${THISFILE} <VC host> all|vmop|capw|gcm <Cluster MoID>

       
    To obtain the cluster MoID, navigate to the cluster in the VC UI. It should look something like 'domain-cXXX' in the URL.

    https://<VC_IP>/ui/app/cluster;nav=h/urn:vmomi:ClusterComputeResource:domain-c1047:eb68342d-b96c-474e-ab02-dc0949dc15a3/summary

    Here, domain-c1047 is the MoID.
EOF

}

VC_IP=${1:-}
COMPONENT_TO_RESTART="${2:-}"
CLUSTER_MOID="${3:-}"
IN_VC=${4:-}

case "${COMPONENT_TO_RESTART}" in
    "all")
        RESTART_SCRIPT=${RESTART_ALL_SCRIPT}
        ;;
    "gcm")
        RESTART_SCRIPT=${GCM_RESTART_SCRIPT}
        ;;
    "capw")
        RESTART_SCRIPT=${CAPW_RESTART_SCRIPT}
        ;;
    "vmop")
        RESTART_SCRIPT=${VMOP_RESTART_SCRIPT}
        ;;
    *)
        usage
        exit 1
esac

# Use the appropriate restart script based on the case statement above.
# It must be set, otherwise the default case results in an early exit.
SV_RUN_SCRIPT=$(cat <<EOF
    ${RESTART_SCRIPT}
    echo "All GCIS components have been restarted."
EOF
)


# What we run within the VCSA. Assumes access to standard VCSA utils like python, grep, etc.
function run_commands_in_vc {
    # Append a colon to the cluster MoID when grepping, this should avoid accidentally picking up the wrong cluster
    #  when two have the same prefix in the MoID.
    CLUSTER_MOID=${1}:
    SV_IP=$(/usr/lib/vmware-wcp/decryptK8Pwd.py | grep -A 2 "${CLUSTER_MOID}" | grep "IP" | cut -f2 -d ":" | awk '{$1=$1;print}')
    # Use an env var to pass password when SSHing to control plane.
    # This avoids the need to add it to the command output.
    SSHPASS=$(/usr/lib/vmware-wcp/decryptK8Pwd.py | grep -A 2 "${CLUSTER_MOID}" | grep "PWD" | cut -f2 -d ":" | awk '{$1=$1;print}')

    SSHPASS=${SSHPASS} /usr/bin/sshpass -e ssh -o StrictHostKeychecking=no root@"${SV_IP}" "${SV_RUN_SCRIPT}"
} 

if [[ -z "${VC_IP}" ]] || [[ -z "${CLUSTER_MOID}" ]]; then
    usage
    exit 1
fi

# Use a 'hiddden' argument to imply we're running within the VC.
if [[ -n "${IN_VC}" ]] && [[ "${IN_VC}" != "true" ]]; then
    usage
    exit 1
fi

# We could use sshpass or expect here, but that
# - adds an additional dependency
# - might have security implications in terms of having the password logged as part of a command.

# Instead, we let the user handle the password prompts to avoid such issues.

# Copy this script to the VCSA,
#  then run it there
if [[ -z "${IN_VC}" ]]; then
    scp "${THISFILE}" root@"${VC_IP}:/usr/lib/vmware-wcp/${THISFILE}"
    #  Automatically generate command to run from from ${THISFILE}
    ssh root@"${VC_IP}" '/usr/lib/vmware-wcp/'"${THISFILE}"' '"${VC_IP}"' '"${COMPONENT_TO_RESTART}"' '"${CLUSTER_MOID}"' true'
else
    run_commands_in_vc "${CLUSTER_MOID}"
fi

