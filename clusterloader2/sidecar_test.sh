#!/bin/bash
export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-0}"
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-1}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-1000}"
export CL2_CHURNS="${CL2_CHURNS:-0}"
export ISTIOD_MEM="${ISTIOD_MEM:-2Gi}"

skip=false
verbosity=0
while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true;;
    -s | --start)  startTime=$2 ;;
    -e | --end) endTime=$2 ;;
    -p | --podCount)    CL2_TOTAL_PODS=$2 ;;
    -i | --istiodFail) istiodFailed=true ;;
    -c | --churn) CL2_CHURNS=$2 ;;
    -pa | --podArray) podArray=$2 ;;
    -ca | --churnArray) churnArray=$2 ;;
    -v) verbosity=$2 ;;
    -l) label=$2;;
    -h | --help) $'-k | --skip : to skip clusterloader \n   -s | --start for startTime \n -e | --end for endTime \n -p | --podCount set CL2_TOTAL_PODS \n  
                  -i | --istiodFail \n  -c | --churn \n  -pa | --podArray have to have quotes \n -v for verbosity lvl'
    exit ;;
  esac
  shift
done

if [ -z "$podArray" ]
then
  pods=(5000)
else
  pods=($podArray)
fi

if [ -z "$churnArray" ]
then
  churn=(0 25 50) # churn * 2 since up and down
else
  churn=($churnArray)
fi

if [ -z "$label" ] 
then
  testLabel="label"
else
  testLabel=$label
fi

if ! $skip; then
    for p in "${pods[@]}"
    do
      for c in "${churn[@]}"
      do
        if $istiodFailed && [ ${p} == ${CL2_TOTAL_PODS} ]; then
          echo failed, skipping - ${istiodFailed} and ${p} == ${CL2_TOTAL_PODS}
          continue
        fi
        echo $allPodsUp and ${p} == ${CL2_TOTAL_PODS}
        if ! [ $allPodsUp ] && [ ${p} == ${CL2_TOTAL_PODS} ]; then
          continue
        fi
        istiodFailed=false
        allPodsUp=false
        CL2_TOTAL_PODS=$p
        CL2_CHURNS=$c
        echo "Test: $testLabel, pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_CHURNS"
        testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
        kubectl delete namespace $testNamespaces
        kubectl -n aks-istio-system delete pod --all
        kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
        kubectl delete -f testing/load/prometheus.yaml
        pkill -f "port-forward"
        echo "----------------------------------------------------------------------------------------------------"
        kubectl apply -f testing/load/prometheus.yaml
        sleep 30s
        echo "----------------------------------------------------------------------------------------------------"
        startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

        go run cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=500 --provider=aks --kubeconfig=${HOME}/.kube/config -v 2 --report-dir=logs

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
        python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp} ${testLabel}
        echo "
        export CL2_TOTAL_PODS=${CL2_TOTAL_PODS}
        export CL2_SERVICE_SIZE=${CL2_SERVICE_SIZE}
        export CL2_CHURNS=${CL2_CHURNS}
        export ISTIOD_MEM=${ISTIOD_MEM}
        export CL2_LOAD_TEST_THROUGHPUT=${CL2_LOAD_TEST_THROUGHPUT}
        "
        echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp} ${testLabel}"
      done
    done
else
  echo "Test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_CHURNS"
  testNamespaces=$(kubectl get ns -l istio.io/rev=asm-1-17 --no-headers -o jsonpath='{.items[*].metadata.name}')
  kubectl delete namespace $testNamespaces
  kubectl -n aks-istio-system delete pod --all
  kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
  kubectl delete -f testing/load/prometheus.yaml
  pkill -f "port-forward"
  echo "----------------------------------------------------------------------------------------------------"
  kubectl apply -f testing/load/prometheus.yaml
  sleep 30s
  echo "Test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, load-$CL2_LOAD_TEST_THROUGHPUT, churn - $CL2_CHURNS"
  startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  go run cmd/clusterloader.go --testconfig=testing/load/large-config-pod.yaml --nodes=500 --provider=aks --kubeconfig=${HOME}/.kube/config -v 2 --report-dir=logs

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
  python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp} ${testLabel}
  echo "
  export CL2_TOTAL_PODS=${CL2_TOTAL_PODS}
  export CL2_SERVICE_SIZE=${CL2_SERVICE_SIZE}
  export CL2_CHURNS=${CL2_CHURNS}
  export ISTIOD_MEM=${ISTIOD_MEM}
  export CL2_LOAD_TEST_THROUGHPUT=${CL2_LOAD_TEST_THROUGHPUT}
  "
  echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} 1 ${allPodsUp} ${testLabel}"
fi