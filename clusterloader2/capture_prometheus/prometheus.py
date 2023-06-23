from textwrap import fill
from matplotlib.backends.backend_pdf import PdfPages
import matplotlib.dates as mdates
import matplotlib.pyplot as plt
import pandas as pd
import sys
import os
import subprocess
import query as ppd

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
        metrics.write("\ncount(count(container_memory_working_set_bytes{namespace="+testns+"}) by (pod))")
    print(testns)

def remove_istiod_query():
    with open(sys.path[0]+'/metrics.txt', "r+", encoding = "utf-8") as file:
        # Move the pointer (similar to a cursor in a text editor) to the end of the file
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
    if sys.argv[3] == "true":
        istiod_query()
        fileName=sys.path[0]+'/results/istiod_failed_'+os.environ['CL2_TOTAL_PODS']+'pods_'+ os.environ['CL2_SERVICE_SIZE']+'svcs_'+os.environ['CL2_REPEATS']+'churn.pdf'
    else:
        fileName=sys.path[0]+'/results/'+os.environ['CL2_TOTAL_PODS']+'pods_'+ os.environ['CL2_SERVICE_SIZE']+'svcs_'+os.environ['CL2_REPEATS']+'churn.pdf'
    plt.rcParams["axes.formatter.limits"] = (-5, 12)
    queries=get_queries()

    f=open(fileName,'w')
    startTime=sys.argv[1]
    endTime=sys.argv[2]
    print(startTime,endTime)
    p=ppd.Prometheus('http://localhost:9090')
    with PdfPages(fileName) as pdf:
        for query in queries:
            print(query)
            df=p.query_range(query,startTime,endTime, '1m')
            # print(df)
            if df.empty:
                continue
            df=df[df.columns[~df.isnull().all()]]
            df=df.dropna(how="all")
            # print(df)
            labels=[fill(l,20) for l in df.columns]
            ax=df.plot(marker="o")
            ax.legend(labels,loc='center left',bbox_to_anchor=(1.0, 0.5))
            # testDuration=time.mktime(datetime.strptime(endTime,"%Y-%m-%dT%H:%M:%SZ").timetuple())-time.mktime(datetime.strptime(startTime,"%Y-%m-%dT%H:%M:%SZ").timetuple())
            ax.set_xlim(pd.to_datetime(startTime), pd.to_datetime(endTime))
            ax.xaxis.set_major_locator(mdates.MinuteLocator(interval=2))
            ax.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))
            # plt.plot(x, y, marker="o", markersize=20, markeredgecolor="red", markerfacecolor="green")
            plt.title(fill(query,55))
            pdf.savefig(bbox_inches='tight')
    f.close()
    if sys.argv[3]=="true":
        remove_istiod_query()

if __name__ == "__main__":
    main()