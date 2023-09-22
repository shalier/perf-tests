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

def istiod_query():
    output=subprocess.check_output(["kubectl","get","namespaces","-o","name"])
    namespaces=str(output)
    namespaces = namespaces.split('\\n')
    testns=""
    for ns in namespaces:
        if ns.find('test') > 0:
            testns=ns
            break
    if not testns:
        return
    testns=testns.split('/')[1]
    with open(sys.path[0]+'/metrics.txt',"a") as metrics:
        metrics.write("\ncount(count(container_memory_working_set_bytes{namespace=\""+testns+"\"}) by (pod))")
    print(testns)

def remove_istiod_query():
    with open(sys.path[0]+'/metrics.txt', "r+", encoding = "utf-8") as file:
        # Move to the end of the file
        file.seek(0, os.SEEK_END)
        # This code means the following code skips the very last character in the file -
        # i.e. in the case the last line is null we delete the last line
        # and the penultimate one
        pos = file.tell() - 1
        # Read each character in the file one at a time from the penultimate
        # character going backwards, searching for a newline character
        # If we find a new line, exit the search
        while pos > 0 and file.read(1) != "\n":
            pos -= 1
            file.seek(pos, os.SEEK_SET)
        # So long as we're not at the start of the file, delete all the characters ahead
        # of this position
        if pos > 0:
            file.seek(pos, os.SEEK_SET)
            file.truncate()

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
        'process_resident_memory_bytes{job="kubernetes-apiservers"}/10^9': 'mem-apiserver',
        'process_resident_memory_bytes{job="kubernetes-apiservers"}/10^6': 'mem-apiserver',
        'max by (resource)(rate(apiserver_storage_list_fetched_objects_total{job="kubernetes-apiservers"}[1m]))':'etcd-object-listed',
        'max by (resource_prefix)(rate(apiserver_cache_list_fetched_objects_total{job="kubernetes-apiservers"}[1m]))': 'cache-obj-listed',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="discovery"}[1m])))': 'cpu-istiod',
        'max by (container)(container_memory_working_set_bytes{container="discovery"})/10^9': 'mem-istiod',
        'max by (container)(container_memory_working_set_bytes{container="discovery"})/10^6': 'mem-istiod',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="coredns"}[1m])))': 'cpu-coredns',
        'max by (container)(container_memory_working_set_bytes{container="coredns"})/10^6': 'mem-coredns',
        'max by (container)(container_memory_working_set_bytes{container="coredns"})/10^9': 'mem-coredns',
        'max by (container)(ceil(rate(container_cpu_usage_seconds_total{container="istio-proxy"}[1m])))': 'cpu-sidecar',
        'max by (container)(container_memory_working_set_bytes{container="istio-proxy"})/10^9': 'mem-sidecar',
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
        podSvcLabel='t'+t+'_'+os.environ['ISTIOD_MEM']+'stiodMem_'+os.environ['CL2_TOTAL_PODS']+'pods_'+ os.environ['CL2_SERVICE_SIZE']+'svc_'+os.environ['CL2_CHURNS']+'churn'
    
    Path(sys.path[0]+'/results/'+podSvcLabel).mkdir(parents=True, exist_ok=True)
    if sys.argv[3] == "true":
        istiod_query()
        # fileName=sys.path[0]+'/results/'+podSvcLabel+'/aistiod_failed_results.pdf'
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/istiod_failed_'
    else:
        # fileName=sys.path[0]+'/results/'+podSvcLabel+'/aresults.pdf'
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/'
    if "STRESS_PROMETHEUS_DIR_PATH" not in os.environ and sys.argv[5]=="false" :
        partialCsvFileName+='podFail_'
    plt.rcParams["axes.formatter.limits"] = (-5, 12)
    queries=get_queries()

    # f=open(fileName,'w')
    startTime=sys.argv[1]
    endTime=sys.argv[2]

    p=ppd.Prometheus('http://localhost:9090')
    # with PdfPages(fileName) as pdf:
    for query in queries:
        # print(query)
        df=p.query_range(query,startTime,endTime, '60s')
        # clean dataframe
        df=df[df.columns[~df.isnull().all()]]
        df=df.dropna(how="all")
        if df.empty:
            continue
        # if "max by (code)" in query:
        #     ax=df.plot(marker="o", stacked=True)
        # else:
        #     ax=df.plot(marker="o")

        # create csv file

        # underscoreQuery=query.replace(" ", "").replace('(','').replace(')','').replace('{','').replace('}','')
        # cleanQuery=''.join(e for e in query if e.isalpha())
        cleanQuery=queryDict[query]
        if  "STRESS_PROMETHEUS_DIR_PATH" in os.environ:
            csvName=partialCsvFileName+os.environ['STRESS_ENDPOINTS']+"e_"+os.environ['STRESS_CHURN']+"c_"+cleanQuery+".csv"
        else:
            csvName=partialCsvFileName+os.environ['CL2_TOTAL_PODS']+'pods_'+os.environ['CL2_CHURNS']+'churn_'+cleanQuery+".csv"
        f=open(csvName,'w')
        df.to_csv(csvName)
        f.close()

        # # apply legend
        # if len(df.columns)>100:
        #     ax.get_legend().remove()
        # elif len(df.columns)>10:
        #     labels=[]
        #     for col in df:
        #         for v in df[col].values:
        #             if v>0:
        #                 labels.append(col)
        #     ax.legend(list(set(labels)),loc='center left',bbox_to_anchor=(1.0, 0.5),prop={'size':6})
        # else:
        #     labels=[fill(l,20) for l in df.columns]
        #     ax.legend(labels,loc='center left',bbox_to_anchor=(1.0, 0.5))
        # ax.set_xlim(pd.to_datetime(startTime), pd.to_datetime(endTime))

        # # figure out ticks
        # timeElapsed=pd.to_datetime(endTime)-pd.to_datetime(startTime)
        # timeElapsedInMin=timeElapsed.total_seconds()/60
        # if  len(os.environ['STRESS_PROMETHEUS_DIR_PATH'])==0:
        #     if timeElapsedInMin>120:
        #         xInterval=10
        #     elif timeElapsedInMin>60:
        #         xInterval=5
        #     else:
        #         xInterval=2
        #     ax.xaxis.set_major_locator(mdates.MinuteLocator(interval=xInterval))
        # else:
        #     ax.xaxis.set_major_locator(mdates.SecondLocator(interval=15))

        # ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
        # plt.title(fill(query,55))
        # pdf.savefig(bbox_inches='tight')
    # remove_istiod_query()


if __name__ == "__main__":
    main()

