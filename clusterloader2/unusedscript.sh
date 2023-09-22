#!/bin/bash
export RESOURCE_GROUP="${RESOURCE_GROUP:-test-asm}"
export RESOURCE_NAME="${RESOURCE_NAME:-stress-test-asm}"

export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-5000}"
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-1}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-1000}"
export CHURNS="${CHURNS:-0}"
export ISTIOD_MEM="${ISTIOD_MEM:-2Gi}"
# Have to use CL2 because the load is created through the framework
# if you delete yourself then how do you continue the load through the pods?
#

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
    -c | --churn) CHURNS=$2 ;;
    -v) verbosity=$2 ;;
    -h | --help) $'-k | --skip : to skip clusterloader \n   -s | --start for startTime \n -e | --end for endTime \n -p | --podCount set CL2_TOTAL_PODS \n  
                  -i | --istiodFail \n  -c | --churn which churn to do: 1 = none, 2 = 90%, 3=80%, 4=50% \n  -v for verbosity lvl'
    exit ;;
  esac
  shift
done
# add check if skip then need to give start/end
CL2_SERVICE_SIZE=1
CL2_LOAD_TEST_THROUGHPUT=1000
pods=(17000 16000 15000 10000 5000)
churn=(50 20 10 0)

for p in "${pods[@]}"
do
  for c in "${churn[@]}"
  do
    CL2_TOTAL_PODS=$p
    CHURNS=$c
    if ! $skip; then
      testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
      kubectl delete namespace $testNamespaces
      testNs=$(echo $testNamespaces |  awk '{print $2;}' )

      kubectl -n aks-istio-system delete pod --all
      echo "restart istiod deployment"
      kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17

      kubectl delete -f testing/load/prometheus.yaml
      pkill -f "port-forward"
      kubectl apply -f testing/load/prometheus.yaml
      sleep 1m
      startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      echo "Running test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CHURNS"
      go run cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=200 --provider=aks --kubeconfig=${HOME}/.kube/config -v ${verbosity}
      echo Checking deployment
      kubectl get deploy -n $testNs

      echo "Checking if istiod failed"
      istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
      statuses=($istiodStatuses)
      for status in "${statuses[@]}"
      do
          if [ $status != "Running" ]; then
              istiodFailed=true
          fi
      done

      if ! $istiodFailed; then
        i=0
        while [ $i != 30 ] ; 
        do
          allPodsUp=$(go run checker/check-pods.go  ${CL2_TOTAL_PODS})
          if [ $allPodsUp != "true" ]; then
            for podName in $(kubectl get pod -n $testNs| grep -v Running | awk '{print $1;}'); 
            do
              kubectl delete pod $podName -n $testNs 
            done
          fi
          i=$[$i+1]
          sleep 15
        done
        echo "Deleting sidecars"
        deploySuccessfully=$(go run sidecars.go ${CL2_TOTAL_PODS} ${CHURNS})
        echo $deploySuccessfully
        sleep 15m 
      fi
      endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      echo "Port forward Prometheus"
      kubectl port-forward svc/prometheus 9090:9090 &
    fi

    echo "Checking if istiod failed"
    istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
    statuses=($istiodStatuses)
    for status in "${statuses[@]}"
    do
        if [ $status != "Running" ]; then
            istiodFailed=true
        fi
    done

    if [ $deploySuccessfully == "true" ]; then
      i=0
      while [ $i != 30 ] ; 
      do
        allPodsUp=$(go run checker/check-pods.go  ${CL2_TOTAL_PODS})
        if [ $allPodsUp != "true" ]; then
          testNs=$(echo $testNamespaces |  awk '{print $2;}' )
          for podName in $(kubectl get pod -n $testNs | grep -v Running | awk '{print $1;}'); 
          do
            kubectl delete pod $podName -n $testNs 
          done
        fi
        i=$[$i+1]
        sleep 30
      done
      if [ $allPodsUp == "true" ]; then
        python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed}
        echo "Captured prometheus graphs: istiod failed - ${istiodFailed}, -s ${startTime} -e ${endTime}"
      fi
    fi
  done
done