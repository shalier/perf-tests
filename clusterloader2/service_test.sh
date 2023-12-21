#!/bin/bash
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-1}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-1000}"
export CL2_CHURNS=0
export ISTIOD_MEM="${ISTIOD_MEM:-2Gi}"
export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-1}"
skip=false
verbosity=0

while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true;;
    -p | --podCount)    CL2_TOTAL_PODS=$2 ;;
    -s | --service)    CL2_SERVICE_SIZE=$2 ;;
    -i | --istiodFail) istiodFailed=true ;;
    -c | --churn) CL2_CHURNS=$2 ;;
    -ea | --endpointsArray) endpointsArray=$2;;
    -v) verbosity=$2 ;;
    -l) label=$2;;
    -h | --help) $'-k | --skip \n  -s | --service set CL2_SERVICE_SIZE \n  
                  -i | --istiodFail \n  -c | --churn which churn to do: 1 = none, 2 = 90%, 3=80%, 4=50% \n  
                  -ea | --endpointsArray have to have quotes \n -v for verbosity lvl'
    exit ;;
  esac
  shift
done

if [ -z "$endpointsArray" ]
then
    endpoints=(15 17 20)
else
  endpoints=($endpointsArray)
fi

if [ -z "$label" ] 
then
  testLabel="label"
else
  testLabel=$label
fi

if ! $skip; then
  svcCount=(1000)
  endpoints=(15 17 20)
    for service in "${svcCount[@]}"
    do
      for endpoint in "${endpoints[@]}"
      do
        if $istiodFailed && [ ${service} == ${CL2_SERVICE_SIZE} ]; then
          echo failed, skipping - ${istiodFailed} and ${service} == ${CL2_SERVICE_SIZE}
          continue
        fi
        istiodFailed=false
        CL2_TOTAL_PODS=$endpoint
        CL2_SERVICE_SIZE=$service
        testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
        kubectl delete namespace $testNamespaces
        kubectl -n aks-istio-system delete pod --all
        kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
        kubectl delete -f testing/load/prometheus.yaml
        pkill -f "port-forward"
        echo "----------------------------------------------------------------------------------------------------"
        kubectl apply -f testing/load/prometheus.yaml
        sleep 5m
        echo "Test: endpoints-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT"
        startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "----------------------------------------------------------------------------------------------------"

        go run cmd/clusterloader.go --testconfig=testing/load/stress-service-not-shared-endpoints.yaml --nodes=500 --provider=aks --kubeconfig=${HOME}/.kube/config -v 2 --report-dir=logs
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
        ISTIOD_MEM=$(kubectl get pods -n aks-istio-system -o=jsonpath='{.items[*].spec.containers[*].resources.requests.memory}')
        endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 2 ${allPodsUp} ${testLabel}
        echo "
        export CL2_TOTAL_PODS=${CL2_TOTAL_PODS}
        export CL2_SERVICE_SIZE=${CL2_SERVICE_SIZE}
        export CL2_CHURNS=${CL2_CHURNS}
        export ISTIOD_MEM=${ISTIOD_MEM}
        export CL2_LOAD_TEST_THROUGHPUT=${CL2_LOAD_TEST_THROUGHPUT}
        "
        echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 2 ${allPodsUp} ${testLabel}"

      done
    done
else
  kubectl -n aks-istio-system delete pod --all
  kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
  # kubectl delete -f testing/load/prometheus.yaml
  # pkill -f "port-forward"
  echo "----------------------------------------------------------------------------------------------------"
  # kubectl apply -f testing/load/prometheus.yaml
  # sleep 30s
  echo "Test: endpoints-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT"
  startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # go run cmd/clusterloader.go --testconfig=testing/load/stress-service-not-shared-endpoints.yaml --nodes=400 --provider=aks --kubeconfig=${HOME}/.kube/config -v $verbosity
  go run cmd/clusterloader.go --testconfig=testing/load/stress-service-shared-endpoints.yaml --nodes=500 --provider=aks --kubeconfig=${HOME}/.kube/config -v $verbosity

  # kubectl port-forward svc/prometheus 9090:9090 &

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
  # testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
  # kubectl delete namespace $testNamespaces
  sleep 5m
  endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 2 ${allPodsUp} ${testLabel}
  echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 2 ${allPodsUp} ${testLabel}"
fi