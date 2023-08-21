#!/bin/bash
export STRESS_CHURN="${STRESS_CHURN:-20}"
export STRESS_ENDPOINTS="${STRESS_ENDPOINTS:-5000}"

while [ $# -gt 0 ] ; do
  case $1 in
    -k | --skip)    skip=true ;;
    -e | --endpoint)    STRESS_ENDPOINTS=$2 ;;
    -c | --churn) STRESS_CHURN=$2 ;;
  esac
  shift
done
export STRESS_PROMETHEUS_DIR_PATH="${STRESS_ENDPOINTS}endpoints_${STRESS_CHURN}percentChurn"
echo "STRESS_PROMETHEUS_DIR_PATH ${STRESS_PROMETHEUS_DIR_PATH}"
kubectl delete ns test
kubectl create ns test
kubectl label namespace test istio-injection=enabled --overwrite
sleep 5
kubectl -n aks-istio-system rollout restart deployment/istiod-asm-1-17
kubectl apply -f testing/load/istio-virtualservice.yaml

kubectl delete -f testing/load/detailedprometheus.yaml
kubectl apply -f testing/load/detailedprometheus.yaml
startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# echo "Port forward Prometheus"
# kubectl port-forward -n aks-istio-system  svc/prometheus 9090:9090 &
sleep 1m

go run testing/load/endpoints.go ${STRESS_ENDPOINTS} ${STRESS_CHURN}
sleep 3m 

endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

python3 ${PWD}/capture_prometheus/prometheus.py ${startTime} ${endTime} false
echo "Captured prometheus graphs ${startTime} ${endTime}"