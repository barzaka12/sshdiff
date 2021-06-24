#!/bin/bash

versionString="1.0"

version()
{
	echo "sshdiff $versionString"
}


usage()
{
	cat <<'EOUSAGE'
Description: Check for discrepancies between the local and remote versions of a file on multiple servers.

Usage:	sshdiff path/to/local/file path/to/remote/file path/to/hosts/file
        sshdiff -l path/to/local/file path/to/remote/file "HOST1 HOST2 HOST3..."
        sshdiff [-o "OPTIONS"] path/to/local/file path/to/remote/file path/to/hosts/file
        sshdiff [-s] path/to/local/file path/to/remote/file path/to/hosts/file
        sshdiff [-j NUMBER] path/to/local/file path/to/remote/file path/to/hosts/file
        sshdiff -h | -V | -v | --help | --version

        -l give remote hosts as a command line argument instead of a path to a file
        -o what options diff to use. You can check them all by "diff --help"
        -s slow/step-by-step mode in which there are no more than 10 ssh connections simultaneously
        -j how many ssh sessions to have simultaneously
        -h display program usage information and exit
        -V display program version information and exit
        -v display program version information and exit

EOUSAGE
}

maxNumberOfSshSessions=10
numberOfRequiredArguments=3

while getopts 'lo:sj:hVv-:' o; do
	case "$o" in
        l)
            lFlag=1
            ((numberOfRequiredArguments++))
            ;;

        o)
            diffOptions=$OPTARG
            ((numberOfRequiredArguments+=2))
            ;;
        s)
            sFlag=1
            ((numberOfRequiredArguments++))
            ;;

        j)
            maxNumberOfSshSessions=$OPTARG
            sFlag=1
            ((numberOfRequiredArguments+=2))
            ;;

		h)
			hFlag=1
			;;

        V)
			vFlag=1
			;;

		v)
			vFlag=1
			;;

		-)
			if [ "$OPTARG" = 'help' ]; then
				hFlag=1
			elif [ "$OPTARG" = 'version' ]; then
				vFlag=1
			else
				echo "Invalid long option ""$OPTARG"" specified" 1>&2
				usage 1>&2
				exit 1
			fi
			;;

		*)
			usage 1>&2
			exit 1
			;;
	esac
done

[ -z "$vFlag" ] || version
[ -z "$hFlag" ] || usage
[ -z "$vFlag$hFlag" ] || exit 0

if [[ $# -ne $numberOfRequiredArguments ]]; then
	usage 1>&2
	exit 1
fi

localFilePath=${@:$#-2:1}
remoteFilePath=${@:$#-1:1}

if ! [ -f "${localFilePath}" ]
then
    echo "There is no ${localFilePath} file" 1>&2
    exit 5
fi


if [ $lFlag ]
then
    hosts=${@:$#:1}
else
    if ! [ -f "${@:$#:1}" ]
    then
        echo "There is no ${@:$#:1} file in this directory" 1>&2
        exit 4
    fi
    hosts=$(cat "${@:$#:1}")
fi

exitCode=0

mkdir -p "sshdiff"

function actualCheck {

    serverCheck="$1"
    sshOutput=$(ssh -q "${serverCheck}" "cat ${remoteFilePath}" < /dev/null 2>&1)
    sshExitCode="$?"
    outputFile="sshdiff/${serverCheck}.out"

    if [[ ${sshExitCode} -ne 0 ]]
    then
        echo "3" > "${outputFile}"
        echo "Critical error in ssh with server \"${serverCheck}\"" >> "${outputFile}"
        echo "Try \"ssh ${serverCheck} cat ${remoteFilePath}\" to reproduce error" >> "${outputFile}"
        echo "Error:" >> "${outputFile}"
        printf -- '%s\n' "$sshOutput" >> "${outputFile}"
        echo "EXIT CODE:" >> "${outputFile}"
        printf -- '%s\n' "$sshExitCode" >> "${outputFile}"
        return 3
    fi

    diffOutput=$(diff "${diffOptions}" "${localFilePath}" - <<< "${sshOutput}" 2>&1)
    diffExitCode="$?"

    if [[ ${diffExitCode} -ge 2 ]]
    then
        echo "2" > "${outputFile}"
        echo "Critical error in diff with server \"${serverCheck}\"" >> "${outputFile}"
        echo "Bellow is the diff output and exit code" >> "${outputFile}"
        echo "OUTPUT:" >> "${outputFile}"
        printf -- '%s\n' "$diffOutput" >> "${outputFile}"
        echo "EXIT CODE:" >> "${outputFile}"
        printf -- '%s\n' "$diffExitCode" >> "${outputFile}"
        return 2
    fi

    if [[ ${diffExitCode} -eq 1 ]]
    then
        echo "1" > "${outputFile}"
        echo "There is difference between the local file and the one on \"${serverCheck}\". You can find it bellow:" >> "${outputFile}"
        printf -- '%s\n' "$diffOutput" >> "${outputFile}"
        return 1
    fi

    echo "0" > "${outputFile}"
    return 0
}

if [ -z "$sFlag" ]
then
    numberOfSshSessions=0
    for server in $hosts; do
        if [[ ${numberOfSshSessions} -ge ${maxNumberOfSshSessions} ]]
        then
            wait -n
            ((numberOfSshSessions--))
        fi
        actualCheck "${server}" &
        ((numberOfSshSessions++))
    done
else
    for server in $hosts; do
        actualCheck "${server}" &
    done
fi

wait

for server in $hosts; do

    outputFile="sshdiff/${server}.out"
    read -r checkExitCode < "${outputFile}"

    if [[ ${checkExitCode} -ge 4 ]]
    then
        echo "Unexpected exit code" 1>&2
        unexpectedExitFlag=1
    fi

    if [[ ${checkExitCode} -eq 3 ]]
    then
        tail -n +2 "${outputFile}" 1>&2
        sshErrorFlag=1
    fi

    if [[ ${checkExitCode} -eq 2 ]]
    then
        tail -n +2 "${outputFile}" 1>&2
        diffErrorFlag=1
    fi

    if [[ ${checkExitCode} -eq 1 ]]
    then
        tail -n +2 "${outputFile}"
        differenceFlag=1
    fi

done

if [ -z "$sshErrorFlag" ]
then
    ((exitCode=exitCode*10+3))
fi
if [ -z "$diffErrorFlag" ]
then
    ((exitCode=exitCode*10+2))
fi
if [ -z "$unexpectedExitFlag" ]
then
    ((exitCode=exitCode*6))
fi
if [ -z "$differenceFlag" ]
then
    ((exitCode=exitCode+1))
fi

rm -r "sshdiff"

exit $exitCode
