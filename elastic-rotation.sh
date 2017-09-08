#!/bin/bash
# Elasticsearch Daily Index Rotation Tool
#
# For a given cluster and a snapshot repository, make snapshots of daily indices 
#  (named with "<prefix>YYYY.DD.MM" pattern) and deletes the old ones.
#
# For elasticsearch >= 5.0 there is a better approach: https://www.elastic.co/blog/managing-time-based-indices-efficiently
#
# You need the jq binary:
# - yum install jq
# - apt-get install jq
# - or download from http://stedolan.github.io/jq/

function usage {
    cat <<EOF
$0 - Elasticsearch Daily Index Rotation Tool
For a given cluster and a snapshot repository, make snapshots of daily indices 
 (named with "<prefix>YYYY.DD.MM" pattern) and deletes the old ones.

Must be called with ALL the following parameters:
    --url           elasticsearch url, eg. https://<host>:<port>
    --repository    snapshot repository or 'DISABLED' to disable snapshotting
    --index-prefix  index pattern to be rotated
    --index-age     days to keep indices - the older ones will be deleted
EOF
}

function snapshotIndex {
    local index=$1
    local status=$(curl -s -XPUT "${BASE_URL}/_snapshot/${REPOSITORY}/${index}" -d "
{
    \"indices\": \"${index}\",
    \"ignore_unavailable\": false,
    \"include_global_state\": false
}
")
    echo ${status}
}

function deleteIndex {
    local index=$1
    local status=$(curl -s -XDELETE "${BASE_URL}/${index}")
    echo ${status}
}

function getSnapshotStatus {
    local index=$1
    local attr=$2
    local val=$(curl -s -XGET "${BASE_URL}/_snapshot/${REPOSITORY}/${index}/_status" | jq -r ".snapshots[0].${attr}")
    echo ${val}
}

function getIndexMetadata {
    local index=$1
    local attr=$2
    local val=$(curl -s -XGET "${BASE_URL}/${index}/" | jq -r ".[].settings.index.${attr}")
    echo ${val}
}

###############################################################################

[ $# -eq 0 ] && usage && exit 0;

PARAMS=${@}

OPTS=`getopt -o u:r:p:i: -l url:,repository:,index-prefix:,index-age: --name "$0" -- "$@"`

if [ $? != 0 ] ; then echo "Failed parsing options." >&2 ; exit 1 ; fi

eval set -- "$OPTS"

while true
do
    case "$1" in
        -u|--url) BASE_URL=$2; shift 2 ;;
        -r|--repository) REPOSITORY=$2; shift 2 ;;
        -p|--index-prefix) INDEX_PREFIX=$2; shift 2 ;;
        -i|--index-age) INDEX_MAX_AGE=$2; shift 2 ;;
	--help) usage; exit 1; ;;
        --) shift; break ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "${BASE_URL}" || -z "${REPOSITORY}" || -z "${INDEX_PREFIX}" || -z "${INDEX_MAX_AGE}" ]]; then
    echo "Error: All options must be set." >&2; exit 1
fi

echo "$(date) Starting $0 with params: ${PARAMS}"

if [[ "${REPOSITORY}" = "DISABLED" ]]; then
    DISABLE_SNAPSHOTS=true
    echo "Info: Snapshots are disabled. Old indices will be rotated without being backed up."
else
    DISABLE_SNAPSHOTS=false
fi

INDICES=$(curl -s -k -XGET "${BASE_URL}/_cat/indices/${INDEX_PREFIX}*?h=index" | sort)

if [[ ! ${DISABLE_SNAPSHOTS} ]]; then

    SNAPSHOTS=$(curl -s -k -XGET "${BASE_URL}/_snapshot/${REPOSITORY}/_all" | jq -r '.snapshots[].snapshot' | sort)
    
    # TODO: fail if snapshot count times out
    #if [ -z "$SNAPSHOTS" ]; then
    #    echo "ERROR: Could not retrieve snapshot list from the server. Aborting..." >/dev/stderr
    #    exit 1
    #fi
    
    # indices without snapshots
    TO_BACKUP=${INDICES[@]}
    for i in ${SNAPSHOTS[@]}
    do
        TO_BACKUP=${TO_BACKUP/${i}/}
    done
    
    # exclude today's index (which is still being written)
    TO_BACKUP=${TO_BACKUP/${INDEX_PREFIX}$(date +%Y.%m.%d)/}
    
    total=$(echo ${TO_BACKUP[@]} | wc -w)
    echo "Indices to backup: ${total}"
    
    n=0
    for index in ${TO_BACKUP[@]}
    do 
        # --------------=[Snapshot Index]=------------------
        ((n++))
        echo "$n/${total}: Snapshotting ${index}..."
        status=$(snapshotIndex ${index})
        if [ "$status" != '{"accepted":true}' ]; then
            echo "ERROR: ${index} snapshot failed!" >/dev/stderr
    	continue
        fi
    
        _start=0
        _end=$(getSnapshotStatus ${index} "shards_stats.total")
        while [[ ${_start} -lt ${_end} ]]; do
            sleep 2
    	_start=$(getSnapshotStatus ${index} "shards_stats.done")
        done
    done

fi # end if [[ ! ${DISABLE_SNAPSHOTS} ]]

# --------------=[Delete Old Indices]=------------------
index_max_age=$(date +%s --date="today - ${INDEX_MAX_AGE} days")

# check if index has a snapshot and deletes the index if it is too old
for index in ${INDICES[@]}
do 
    # https://stackoverflow.com/questions/3685970/check-if-an-array-contains-a-value
    if [[ "${SNAPSHOTS[@]}" =~ "${index}" ]] || [[ ${DISABLE_SNAPSHOTS} ]]; then

        index_creation=$(( $(getIndexMetadata ${index} "creation_date") / 1000 ))
        if [[ ${index_creation} -lt ${index_max_age} ]]; then
            echo "Deleting old index already snapshotted: ${index}"
            status=$(deleteIndex ${index})
            if [ "$status" != '{"acknowledged":true}' ]; then
                echo "ERROR: ${index} delete failed!" >/dev/stderr
            fi
        fi
    fi
done

# TODO: purge old snapshots?
#snapshot_max_age=$(date +%s --date="today - ${DAYS_TO_KEEP_SNAPSHOT} days")

echo "$(date) - Done"
