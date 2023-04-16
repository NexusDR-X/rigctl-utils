#!/bin/bash
#================================================================
# HEADER
#================================================================
#% SYNOPSIS
#+   ${SCRIPT_NAME} [-hv] [FILE]
#%
#% DESCRIPTION
#%   This script provides a GUI to configure and operate rigctld.
#%
#% OPTIONS
#%    -h, --help                  Print this help
#%    -v, --version               Print script information
#%
#% OPTIONAL PARAMETERS
#%    If supplied, this script will use the file path supplied
#%    for the ARGS_CONFIG variable. That file will be used to 
#%    to launch the rigctld systemd service. It will use a
#%    default file if this parameter is not supplied.
#================================================================
#- IMPLEMENTATION
#-    version         ${SCRIPT_NAME} 2.0.3
#-    author          Steve Magnuson, AG7GN
#-    license         CC-BY-SA Creative Commons License
#-    script_id       0
#-
#================================================================
#  HISTORY
#     20200609 : Steve Magnuson : Script creation.
#     20200718 : Steve Magnuson : Delete unused function.
#     20211129 : Steve Magnuson : Updated to suppor new locations
#											 for pat confuguration
#     20230318 : Steve Magnuson : Refactor for systemd
# 
#================================================================
#  DEBUG OPTION
#    set -n  # Uncomment to check your syntax, without execution.
#    set -x  # Uncomment to debug this shell script
#
#================================================================
# END_OF_HEADER
#================================================================

SYNTAX=false
DEBUG=false
Optnum=$#

#============================
#  FUNCTIONS
#============================

function TrapCleanup () {
   for P in ${YAD_PIDs[@]}
	do
		kill $P >/dev/null 2>&1
	done
	rm -f $TERM_PIPE
	unset argModify
	unset Message
	unset rigctldStatus
	unset restartRigctld
	unset stopRigctld
	unset RIGCTL_LOG
	unset RIGS_FILE
	unset ARGS_CONFIG
}

function SafeExit() {
	TrapCleanup
   trap - INT TERM EXIT
	[[ -d "${TMPDIR}" ]] && rm -rf "${TMPDIR}/" 2>/dev/null
   exit ${1:-0}
}

function ScriptInfo() { 
	HEAD_FILTER="^#-"
	[[ "$1" = "usage" ]] && HEAD_FILTER="^#+"
	[[ "$1" = "full" ]] && HEAD_FILTER="^#[%+]"
	[[ "$1" = "version" ]] && HEAD_FILTER="^#-"
	head -${SCRIPT_HEADSIZE:-99} ${0} | grep -e "${HEAD_FILTER}" | \
	sed -e "s/${HEAD_FILTER}//g" \
	    -e "s/\${SCRIPT_NAME}/${SCRIPT_NAME}/g" \
	    -e "s/\${SPEED}/${SPEED}/g" \
	    -e "s/\${DEFAULT_PORTSTRING}/${DEFAULT_PORTSTRING}/g"
}

function Usage() { 
	printf "Usage: "
	ScriptInfo usage
	exit
}

function Die () {
	echo "${*}"
	SafeExit
}

function Message () {
	# Data piped to this function is sent to a stdout, prepended by  
	# a time stamp
   TIME_FORMAT="%Y/%m/%d %H:%M:%S"
   echo "$1" | stdbuf -oL ts "${TIME_FORMAT}" >> $RIGCTL_LOG
}
export -f Message

function trim() {
  # Trims leading and trailing white space from a string
  local s2 s="$*"
  until s2="${s#[[:space:]]}"; [ "$s2" = "$s" ]; do s="$s2"; done
  until s2="${s%[[:space:]]}"; [ "$s2" = "$s" ]; do s="$s2"; done
  echo "$s"
}

function argModify () {
   local ARG=$(echo $@ | cut -d '=' -f1)
   grep -v "^${ARG}" $ARGS_CONFIG | sponge $ARGS_CONFIG
   cat >> $ARGS_CONFIG <<EOF
$@
EOF
}
export -f argModify

