//go:build !unit

package main

import (
	"flag"
	"log"
	"net/http"
	"time"
)

func startCollector(store *Store, interval time.Duration, procRoot, thermalRoot string) {
	var previousCPU CPUStat
	for {
		snapshot, nextCPU := collectOnceWithPreviousCPU(procRoot, thermalRoot, previousCPU)
		snapshot.RefreshIntervalSeconds = int64(interval.Seconds())
		store.Set(snapshot)
		previousCPU = nextCPU
		time.Sleep(interval)
	}
}

func main() {
	listen := flag.String("listen", "0.0.0.0:9898", "HTTP listen address")
	interval := flag.Duration("interval", 10*time.Second, "metrics refresh interval")
	procRoot := flag.String("proc", "/proc", "procfs root")
	thermalRoot := flag.String("thermal", "/sys/class/thermal", "thermal sysfs root")
	flag.Parse()

	store := &Store{}
	store.Set(Snapshot{Time: time.Now().Unix(), RefreshIntervalSeconds: int64(interval.Seconds()), Error: "initializing"})
	go startCollector(store, *interval, *procRoot, *thermalRoot)

	log.Printf("router-monitor listening on %s, interval=%s", *listen, interval.String())
	log.Fatal(http.ListenAndServe(*listen, newMux(store)))
}
