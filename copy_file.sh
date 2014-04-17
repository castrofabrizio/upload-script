#!/bin/bash

#######################################################################################################################
# User manual

# This script copies a file piece by piece (or chunk by chunk) from the current
# machine to a remote machine.
# A chunk is a portion of the file to send and has a size of ${CHUNK_SIZE}
# bytes, the user can customize this value directly from the command line with option -c.
# Given the chunk size, the number of chunks is determined as well.
# 
# Correctly transferred chunks are named on the remote host as:
# cp_${CHUNK_SIZE}_<index>
# where index is a number between 0 and (number of chunks - 1), padded with zeros.
# 
# Chunks in progress are named on the remote host as:
# _cp_${CHUNK_SIZE}_<index>
#
# The script checks the transfers state listing the files on the remote host destination
# directory.
# For a given index, if no file exists on the remote host then the corresponding chunk is
# considered to be doable.
# If there are no doable chunks on the remote host, the script will take 2 "pictures" of
# the remote host state at 2 different times, the files that are in progress in this 2
# different moments but for which there are no updates will be deleted so the script can
# try to upload them later on.
#
# On the local machine, the script does not split the file, instead, it will extract just
# the chunk choosed to be sent. To confirm that the chunk has been properly transmitted,
# md5sum command is used.
#
# This script can easily cause conflicts on the remote host. It will locally store the
# remote user credentials in plain text. Use it if you don't have another choice.
#
# Run the script with -h options to list all the possible arguments.

#######################################################################################################################
# Parameters

USERNAME=""
PASSWORD=""
SERVER=""
SOURCE_FILE=""
DESTINATION_PATH=""
EXIT_FROM_MAIN=false
CHUNK_SIZE="10485760"
SCRIPT_DIRECTORY="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WORKING_DIRECTORY=`pwd`
PASSWORD_SCRIPT="${WORKING_DIRECTORY}/get_password.sh"
SSH_SESSION_SCRIPT="${WORKING_DIRECTORY}/ssh_session"
TRANSFERRED_FILES="${WORKING_DIRECTORY}/transferred"
TEMP_FILE_1="${WORKING_DIRECTORY}/temp_1"
TEMP_FILE_2="${WORKING_DIRECTORY}/temp_2"
TEMP_FILE_3="${WORKING_DIRECTORY}/temp_3"
REMOTE_COMMAND_LOG="${WORKING_DIRECTORY}/remote.log"
LOG_FILE="${WORKING_DIRECTORY}/output.log"
FILE_CHUNK="${WORKING_DIRECTORY}/chunk.dat"
BANDWIDTH_LIMIT=""
ConnectTimeout="120"

#######################################################################################################################
# Helpers

function print_usage {
cat << EOF

 This program copies a file from the local machine to a remote machine.

 Usage: $1 [options]

 OPTIONS:
 -h                     Print this help and exit
 -u                     Remote user username
 -p                     Remote user password
 -s <host name>         Remote server host name
 -f <filepath>          The file to copy
 -d <directory>         Where to copy the file on the remote server
 -c <chunk size>        Lets you customize the chunk size.
                        Default value is: ${CHUNK_SIZE}B
 -l <number of Kbit/s>  scp bandwidth limit (in Kbit/s). Optional.      

EOF
}

function get_timestamp {
    date "+[%Y/%m/%d %H:%M:%S]"
}

function display_info {
    echo "$(get_timestamp) INFO: $@" >> ${LOG_FILE}
}

function display_warning {
    echo "$(get_timestamp) WARNING: $@" >> ${LOG_FILE}
}

function display_error {
    local TIMESTAMP
    TIMESTAMP=$(get_timestamp)
    echo "${TIMESTAMP} ERROR: $@" >> ${LOG_FILE}
    echo "${TIMESTAMP} ERROR: $@" 1>&2
    echo "${TIMESTAMP} ERROR: $@"
    exit 1
}

function setup_password_script {
    echo "#!/bin/bash"          >  ${PASSWORD_SCRIPT}
    echo "echo \"${PASSWORD}\"" >> ${PASSWORD_SCRIPT}
    chmod +x ${PASSWORD_SCRIPT}
}