function rigctldStatus() {
	if systemctl --user --quiet is-active $(systemd-escape --template rigctld@.service "$ARGS_CONFIG")
	then
		local PROCESS="$(systemd-cgls -l --user $(systemd-escape \
		--template rigctld@.service "$ARGS_CONFIG") | grep "rigctld -")"
		PROCESS="${PROCESS:2}"
		local PID=$(echo "$PROCESS" | awk '{print $1}')
		local CMD="$(ps -o args= $PID)"
		local TOKEN="${CMD##*-m }"
		local RIG_NUM="${TOKEN%% *}"
		source $RIGS_FILE
		local MAKE_MODEL="${RIGS_ARRAY[$RIG_NUM]}"
		TOKEN="${CMD##*-r }"
		[[ -n $TOKEN ]] && local DEVICE="${TOKEN%% *}"
		TOKEN="${CMD##*-s }"
		[[ -n $TOKEN ]] && local SPEED="${TOKEN%% *}"
		case $RIG_NUM in
			1|2|4|6)
				Message "rigctld is running. Rig # ${RIG_NUM} $MAKE_MODEL"
				echo "$RIG_NUM:Not Applicable:Not Applicable"
				;;
			*)
				Message "rigctld is running. Rig # ${RIG_NUM} ${MAKE_MODEL} on ${DEVICE} at $SPEED"
				echo "$RIG_NUM:${DEVICE##*/}:$SPEED"
				;;
		esac
	else
		Message "rigctld is not running."
		echo ""
	fi
}
export -f rigctldStatus

function restartRigctld () {
	source $RIGS_FILE
	local RIG_NUM=$(declare -p RIGS_ARRAY | sed -n "s|.*\[\(.*\)\]=\"${1}\".*|\1|p")
	if ! [[ $RIG_NUM =~ ^[0-9] ]]
	then
		Message "ERROR: Invalid Rig: ${1}"
		return 1
	fi
	case $RIG_NUM in
		1|2|4|6) # Hamlib dummy and FLRig "rigs" don't use a serial port
			PORT=""
			SPEED=""
			Message "Serial port, speed not needed. Setting to Not Applicable"
			;;
		*)
			if [[ ${3} =~ ^Not || ${4} =~ ^Not ]]
			then
				Message "ERROR: Rig ${1} requries a serial port and speed"
				return 1
			fi
			#PORT="-r /dev/serial/by-id/${2}"
			# Strip out any newlines inserted when the yad combobox entries were created
			PORT="-r $(tr -d '\n' <<<${2})"
			SPEED="-s ${3}"
			;;
	esac
	eval $(grep RIGCTLD_PORT $ARGS_CONFIG)
	if [[ -n "$RIGCTLD_PORT" ]]
	then
		argModify RIGCTLD_ARGS=\"-v -t $RIGCTLD_PORT -m $RIG_NUM $PORT $SPEED\"
	else
		argModify RIGCTLD_ARGS=\"-v -m $RIG_NUM $PORT $SPEED\"
	fi
	eval $(grep RIGCTLD_ARGS $ARGS_CONFIG)
	stopRigctld
	if systemctl --user start $(systemd-escape --template rigctld@.service "$ARGS_CONFIG")
	then
		Message "rigctld $RIGCTLD_ARGS for $1 started successfully."
	else
		Message "ERROR starting rigctld $RIGCTLD_ARGS for $1"
		return 1
	fi
	return 0    		
}
export -f restartRigctld

function stopRigctld () {
	systemctl --user stop $(systemd-escape --template rigctld@.service "$ARGS_CONFIG")
	Message "rigctld stopped."
}
export -f stopRigctld

