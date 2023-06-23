#!/bin/bash
export RESOURCE_GROUP="${RESOURCE_GROUP:-test-asm}"
export RESOURCE_NAME="${RESOURCE_NAME:-stress-test-asm}"

export CL2_TOTAL_PODS="${CL2_TOTAL_PODS:-10}"
export CL2_SERVICE_SIZE="${CL2_SERVICE_SIZE:-10}"
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-10}"
export CL2_REPEATS="${CL2_REPEATS:-1}"

declare -a podCount=(5000)
declare -a churn=(1)

echo pod tests
for pod in "${podCount[@]}"
do
    CL2_TOTAL_PODS=${pod}
    CL2_SERVICE_SIZE=1000
    CL2_LOAD_TEST_THROUGHPUT=1000
    for c in "${churn[@]}"
    do
        echo "Disabling Istio Addon"
        az aks mesh disable -g $RESOURCE_GROUP -n $RESOURCE_NAME -y --only-show-errors
        echo "Enabling Istio Addon"
        az aks mesh enable -g $RESOURCE_GROUP -n $RESOURCE_NAME --only-show-errors
        CL2_REPEATS=${c}
        startTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "Running test: pods-${CL2_TOTAL_PODS}, services-${CL2_SERVICE_SIZE}, churn-${CL2_REPEATS}, load-$CL2_LOAD_TEST_THROUGHPUT"
        go run cmd/clusterloader.go --testconfig=testing/load/large-config-multiple-teardown.yaml --nodes=100 --provider=aks --kubeconfig=${HOME}/.kube/config
        endTime=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        echo "Port forward Prometheus"
        kubectl port-forward svc/prometheus 9090:9090 &
        sleep 5
        # Checking if istiod OOMKilled or Errored
        istiodStatuses=$(kubectl get pod -l=app='istiod' -n aks-istio-system -o jsonpath='{.items[*].status.phase}')
        statuses=($istiodStatuses)
        istiodFailed=false
        for i in "${statuses[@]}"
        do 
            if [ $i != "Running" ]; then
                istiodFailed=true
            fi
        done
        echo capturing prometheus graphs: ${startTime} and ${endTime}
        python3 capture_prometheus/prometheus.py ${startTime} ${endTime} ${istiodFailed}
        #${startTime} ${endTime} ${istiodFailed}
        echo Finished capturing Prometheus graphs
        cd ..
    done
done