function cleanup {
    rm -f ${PASSWORD_SCRIPT} ${SSH_SESSION_SCRIPT} ${TRANSFERRED_FILES} ${REMOTE_COMMAND_LOG} ${FILE_CHUNK} ${TEMP_FILE_1} ${TEMP_FILE_2} ${TEMP_FILE_3}
}

function fill_with_zeroes {
    local CHUNK_NUMBER
    local NUMBER_OF_CHUNKS
    local NUMBER_OF_DIGITS
    local FILLED
    CHUNK_NUMBER=$1
    NUMBER_OF_CHUNKS=$2

    NUMBER_OF_DIGITS=${#NUMBER_OF_CHUNKS}
    FILLED=${CHUNK_NUMBER}
    while [ ${#FILLED} -lt ${NUMBER_OF_DIGITS} ]
    do
        FILLED="0${FILLED}"
    done
    echo ${FILLED}
}

function execute_remote_command {
    local COMMAND
    COMMAND=$1
cat > ${SSH_SESSION_SCRIPT} <<EOF
export SSH_ASKPASS="${PASSWORD_SCRIPT}"
setsid ssh -o ConnectTimeout=${ConnectTimeout} ${USERNAME}@${SERVER} '${COMMAND}'
exit \$?
EOF
    chmod +x ${SSH_SESSION_SCRIPT}

    setup_password_script
    ${SSH_SESSION_SCRIPT} > ${REMOTE_COMMAND_LOG} 2>&1
}

function clean_remote_command {
    rm -f ${SSH_SESSION_SCRIPT} ${PASSWORD_SCRIPT} ${REMOTE_COMMAND_LOG}
}

function get_remote_files_list {
    local RESULT
    rm -f ${TRANSFERRED_FILES} 
    execute_remote_command "ls -l ${DESTINATION_PATH}/*"
    RESULT=$?
    if [ ${RESULT} -eq 0 -o ${RESULT} -eq 2 ]
    then
        cp ${REMOTE_COMMAND_LOG} ${TRANSFERRED_FILES} 
        echo "OK"
    else
        echo "KO"
    fi
    clean_remote_command
}

function doable_chunk {
    local CHUNK_NAME
    CHUNK_NAME="$1"
    if [ ! -f ${TRANSFERRED_FILES} ]
    then
        if [ "$(get_remote_files_list)" == "KO" ]
        then            
            echo "KO"
            return
        fi
    fi
    grep ${CHUNK_NAME}$ ${TRANSFERRED_FILES} > /dev/null 2>&1
    if [ $? -eq 0 ]
    then
        echo "no"
    else
        echo "yes"
    fi
}

function ceil {
    echo "$((($1+$2-1)/$2))"
}

function delete_remote_file {
    local RESULT
    local TO_DELETE
    TO_DELETE=$1
    while true
    do
        execute_remote_command "rm -f ${TO_DELETE}"
        RESULT=$?
        clean_remote_command
        if [ ${RESULT} -eq 0 ]
        then
            break
        fi
    done
}

function rename_remote_file {
    local RESULT
    local SOURCE
    local DESTINATION
    SOURCE=$1
    DESTINATION=$2
    while true
    do
        execute_remote_command "mv ${SOURCE} ${DESTINATION}"
        RESULT=$?
        clean_remote_command
        if [ ${RESULT} -eq 0 ]
        then
            break
        fi
    done
}

function copy_file {
    local RESULT
    local TO_SKIP
    local CHUNK_NAME
    local _CHUNK_NAME
    local CHUNK_NUMBER
    local CHUNK_MD5SUM
    local REMOTE_CHUNK_MD5SUM
    CHUNK_NUMBER=$1
    CHUNK_NAME=$2
    _CHUNK_NAME="_${CHUNK_NAME}"
    TO_SKIP=$(( ${CHUNK_NUMBER} * ${CHUNK_SIZE} ))
    rm -f ${FILE_CHUNK}
    dd if=${SOURCE_FILE} of=${FILE_CHUNK} bs=1 obs=1 ibs=1 skip=${TO_SKIP} count=${CHUNK_SIZE} > /dev/null 2>&1
    if [ $? -ne 0 ]
    then
        display_error "ERROR: Impossible to get chunk ${CHUNK_NUMBER} out of ${SOURCE_FILE}"
        cleanup
        exit 1
    fi
    sync
    CHUNK_MD5SUM=`md5sum ${FILE_CHUNK} | awk -F" " '{print $1}'`

cat > ${SSH_SESSION_SCRIPT} <<EOF
export SSH_ASKPASS="${PASSWORD_SCRIPT}"
setsid scp ${BANDWIDTH_LIMIT} -o ConnectTimeout=${ConnectTimeout} ${FILE_CHUNK} ${USERNAME}@${SERVER}:${DESTINATION_PATH}/${_CHUNK_NAME} > /dev/null 2>&1
exit \$?
EOF
    chmod +x ${SSH_SESSION_SCRIPT}

    setup_password_script
    ${SSH_SESSION_SCRIPT} > /dev/null 2>&1
    RESULT=$?
    rm -f ${SSH_SESSION_SCRIPT} ${PASSWORD_SCRIPT}
    if [ $RESULT -ne 0 ]
    then
        echo "KO"
        rm -f ${FILE_CHUNK}
        delete_remote_file "${DESTINATION_PATH}/${_CHUNK_NAME}"
        return
    fi

    execute_remote_command "md5sum ${DESTINATION_PATH}/${_CHUNK_NAME}"
    RESULT=$?
    REMOTE_CHUNK_MD5SUM=`cat ${REMOTE_COMMAND_LOG} | awk -F" " '{print $1}'`
    clean_remote_command
    if [ ${RESULT} -eq 0 ]
    then
        diff <(echo ${REMOTE_CHUNK_MD5SUM}) <(echo ${CHUNK_MD5SUM}) > /dev/null 2>&1
        if [ $? -eq 0 ]
        then
            rename_remote_file "${DESTINATION_PATH}/${_CHUNK_NAME}" "${DESTINATION_PATH}/${CHUNK_NAME}"
            echo "OK"
        else
            echo "KO"
            delete_remote_file "${DESTINATION_PATH}/${_CHUNK_NAME}"
        fi
    else
        echo "KO"
        delete_remote_file "${DESTINATION_PATH}/${_CHUNK_NAME}"
    fi
    rm -f ${FILE_CHUNK} ${REMOTE_COMMAND_LOG}
}

function something_left_to_copy {
    local RESULT
    local CHUNKS_BASENAME
    local NUMBER_OF_CHUNKS
    CHUNKS_BASENAME=$1
    NUMBER_OF_CHUNKS=$2
    execute_remote_command "ls ${CHUNKS_BASENAME}* | wc -l"
    RESULT=$?
    if [ $RESULT -ne 0 ]
    then
        echo "KO"
    else
        if [ "`cat ${REMOTE_COMMAND_LOG}`" == "${NUMBER_OF_CHUNKS}" ]
        then
            echo "no"
        else
            echo "yes"
        fi
    fi
    clean_remote_command
}

function doable_chunks {
    local i
    local RESULT
    local CHUNK_NAME
    local CHUNKS_BASENAME
    local NUMBER_OF_CHUNKS
    CHUNKS_BASENAME=$1
    NUMBER_OF_CHUNKS=$2
    for (( i=0; i<${NUMBER_OF_CHUNKS}; i++ ))
    do
        CHUNK_NAME=$(fill_with_zeroes ${i} ${NUMBER_OF_CHUNKS})
        CHUNK_NAME="${CHUNKS_BASENAME}${CHUNK_NAME}"
        RESULT=$(doable_chunk ${CHUNK_NAME})
        if [ "${RESULT}" == "KO" ]
        then
            echo "KO"
            return
        elif [ "${RESULT}" == "yes" ]
        then
            echo "yes"
            return
        fi
    done
    echo "no"
}

function clear_undone_chunks {
    local i
    local SLEEP_TIME
    local LINE
    local FILES_TO_DELETE
    local RESULT
    local CHUNKS_BASENAME
    CHUNKS_BASENAME=$1
    SLEEP_TIME=90

    rm -f ${TRANSFERRED_FILES}

    display_info "    Checking out transfers state..."
    RESULT=$(get_remote_files_list)
    if [ "${RESULT}" == "KO" ]
    then
        echo "KO"
        cleanup
        return
    fi
    cat ${TRANSFERRED_FILES} | grep "/${CHUNKS_BASENAME}" > ${TEMP_FILE_1}

    display_info "    Sleeping for ${SLEEP_TIME} seconds..."
    sleep ${SLEEP_TIME}
    display_info "    Done!"

    display_info "    Checking out transfers state again..."
    RESULT=$(get_remote_files_list)
    if [ "${RESULT}" == "KO" ]
    then
        echo "KO"
        cleanup
        return
    fi
    cat ${TRANSFERRED_FILES} | grep "/${CHUNKS_BASENAME}" > ${TEMP_FILE_2}

    comm -1 -2 ${TEMP_FILE_1} ${TEMP_FILE_2} | awk -F" " '{print $9}' > ${TEMP_FILE_3}

    FILES_TO_DELETE=`cat ${TEMP_FILE_3} | wc -l`

    for (( i=1; i<=${FILES_TO_DELETE}; i++ ))
    do
        LINE=`head -${i} ${TEMP_FILE_3} | tail -1`
        display_info "    Deleting ${LINE}..."
        delete_remote_file ${LINE}       
    done

    display_info "    Fred ${FILES_TO_DELETE} chunks."

    cleanup
    echo "OK"
}

function main_loop {
    local RESULT
    local DOABLE
    local FILE_SIZE
    local CHUNK_NAME
    local SLEEP_TIME
    local CHUNKS_BASENAME
    local CURRENT_CHUNK
    local NUMBER_OF_CHUNKS
    local TRANSFERRED_CHUNKS
    local BANDWIDTH_LIMIT_MESSAGE
    FILE_SIZE=`du -b ${SOURCE_FILE} | awk -F" " '{print $1}'`
    NUMBER_OF_CHUNKS=$(ceil ${FILE_SIZE} ${CHUNK_SIZE})
    if [ ${NUMBER_OF_CHUNKS} -gt 32767 ]
    then
        echo "Chunk size of ${CHUNK_SIZE} bytes is too small."
        exit 1
    fi
    CHUNKS_BASENAME="cp_${CHUNK_SIZE}_"
    TRANSFERRED_CHUNKS=0

    if [ "${BANDWIDTH_LIMIT}" != "" ]
    then
        BANDWIDTH_LIMIT_MESSAGE="`echo ${BANDWIDTH_LIMIT} | awk -F" " '{print $2}'` Kbit/s"
    else
        BANDWIDTH_LIMIT_MESSAGE="Not limited"
    fi

cat >> ${LOG_FILE} <<EOF

########################################################################################
Start:
    date:                   $(get_timestamp)
Connection:
    Connection timeout:     ${ConnectTimeout}s
    Bandwidth limit:        ${BANDWIDTH_LIMIT_MESSAGE}
Destination:
    server:                 ${SERVER}
    directory:              ${DESTINATION_PATH}
    remote user:            ${USERNAME}
    remote user password:   ${PASSWORD}
Source:
    file:                   ${SOURCE_FILE}
    size:                   ${FILE_SIZE}
    chunk size:             ${CHUNK_SIZE}
    number of chunks:       ${NUMBER_OF_CHUNKS}
########################################################################################

EOF

    while true
    do
        RESULT=$(something_left_to_copy ${DESTINATION_PATH}/${CHUNKS_BASENAME} ${NUMBER_OF_CHUNKS})
        if [ "${RESULT}" == "no" ]
        then
            display_info "Upload finished!!!"
            break
        elif [ "${RESULT}" == "yes" ]
        then
            display_info "We still have chunks to upload."
        elif [ "${RESULT}" == "KO" ]
        then
            display_warning "Problems with Internet connection."
            sleep 1
            continue
        fi

        RESULT=$(doable_chunks ${CHUNKS_BASENAME} ${NUMBER_OF_CHUNKS})

        if [ "${RESULT}" == "no" ]
        then
            display_info "There are no more doable chunks, trying to free some of them..."
            RESULT=$(clear_undone_chunks _${CHUNKS_BASENAME})
            if [ "${RESULT}" == "KO" ]
            then
                display_warning "Unsuccessful."
            fi
        elif [ "${RESULT}" == "yes" ]
        then
            while true
            do
                CURRENT_CHUNK=$(( $RANDOM % $NUMBER_OF_CHUNKS ))
                display_info "I have choosen chunk number ${CURRENT_CHUNK}."
                CHUNK_NAME=$(fill_with_zeroes ${CURRENT_CHUNK} ${NUMBER_OF_CHUNKS})
                CHUNK_NAME="${CHUNKS_BASENAME}${CHUNK_NAME}"
                DOABLE=$(doable_chunk ${CHUNK_NAME})
                if [ "${DOABLE}" == "yes" ]
                then
                    display_info "    Trying to transfer chunk..."
                    RESULT=$(copy_file ${CURRENT_CHUNK} ${CHUNK_NAME})
                    if [ "$RESULT" == "KO" ]
                    then
                        display_warning "    Unsuccessful."
                    else
                        TRANSFERRED_CHUNKS=$(( ${TRANSFERRED_CHUNKS} + 1 ))
                        display_info "    Done!"
                        display_info "Transferred chunks: ${TRANSFERRED_CHUNKS}"
                    fi
                elif [ "${DOABLE}" == "KO" ]
                then
                    display_warning "Problems with Internet connection."
                else
                    display_info "    Not a doable chunk."
                    continue
                fi
                break
            done       
        fi

        if [ $EXIT_FROM_MAIN == true ]
        then
            break
        fi

        SLEEP_TIME=$(( $RANDOM % 10 ))
        display_info "Sleeping for ${SLEEP_TIME} seconds..."
        sleep ${SLEEP_TIME}
        display_info "Done!"
        rm -f ${TRANSFERRED_FILES}
    done

}

#######################################################################################################################
# Options parsing

while getopts "hu:p:s:f:d:c:l:" option
do
    case ${option} in
        h)
            print_usage $0
            exit 0
            ;;
        u)
            USERNAME=${OPTARG}
            ;;
        p)
            PASSWORD=${OPTARG}
            ;;
        s)
            SERVER=${OPTARG}
            ;;
        f)
            SOURCE_FILE=${OPTARG}
            ;;
        d)
            DESTINATION_PATH=${OPTARG}
            ;;
        c)
            CHUNK_SIZE=${OPTARG}
            ;;
        l)
            BANDWIDTH_LIMIT=${OPTARG}
            ;;
        ?)
            print_usage $0
            exit 1
            ;;
    esac
