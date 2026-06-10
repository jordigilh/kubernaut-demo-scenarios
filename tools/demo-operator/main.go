// demo-operator: a minimal controller-runtime operator with a
// deliberately unfiltered ConfigMap cache.
//
// This reproduces the vulnerability documented in kubeflow/spark-operator#2878
// and the Red Hat Developer blog post "Protect your Kubernetes Operator from
// OOMKill". The Pod informer is correctly filtered by label, but the ConfigMap
// informer caches ALL ConfigMaps cluster-wide. Flooding the namespace with
// large ConfigMaps causes the informer to exceed the pod's memory limit,
// triggering an OOMKill and CrashLoopBackOff.
//
// Reference: https://developers.redhat.com/articles/2026/06/01/protect-your-kubernetes-operator-oomkill
package main

import (
	"context"
	"os"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"
	"sigs.k8s.io/controller-runtime/pkg/reconcile"
)

var scheme = runtime.NewScheme()

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
}

// Reconciler is a no-op reconciler. The vulnerability is in the cache
// configuration, not in the reconciliation logic.
type Reconciler struct {
	client.Client
}

func (r *Reconciler) Reconcile(_ context.Context, _ reconcile.Request) (reconcile.Result, error) {
	return reconcile.Result{}, nil
}

// configCache is a global slice that holds ConfigMap data to prevent GC.
// This reproduces the real-world pattern where operators cache ConfigMap
// contents in memory for cross-referencing (e.g. Spark operator, Flux).
var configCache []map[string]string

func main() {
	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	log := ctrl.Log.WithName("demo-operator")

	watchNamespace := os.Getenv("WATCH_NAMESPACE")

	cacheOpts := cache.Options{
		ByObject: map[client.Object]cache.ByObject{
			&corev1.Pod{}: {
				Label: labels.SelectorFromSet(labels.Set{
					"app.kubernetes.io/managed-by": "demo-operator",
				}),
			},
			&corev1.ConfigMap{}: {}, // <-- THE VULNERABILITY: caches ALL ConfigMaps
		},
	}
	if watchNamespace != "" {
		cacheOpts.DefaultNamespaces = map[string]cache.Config{
			watchNamespace: {},
		}
	}

	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		Cache:                  cacheOpts,
		LeaderElection:         false,
		HealthProbeBindAddress: ":8081",
	})
	if err != nil {
		log.Error(err, "unable to create manager")
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up health check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		log.Error(err, "unable to set up ready check")
		os.Exit(1)
	}

	if err := ctrl.NewControllerManagedBy(mgr).
		For(&corev1.Pod{}).
		Complete(&Reconciler{Client: mgr.GetClient()}); err != nil {
		log.Error(err, "unable to create controller")
		os.Exit(1)
	}

	// Load all ConfigMaps into an in-memory cache on startup.
	// This is the vulnerable pattern: operators that list and cache all
	// ConfigMaps without filtering expose themselves to OOMKill when an
	// attacker floods the namespace with large ConfigMaps.
	ctx := ctrl.SetupSignalHandler()

	go func() {
		if !mgr.GetCache().WaitForCacheSync(ctx) {
			log.Error(nil, "cache sync failed")
			return
		}
		var cmList corev1.ConfigMapList
		if err := mgr.GetClient().List(ctx, &cmList); err != nil {
			log.Error(err, "failed to list ConfigMaps")
			return
		}
		for i := range cmList.Items {
			configCache = append(configCache, cmList.Items[i].Data)
		}
		totalBytes := 0
		for _, data := range configCache {
			for _, v := range data {
				totalBytes += len(v)
			}
		}
		log.Info("loaded ConfigMaps into in-memory cache",
			"count", len(configCache),
			"totalDataBytes", totalBytes)
	}()

	log.Info("starting demo-operator",
		"watchNamespace", watchNamespace)
	if err := mgr.Start(ctx); err != nil {
		log.Error(err, "manager exited with error")
		os.Exit(1)
	}
}
