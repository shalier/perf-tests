package main

import (
	"context"
	"flag"
	"fmt"
	"math"
	"math/rand"
	"os"
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
	"k8s.io/utils/pointer"
)

const (
	namespaceName = "test"
	svcName       = "test-service"
)

var (
	numEndpointsToTest string = os.Args[1]
	port80             int32  = 80
	initialIP                 = "10.244."
)

// creates one service
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

	// create service with no selector
	_, err = clientset.CoreV1().Services(namespaceName).Create(context.Background(),
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
		// panic(err)
	}

	endpointAddrs := generateEndpointIPs()
	// fmt.Println(len(endpointAddrs))
	// fmt.Println("Creating endpoint slices")
	// err = createEndpointSlices(clientset, namespaceName, &port80, endpointAddrs)
	// if err != nil {
	// 	fmt.Println("failed to make endpoint slices", err)
	// 	// panic(err)
	// }
	fmt.Println("creating endpoints")
	err = createEndpoints(clientset, namespaceName, port80, endpointAddrs)
	if err != nil {
		fmt.Println("failed to make endpoints")
		// panic(err)
	}
	fmt.Println("Wait before churn")
	time.Sleep(5 * time.Second)

	ticker := time.NewTicker(200 * time.Millisecond)
	done := make(chan bool)
	percentage, err := strconv.Atoi(os.Args[2])
	fmt.Println("endpoint churn", percentage, "%")
	if err != nil {
		fmt.Println("percentage must be an int")
		panic(err)
	}
	shouldRm := true
	go func() {
		for {
			select {
			case <-done:
				return
			case t := <-ticker.C:
				fmt.Println("Tick at", t)
				endpointList, err := clientset.CoreV1().Endpoints(namespaceName).List(context.Background(), metav1.ListOptions{})
				if err != nil {
					fmt.Println("couldn't list endpoint obj", err)
				}
				endpointObj := endpointList.Items[0]
				endpointAddrs := endpointObj.Subsets[0].Addresses
				numChangePer200ms := percentage * len(endpointAddrs) / 500
				if shouldRm {
					fmt.Println("removing endpoints")
					shouldRm = false
					randomRemoveEndpointAddrs(&endpointAddrs, numChangePer200ms)
				} else {
					fmt.Println("creating endpoints")
					shouldRm = true
					addEndpointAddrs(&endpointAddrs, numChangePer200ms)
				}
				diff := compareEndpointAddrs(endpointAddrs, endpointObj.Subsets[0].Addresses)
				fmt.Println(len(diff))
				endpointObj.Subsets[0].Addresses = endpointAddrs
				fmt.Println("updating endpoints")
				_, err = clientset.CoreV1().Endpoints(namespaceName).Update(context.Background(), &endpointObj, metav1.UpdateOptions{})
				if err != nil {
					fmt.Println("failed to update endpoints", err)
					panic(err)
				}
			}
		}
	}()

	time.Sleep(1000 * time.Millisecond)
	ticker.Stop()
	done <- true
	fmt.Println("Ticker stopped")
}

func compareEndpointAddrs(a, b []core.EndpointAddress) []core.EndpointAddress {
	mb := make(map[core.EndpointAddress]struct{}, len(b))
	for _, x := range b {
		mb[x] = struct{}{}
	}
	var diff []core.EndpointAddress
	for _, x := range a {
		if _, found := mb[x]; !found {
			diff = append(diff, x)
		}
	}
	return diff
}

func addEndpointAddrs(addrs *[]core.EndpointAddress, numAdd int) {
	numEndpoints, _ := strconv.ParseFloat(numEndpointsToTest, 64)
	min := int(math.Ceil(numEndpoints / 256))
	for i := 0; i < numAdd; i++ {
		rand.Seed(time.Now().UnixNano())
		newFourth := rand.Intn(256-min) + min
		newThird := rand.Intn(256)
		fourth := strconv.Itoa(newFourth)
		third := strconv.Itoa(newThird)

		*addrs = append(*addrs, core.EndpointAddress{
			IP: initialIP + third + "." + fourth,
		})
	}
}

