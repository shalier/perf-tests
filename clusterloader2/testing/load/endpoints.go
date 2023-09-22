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

	endpointAddrs := generateEndpointIPs()
	endpointMap := make(map[string]int)
	for _, addr := range endpointAddrs {
		endpointMap[addr] = 0
	}

	err = createEndpoints(clientset, namespaceName, port80, endpointAddrs)
	if err != nil {
		fmt.Println("failed to make endpoints", err)
	}
	var tickerTime time.Duration = 500    // ms
	var testDuration time.Duration = 1500 // ms
	ticker := time.NewTicker(tickerTime * time.Millisecond)
	done := make(chan bool)
	// percentChurnTotal includes the churn down and churn up
	percentChurnTotal, err := strconv.Atoi(os.Args[2])
	if err != nil {
		fmt.Println("percentage must be an int", err)
		panic(err)
	}

	// stepsPerChurnType is steps per churn up and steps per churn down
	stepsPerChurnType := testDuration / (tickerTime * 2) // ex. 10 stepsPerChurnType for down and 10 for up
	intSteps := int(stepsPerChurnType)
	ogEndpointCount := len(endpointAddrs)
	// if 10% churn = 100 then 50 down 50 up per second
	// should divide by 2 ^^^
	// totalChurnEndpoints would be 50 if 10% churn = 100
	totalChurnEndpoints := percentChurnTotal * ogEndpointCount / (100 * 2)
	// for each tick remove numChangePerTick for each stepsPerChurnType
	// so following the example of 10% churn = 100, then will need to churn down 50 and churn up 50
	// so for each step churn 50/stepsPerChurnType (if there's 10 steps then churn down 5 each tick)
	numChangePerTick := totalChurnEndpoints / intSteps
	rmTarget := ogEndpointCount - totalChurnEndpoints

	// fmt.Println("ogEndpointCount", ogEndpointCount, "numChangePerTick", numChangePerTick, "steps", intSteps, "target", rmTarget)

	operations := 0
	rmStep := 0
	addStep := 0
	endpointAddrsSlice := []*[]core.EndpointAddress{}
	endpointList, err := clientset.CoreV1().Endpoints(namespaceName).List(context.Background(), metav1.ListOptions{})
	if err != nil {
		fmt.Println("couldn't list endpoint obj", err)
	}
	endpointObj := endpointList.Items[0]
	// get the created endpoint object Addresses field
	endpointAddrsCreated := endpointObj.Subsets[0].Addresses
	// generate new endpoint maps before updating
	for addStep < intSteps {
		if rmStep < intSteps && len(endpointMap) > rmTarget {
			rmStep++
			// fmt.Print("removing endpoints")
			randomRemoveEndpointAddrs(&endpointAddrsCreated, endpointMap, numChangePerTick, &endpointAddrsSlice)
		} else {
			addStep++
			// fmt.Print("creating endpoints")
			addEndpointAddrs(endpointMap, numChangePerTick, &endpointAddrsSlice)
		}
	}

	i := 0
	go func() {
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				// fmt.Println(t)
				endpointObj, _ := clientset.CoreV1().Endpoints(namespaceName).Get(context.Background(), svcName, metav1.GetOptions{})
				if err != nil {
					fmt.Println("couldn't get endpoint obj", err)
				}
				newAddrs := endpointAddrsSlice[i]
				// fmt.Println(len(*newAddrs))
				endpointObj.Subsets[0].Addresses = *newAddrs
				_, err = clientset.CoreV1().Endpoints(namespaceName).Update(context.Background(), endpointObj, metav1.UpdateOptions{})
				if err != nil {
					panic(err)
				}
				operations++
				i++
			}
		}
	}()

	time.Sleep(testDuration * time.Millisecond)
	ticker.Stop()
	done <- true
	fmt.Printf("%vop", strconv.Itoa(operations))
}

// endpoints to add back should be different from endpoints that were already in the []EndpointAddress
// generate random numbers from the ceiling found in generateEndpointIPs to 256
func addEndpointAddrs(endpointMap map[string]int, numAdd int, endpointAddrsSlice *[]*[]core.EndpointAddress) {
	rand.New(rand.NewSource(time.Now().UnixNano()))
	thirdRange := rand.Perm(256)
	fourthRange := rand.Perm(256)
	// fmt.Print("numAdd", numAdd)
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
	updatedAddrs := convertEndpointMapToAddrs(endpointMap)
	*endpointAddrsSlice = append(*endpointAddrsSlice, updatedAddrs)
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

func randomRemoveEndpointAddrs(addrs *[]core.EndpointAddress, endpointMap map[string]int, numRm int, endpointAddrsSlice *[]*[]core.EndpointAddress) {
	rand.New(rand.NewSource(time.Now().UnixNano()))
	p := rand.Perm(len(*addrs))
	// fmt.Print("Deleting", numRm)
	for _, index := range p {
		if numRm <= 0 {
			break
		}
		delete(endpointMap, (*addrs)[index].IP)
		numRm--
	}
	// Can't have empty endpoint
	if len(endpointMap) == 0 {
		endpointMap["1.1.1.1"] = 0
	}
	updatedAddrs := convertEndpointMapToAddrs(endpointMap)
	*endpointAddrsSlice = append(*endpointAddrsSlice, updatedAddrs)
}

func convertEndpointMapToAddrs(endpointMap map[string]int) *[]core.EndpointAddress {
	newAddrs := make([]core.EndpointAddress, len(endpointMap))
	i := 0
	for k := range endpointMap {
		newAddrs[i] = core.EndpointAddress{
			IP: k,
		}
		i++
	}
	return &newAddrs
}

// Specifies the endpoints for the test service
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
