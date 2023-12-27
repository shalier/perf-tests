#!/bin/bash
# trap -- '' SIGINT SIGTERM


export RESOURCE_GROUP="${RESOURCE_GROUP:-xiarg}"
export LOCATION="${LOCATION:-eastus}"
export SUBSCRIPTION="${SUBSCRIPTION:-854c9ddb-fe9e-4aea-8d58-99ed88282881}"
export NODESUBNET="${NODESUBNET:-nodesubnet}"
export PODSUBNET="${PODSUBNET:-podsubnet}"
export CILIUM_VNET="${CILIUM_VNET:-cilium-vnet}"
export KUBENET_VNET="${KUBENET_VNET:-myAKSVnet}"
export KUBENET_SUBNET="${KUBENET_SUBNET:-myAKSSubnet}"

# create subnet for cilium and kubenet
# az network vnet create -g xiarg --location eastus --name ${CILIUM_VNET} --address-prefixes 10.0.0.0/8 -o none 
# az network vnet subnet create -g xiarg  --vnet-name ${CILIUM_VNET}  --name nodesubnet --address-prefixes 10.0.0.0/8 -o none 
# az network vnet subnet create -g xiarg  --vnet-name ${CILIUM_VNET}  --name podsubnet --address-prefixes 10.0.0.0/8 -o none
VNET_SUBNET_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${CILIUM_VNET}/subnets/${NODESUBNET}"
POD_SUBNET_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${CILIUM_VNET}/subnets/${PODSUBNET}"

# az network vnet create --resource-group ${RESOURCE_GROUP} --name ${KUBENET_VNET} --address-prefixes 192.0.0.0/8 --subnet-name ${KUBENET_SUBNET} --subnet-prefix 192.0.0.0/8

KUBENET_VNET_SUBNET_ID="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Network/virtualNetworks/${KUBENET_VNET}/subnets/${KUBENET_SUBNET}"

#Azure CNI vnet + Cilium
# echo "creating cni-cilium" this is the same thing as dynamic cilium
# Cilium dataplane requires either network plugin mode overlay or pod subnet
# az aks create --name cni-cilium \
#     --resource-group ${RESOURCE_GROUP}\
#     --location ${LOCATION}\
#     --network-plugin azure \
#     --generate-ssh-keys \
#     --vnet-subnet-id "${VNET_SUBNET_ID}" \
#     --pod-subnet-id "${POD_SUBNET_ID}" \
#     --network-dataplane cilium \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating cni-azure"
# #Azure CNI vnet + Azure (iptables)
#  az aks create --name cni-azure \
#     --resource-group ${RESOURCE_GROUP}\
#     --location ${LOCATION}\
#     --network-plugin azure \
#     --generate-ssh-keys \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating dynamic-cilium"
# #Azure CNI vnet (dynamic) + Cilium
# az aks create -n dynamic-cilium \
#     --resource-group ${RESOURCE_GROUP}\
#     --location ${LOCATION}\
#     --max-pods 250 \
#     --network-plugin azure \
#     --vnet-subnet-id "${VNET_SUBNET_ID}" \
#     --pod-subnet-id "${POD_SUBNET_ID}" \
#     --network-dataplane cilium \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating dynamic-azure"
# #Azure CNI vnet (dynamic) + Azure (iptables)
# az aks create --name dynamic-azure \
#     --resource-group ${RESOURCE_GROUP}\
#     --location ${LOCATION}\
#     --max-pods 250 \
#     --network-plugin azure \
#     --vnet-subnet-id "${VNET_SUBNET_ID}" \
#     --pod-subnet-id "${POD_SUBNET_ID}" \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating overlay-cilium"
# #Azure CNI Overlay + Cilium
# az aks create --name overlay-cilium \
#     --resource-group ${RESOURCE_GROUP} \
#     --location ${LOCATION} \
#     --network-plugin azure \
#     --network-plugin-mode overlay \
#     --pod-cidr 192.0.0.0/8 \
#     --network-dataplane cilium \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating overlay-azure"
# #Azure CNI Overlay + Azure (iptables)
#  az aks create --name overlay-azure \
#     --resource-group ${RESOURCE_GROUP} \
#     --location ${LOCATION} \
#     --network-plugin azure \
#     --network-plugin-mode overlay \
#     --pod-cidr 192.0.0.0/8\
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