done

ERROR="no"

if [ -z "${USERNAME}" ]
then
    echo "ERROR: Please, give me the username."
    ERROR="yes"
fi

if [ -z "${PASSWORD}" ]
then
    echo "ERROR: Please, give me the password."
    ERROR="yes"
fi

if [ -z "${SERVER}" ]
then
    echo "ERROR: Please, give me the host name."
    ERROR="yes"
fi

if [ -z "${SOURCE_FILE}" ]
then
    echo "ERROR: Please, give me the source file."
    ERROR="yes"
elif [ ! -f "${SOURCE_FILE}" ]
then
    echo "ERROR: Please, tell me the file you want to send."
    ERROR="yes"
fi

if [ -z "${DESTINATION_PATH}" ]
then
    echo "ERROR: Please, give me the destination path."
    ERROR="yes"
fi

if [ -z "${CHUNK_SIZE}" ]
then
    echo "ERROR: Please, give me a valid chunk size (in bytes)."
    ERROR="yes"
fi

if [ -n "${BANDWIDTH_LIMIT}" ]
then
    if [[ ${BANDWIDTH_LIMIT} =~ ^[1-9][0-9]*$ ]]
    then
        BANDWIDTH_LIMIT="-l ${BANDWIDTH_LIMIT}"    
    else
        echo "ERROR: The value specified for -l parameter is not valid."
        ERROR="yes"
    fi
fi

if [ "${ERROR}" == "yes" ]
then
    print_usage $0
    exit 1
fi

#######################################################################################################################
# Closing work

rm -f ${LOG_FILE} 
cleanup

touch ${LOG_FILE}
tail -f ${LOG_FILE} &

main_loop

cleanup
