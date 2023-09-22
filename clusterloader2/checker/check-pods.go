package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
)

func main() {
	var kubeconfig *string
	if home := homedir.HomeDir(); home != "" { // check if machine has home directory.
		// read kubeconfig flag. if not provided use config file $HOME/.kube/config
		kubeconfig = flag.String("kubeconfig", filepath.Join(home, ".kube", "config"), "(optional) absolute path to the kubeconfig file")
	}
	// build configuration from the config file.
	config, err := clientcmd.BuildConfigFromFlags("", *kubeconfig)
	if err != nil {
		panic(err)
	}
	// create kubernetes clientset. can create,delete,patch,list etc. kubernetes resources
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		panic(err)
	}
	nsList, err := clientset.CoreV1().Namespaces().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		fmt.Println("struggled getting namespaces", err)
	}
	nsName := ""
	for _, ns := range nsList.Items {
		_, ok := ns.Labels["istio.io/rev"]
		if ok {
			nsName = ns.Name
		}
	}
	numPods, err := strconv.Atoi(os.Args[1])
	if err != nil {
		fmt.Println("numPods must be an int", err)
		panic(err)
	}

	deployList, err := clientset.AppsV1().Deployments(nsName).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		fmt.Println("couldnt get deployment", err)
	}
	if deployList.Items[0].Status.AvailableReplicas != int32(numPods) {
		fmt.Print("false")
		return
	}
	fmt.Print("true")
}
