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
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/intstr"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/util/homedir"
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
				Labels:    map[string]string{"istio.io/rev": "asm-1-17"},
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
		fmt.Println("failed to make service", err)
	}

	endpointAddrs := generateEndpointIPs()
	endpointMap := make(map[string]int)
	for _, addr := range endpointAddrs {
		endpointMap[addr] = 0
	}
	// fmt.Println("starting length", len(endpointAddrs))

	err = createEndpoints(clientset, namespaceName, port80, endpointAddrs)
	if err != nil {
		fmt.Println("failed to make endpoints", err)
	}
	var tickerTime time.Duration = 500
	var testDuration time.Duration = 30 // testDuration s
	ticker := time.NewTicker(tickerTime * time.Millisecond)
	done := make(chan bool)
	percentage, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Println("percentage must be an int", err)
		panic(err)
	}
	// now there's a wait time of tickerTime between updates so the num changes needs to be higher
	// half percentage churn down and half percentage churn up
	// if 10% churn = 100 then 50 down 50 up per second
	stepsPerSecond := testDuration / (tickerTime * 2 / 1000)
	stages := int(stepsPerSecond)
	numChangePerTickerTime := percentage * len(endpointAddrs) / (100 * 2 * stages)
	// fmt.Println("numChangePerTickerTime", numChangePerTickerTime, "stages", stages)
	operations := 0
	stage := 0
	go func() {
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				endpointList, err := clientset.CoreV1().Endpoints(namespaceName).List(context.Background(), metav1.ListOptions{})
				if err != nil {
					fmt.Println("couldn't list endpoint obj", err)
				}
				endpointObj := endpointList.Items[0]
				endpointAddrs := endpointObj.Subsets[0].Addresses
				// fmt.Println("after creating length:", len(endpointAddrs))

				if stage < stages {
					stage++
					// fmt.Println("removing endpoints")
					randomRemoveEndpointAddrs(&endpointAddrs, endpointMap, numChangePerTickerTime)
				} else {
					// fmt.Println("creating endpoints")
					addEndpointAddrs(endpointMap, numChangePerTickerTime)
				}
				// fmt.Println("length:", len(endpointMap))
				newAddrs := []core.EndpointAddress{}
				for k := range endpointMap {
					newAddrs = append(newAddrs, core.EndpointAddress{
						IP: k,
					})
				}
				endpointObj.Subsets[0].Addresses = newAddrs
				// fmt.Println("updating endpoints")
				_, err = clientset.CoreV1().Endpoints(namespaceName).Update(context.Background(), &endpointObj, metav1.UpdateOptions{})
				if err != nil {
					fmt.Println("failed to update endpoints", err)
					panic(err)
				}
				operations++
			}
		}
	}()

	time.Sleep(testDuration * time.Second)
	ticker.Stop()
	done <- true
	fmt.Printf("%vop", strconv.Itoa(operations))
}

// endpoints to add back should be different from endpoints that were already in the []EndpointAddress
// generate random numbers from the ceiling found in generateEndpointIPs to 256
func addEndpointAddrs(endpointMap map[string]int, numAdd int) {
	rand.New(rand.NewSource(time.Now().UnixNano()))
	thirdRange := rand.Perm(256)
	fourthRange := rand.Perm(256)
	// fmt.Println("Adding")
	// fmt.Println("numAdd", numAdd)
outer:
	for _, t := range thirdRange {
		for _, f := range fourthRange {
			if numAdd <= 0 {
				break outer
			}
			third := strconv.Itoa(t)
			fourth := strconv.Itoa(f)
			newIP := initialIP + third + "." + fourth
			_, ok := endpointMap[newIP]
			if !ok {
				endpointMap[newIP] = 0
				numAdd--
			}
		}
	}
}

// generate endpoints 10.244.[0-256].[0-<needToCalculate>]
// fourth IP section is from the range 0 to needToCalculate
// needToCalcualte is found by ceil(numEndpoints being tested / 256)
func generateEndpointIPs() []string {
	addresses := []string{}
	numEndpoints, _ := strconv.ParseFloat(numEndpointsToTest, 64)
	fourthLimIPAddr := int(math.Ceil(numEndpoints / 256))

	for t := 0; t < 256; t++ {
		for f := 0; f <= fourthLimIPAddr; f++ {
			third := strconv.Itoa(t)
			fourth := strconv.Itoa(f)
			addr := initialIP + third + "." + fourth
			addresses = append(addresses, addr)
			if len(addresses) == int(numEndpoints) {
				return addresses
			}
		}
	}
	return nil
}

func randomRemoveEndpointAddrs(addrs *[]core.EndpointAddress, endpointMap map[string]int, numRm int) {
	rand.New(rand.NewSource(time.Now().UnixNano()))
	p := rand.Perm(len(*addrs))
	// fmt.Print("Deleting")
	for _, index := range p {
		if numRm <= 0 {
			break
		}
		// fmt.Print((*addrs)[index].IP, " ")
		delete(endpointMap, (*addrs)[index].IP)
		numRm--
	}
	if len(endpointMap) == 0 {
		endpointMap["1.1.1.1"] = 0
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

/*
Create service spec

[chose to just use endpoints] create endpoint slices --max-endpoints-per-slice 1000 (default 100, max 1000)
create endpoints
Burst Load Test

Endpoint Discovery Service (EDS) Update Test
–  One service with 5000 endpoints
–  Randomly churn one endpoint object at various rates
-- Randomly get 10% endpoints, delete and re-create per second
-- 20%
-- 50%
*/
