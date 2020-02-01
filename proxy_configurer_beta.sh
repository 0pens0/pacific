#!/usr/bin/env bash

# 1. parse parameters: <gateway-vm-ip>, <api-master-ip>, <api-master-root-login-passwd>
if [ "$#" -ne 3 ]; then
  echo "Usage: $0 <gateway-vm-ip> <api-master-ip> <api-master-root-login-passwd>" >&2
  exit 1
fi

GATEWAY_VM_IP=$1
GATEWAY_VM_ROOT_PASSWD="VMware1!"
API_MASTER_IP=$2
API_MASTER_ROOT_PASSWD=$3

ROOT_USER=root
GATEWAY_TINY_PROXY_CONF=http://engweb.eng.vmware.com/~ecao/wcp/tinyproxy.conf
REGISTRY_AGENT_YAML=/usr/lib/vmware-wcp/objects/PodVM/40-registry-agent/registry-agent.yaml
REGISTRY_NAMESPACE=vmware-system-registry

# 2. login to gateway VM and configure tiny proxy
sshpass -p $GATEWAY_VM_ROOT_PASSWD ssh -o StrictHostKeyChecking=no $ROOT_USER@$GATEWAY_VM_IP <<EOF
apt-get install tinyproxy;
curl $GATEWAY_TINY_PROXY_CONF -o /etc/tinyproxy.conf;
systemctl restart tinyproxy.service;
EOF

# 3. login to api master to configure registry agent to use tiny proxy

sshpass -p $API_MASTER_ROOT_PASSWD ssh -o StrictHostKeyChecking=no $ROOT_USER@$API_MASTER_IP <<EOF
sed -i '0,/vmware\/registry-agent/!b;//a\
\ \ \ \ \ \ \ \ \ \ \ \ - name: HTTP_PROXY\
\n\ \ \ \ \ \ \ \ \ \ \ \ \ \ value: http://${GATEWAY_VM_IP}:8888\
\n\ \ \ \ \ \ \ \ \ \ \ \ - name: HTTPS_PROXY\
\n\ \ \ \ \ \ \ \ \ \ \ \ \ \ value: http://${GATEWAY_VM_IP}:8888' $REGISTRY_AGENT_YAML;
sed -i 's/40Mi/50Mi/g' $REGISTRY_AGENT_YAML;
sed -i 's/30Mi/40Mi/g' $REGISTRY_AGENT_YAML;
kubectl apply -f $REGISTRY_AGENT_YAML;
kubectl get pod -n $REGISTRY_NAMESPACE --no-headers=true | awk '{print  \$1}' | xargs kubectl delete -n $REGISTRY_NAMESPACE pod \$1;
EOF

# 4. manually delete test-cluster-ip-service namespace