# echo "creating kubenet-azure"
# #Kubenet + Azure (iptables)
# az aks create --name kubenet-azure \
#     --resource-group ${RESOURCE_GROUP} \
#     --location ${LOCATION} \
#     --network-plugin kubenet \
#     --service-cidr 1.0.0.0/16 \
#     --dns-service-ip 1.0.0.10 \
#     --pod-cidr 10.0.0.0/8 \
#     --vnet-subnet-id "${KUBENET_VNET_SUBNET_ID}" \
#     --tier standard \
#     --node-vm-size Standard_D16_v3 \
#     --enable-azure-service-mesh

#skipping cni-cilium for now
# done cni-azure dynamic-azure overlay-azure dynamic-cilium kubenet-azure
# increased metrics server mem limit - 600mi; increase node pool 850 for overlay-cilium
# overlay-cilium is being weird skipping for now
clusterNames=(overlay-azure kubenet-azure dynamic-cilium dynamic-azure)

# for n in "${clusterNames[@]}"
# do
#     az aks get-credentials \
#         --resource-group ${RESOURCE_GROUP} \
#         --name ${n}
# done

# kubectl config get-contexts

for n in "${clusterNames[@]}"
do
    kubectl config use-context $n

    if [[ $n == *"dynamic"* ]]; then
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n prom --mode User --node-vm-size Standard_E32-16s_v3 --node-count 1 --vnet-subnet-id "${VNET_SUBNET_ID}" --pod-subnet-id "${POD_SUBNET_ID}"
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n userpool --mode User --node-vm-size Standard_D16_V3 --node-count 500 --vnet-subnet-id "${VNET_SUBNET_ID}" --pod-subnet-id "${POD_SUBNET_ID}" --max-pods 250
        if [[ $n == *"azure"* ]]; then #dynamic-azure
            ./sidecar_test.sh -pa "30000 40000" -l $n # 25000
            ./service_test.sh -ea "15 17" -l $n #15
        else #dynamic-cilium
            ./sidecar_test.sh -pa "20000" -l $n #15000 f 25000
            ./service_test.sh -ea "15 17" -l $n #15
        fi
    elif [[ $n == *"kubenet"* ]]; then #kubenet-azure
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n prom --mode User --node-vm-size Standard_E32-16s_v3 --node-count 1 --vnet-subnet-id "${KUBENET_VNET_SUBNET_ID}"
        # kubenet can only have 400 nodes, systempool - 5, prom -1, userpool - 394
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n userpool --mode User --node-vm-size Standard_D16_V3 --node-count 394 --vnet-subnet-id "${KUBENET_VNET_SUBNET_ID}" --max-pods 250
        # ./sidecar_test.sh -pa "25000 30000 35000" -l $n #25000 30000 35000
        ./service_test.sh -ea "15 17" -l $n #15

    else
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n prom --mode User --node-vm-size Standard_E32-16s_v3 --node-count 1
        az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n userpool --mode User --node-vm-size Standard_D16_V3 --node-count 500 --max-pods 250
        if [[ $n == *"cilium"* ]]; then #overlay-cilium
            az aks nodepool add --cluster-name $n -g ${RESOURCE_GROUP} -n userpool2 --mode User --node-vm-size Standard_D16_V3 --node-count 450 --max-pods 250
            ./sidecar_test.sh -pa "10000 15000" -l $n #5000
            ./service_test.sh -ea "10" -l $n #
        elif [[ $n == *"cni"* ]]; then #cni-azure
            ./sidecar_test.sh -pa "15000" -l $n #15000
            ./service_test.sh -ea "15 17" -l $n #15
        else #overlay-azure
            ./sidecar_test.sh -pa "25000" -l $n #35000 30000
            ./service_test.sh -ea "15 17" -l $n #15
        fi
    fi

    for node in $(kubectl get nodes | grep userpool | awk '{print $1}');
    do
        kubectl cordon $node
    done
    testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
    kubectl delete namespace $testNamespaces
    kubectl -n aks-istio-system delete pod --all
    kubectl delete -f testing/load/prometheus.yaml

    az aks nodepool delete --cluster-name $n -g ${RESOURCE_GROUP} -n prom
    az aks nodepool delete --cluster-name $n -g ${RESOURCE_GROUP} -n userpool
done