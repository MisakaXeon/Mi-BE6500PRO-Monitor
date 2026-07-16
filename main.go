//go:build !unit

package main

import (
	"flag"
	"fmt"
	"log"
	"os"
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
	logPath := flag.String("log", "", "append logs to this file")
	showVersion := flag.Bool("version", false, "print version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println(version)
		return
	}

	if *logPath != "" {
		logFile, err := os.OpenFile(*logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			log.Fatalf("open log file: %v", err)
		}
		defer logFile.Close()
		log.SetOutput(logFile)
	}

	store := &Store{}
	store.Set(Snapshot{Time: time.Now().Unix(), RefreshIntervalSeconds: int64(interval.Seconds()), Error: "initializing"})
	go startCollector(store, *interval, *procRoot, *thermalRoot)

	log.Printf("router-monitor listening on %s, interval=%s", *listen, interval.String())
	server := newHTTPServer(*listen, newMux(store))
	log.Fatal(listenAndServe(server))
}
