package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestParseMemInfo(t *testing.T) {
	input := strings.NewReader(`MemTotal:         883916 kB
MemFree:          120000 kB
MemAvailable:     367424 kB
Buffers:            1000 kB
Cached:             2000 kB
`)

	mem, err := parseMemInfo(input)
	if err != nil {
		t.Fatalf("parseMemInfo returned error: %v", err)
	}

	if mem.TotalMB < 863.19 || mem.TotalMB > 863.21 {
		t.Fatalf("TotalMB = %.2f, want about 863.20", mem.TotalMB)
	}
	if mem.AvailableMB != 358.8125 {
		t.Fatalf("AvailableMB = %.4f, want 358.8125", mem.AvailableMB)
	}
	if mem.UsagePercent < 58.43 || mem.UsagePercent > 58.44 {
		t.Fatalf("UsagePercent = %.4f, want about 58.42", mem.UsagePercent)
	}
}

func TestParseMemInfoFallbackWithoutMemAvailable(t *testing.T) {
	input := strings.NewReader(`MemTotal:         1024000 kB
MemFree:          100000 kB
Buffers:           20000 kB
Cached:           180000 kB
`)

	mem, err := parseMemInfo(input)
	if err != nil {
		t.Fatalf("parseMemInfo returned error: %v", err)
	}

	if mem.AvailableMB != 300000.0/1024.0 {
		t.Fatalf("AvailableMB = %.4f, want %.4f", mem.AvailableMB, 300000.0/1024.0)
	}
	if mem.UsagePercent < 70.70 || mem.UsagePercent > 70.71 {
		t.Fatalf("UsagePercent = %.2f, want about 70.70", mem.UsagePercent)
	}
}

func TestParseMemInfoErrors(t *testing.T) {
	if _, err := parseMemInfo(strings.NewReader("MemTotal: nope kB\n")); err == nil {
		t.Fatalf("expected invalid memory value error")
	}
	if _, err := parseMemInfo(strings.NewReader("MemFree: 1 kB\n")); err == nil {
		t.Fatalf("expected missing MemTotal error")
	}
}

func TestParseCPUStatAndUsage(t *testing.T) {
	first, err := parseCPUStat(strings.NewReader("cpu  100 0 100 800 0 0 0 0 0 0\n"))
	if err != nil {
		t.Fatalf("parseCPUStat first returned error: %v", err)
	}
	second, err := parseCPUStat(strings.NewReader("cpu  150 0 150 900 0 0 0 0 0 0\n"))
	if err != nil {
		t.Fatalf("parseCPUStat second returned error: %v", err)
	}

	usage := cpuUsage(first, second)
	if usage < 50.0 || usage > 50.1 {
		t.Fatalf("cpuUsage = %.2f, want 50.0", usage)
	}
}

func TestParseCPUStatErrors(t *testing.T) {
	if _, err := parseCPUStat(strings.NewReader("intr 1 2 3\n")); err == nil {
		t.Fatalf("expected missing cpu line error")
	}
	if _, err := parseCPUStat(strings.NewReader("cpu  bad 0 0 0\n")); err == nil {
		t.Fatalf("expected invalid cpu value error")
	}
	if usage := cpuUsage(CPUStat{Idle: 1, Total: 1}, CPUStat{Idle: 1, Total: 1}); usage != 0 {
		t.Fatalf("zero delta usage = %.2f, want 0", usage)
	}
}

func TestReadThermalZones(t *testing.T) {
	root := t.TempDir()
	base := filepath.Join(root, "sys", "class", "thermal")
	for _, zone := range []struct {
		name string
		typ  string
		temp string
	}{
		{"thermal_zone0", "tsens_tz_sensor11", "69300"},
		{"thermal_zone1", "tsens_tz_sensor12", "70700"},
	} {
		dir := filepath.Join(base, zone.name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "type"), []byte(zone.typ), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "temp"), []byte(zone.temp), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	zones, err := readThermalZones(base)
	if err != nil {
		t.Fatalf("readThermalZones returned error: %v", err)
	}

	if len(zones) != 2 {
		t.Fatalf("len(zones) = %d, want 2", len(zones))
	}
	if zones[0].Zone != "thermal_zone0" || zones[0].Type != "tsens_tz_sensor11" || zones[0].Celsius != 69.3 {
		t.Fatalf("unexpected first zone: %+v", zones[0])
	}
}