function getSerialPorts() {
	# Returns '|' list of the basenames of all files /dev/serial/by-id 
	PORTS="Not Applicable|"
	local MAXLEN=60
	for P in /dev/tty[US]* $(find /dev -lname "*tty[US]*")
	do
   	if ! [[ $P =~ /dev/char ]]
   	then
   		# Tag the default port
  			[[ -n $1 && $P =~ $1 ]] && P="^$P"
   		# Wrap if lines exceed MAXLEN so that GUI doesn't get too long
   		if [[ ${#P} -gt $MAXLEN ]]
   		then
  				P="$(sed -r "s/.{$MAXLEN}/&\n/g" <<<$P)"
   		fi
   		PORTS+="$P|"
		fi
	done
	echo -e "$PORTS" | sed -e 's/|$//'
}

function getSpeeds() {
	# Returns '|' list of serial port speeds
	SPEEDs="Not Applicable|300|1200|2400|4800|9600|19200|38400|57600|115200"
	[[ $1 != "" && $SPEEDs =~ $1 ]] && echo "$SPEEDs" | sed -e "s/$1/^$1/" || echo "$SPEEDs"
}

#============================
#  FILES AND VARIABLES
#============================

# Set Temp Directory
# -----------------------------------
# Create temp directory with three random numbers and the process ID
# in the name.  This directory is removed automatically at exit.
# -----------------------------------
TMPDIR="/tmp/${SCRIPT_NAME}.$RANDOM.$RANDOM.$RANDOM.$$"
(umask 077 && mkdir "${TMPDIR}") || {
  Die "Could not create temporary directory! Exiting."
}

  #== general variables ==#
SCRIPT_NAME="$(basename ${0})" # scriptname without path
SCRIPT_DIR="$( cd $(dirname "$0") && pwd )" # script directory
SCRIPT_FULLPATH="${SCRIPT_DIR}/${SCRIPT_NAME}"
SCRIPT_ID="$(ScriptInfo | grep script_id | tr -s ' ' | cut -d' ' -f3)"
SCRIPT_HEADSIZE=$(grep -sn "^# END_OF_HEADER" ${0} | head -1 | cut -f1 -d:)
VERSION="$(ScriptInfo version | grep version | tr -s ' ' | cut -d' ' -f 4)"

TITLE="Hamlib Rig Control (rigctld) Manager $VERSION"
CONFIG_DIR="$TMPDIR"
[[ -f "$HOME/rigctld.conf" ]] && mv "$HOME/rigctld.conf" "$CONFIG_DIR/"
CONFIG_FILE="$CONFIG_DIR/rigctld.conf"
DEFAULT_ARGS_CONF="$HOME/.config/nexus/args.conf"
MESSAGE="Hamlib rigctld Configuration"

TERM_PIPE=$TMPDIR/termpipe
mkfifo $TERM_PIPE
exec 5<> $TERM_PIPE
export RIGCTL_LOG="$TMPDIR/rigctld.log"
touch $RIGCTL_LOG
export RIGS_FILE="$TMPDIR/rigs"
fkey=$(($RANDOM * $$))

#============================
#  PARSE OPTIONS WITH GETOPTS
#============================
  
#== set short options ==#
SCRIPT_OPTS=':hv-:'

#== set long options associated with short one ==#
typeset -A ARRAY_OPTS
ARRAY_OPTS=(
	[help]=h
	[version]=v
)

LONG_OPTS="^($(echo "${!ARRAY_OPTS[@]}" | tr ' ' '|'))="

# Parse options
while getopts ${SCRIPT_OPTS} OPTION
do
	# Translate long options to short
	if [[ "x$OPTION" == "x-" ]]
	then
		LONG_OPTION=$OPTARG
		LONG_OPTARG=$(echo $LONG_OPTION | egrep "$LONG_OPTS" | cut -d'=' -f2-)
		LONG_OPTIND=-1
		[[ "x$LONG_OPTARG" = "x" ]] && LONG_OPTIND=$OPTIND || LONG_OPTION=$(echo $OPTARG | cut -d'=' -f1)
		[[ $LONG_OPTIND -ne -1 ]] && eval LONG_OPTARG="\$$LONG_OPTIND"
		OPTION=${ARRAY_OPTS[$LONG_OPTION]}
		[[ "x$OPTION" = "x" ]] &&  OPTION="?" OPTARG="-$LONG_OPTION"
		
		if [[ $( echo "${SCRIPT_OPTS}" | grep -c "${OPTION}:" ) -eq 1 ]]; then
			if [[ "x${LONG_OPTARG}" = "x" ]] || [[ "${LONG_OPTARG}" = -* ]]; then 
				OPTION=":" OPTARG="-$LONG_OPTION"
			else
				OPTARG="$LONG_OPTARG";
				if [[ $LONG_OPTIND -ne -1 ]]; then
					[[ $OPTIND -le $Optnum ]] && OPTIND=$(( $OPTIND+1 ))
					shift $OPTIND
					OPTIND=1
				fi
			fi
		fi
	fi

	# Options followed by another option instead of argument
	if [[ "x${OPTION}" != "x:" ]] && [[ "x${OPTION}" != "x?" ]] && [[ "${OPTARG}" = -* ]]
	then 
		OPTARG="$OPTION" OPTION=":"
	fi

	# Finally, manage options
	case "$OPTION" in
		h) 
			ScriptInfo full
			exit 0
			;;
		v) 
			ScriptInfo version
			exit 0
			;;
		:) 
			Die "${SCRIPT_NAME}: -$OPTARG: option requires an argument"
			;;
		?) 
			Die "${SCRIPT_NAME}: -$OPTARG: unknown option"
			;;
	esac
