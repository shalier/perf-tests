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
    # print(sys.path[0]+ "hi")
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

def get_churn():
    churn = os.environ['CL2_REPEATS']
    match churn:
        case "1":
            return "_no_churn"
        case "2":
            return "_90_churn"
        case "3":
            return "_80_churn"
        case "4":
            return "_50_churn"
        case _:
            return "gt 4"

def main():
    churn=get_churn()
    podSvcLabel='t1_'+os.environ['ISTIOD_MEM']+'stiodMem_'+os.environ['CL2_TOTAL_PODS']+'pods_'+ os.environ['CL2_SERVICE_SIZE']+'svcs'+churn
    Path(sys.path[0]+'/results/'+podSvcLabel).mkdir(parents=True, exist_ok=True)
    if sys.argv[3] == "true":
        istiod_query()
        # fileName=sys.path[0]+'/results/'+podSvcLabel+'/aistiod_failed_results.pdf'
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/istiod_failed_'
    else:
        # fileName=sys.path[0]+'/results/'+podSvcLabel+'/aresults.pdf'
        partialCsvFileName=sys.path[0]+'/results/'+podSvcLabel+'/'
    plt.rcParams["axes.formatter.limits"] = (-5, 12)
    queries=get_queries()

    # f=open(fileName,'w')
    startTime=sys.argv[1]
    endTime=sys.argv[2]

    p=ppd.Prometheus('http://localhost:9090')
    # with PdfPages(fileName) as pdf:
    for query in queries:
        print(query)
        df=p.query_range(query,startTime,endTime, '1m')
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
        underscoreQuery=query.replace(" ", "").replace('(','').replace(')','').replace('{','').replace('}','')
        cleanQuery=''.join(e for e in query if e.isalpha())
        csvName=partialCsvFileName+cleanQuery+".csv"
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
            # # ax.set_xlim(pd.to_datetime(startTime), pd.to_datetime(endTime))

            # # figure out ticks
            # timeElapsed=pd.to_datetime(endTime)-pd.to_datetime(startTime)
            # timeElapsedInMin=timeElapsed.total_seconds()/60
            # if timeElapsedInMin>120:
            #     xInterval=10
            # elif timeElapsedInMin>60:
            #     xInterval=5
            # else:
            #     xInterval=2
            # print("using xInterval",xInterval)
            # ax.xaxis.set_major_locator(mdates.MinuteLocator(interval=xInterval))
            # ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
            
            # plt.title(fill(query,55))
            # pdf.savefig(bbox_inches='tight')
    if sys.argv[3]=="true":
        remove_istiod_query()

if __name__ == "__main__":
    main()