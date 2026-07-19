# Ollama is deployed on a separate host (`aiserver.home:11434`), not in
# this Kubernetes cluster. The Open WebUI deployment is configured to talk
# to it (or to the Bifrost gateway, depending on the active kustomization
# in `clusters/util-server/applications/openwebui/kustomization.yaml`).
#
# If you ever want to move Ollama into the cluster, add a kustomization.yaml
# here based on the `ollama/ollama` image. The relevant env vars are:
#   OLLAMA_KEEP_ALIVE, OLLAMA_MAX_LOADED_MODELS, OLLAMA_NUM_PARALLEL
# Storage: 50Gi PVC at /root/.ollama.
