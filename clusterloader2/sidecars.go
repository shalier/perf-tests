package main

import (
	"context"
	"flag"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

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
			if strings.Contains(ns.Name, "test") {
				nsName = ns.Name
			}
		}
	}
	fmt.Println("namespace", nsName)
	numPods, err := strconv.Atoi(os.Args[1])
	if err != nil {
		fmt.Println("numPods must be an int", err)
		panic(err)
	}
	percentage, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Println("percentage must be an int", err)
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

	var tickerTime time.Duration = 500 // milliseconds
	var testDuration time.Duration = 1 // seconds
	ticker := time.NewTicker(tickerTime * time.Millisecond)
	done := make(chan bool)

	numToRemove := math.Ceil(float64(percentage) * float64(numPods) / (100 * 2))
	fmt.Println("numToRemove", numToRemove)
	go func() {
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				fmt.Println("removing pods")
				removePods(clientset, nsName, int(numToRemove))
			}
		}
	}()

	time.Sleep(testDuration * time.Second)
	ticker.Stop()
	done <- true
	fmt.Print("true")
}

func removePods(clientset *kubernetes.Clientset, nsName string, numToRemove int) {
	numRemoved := 0
	podList, err := clientset.CoreV1().Pods(nsName).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		fmt.Println("struggled to get pods", err)
	}
	for {
		for _, pod := range podList.Items {
			err = clientset.CoreV1().Pods(nsName).Delete(context.Background(), pod.Name, metav1.DeleteOptions{})
			if err != nil {
				fmt.Println("couldnt delete pod", err)
				continue
			}
			numRemoved++
			if numRemoved%10 == 0 {
				fmt.Println("numRemoved:", numRemoved)
			}
			if numToRemove == numRemoved {
				return
			}
		}
	}
}
