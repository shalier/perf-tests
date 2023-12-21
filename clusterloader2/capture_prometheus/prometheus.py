from textwrap import fill
from matplotlib.backends.backend_pdf import PdfPages
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd
import sys
import os
import subprocess
import query as ppd
from pathlib import Path

def get_queries():
    if  "STRESS_PROMETHEUS_DIR_PATH" in os.environ:
        with open(sys.path[0]+'/endpoints_metrics.txt') as input_metrics:
            lines = input_metrics.read().splitlines()
        queries = list(set(lines))
    else:
        with open(sys.path[0]+'/metrics.txt') as input_metrics:
            lines = input_metrics.read().splitlines()
        queries = list(set(lines))
    return queries

def main():
    queryDict={
        'sum(rate(apiserver_request_total{job="kubernetes-apiservers",code=~"2.."}[1m]))*100/sum(rate(apiserver_request_total{job="kubernetes-apiservers"}[1m]))': 'success-rate-of-requests-apiserver',
        'sum(rate(apiserver_request_total{job="kubernetes-apiservers",code=~"[45].."}[1m]))*100/sum(rate(apiserver_request_total{job="kubernetes-apiservers"}[1m]))': 'fail-rate-of-requests-apiserver',
        'max by (code)(rate(apiserver_request_total{code=~"^(?:5..)$"}[1m])) >0': '5xx-requests-apiserver',
        'max by (code)(rate(apiserver_request_total{code=~"^(?:4..)$"}[1m])) >0': '4xx-requests-apiserver',
        'max by (code)(rate(apiserver_request_total{code=~"^(?:5..)$"}[1m]) / rate(apiserver_request_total[1m]))': '5xx-alt-requests-apiserver',
        'max by (code)(rate(apiserver_request_total{code=~"^(?:4..)$"}[1m]) / rate(apiserver_request_total[1m]))': '4xx-alt-requests-apiserver',
        'histogram_quantile(0.99, sum(rate(apiserver_request_slo_duration_seconds_bucket{job="kubernetes-apiservers"}[1m])) by (verb, le))': 'p99-apiserver-response-latency',
        'sum(rate(apiserver_request_total[1m])) by (verb)': 'rate-of-requests-apiserver-by-verb',
        'histogram_quantile(0.99, sum(rate(etcd_request_duration_seconds_bucket{job="kubernetes-apiservers"}[1m])) by (le,operation))': 'p99-etcd-request-latency',
        'max by (name)(rate(workqueue_adds_total{job="kubernetes-apiservers"}[1m]))': 'avg-add-workqueue',
        'rate(process_cpu_seconds_total{job="kubernetes-apiservers"}[1m])': 'cpu-apiserver',
        'process_resident_memory_bytes{job="kubernetes-apiservers"}/10^9': 'mem-apiserver-gb',
        'process_resident_memory_bytes{job="kubernetes-apiservers"}/10^6': 'mem-apiserver-mb',
        'max by (resource)(rate(apiserver_storage_list_fetched_objects_total{job="kubernetes-apiservers"}[1m]))>0':'etcd-object-listed',
        'max by (resource_prefix)(rate(apiserver_cache_list_fetched_objects_total{job="kubernetes-apiservers"}[1m]))': 'cache-obj-listed',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="discovery"}[1m])))': 'cpu-istiod',
        'max by (container)(container_memory_working_set_bytes{container="discovery"})/10^9': 'mem-istiod-gb',
        'max by (container)(container_memory_working_set_bytes{container="discovery"})/10^6': 'mem-istiod-mb',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="coredns"}[1m])))': 'cpu-coredns',
        'max by (container)(container_memory_working_set_bytes{container="coredns"})/10^6': 'mem-coredns-mb',
        'max by (container)(container_memory_working_set_bytes{container="coredns"})/10^9': 'mem-coredns-gb',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="istio-proxy"}[1m])))': 'cpu-sidecar',
        'max by (container)(container_memory_working_set_bytes{container="istio-proxy"})/10^9': 'mem-sidecar-gb',
        'sidecar_injection_requests_total': 'count-sidecar-created',
        'count(istio_agent_xds_proxy_requests)':'count-sidecar-literal',
        'sum(increase(envoy_cluster_upstream_rq_total[1y]))':'RPS',
        'sum by (namespace)(istio_agent_xds_proxy_requests)':'xds-proxy-request',
        'sum by (namespace)(increase(istio_agent_xds_proxy_responses[1y]))':'xds-proxy-response',
        'sum by (namespace)(istio_agent_pilot_xds)':'xds-pilot',
        'sum by (namespace)(increase(istio_agent_scrapes_total[1y]))':'istio-agent-scrape-total',
        'sum by (namespace)(increase(istio_agent_scrape_failures_total[1y]))':'istio-agent-scrape-fail',
        'pilot_inbound_updates':'pilot_inbound_updates',
        'pilot_services':'pilot_services',
        'pilot_k8s_reg_events':'pilot_k8s_reg_events',
    }
    if  "STRESS_PROMETHEUS_DIR_PATH" in os.environ:
        podSvcLabel=os.environ['STRESS_PROMETHEUS_DIR_PATH']
    else:
        t=sys.argv[4]
        testLabel=sys.argv[6]
        podSvcLabel=testLabel+'_t'+t+'_'+os.environ['ISTIOD_MEM']+'stiodMem_'+os.environ['CL2_TOTAL_PODS']+'pods_'+ os.environ['CL2_SERVICE_SIZE']+'svc_'+os.environ['CL2_CHURNS']+'churn'
    
    Path(sys.path[0]+'/results/'+podSvcLabel).mkdir(parents=True, exist_ok=True)
    if sys.argv[3] == "true":
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/istiod_failed_'
    else:
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/'
    if "STRESS_PROMETHEUS_DIR_PATH" not in os.environ and sys.argv[5]=="false" :
        partialCsvFileName+='podFail_'
    plt.rcParams["axes.formatter.limits"] = (-5, 12)
    queries=get_queries()

    startTime=sys.argv[1]
    endTime=sys.argv[2]

    p=ppd.Prometheus('http://localhost:9090')
    for query in queries:
        df=p.query_range(query,startTime,endTime, '60s')
        # clean dataframe
        df=df[df.columns[~df.isnull().all()]]
        df=df.dropna(how="all")
        if df.empty:
            continue
        cleanQuery=queryDict[query]
        if  "STRESS_PROMETHEUS_DIR_PATH" in os.environ:
            csvName=partialCsvFileName+os.environ['STRESS_ENDPOINTS']+"e_"+os.environ['STRESS_CHURN']+"c_"+cleanQuery+".csv"
        else:
            csvName=partialCsvFileName+os.environ['CL2_TOTAL_PODS']+'pods_'+os.environ['CL2_CHURNS']+'churn_'+cleanQuery+".csv"
        f=open(csvName,'w')
        df.to_csv(csvName)
        f.close()


if __name__ == "__main__":
    main()