done
shift $((${OPTIND} - 1)) ## shift options

# Ensure only one instance of this script is running.
pidof -o %PPID -x $(basename "$0") >/dev/null && exit 1

# Check for required apps.
for A in yad rigctld
do 
	command -v $A >/dev/null 2>&1 || Die "$A is required but not installed."
done

export ARGS_CONFIG=${1:-$DEFAULT_ARGS_CONF}
touch $ARGS_CONFIG
#cat $ARGS_CONFIG
[[ -f $ARGS_CONFIG ]] || SafeExit 1
#SOCAT_PORT=${2:-3333}
#argModify SOCAT_PORT=$SOCAT_PORT

#============================
#  MAIN SCRIPT
#============================

trap SafeExit INT TERM EXIT

declare -A RIGS_ARRAY
RIGS=""
while read -r LINE
do
   INDEX="$(cut -d' ' -f1 <<<"$LINE")"
   VALUE="$(cut -d' ' -f2- <<<"$LINE")"
   RIGS_ARRAY[$INDEX]=$VALUE
   RIGS+="${VALUE}|"
done < <($(command -v rigctl) -l | grep -v '^ Rig' | \
   cut -c-55 | sed -e 's/^ *//' -e 's/ *$//' | \
   tr -s '[:space:]')
RIGS="$(echo "$RIGS" | sed "s/|$//")"
declare -p RIGS_ARRAY > $RIGS_FILE

RUNNING_RIG=$(rigctldStatus)
if [[ -n $RUNNING_RIG ]]
then
	INDEX=$(cut -d: -f1 <<<"$RUNNING_RIG")
	DEFAULT_RIG="${RIGS_ARRAY[$INDEX]}"
	RIGS="$(echo "$RIGS" | sed -e "s/$DEFAULT_RIG/^$DEFAULT_RIG/")"
	DEFAULT_DEVICE="$(cut -d: -f2 <<<"$RUNNING_RIG")"
	DEFAULT_SPEED="$(cut -d: -f3 <<<"$RUNNING_RIG")"
fi

YAD_PIDs=()

yad --plug="$fkey" --tabnum=1 --text-align=center \
    --text="<big><b>Manage Hamlib Rig Control Daemon (rigctld)</b></big>\n \
   <span color='red'><b>Not all rigs are supported by Hamlib!</b></span>\nStart typing \
the make/model of radio in the <b>Select Rig</b> field below then select \
rig from the list. Hamlib and FLRig models don't use the <b>Serial Port</b> or \
<b>Speed</b> settings. Set them to 'Not Applicable' for those models." \
  	--form \
  	--align=right \
 	--columns=2 \
 	--css="$HOME/.config/gtk-3.0/yad.css" \
 	--complete=any \
  	--item-separator="|" \
  	--focus-field=1 \
  	--field="<b>Select Rig</b>":CE "$RIGS" \
  	--field="<b>Serial Port</b>":CB "$(getSerialPorts "$DEFAULT_DEVICE")" \
  	--field="<b>Speed</b>":CB "$(getSpeeds "$DEFAULT_SPEED")" \
  	--field="<b>[Re]start rigctld</b>":FBTN 'bash -c "restartRigctld %1 %2 %3; rigctldStatus >/dev/null"' \
  	--field="<b>Stop rigctld</b>":FBTN 'bash -c "stopRigctld"' \
  	--field="<b>Show rigctld status</b>":FBTN 'bash -c "rigctldStatus >/dev/null"' &
YAD_PIDs+=( $! )
   
yad --plug="$fkey" --tabnum=2 --text-align="center" \
	 --back=black --fore=yellow --text-info \
	 --tail --listen <&5 &
monitor_PID=$!
YAD_PIDs+=( $monitor_PID )
(tail -F --pid=$monitor_PID -q -n 5 $RIGCTL_LOG 2>/dev/null | cat -v >&5) &

yad --paned --key="$fkey" --buttons-layout=center \
  	--borders=10 \
  	--geometry=450x450+10+50 \
  	--focused=1 \
  	--title="$TITLE" \
  	--button="<b>Close</b>"!!"Close this manager, leaving rigctld as-is":1
RETURN_CODE=$?	
   	
case $RETURN_CODE in
  	*) # exit
  		SafeExit 0
  		;;
esac
SafeExit 0
