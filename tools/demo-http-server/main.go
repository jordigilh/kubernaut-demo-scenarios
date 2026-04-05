package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"gopkg.in/yaml.v3"
)

var (
	httpRequestsTotal = prometheus.NewCounterVec(
		prometheus.CounterOpts{
			Name: "http_requests_total",
			Help: "Total number of HTTP requests by status code.",
		},
		[]string{"code", "method", "path"},
	)
	httpRequestDuration = prometheus.NewHistogramVec(
		prometheus.HistogramOpts{
			Name:    "http_request_duration_seconds",
			Help:    "HTTP request latency in seconds.",
			Buckets: prometheus.DefBuckets,
		},
		[]string{"code", "method", "path"},
	)
)

func init() {
	prometheus.MustRegister(httpRequestsTotal)
	prometheus.MustRegister(httpRequestDuration)
}

type RouteConfig struct {
	Path   string `yaml:"path"`
	Status int    `yaml:"status"`
	Body   string `yaml:"body"`
}

type Config struct {
	Port   int           `yaml:"port"`
	Routes []RouteConfig `yaml:"routes"`
}

func loadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("reading config: %w", err)
	}

	content := string(data)

	if strings.Contains(content, "invalid_directive") {
		fmt.Fprintf(os.Stderr, "[emerg] invalid directive found in %s — aborting\n", path)
		os.Exit(1)
	}

	var cfg Config
	if err := yaml.Unmarshal(data, &cfg); err != nil {
		fmt.Fprintf(os.Stderr, "[emerg] failed to parse config %s: %v — aborting\n", path, err)
		os.Exit(1)
	}
	return &cfg, nil
}

func instrumentedHandler(path string, status int, body string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		code := status
		w.WriteHeader(code)
		fmt.Fprint(w, body)
		duration := time.Since(start).Seconds()
		codeStr := fmt.Sprintf("%d", code)
		httpRequestsTotal.WithLabelValues(codeStr, r.Method, path).Inc()
		httpRequestDuration.WithLabelValues(codeStr, r.Method, path).Observe(duration)
	}
}

// catchAllHandler records metrics for any path not matched by explicit routes.
func catchAllHandler(defaultStatus int, defaultBody string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/metrics" {
			promhttp.Handler().ServeHTTP(w, r)
			return
		}
		start := time.Now()
		code := defaultStatus
		w.WriteHeader(code)
		fmt.Fprint(w, defaultBody)
		duration := time.Since(start).Seconds()
		codeStr := fmt.Sprintf("%d", code)
		httpRequestsTotal.WithLabelValues(codeStr, r.Method, r.URL.Path).Inc()
		httpRequestDuration.WithLabelValues(codeStr, r.Method, r.URL.Path).Observe(duration)
	}
}

func main() {
	listenPort := envOrDefault("LISTEN_PORT", "8080")
	configPath := envOrDefault("CONFIG_PATH", "/etc/demo-http-server/config.yaml")
	tlsCertDir := os.Getenv("TLS_CERT_DIR")

	cfg, err := loadConfig(configPath)
	if err != nil {
		log.Fatalf("config error: %v", err)
	}

	if cfg != nil && cfg.Port > 0 {
		listenPort = fmt.Sprintf("%d", cfg.Port)
	}

	mux := http.NewServeMux()

	hasRoot := false
	hasHealthz := false

	if cfg != nil {
		for _, route := range cfg.Routes {
			body := route.Body
			if body == "" {
				body = http.StatusText(route.Status)
			}
			mux.HandleFunc(route.Path, instrumentedHandler(route.Path, route.Status, body))
			if route.Path == "/" {
				hasRoot = true
			}
			if route.Path == "/healthz" {
				hasHealthz = true
			}
		}
	}

	if !hasRoot {
		mux.HandleFunc("/", catchAllHandler(http.StatusOK, `{"status":"ok"}`))
	}
	if !hasHealthz {
		mux.HandleFunc("/healthz", instrumentedHandler("/healthz", http.StatusOK, "ok"))
	}
	mux.Handle("/metrics", promhttp.Handler())

	addr := ":" + listenPort
	log.Printf("demo-http-server starting on %s (config=%s, tls=%v)", addr, configPath, tlsCertDir != "")

	if tlsCertDir != "" {
		certFile := tlsCertDir + "/tls.crt"
		keyFile := tlsCertDir + "/tls.key"
		if _, err := tls.LoadX509KeyPair(certFile, keyFile); err != nil {
			log.Printf("TLS cert not yet available (%v), serving plain HTTP until cert appears", err)
			servePlainUntilTLS(mux, addr, certFile, keyFile)
			return
		}
		log.Printf("TLS enabled, serving HTTPS on %s", addr)
		log.Fatal(http.ListenAndServeTLS(addr, certFile, keyFile, mux))
	} else {
		log.Fatal(http.ListenAndServe(addr, mux))
	}
}

// servePlainUntilTLS serves HTTP and polls for the TLS cert to appear,
// then switches to HTTPS. This handles the cert-failure scenario where
// the secret may not exist at pod startup.
func servePlainUntilTLS(mux *http.ServeMux, addr, certFile, keyFile string) {
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for range ticker.C {
			if _, err := tls.LoadX509KeyPair(certFile, keyFile); err == nil {
				log.Printf("TLS cert now available, but already serving plain HTTP — restart required for HTTPS")
				return
			}
		}
	}()
	log.Fatal(http.ListenAndServe(addr, mux))
}

func envOrDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
