#!/bin/bash

# ensure case sensitivity for options
shopt -u nocasematch

# Help Info
#-------------------------------------------------------------------------------
function helpText(){
cat <<EOF
Cluster Diagnostics Collection

This script will pull information from the cluster about your FOSSA deployment and produce a tarball that can be shared with support.

USAGE
    This command can be ran with no flags, input will be prompted.
    ------------------------------------------------------------------------
    ${0}

    Check if you are missing any commands that this one depends on.
    ------------------------------------------------------------------------
    ${0} -R

    If these are both set, NON_INTERACTIVE mode is assumed.
    ------------------------------------------------------------------------
    ${0} -r <RELEASE_NAME> -n <NAMESPACE>

    If the filename is explicitly set, the prompt will be skipped.
    ------------------------------------------------------------------------
    ${0} -f mydata.tar.gz

    Forced NON_INTERACTIVE node will error instead of prompt.
    ------------------------------------------------------------------------
    NON_INTERACTIVE="true" ${0} -r <RELEASE_NAME> -n <NAMESPACE>

FLAGS
    -r   name of the fossa-core release
    -n   namespace fossa-core is installed in
    -h   this help message
    -R   lists missing commands required for this script to work
    -o   file save path to output tarball with info (default: ./fossa-diag.tar.gz)
    -d   enable debugging

EOF
exit 1
}

# Validate command is installed or a helpful error message.
# Usage:
#   checkCmd "command" "used to do ..." "https://instructions-for-install"
#-------------------------------------------------------------------------------
function checkCmd(){
    command -v ${1} > /dev/null 2>&1 || FAILED="true"

    # print "found" messages during NO_EXIT
    if [ -z "${FAILED}" ] && [ ! -z "${NO_EXIT}" ]; then
        echo "✅ Command ${1} was found."
    fi

    # print a failure message to help user get the tool
    if [ ! -z "${FAILED}" ]; then
        echo 
        echo "❌ Command not found: ${1}"
        echo
        echo "${2}"
        echo
        echo "Info about installing this command can be found here:"
        echo "- ${3}"

        # this disables exit to enable checking all requirements
        if [ -z "${NO_EXIT}" ]; then
            exit 1
        else
            # this separates the requirements check outputs
            echo "----------------------------------------------------------------"
            echo 
        fi
    fi
}

# Used for generic error output
#-------------------------------------------------------------------------------
function fatal(){
   echo "${0}: ERROR: $1" >&2
   exit 1
}


# Default options
#-------------------------------------------------------------------------------
DEFAULT_SAVEPATH="./fossa-diag.tar.gz"
SAVEPATH="${DEFAULT_SAVEPATH}"

# enable interactive mode if release name or namespace are empty
[ -z "${RELEASE_NAME}" ] && INTERACTIVE="true"
[ -z "${NAMESPACE}" ] && INTERACTIVE="true"

# if NON_INTERACTIVE has a value, disable INTERACTIVE mode
[ -z "${NON_INTERACTIVE}" ] && INTERACTIVE=""

# Parse options
#-------------------------------------------------------------------------------
while getopts 'dn:f:Rr:h' opt; do
    HAS_FLAGS="true"

    case "${opt}" in
    d )
        DEBUGGING="true"
        ;;
    n )
        NAMESPACE="${OPTARG}"
        ;;
    f )
        DEFAULT_SAVEPATH="skip-prompt"
        SAVEPATH="${OPTARG}"
        ;;
    R )
        EXPLAIN_ONLY="true"
        ;;
    r )
        RELEASE_NAME="${OPTARG}"
        ;;
    h )
        helpText
        ;;
    esac
done

[ ! -z "${DEBUGGING}" ] && set -x

# Setup data packing at end of script
#-------------------------------------------------------------------------------
_TMP=$(mktemp -d)
echo "Using temp directory for non-collected information: ${_TMP}"

_CAPTURE_PATH=$(mktemp -d)
echo "Using temp directory for collected information: ${_CAPTURE_PATH}"

[ ! -d "${_CAPTURE_PATH}" ] && fatal "temp directory not found for capturing support data: ${_CAPTURE_PATH}"

function packSupportTarball(){
    echo
    echo "Creating a tarball from contents of: ${1}"

    tar czvf "${1}" -C "${2}" .

    echo
    echo "Archive with information created:"
    ls -lah "${1}"
}


