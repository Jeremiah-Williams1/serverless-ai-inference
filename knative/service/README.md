# knative/service

Actual Knative Service (ksvc) manifests. Separate manifests per target
(minikube vs eks) on purpose — GPU resource requests, image pull specs,
and node selectors genuinely differ; don't collapse these into one
templated file until the differences are well understood.
