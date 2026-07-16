package main

import (
	"bufio"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

//go:embed web/index.html web/echarts.min.js
var webAssets embed.FS

type CPUStat struct {
	Idle  uint64
	Total uint64
}

type CPUInfo struct {
	UsagePercent float64 `json:"usage_percent"`
}

type MemoryInfo struct {
	TotalMB      float64 `json:"total_mb"`
	UsedMB       float64 `json:"used_mb"`
	AvailableMB  float64 `json:"available_mb"`
	UsagePercent float64 `json:"usage_percent"`
}

type ThermalZone struct {
	Zone    string  `json:"zone"`
	Type    string  `json:"type"`
	Celsius float64 `json:"celsius"`
}

type Snapshot struct {
	Time                   int64         `json:"time"`
	RefreshIntervalSeconds int64         `json:"refresh_interval_seconds"`
	CPU                    CPUInfo       `json:"cpu"`
	Memory                 MemoryInfo    `json:"memory"`
	Temperatures           []ThermalZone `json:"temperatures"`
	Error                  string        `json:"error,omitempty"`
}

type Store struct {
	mu       sync.RWMutex
	snapshot Snapshot
}

func (s *Store) Set(snapshot Snapshot) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.snapshot = snapshot
}

func (s *Store) Get() Snapshot {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.snapshot
}

func parseCPUStat(r io.Reader) (CPUStat, error) {
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 || fields[0] != "cpu" {
			continue
		}
		var stat CPUStat
		for i := 1; i < len(fields); i++ {
			value, err := strconv.ParseUint(fields[i], 10, 64)
			if err != nil {
				return CPUStat{}, err
			}
			stat.Total += value
			if i == 4 || i == 5 {
				stat.Idle += value
			}
		}
		return stat, nil
	}
	if err := scanner.Err(); err != nil {
		return CPUStat{}, err
	}
	return CPUStat{}, errors.New("cpu line not found")
}

func cpuUsage(first, second CPUStat) float64 {
	totalDelta := second.Total - first.Total
	if totalDelta == 0 {
		return 0
	}
	idleDelta := second.Idle - first.Idle
	return (1 - float64(idleDelta)/float64(totalDelta)) * 100
}

func readCPUStat(path string) (CPUStat, error) {
	f, err := os.Open(path)
	if err != nil {
		return CPUStat{}, err
	}
	defer f.Close()
	return parseCPUStat(f)
}

func parseMemInfo(r io.Reader) (MemoryInfo, error) {
	values := map[string]float64{}
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 2 {
			continue
		}
		key := strings.TrimSuffix(fields[0], ":")
		value, err := strconv.ParseFloat(fields[1], 64)
		if err != nil {
			return MemoryInfo{}, err
		}
		values[key] = value
	}
	if err := scanner.Err(); err != nil {
		return MemoryInfo{}, err
	}

	total := values["MemTotal"]
	if total <= 0 {
		return MemoryInfo{}, errors.New("MemTotal not found")
	}
	available := values["MemAvailable"]
	if available <= 0 {
		available = values["MemFree"] + values["Buffers"] + values["Cached"]
	}
	used := total - available
	if used < 0 {
		used = 0
	}

	return MemoryInfo{
		TotalMB:      total / 1024,
		UsedMB:       used / 1024,
		AvailableMB:  available / 1024,
		UsagePercent: used / total * 100,
	}, nil
}

func readMemInfo(path string) (MemoryInfo, error) {
	f, err := os.Open(path)
	if err != nil {
		return MemoryInfo{}, err
	}
	defer f.Close()
	return parseMemInfo(f)
}

