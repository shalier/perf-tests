#!/bin/bash
export STRESS_CHURN="${STRESS_CHURN:-20}"
export STRESS_ENDPOINTS="${STRESS_ENDPOINTS:-5000}"
export STRESS_PROMETHEUS_DIR_PATH=""

skip=false
while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true ;;
    -e | --endpoint)    STRESS_ENDPOINTS=$2 ;;
    -c | --churn) STRESS_CHURN=$2 ;;
  esac
  shift
done

kubectl apply -f testing/load/detailedprometheus.yaml

istiodFailed=false
churn=(50)
endpoints=(50000)
tries=(1)
for try in "${tries[@]}"
do
  for e in "${endpoints[@]}"
  do
    for c in "${churn[@]}"
    do
      STRESS_ENDPOINTS=$e
      STRESS_CHURN=$c
      
      kubectl delete ns test
      kubectl create ns test
      kubectl label ns test istio.io/rev=asm-1-17
      kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
      kubectl apply -f testing/load/istio-virtualservice.yaml # in test ns
      
      pkill -f "port-forward"
      kubectl rollout restart deployment/prometheus -n aks-istio-system
      echo "Port forward Prometheus"
      startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      kubectl port-forward -n aks-istio-system svc/prometheus 9090:9090 &
      echo Waiting for istiod to stabilize
      sleep 5m

      echo "Churn endpoints"
      operations=$(go run testing/load/endpoints.go ${STRESS_ENDPOINTS} ${STRESS_CHURN})
      STRESS_PROMETHEUS_DIR_PATH="t0_${STRESS_ENDPOINTS}endpoints_${STRESS_CHURN}percentChurn_${operations}"
      echo "STRESS_PROMETHEUS_DIR_PATH ${STRESS_PROMETHEUS_DIR_PATH}"
      sleep 10m 
      echo "Checking if istiod failed"
      istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
      statuses=($istiodStatuses)
      for i in "${statuses[@]}"
      do
          if [ $i != "Running" ]; then
              istiodFailed=true
          fi
      done

      endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} ${try}
      echo "python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed} ${try}"
    done
  done
done