func TestReadThermalZonesSkipsInvalidAndMissingBase(t *testing.T) {
	root := t.TempDir()
	missing := filepath.Join(root, "missing")
	zones, err := readThermalZones(missing)
	if err != nil {
		t.Fatalf("missing thermal base should not error: %v", err)
	}
	if len(zones) != 0 {
		t.Fatalf("missing thermal base zones = %d, want 0", len(zones))
	}

	base := filepath.Join(root, "thermal")
	bad := filepath.Join(base, "thermal_zone0")
	good := filepath.Join(base, "thermal_zone1")
	if err := os.MkdirAll(bad, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bad, "type"), []byte("bad"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bad, "temp"), []byte("not-a-temp"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(good, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(good, "type"), []byte("good"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(good, "temp"), []byte("42000"), 0o644); err != nil {
		t.Fatal(err)
	}
	zones, err = readThermalZones(base)
	if err != nil {
		t.Fatal(err)
	}
	if len(zones) != 1 || zones[0].Type != "good" {
		t.Fatalf("unexpected zones after skipping invalid: %+v", zones)
	}
}

func TestReadThermalZonesFollowsSymlinks(t *testing.T) {
	root := t.TempDir()
	base := filepath.Join(root, "class", "thermal")
	target := filepath.Join(root, "devices", "virtual", "thermal", "thermal_zone0")
	if err := os.MkdirAll(base, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "type"), []byte("tsens_tz_sensor11"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "temp"), []byte("70300"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(base, "thermal_zone0")); err != nil {
		t.Skipf("symlink not available: %v", err)
	}

	zones, err := readThermalZones(base)
	if err != nil {
		t.Fatal(err)
	}
	if len(zones) != 1 || zones[0].Celsius != 70.3 {
		t.Fatalf("unexpected zones through symlink: %+v", zones)
	}
}

func TestCollectOnce(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	thermal := filepath.Join(root, "sys", "class", "thermal")
	if err := os.MkdirAll(proc, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "stat"), []byte("cpu  100 0 100 800 0 0 0 0 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "meminfo"), []byte("MemTotal: 1024000 kB\nMemAvailable: 512000 kB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	zone := filepath.Join(thermal, "thermal_zone0")
	if err := os.MkdirAll(zone, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zone, "type"), []byte("cpu-thermal"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zone, "temp"), []byte("55000"), 0o644); err != nil {
		t.Fatal(err)
	}

	go func() {
		time.Sleep(10 * time.Millisecond)
		_ = os.WriteFile(filepath.Join(proc, "stat"), []byte("cpu  150 0 150 900 0 0 0 0 0 0\n"), 0o644)
	}()

	snapshot := collectOnce(proc, thermal, 20*time.Millisecond)
	if snapshot.Error != "" {
		t.Fatalf("snapshot error = %q", snapshot.Error)
	}
	if snapshot.CPU.UsagePercent < 50.0 || snapshot.CPU.UsagePercent > 50.1 {
		t.Fatalf("cpu usage = %.2f, want 50.0", snapshot.CPU.UsagePercent)
	}
	if snapshot.Memory.UsagePercent != 50 {
		t.Fatalf("memory usage = %.2f, want 50.0", snapshot.Memory.UsagePercent)
	}
	if len(snapshot.Temperatures) != 1 || snapshot.Temperatures[0].Celsius != 55 {
		t.Fatalf("unexpected temperatures: %+v", snapshot.Temperatures)
	}
}

func TestCollectOnceReportsErrors(t *testing.T) {
	snapshot := collectOnce(filepath.Join(t.TempDir(), "proc"), filepath.Join(t.TempDir(), "thermal"), 0)
	if !strings.Contains(snapshot.Error, "read cpu") {
		t.Fatalf("expected cpu error, got %+v", snapshot)
	}
}

func TestCollectOnceWithPreviousCPU(t *testing.T) {
	root := t.TempDir()
	proc := filepath.Join(root, "proc")
	thermal := filepath.Join(root, "thermal")
	if err := os.MkdirAll(proc, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "stat"), []byte("cpu  150 0 150 900 0 0 0 0 0 0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proc, "meminfo"), []byte("MemTotal: 1024000 kB\nMemAvailable: 512000 kB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	zone := filepath.Join(thermal, "thermal_zone0")
	if err := os.MkdirAll(zone, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zone, "type"), []byte("cpu-thermal"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(zone, "temp"), []byte("57000"), 0o644); err != nil {
		t.Fatal(err)
	}

	snapshot, current := collectOnceWithPreviousCPU(proc, thermal, CPUStat{Idle: 800, Total: 1000})
	if snapshot.Error != "" {
		t.Fatalf("snapshot error = %q", snapshot.Error)
	}
	if snapshot.CPU.UsagePercent != 50 || snapshot.Memory.UsagePercent != 50 {
		t.Fatalf("unexpected utilization: %+v", snapshot)
	}
	if len(snapshot.Temperatures) != 1 || snapshot.Temperatures[0].Celsius != 57 {
		t.Fatalf("unexpected temperatures: %+v", snapshot.Temperatures)
	}
	if current.Total != 1200 || current.Idle != 900 {
		t.Fatalf("current CPU stat = %+v", current)
	}
}

func TestCollectOnceWithPreviousCPUReportsReadError(t *testing.T) {
	previous := CPUStat{Idle: 8, Total: 10}
	snapshot, current := collectOnceWithPreviousCPU(filepath.Join(t.TempDir(), "missing"), t.TempDir(), previous)
	if !strings.Contains(snapshot.Error, "read cpu") {
		t.Fatalf("expected CPU error, got %+v", snapshot)
	}
	if current != previous {
		t.Fatalf("current CPU stat = %+v, want %+v", current, previous)
	}
}

func TestStoreAndWriteJSON(t *testing.T) {
	store := &Store{}
	store.Set(Snapshot{Time: 123, CPU: CPUInfo{UsagePercent: 12.5}})
	if got := store.Get(); got.Time != 123 || got.CPU.UsagePercent != 12.5 {
		t.Fatalf("store returned unexpected snapshot: %+v", got)
	}

	rec := httptest.NewRecorder()
	writeJSON(rec, store.Get())
	if rec.Code != 200 {
		t.Fatalf("status = %d, want 200", rec.Code)
	}
	if rec.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("missing CORS header")
	}
	var decoded Snapshot
	if err := json.Unmarshal(rec.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Time != 123 {
		t.Fatalf("decoded time = %d, want 123", decoded.Time)
	}
}

func TestMuxEndpoints(t *testing.T) {
	store := &Store{}
	store.Set(Snapshot{Time: 456, Memory: MemoryInfo{UsagePercent: 42}})
	mux := newMux(store)

	health := httptest.NewRecorder()
	mux.ServeHTTP(health, httptest.NewRequest(http.MethodGet, "/health", nil))
	if health.Code != 200 || !strings.Contains(health.Body.String(), `"ok"`) {
		t.Fatalf("unexpected health response: %d %s", health.Code, health.Body.String())
	}

	metrics := httptest.NewRecorder()
	mux.ServeHTTP(metrics, httptest.NewRequest(http.MethodGet, "/metrics.json", nil))
	var decoded Snapshot
	if err := json.Unmarshal(metrics.Body.Bytes(), &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded.Time != 456 || decoded.Memory.UsagePercent != 42 {
		t.Fatalf("unexpected metrics response: %+v", decoded)
	}

	options := httptest.NewRecorder()
	mux.ServeHTTP(options, httptest.NewRequest(http.MethodOptions, "/metrics.json", nil))
	if options.Header().Get("Access-Control-Allow-Origin") != "*" {
		t.Fatalf("missing CORS header on OPTIONS")
	}

	root := httptest.NewRecorder()
	mux.ServeHTTP(root, httptest.NewRequest(http.MethodGet, "/", nil))
	if root.Code != http.StatusOK || !strings.Contains(root.Body.String(), "小米BE6500 Pro性能监控") {
		t.Fatalf("unexpected root response: %q", root.Body.String())
	}

	echarts := httptest.NewRecorder()
	mux.ServeHTTP(echarts, httptest.NewRequest(http.MethodGet, "/echarts.min.js", nil))
	if echarts.Code != http.StatusOK || !strings.Contains(echarts.Body.String(), "Apache License") {
		t.Fatalf("unexpected echarts response: %d", echarts.Code)
	}
}
