#!/usr/bin/env bash
# Install OpenShift Pipelines on the current cluster

set -o errexit
set -o nounset
set -o pipefail

readonly export DEPLOYMENT_TIMEOUT="${DEPLOYMENT_TIMEOUT:-5m}"

function fail() {
    echo "ERROR: ${*}" >&2
    exit 1
}

function rollout_status() {
    local namespace="${1}"
    local deployment="${2}"

    if ! kubectl --namespace="${namespace}" --timeout=${DEPLOYMENT_TIMEOUT} \
         rollout status deployment "${deployment}"; then
        fail "'${namespace}/${deployment}' is not deployed as expected!"
    fi
}

function install_channel() {
    local channel="${1}"
    echo "Installing OpenShift Pipelines from channel ${channel}"
    echo "testing pr https://github.com/openshift/release/pull/57510"
    cat <<EOF | oc apply -f-
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator-rh
  namespace: openshift-operators
spec:
  channel: ${channel}
  name: openshift-pipelines-operator-rh
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
}

function install_nightly() {
    oc patch operatorhub.config.openshift.io/cluster -p='{"spec":{"disableAllDefaultSources":true}}' --type=merge
    sleep 2
    # Add a custom catalog-source
    cat <<EOF | oc apply -f-
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:                      
  name: custom-osp-nightly
  namespace: openshift-marketplace         
spec:                                                                                                                                                                                                                                                
  sourceType: grpc
  # image: quay.io/openshift-pipeline/openshift-pipelines-operator-index:5.0
  image: quay.io/openshift-pipeline/openshift-pipelines-pipelines-operator-bundle-container-index:v4.14-candidate
  displayName: "Custom OSP Nightly"
  updateStrategy:
    registryPoll:
      interval: 30m                                                                                                                                                                                                                                  
EOF
    sleep 10
    # Create the "correct" subscription
    oc delete subscription pipelines -n openshift-operators || true
    cat <<EOF | oc apply -f-
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-pipelines-operator
  namespace: openshift-operators
spec:
  channel: latest
  name: openshift-pipelines-operator-rh
  source: custom-osp-nightly
  sourceNamespace: openshift-marketplace
EOF
}

OSP_VERSION=${1:-latest}
shift

case "$OSP_VERSION" in
    nightly)
	install_nightly
	;;
    latest)
	install_channel latest
	;;
    *)
	install_channel "pipelines-$OSP_VERSION"
	;;
esac

# wait until tekton pipelines operator is created
echo "Waiting for OpenShift Pipelines Operator to be created..."
timeout 5m bash <<- EOF
  until oc get deployment openshift-pipelines-operator -n openshift-operators; do
    sleep 5
  done
EOF
oc rollout status -n openshift-operators deployment/openshift-pipelines-operator --timeout 10m

# wait until clustertasks tekton CRD is properly deployed
timeout 10m bash <<- EOF
  until oc get crd tasks.tekton.dev; do
    sleep 5
  done
EOF

timeout 2m bash <<- EOF
  until oc get deployment tekton-pipelines-controller -n openshift-pipelines; do
    sleep 5
  done
EOF
rollout_status "openshift-pipelines" "tekton-pipelines-controller"
rollout_status "openshift-pipelines" "tekton-pipelines-webhook"

oc get -n openshift-pipelines pods
tkn version

# Make sure we are on the default project
oc new-project e2e-test
oc project e2e-test