# Validate required commands are installed with helpful failure messages
#-------------------------------------------------------------------------------
echo "Running command: ${0} ${@}"
echo "Datetime: $(date)"
echo "--------------------------------------------------------------------------------"

# Validate required commands are installed with helpful failure messages
#-------------------------------------------------------------------------------
# let the user know required commands are being checked
if [ ! -z "${EXPLAIN_ONLY}" ]; then
    echo
    echo "Checking for required commands."
    echo "----------------------------------------------------------------"

fi

NO_EXIT="${EXPLAIN_ONLY}" checkCmd yq "required for reading cluster manifests" "https://github.com/mikefarah/yq#install"
NO_EXIT="${EXPLAIN_ONLY}" checkCmd kubectl "required for accessing kubernetes cluster" "https://kubernetes.io/docs/tasks/tools/#kubectl"
NO_EXIT="${EXPLAIN_ONLY}" checkCmd helm "required for reading helm release info" "https://helm.sh/docs/intro/install/"

# exit after checking requirements
if [ ! -z "${EXPLAIN_ONLY}" ]; then
    echo "Done checking required commands."
    echo
    exit 0
fi

# Confirm save path
#-------------------------------------------------------------------------------
if [ "${SAVEPATH}" == "${DEFAULT_SAVEPATH}" ] && [ ! -z "${INTERACTIVE}" ]; then
    echo
    echo -n "Save path for data [${DEFAULT_SAVEPATH}]: "
    read SAVEPATH
    [ -z "${SAVEPATH}" ] && SAVEPATH="${DEFAULT_SAVEPATH}"
    echo "Using: ${SAVEPATH}"

fi

[ -d "$(dirname "${SAVEPATH}")" ] || fatal "invalid save path ${SAVEPATH}"

# Confirm required info
#-------------------------------------------------------------------------------
if [ -z "${RELEASE_NAME}" ] || [ -z "${NAMESPACE}" ]; then
    # throw error if non-interactive
    [ -z "${INTERACTIVE}" ] && fatal "NAMESPACE and RELEASE NAME must be provided with -n and -r in non-interactive mode."

    echo
    echo "Listing FOSSA releases."
    helm ls --all-namespaces -oyaml | yq '[ .[] | select(.chart | contains("fossa-core")) ] | to_entries | [ .[] | (.key = .key + 1) ] ' > "${_TMP}/fossa.releases.yaml" || fatal "failed to get list of charts with helm"
    
    # confirm entries were found
    [ "$(yq '.|length' "${_TMP}/fossa.releases.yaml")" -gt "0" ] || fatal "no releases found for fossa-core"

    yq '.[] | [ "  ", .key, ")", .value.name + " (namespace=" + .value.namespace + " chart=" + .value.chart + ")" ] | join (" ") ' "${_TMP}/fossa.releases.yaml"
    
    # input loop for selecting a helm release
    SELECTED="-1" # this default value prevents escaping the loop
    while [ "${SELECTED}" == "-1" ]; do

        echo
        echo -n "Select a which fossa-core release to collect info about: "
        read SELECTED
        echo

        # validate that SELECTED is a number
        if [[ "${SELECTED}" =~ ^[0-9]+$ ]]; then
            # decrease it by 1, because the real options are array keys
            SELECTED=$(("${SELECTED}"-1))

            # get the highest key for testing
            LAST=$(yq '.[-1].key' "${_TMP}/fossa.releases.yaml")

            # option should be somewhere from 0 to LAST.
            if [[ "${SELECTED}" -lt "0" ]] || [[ "${SELECTED}" -gt "${LAST}" ]]; then
                SELECTED="-1" # let the user try again
            fi
        else
            SELECTED="-1" # let the user try again
        fi

        # inform them of the issue before looping
        if [[ "${SELECTED}" -eq "-1" ]]; then
            echo "Invalid entry. Try again."
        fi
    done

    # dump a copy of the chart info into a file to be collected
    selected="${SELECTED}" yq '.[env(selected)].value' "${_TMP}/fossa.releases.yaml" > "${_CAPTURE_PATH}/fossa.selected.release.yaml"
else
    # input was passed via flags to get helm release info
    helm --namespace "${NAMESPACE}" ls -oyaml | yq '.[] | select(.name == "'"${RELEASE_NAME}"'")' > "${_CAPTURE_PATH}/fossa.selected.release.yaml"

    # confirm the release was fossa-core
    yq '.chart' "${_CAPTURE_PATH}/fossa.selected.release.yaml" | grep -q "fossa-core" || fatal "release selected is not fossa-core"
