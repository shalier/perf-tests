package main

import (
	"context"
	"flag"
	"fmt"
	"path/filepath"
	"time"

	core "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
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
	fmt.Println("kubeconfig is", kubeconfig)
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

	// create service with no selector
	_, err = clientset.CoreV1().Services("default").Create(context.Background(),
		&core.Service{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "test-service",
				Namespace: "default",
			},
			Spec: core.ServiceSpec{
				Ports: []core.ServicePort{
					{
						Protocol:   core.ProtocolTCP,
						Port:       80,
						TargetPort: intstr.IntOrString{IntVal: 80},
					},
				},
			},
		},
		metav1.CreateOptions{})
	if err != nil {
		fmt.Println("failed to make service")
		panic(err)
	}

	// create endpoints
	_, err = clientset.CoreV1().Endpoints("default").Create(context.Background(),
		&core.Endpoints{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "test-service",
				Namespace: "default",
			},
			Subsets: []core.EndpointSubset{
				{
					Addresses: []core.EndpointAddress{},
					Ports:     []core.EndpointPort{},
				},
			},
		},
		metav1.CreateOptions{})
	if err != nil {
		fmt.Println("failed to make endpoint slices")
		panic(err)
	}

	ticker := time.NewTicker(500 * time.Millisecond)
	done := make(chan bool)

	go func() {
		for {
			select {
			case <-done:
				return
			case t := <-ticker.C:
				fmt.Println("Tick at", t)
			}
		}
	}()

	time.Sleep(1600 * time.Millisecond)
	ticker.Stop()
	done <- true
	fmt.Println("Ticker stopped")
}

/*
Create service spec

create endpoint slices --max-endpoints-per-slice 1000 (default 100, max 1000)
create endpoints
Burst Load Test

Endpoint Discovery Service (EDS) Update Test
–  One service with 5000 endpoints
–  Randomly churn one endpoint object at various rates
-- Randomly get 10% endpoints, delete and re-create per second
-- 20%
-- 50%
*/