func randomRemoveEndpointAddrs(addrs *[]core.EndpointAddress, numRm int) {
	for i := 0; i < numRm; i++ {
		rand.Seed(time.Now().UnixNano())
		index := rand.Intn(len(*addrs))
		*addrs = append((*addrs)[:index], (*addrs)[index+1:]...)
	}
}

func createEndpoints(clientset *kubernetes.Clientset, ns string, port int32, ipAddrs []string) error {
	// create endpoint addresses
	addrs := createEndpointAddresses(clientset, ipAddrs)
	// create endpoints
	_, err := clientset.CoreV1().Endpoints(ns).Create(context.Background(),
		&core.Endpoints{
			ObjectMeta: metav1.ObjectMeta{
				Name:      svcName,
				Namespace: namespaceName,
			},
			Subsets: []core.EndpointSubset{
				{
					Addresses: addrs,
					Ports:     []core.EndpointPort{{Port: port80}},
				},
			},
		},
		metav1.CreateOptions{})
	if err != nil {
		fmt.Println("failed to make endpoints")
		return err
	}
	return nil
}

func createEndpointAddresses(clientset *kubernetes.Clientset, ipAddrs []string) []core.EndpointAddress {
	addrs := []core.EndpointAddress{}
	for _, ip := range ipAddrs {
		addrs = append(addrs, core.EndpointAddress{
			IP: ip,
		})
	}
	return addrs
}

// This creates the endpoint slices but doesn't create the endpoints themselves
func createEndpointSlices(clientset *kubernetes.Clientset, ns string, port *int32, ipAddrs []string) error {
	// endpoint slice can have 1000 endpoints
	numEndpointsInSlice := 1000
	numEndpointSlices := len(ipAddrs) / numEndpointsInSlice
	endpointSlicePrefix := "endpoint-slice-"
	for currEndpointSlice := 0; currEndpointSlice < numEndpointSlices; currEndpointSlice++ {
		endpoints := createEndpointsForEndpointSlice(ipAddrs, currEndpointSlice, numEndpointsInSlice)

		_, err := clientset.DiscoveryV1().EndpointSlices(ns).Create(context.Background(),
			&discoveryv1.EndpointSlice{
				ObjectMeta: metav1.ObjectMeta{
					Name:      endpointSlicePrefix + strconv.Itoa(currEndpointSlice+1),
					Namespace: ns,
					Labels: map[string]string{
						"kubernetes.io/service-name": svcName,
						// "endpointslice.kubernetes.io/managed-by": "endpointslicemirroring-controller.k8s.io",
					},
				},
				AddressType: discoveryv1.AddressTypeIPv4,
				Ports:       []discoveryv1.EndpointPort{{Port: port}},
				Endpoints:   endpoints,
			}, metav1.CreateOptions{})
		if err != nil {
			return fmt.Errorf("failed to make endpoint slice %v: error %v", currEndpointSlice, err)
		}
	}
	return nil
}

func createEndpointsForEndpointSlice(ipAddrs []string, currEndpointSlice, numEndpoints int) []discoveryv1.Endpoint {
	endpoints := []discoveryv1.Endpoint{}
	start := currEndpointSlice * numEndpoints
	end := start + numEndpoints

	for i := start; i < end; i++ {
		// fmt.Println(start, end, len(ipAddrs))
		endpoints = append(endpoints, discoveryv1.Endpoint{
			Addresses: []string{ipAddrs[i]},
			Conditions: discoveryv1.EndpointConditions{
				Ready: pointer.Bool(true),
			},
		})
	}
	return endpoints
}

func generateEndpointIPs() []string {
	addresses := []string{}
	numEndpoints, _ := strconv.ParseFloat(numEndpointsToTest, 64)
	fourthLimIPAddr := int(math.Ceil(numEndpoints / 256))

	for i := 0; i <= 256; i++ {
		for j := 0; j <= fourthLimIPAddr; j++ {
			third := strconv.Itoa(i)
			fourth := strconv.Itoa(j)
			addr := initialIP + third + "." + fourth
			addresses = append(addresses, addr)
			if len(addresses) == int(numEndpoints) {
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
