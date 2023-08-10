#!/bin/bash
export RESOURCE_GROUP="${RESOURCE_GROUP:-test-asm}"
export RESOURCE_NAME="${RESOURCE_NAME:-stress-test-asm}"

export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-10}"
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-1000}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-1000}"
export CL2_REPEATS="${CL2_REPEATS:-1}"
export ISTIOD_MEM="${ISTIOD_MEM:-2Gi}"

# make sure prometheus is deployed
skip=false
verbosity=0
istiodFailed=false
ISTIOD_MEM=$(kubectl get pods -n aks-istio-system -o=jsonpath='{.items[*].spec.containers[*].resources.requests.memory}')
echo "istiod memory request is $ISTIOD_MEM"
while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true
                    echo "skipping cl2" ;;
    -s | --start)  startTime=$2 ;;
    -e | --end) endTime=$2 ;;
    -p | --podCount)    CL2_TOTAL_PODS=$2 ;;
    -i | --istiodFail) istiodFailed=true ;;
    -c | --churn) CL2_REPEATS=$2 ;;
    -v) verbosity=$2 ;;
    -h | --help) $'-k | --skip : to skip clusterloader \n   -s | --start for startTime \n -e | --end for endTime \n -p | --podCount set CL2_TOTAL_PODS \n  
                  -i | --istiodFail \n  -c | --churn which churn to do: 1 = none, 2 = 90%, 3=80%, 4=50% \n  -v for verbosity lvl'
    exit ;;
  esac
  shift
done

# add check if skip then need to give start/end
CL2_SERVICE_SIZE=1000
CL2_LOAD_TEST_THROUGHPUT=1000
if ! $skip; then
  kubectl delete -f testing/load/prometheus.yaml
  sleep 5
  kubectl apply -f testing/load/prometheus.yaml

  startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo "Running test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_REPEATS"
  go run ${PWD}/cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=150 --provider=aks --kubeconfig=${HOME}/.kube/config -v ${verbosity}
  endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  sleep 5m 

fi

echo "Checking if istiod failed"
istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
statuses=($istiodStatuses)
for i in "${statuses[@]}"
do
    if [ $i != "Running" ]; then
        istiodFailed=true
    fi
done
if [ ${#statuses[@]} -gt 1 ] ; then
  echo hi
fi

if [ $istiodFailed != true ]; then
  echo "istiod didn't fail at ${CL2_TOTAL_PODS} pods"
else
  echo "istiod did fail at ${CL2_TOTAL_PODS} pods"
fi

echo "Port forward Prometheus"
kubectl port-forward svc/prometheus 9090:9090 &
sleep 5
# ./server &
# serverpid=$!
# # ... lots of other stuff
# kill $serverpid

echo "Capturing prometheus graphs: istiod failed - ${istiodFailed}, -s ${startTime} -e ${endTime}"
python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed}
echo "Captured prometheus graphs: istiod failed - ${istiodFailed}, -s ${startTime} -e ${endTime}"

startTimeDeleteNS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "delete test ns at ${startTimeDeleteNS}"
testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
kubectl delete namespace $testNamespaces

kubectl -n aks-istio-system delete pod --all

echo "restart istiod deployment"
kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17