func readThermalZones(base string) ([]ThermalZone, error) {
	entries, err := os.ReadDir(base)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}

	var zones []ThermalZone
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), "thermal_zone") {
			continue
		}
		dir := filepath.Join(base, entry.Name())
		info, err := os.Stat(dir)
		if err != nil || !info.IsDir() {
			continue
		}
		typeBytes, err := os.ReadFile(filepath.Join(dir, "type"))
		if err != nil {
			continue
		}
		tempBytes, err := os.ReadFile(filepath.Join(dir, "temp"))
		if err != nil {
			continue
		}
		rawTemp, err := strconv.ParseFloat(strings.TrimSpace(string(tempBytes)), 64)
		if err != nil {
			continue
		}
		zones = append(zones, ThermalZone{
			Zone:    entry.Name(),
			Type:    strings.TrimSpace(string(typeBytes)),
			Celsius: rawTemp / 1000,
		})
	}

	sort.Slice(zones, func(i, j int) bool {
		return zones[i].Zone < zones[j].Zone
	})
	return zones, nil
}

func collectOnce(procRoot, thermalRoot string, cpuDelay time.Duration) Snapshot {
	snapshot := Snapshot{Time: time.Now().Unix()}

	first, err := readCPUStat(filepath.Join(procRoot, "stat"))
	if err != nil {
		snapshot.Error = fmt.Sprintf("read cpu: %v", err)
		return snapshot
	}
	time.Sleep(cpuDelay)
	second, err := readCPUStat(filepath.Join(procRoot, "stat"))
	if err != nil {
		snapshot.Error = fmt.Sprintf("read cpu: %v", err)
		return snapshot
	}
	snapshot.CPU = CPUInfo{UsagePercent: cpuUsage(first, second)}

	mem, err := readMemInfo(filepath.Join(procRoot, "meminfo"))
	if err != nil {
		snapshot.Error = fmt.Sprintf("read memory: %v", err)
		return snapshot
	}
	snapshot.Memory = mem

	zones, err := readThermalZones(thermalRoot)
	if err != nil {
		snapshot.Error = fmt.Sprintf("read thermal: %v", err)
		return snapshot
	}
	snapshot.Temperatures = zones
	return snapshot
}

func collectOnceWithPreviousCPU(procRoot, thermalRoot string, previousCPU CPUStat) (Snapshot, CPUStat) {
	snapshot := Snapshot{Time: time.Now().Unix()}

	currentCPU, err := readCPUStat(filepath.Join(procRoot, "stat"))
	if err != nil {
		snapshot.Error = fmt.Sprintf("read cpu: %v", err)
		return snapshot, previousCPU
	}
	if previousCPU.Total > 0 && currentCPU.Total >= previousCPU.Total && currentCPU.Idle >= previousCPU.Idle {
		snapshot.CPU = CPUInfo{UsagePercent: cpuUsage(previousCPU, currentCPU)}
	}

	mem, err := readMemInfo(filepath.Join(procRoot, "meminfo"))
	if err != nil {
		snapshot.Error = fmt.Sprintf("read memory: %v", err)
		return snapshot, currentCPU
	}
	snapshot.Memory = mem

	zones, err := readThermalZones(thermalRoot)
	if err != nil {
		snapshot.Error = fmt.Sprintf("read thermal: %v", err)
		return snapshot, currentCPU
	}
	snapshot.Temperatures = zones
	return snapshot, currentCPU
}

func writeJSON(w http.ResponseWriter, value any) {
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
	w.Header().Set("Access-Control-Allow-Private-Network", "true")
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(value)
}

func newMux(store *Store) *http.ServeMux {
	indexContent, indexErr := webAssets.ReadFile("web/index.html")
	echartsContent, echartsErr := webAssets.ReadFile("web/echarts.min.js")
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		if indexErr != nil {
			http.Error(w, "index.html not found", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(indexContent)
	})
	mux.HandleFunc("/echarts.min.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Content-Type", "text/javascript; charset=utf-8")
		w.Header().Set("Cache-Control", "public, max-age=604800")
		if echartsErr != nil {
			http.Error(w, "echarts.min.js not found", http.StatusInternalServerError)
			return
		}
		_, _ = w.Write(echartsContent)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/metrics.json", func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			writeJSON(w, map[string]string{"status": "ok"})
			return
		}
		writeJSON(w, store.Get())
	})
	return mux
}
