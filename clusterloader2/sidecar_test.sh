#!/bin/bash
export RESOURCE_GROUP="${RESOURCE_GROUP:-test-asm}"
export RESOURCE_NAME="${RESOURCE_NAME:-stress-test-asm}"

export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-5000}"
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-1}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-1000}"
export CL2_CHURNS="${CL2_CHURNS:-0}"
export ISTIOD_MEM="${ISTIOD_MEM:-2Gi}"

skip=false
verbosity=0
istiodFailed=false
ISTIOD_MEM=$(kubectl get pods -n aks-istio-system -o=jsonpath='{.items[*].spec.containers[*].resources.requests.memory}')

while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true;;
                    # echo "skipping cl2" ;;
    -s | --start)  startTime=$2 ;;
    -e | --end) endTime=$2 ;;
    -p | --podCount)    CL2_TOTAL_PODS=$2 ;;
    -i | --istiodFail) istiodFailed=true ;;
    -c | --churn) CL2_CHURNS=$2 ;;
    -v) verbosity=$2 ;;
    -h | --help) $'-k | --skip : to skip clusterloader \n   -s | --start for startTime \n -e | --end for endTime \n -p | --podCount set CL2_TOTAL_PODS \n  
                  -i | --istiodFail \n  -c | --churn which churn to do: 1 = none, 2 = 90%, 3=80%, 4=50% \n  -v for verbosity lvl'
    exit ;;
  esac
  shift
done

kubectl apply -f testing/load/prometheus.yaml

if ! $skip; then
  pods=(500)
  churn=(0 10 25 50) # churn * 2 since up and down
    for p in "${pods[@]}"
    do
      for c in "${churn[@]}"
      do
        CL2_TOTAL_PODS=$p
        CL2_CHURNS=$c
        kubectl -n aks-istio-system delete pod --all
        kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
        kubectl delete pod --all
        kubectl rollout restart deployment/prometheus
        pkill -f "port-forward"
        echo "----------------------------------------------------------------------------------------------------"

        echo "Test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_CHURNS"
        startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo startTime $startTime

        go run cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=449 --provider=aks --kubeconfig=${HOME}/.kube/config -v $verbosity

        endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo endTime $endTime

        istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
        statuses=($istiodStatuses)
        for status in "${statuses[@]}"
        do
          if [ $status != "Running" ]; then
            echo istiod failed
            istiodFailed=true
          fi
        done
        echo ====================================================================================================
        # echo Check that all pods are running
        allPodsUp=$(go run checker/check-pods.go  ${CL2_TOTAL_PODS})
        echo ${allPodsUp}
        testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
        kubectl delete namespace $testNamespaces
        testNs=$(echo $testNamespaces |  awk '{print $2;}' )
        sleep 5m
        # echo "Port forward Prometheus"
        kubectl port-forward svc/prometheus 9090:9090 &
          
        python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp}
        echo "Captured prometheus graphs: istiod failed - ${istiodFailed}, -s ${startTime} -e ${endTime}"
      done
    done
else
  kubectl -n aks-istio-system delete pod --all
  kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
  kubectl delete pod --all
  kubectl rollout restart deployment/prometheus
  pkill -f "port-forward"
  echo "----------------------------------------------------------------------------------------------------"

  echo "Test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_CHURNS"
  startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo startTime $startTime

  go run cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=450 --provider=aks --kubeconfig=${HOME}/.kube/config -v $verbosity


  kubectl port-forward svc/prometheus 9090:9090 &

  istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
  statuses=($istiodStatuses)
  for status in "${statuses[@]}"
  do
    if [ $status != "Running" ]; then
      echo istiod failed
      istiodFailed=true
    fi
  done
  echo ====================================================================================================
  allPodsUp=$(go run checker/check-pods.go  ${CL2_TOTAL_PODS})
  echo ${allPodsUp}
  testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
  kubectl delete namespace $testNamespaces
  testNs=$(echo $testNamespaces |  awk '{print $2;}' )
  sleep 5m
  endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  echo endTime $endTime
  python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp}
  echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp}"
fi