fi

echo
echo "Release information:"
echo "---"
cat "${_CAPTURE_PATH}/fossa.selected.release.yaml"
echo

# pull values from release yaml
NAMESPACE=$(yq '.namespace' "${_CAPTURE_PATH}/fossa.selected.release.yaml")
RELEASE_NAME=$(yq '.name' "${_CAPTURE_PATH}/fossa.selected.release.yaml")
CHART_VERSION=$(yq '.chart' "${_CAPTURE_PATH}/fossa.selected.release.yaml" | cut -d- -f3)

# throw error if a value is missing
[ -z "${NAMESPACE}" ] && fatal "failed to find release by namespace ${NAMESPACE}"
[ -z "${RELEASE_NAME}" ] && fatal "failed to find release by release name ${RELEASE_NAME}"
[ -z "${CHART_VERSION}" ] && fatal "failed to find release by chart version ${CHART_VERSION}"

echo
echo "Acquiring object list from helm manifest."
helm --namespace "${NAMESPACE}" get manifest "${RELEASE_NAME}" | yq -N '[.kind, .metadata.name] | join("/") | select((.|length)!=0)' | sort > "${_CAPTURE_PATH}/release.objects.yaml"

# Explain that this might take time.
#-------------------------------------------------------------------------------
echo
echo "The data about to be collected may take a while."
echo 
echo "To cancel this command, press CTRL + C"
echo 
echo "This will begin in 15 seconds."
for COUNTDOWN in {15..0}; do
    echo -n "${COUNTDOWN}..."
    sleep 1
    [[ "${COUNTDOWN}" -eq "0" ]] && echo && echo "Starting..."
done

# Collecting data
#-------------------------------------------------------------------------------
echo
echo "Doing kubectl get for all fossa objects."
[ ! -z "${INTERACTIVE}" ] && sleep 3
kubectl --namespace "${NAMESPACE}" get $(grep -vE '^ConfigMap/('"${RELEASE_NAME}"'-(config|scotland-yard))' "${_CAPTURE_PATH}/release.objects.yaml") | tee "${_CAPTURE_PATH}/kubectl-get-release-objects.txt"

echo
echo "Gathering descriptions of all fossa objects."
[ ! -z "${INTERACTIVE}" ] && sleep 3
kubectl --namespace "${NAMESPACE}" describe $(grep -vE '^ConfigMap/'"${RELEASE_NAME}"'-(config|scotland-yard)$' "${_CAPTURE_PATH}/release.objects.yaml") > "${_CAPTURE_PATH}/kubectl-describe-release-objects.txt"

echo
echo "Gathering descriptions of all the pods in the namespace."
[ ! -z "${INTERACTIVE}" ] && sleep 3
kubectl --namespace "${NAMESPACE}" describe pods > "${_CAPTURE_PATH}/kubectl-describe-pods.txt"

echo
echo "Identifying non-running fossa pods."
[ ! -z "${INTERACTIVE}" ] && sleep 3
NOT_RUNNING=$(kubectl --namespace "${NAMESPACE}" get pods -oyaml | yq '.items[] | select(.status.phase != "Running") | select(.status.phase != "Succeeded") | [ select((.status.containerStatuses[] | .image | contains("fossa"))) ] | .[] | .metadata.name')
kubectl --namespace "${NAMESPACE}" get pods ${NOT_RUNNING} > "${_CAPTURE_PATH}/kubectl-describe-pods-not-running.txt"

echo
echo "Gathering logs for non-running fossa pods."
[ ! -z "${INTERACTIVE}" ] && sleep 3
for pod in ${NOT_RUNNING}; do
    echo "Getting logs for ${pod}"
    kubectl --namespace "${namespace}" logs "${pod}" 2>/dev/null > "${_CAPTURE_PATH}/kubectl-logs-${pod}.log"
done

echo
echo "Gathering events in the namespace ${NAMESPACE}"
[ ! -z "${INTERACTIVE}" ] && sleep 3
kubectl --namespace "${NAMESPACE}" get events > "${_CAPTURE_PATH}/kubectl-get-events.txt"

# safe to trap exit now
trap 'packSupportTarball ${SAVEPATH} ${_CAPTURE_PATH}' EXIT SIGKILL
