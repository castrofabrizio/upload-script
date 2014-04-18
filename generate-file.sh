#!/bin/sh

#######################################################################################################################
# Parameters

FILES_BASENAME=""
OUTPUT_FILENAME=""
FIRST_FILE=""
LAST_FILE=""
CAT_FILE="yes"
PARAMETERS_ERROR="no"
TEMP_FILE=""

#######################################################################################################################
# Helper

function print_usage {
cat << EOF

 This script takes as input a list of files to use to (re)compose an
 output file. 

 Usage: $1 [options]

 OPTIONS:
 -h                 Print this help and exit
 -b <basename>      Files common basename. This option is mandatory
 -f <first file>    Among the files with the same common basename, this is
                    the first file to use. This option is not mandatory
 -l <last file>     Among the files with the same common basename, this is
                    the last file to use. This option is not mandatory
 -o <output file>   File to generate. This options is mandatory

EOF
}

#######################################################################################################################
# Options parsing

while getopts "hb:o:f:l:" option
do
    case ${option} in
        h)
            print_usage $0
            exit 0
            ;;
        b)
            FILES_BASENAME=${OPTARG}
            ;;
        o)
            OUTPUT_FILENAME=${OPTARG}
            ;;
        f)
            FIRST_FILE=${OPTARG}
            ;;
        l)
            LAST_FILE=${OPTARG}
            ;;
        ?)
            print_usage $0
            exit 1
            ;;
    esac
done

echo ""

if [ -z "${FILES_BASENAME}" ]
then
    echo " ERROR: Please, specify the input files basename."
    PARAMETERS_ERROR="yes"
else
    ls ${FILES_BASENAME}* > /dev/null 2>&1
    if [ $? -ne 0 ]
    then
        echo " ERROR: Wrong input files basename."
        PARAMETERS_ERRORS="yes"
    fi
fi

if [ -n "${FIRST_FILE}" ]
then
    if [ ! -f ${FIRST_FILE} ]
    then
        echo " ERROR: File ${FIRST_FILE} does not exists."
        PARAMETERS_ERROR="yes"
    else
        ls ${FILES_BASENAME}* | grep $(basename ${FIRST_FILE}) > /dev/null 2>&1
        if [ $? -ne 0 ]
        then
            echo " ERROR: File ${FIRST_FILE} is not among the files to use to compose the output file."
            PARAMETERS_ERROR="yes"
        else
            CAT_FILE="no"
            FIRST_FILE=$(basename ${FIRST_FILE})
        fi
    fi
fi

if [ -n "${LAST_FILE}" ]
then
    if [ ! -f ${LAST_FILE} ]
    then
        echo " ERROR: File ${LAST_FILE} does not exists."
        PARAMETERS_ERROR="yes"
    else
        ls ${FILES_BASENAME}* | grep $(basename ${LAST_FILE}) > /dev/null 2>&1
        if [ $? -ne 0 ]
        then
            echo " ERROR: File ${LAST_FILE} is not among the files to use to compose the output file."
            PARAMETERS_ERROR="yes"
        else
            LAST_FILE=$(basename ${LAST_FILE})
        fi
    fi
fi

if [ -z "${OUTPUT_FILENAME}" ]
then
    echo " ERROR: Please, specify the output file name."
    PARAMETERS_ERROR="yes"
else
    if [ -f ${OUTPUT_FILENAME} ]
    then
        if [ -z "${FIRST_FILE}" -a -z "${LAST_FILE}" ]
        then
            echo " WARNING: File ${OUTPUT_FILENAME} already exists, this script will rewrite it."
            read -p " Are you sure you want to continue? [yN]: "
            if [ "${REPLY}" != "y" -a "${REPLY}" != "Y" ]
            then
                PARAMETERS_ERROR="yes"
            else
                rm ${OUTPUT_FILENAME}
                if [ $? -ne 0 ]
                then
                    echo " ERROR: Impossible to delete file ${OUTPUT_FILENAME}."
                    PARAMETERS_ERROR="yes"
                fi
            fi
        fi
    fi
fi

if [ "${PARAMETERS_ERROR}" == "yes" ]
then
    print_usage $0
    exit 1
fi

touch ${OUTPUT_FILENAME}
if [ $? -ne 0 ]
then
    echo " ERROR: Impossible to create file ${OUTPUT_FILENAME}."
    print_usage $0
    exit 1
fi

TEMP_FILE=$(mktemp)
if [ $? -ne 0 ]
then
    echo " ERROR: Impossible to create a temporary file. Aborting."
    exit 1
fi

ls ${FILES_BASENAME}* > ${TEMP_FILE}

while read CHUNK_NAME
do
    CHUNK_BASENAME=$(basename ${CHUNK_NAME})

    if [ "${CHUNK_BASENAME}" == "${FIRST_FILE}" ]
    then
        CAT_FILE="yes"
    fi

    if [ "${CAT_FILE}" == "yes" ]
    then
        echo " INFO: Using file ${CHUNK_NAME}..."
        cat ${CHUNK_NAME} >> ${OUTPUT_FILENAME}
    fi

    if [ "${CHUNK_BASENAME}" == "${LAST_FILE}" ]
    then
        break
    fi
done < ${TEMP_FILE}

rm -f ${TEMP_FILE}

echo ""
