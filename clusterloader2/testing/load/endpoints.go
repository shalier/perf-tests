package main

import (
	"context"
	"flag"
	"fmt"
	"math"
	"path/filepath"
	"strconv"
	"time"

	core "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
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
	svcName := "test-service"
	namespaceName := "default"
	// create service with no selector
	_, err = clientset.CoreV1().Services("default").Create(context.Background(),
		&core.Service{
			ObjectMeta: metav1.ObjectMeta{
				Name:      svcName,
				Namespace: namespaceName,
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

	var port80 int32 = 80
	endpointAddrs := generateEndpointIPs(5000)

	// create endpoints
	_, err = clientset.CoreV1().Endpoints(namespaceName).Create(context.Background(),
		&core.Endpoints{
			ObjectMeta: metav1.ObjectMeta{
				Name:      svcName,
				Namespace: namespaceName,
			},
			Subsets: []core.EndpointSubset{
				{
					Addresses: endpointAddrs,
					Ports:     []core.EndpointPort{{Port: port80}},
				},
			},
		},
		metav1.CreateOptions{})
	if err != nil {
		fmt.Println("failed to make endpoints")
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

// need to distribute 5k endpoints to endpointslices
// probably need to put kube stuff as parameter
func distributeEndpointsToEndpointSlices(clientset *kubernetes.Clientset, ns string, port *int32, ipAddrs []string) error {
	endpointSliceName := "endpoint-slice"
	_, err := clientset.DiscoveryV1().EndpointSlices(ns).Create(context.Background(),
		&discoveryv1.EndpointSlice{
			ObjectMeta: metav1.ObjectMeta{
				Name:      endpointSliceName,
				Namespace: ns,
				Labels:    map[string]string{"kubernetes.io/service-name": "test-service"},
			},
			AddressType: discoveryv1.AddressTypeIPv4,
			Ports:       []discoveryv1.EndpointPort{{Port: port}},
			Endpoints:   []discoveryv1.Endpoint{},
		}, metav1.CreateOptions{})
	return err
}

func generateEndpointIPs(numIpToCreate float64) []string {
	addresses := []string{}
	initialIP := "10.244."
	fourthLim := math.Ceil(numIpToCreate / 256)
	for i := 0; i <= 256; i++ {
		for j := 0; j <= int(fourthLim); j++ {
			third := strconv.Itoa(i)
			fourth := strconv.Itoa(j)
			addr := initialIP + third + "." + fourth
			addresses = append(addresses, addr)
			if len(addresses) == 999 {
				return addresses
			}
		}
	}
	return nil
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
