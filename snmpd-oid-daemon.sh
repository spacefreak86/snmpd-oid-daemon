#!/bin/bash

SCRIPT_PATH=$(readlink -f -- "$BASH_SOURCE")
SCRIPT_DIR=$(dirname "$SCRIPT_PATH")
SCRIPT=$(basename "$SCRIPT_PATH")

# default config
OVERLOAD_SCRIPT="${SCRIPT_DIR}/${SCRIPT%.*}-overload.sh"
DEBUG=false
BASE_OID=.1.3.6.1.4.1.8072.9999.9999
LOG_ENABLED=true
LOG_TAG=${SCRIPT%.*}
DEBUG_LOG_MARKER=


#############################################################################################################
#
# COMMAND LINE
#

function usage() {
  cat <<EOF
Usage: $SCRIPT [-b BASE_OID] [-d] [-m FILE] [-n] [-h]

Mandatory arguments to long options are mandatory for short options too.
  -b, --base=BASE_OID        base OID to operate on, default is '$BASE_OID'
  -d, --debug                enable debug output
  -h, --help                 display this help and exit
  -m, --debug-marker=FILE    debug logs will enabled or disabled during runtime
                             based on the existence of this file
  -o, --overload-script=FILE source file to add or overload data gathering functions
  -n, --no-log               disable logging
  -t, --tag                  mark every line to be logged with the specified tag,
                             default is '$LOG_TAG'
EOF
}

while (( $# > 0 )); do
  arg=$1
  shift
  case "$arg" in
    -b|--base-oid)
      BASE_OID=$1
      shift
      ! [[ $BASE_OID =~ ^(\.[0-9]+)+$ ]] && echo "invalid base OID '$BASE_OID'!" >&2 && exit 1
    ;;
    -d|--debug)
      DEBUG=true
    ;;
    -h|--help)
      usage
      exit 0
    ;;
    -m|--debug-marker)
      DEBUG_LOG_MARKER=$1
      shift
    ;;
    -n|--no-log)
      LOG_ENABLED=false
    ;;
    -o|--overload-script)
      OVERLOAD_SCRIPT=$1
      shift
      [ -z "$OVERLOAD_SCRIP" ] && echo "overload-script is empty!" >&2 && exit 1
    ;;
    -t|--tag)
      LOG_TAG=$1
      shift
      [ -z "$LOG_TAG" ] && echo "log tag is empty!" >&2 && exit 1
    ;;
    *)
      echo "invalid argument '$arg'!" >&2
      usage
      exit 1
    ;;
  esac
done


#############################################################################################################
#
# LOGGING
#

if $LOG_ENABLED; then
  exec {logger}> >(logger --id=$$ -t "$LOG_TAG")
  exec {logger_err}> >(logger --id=$$ -t "$LOG_TAG"-error)
  if $DEBUG; then
    logger_debug=$logger
  elif [ -n "$DEBUG_LOG_MARKER" ]; then
    exec {logger_debug}> >(while read -r line; do test -f "$DEBUG_LOG_MARKER" && echo "$line" >&$logger; done)
  else
    exec {logger_debug}>/dev/null
  fi
else
  exec {logger}>/dev/null
  exec {logger_err}>/dev/null
  exec {logger_debug}>/dev/null
fi

if $DEBUG && [ -t 0 ]; then
  exec {LOG}> >(tee /dev/fd/$logger)
  exec 2> >(tee /dev/fd/$logger_err)
  exec {DEBUGLOG}> >(tee /dev/fd/$logger_debug)
else
  exec {LOG}>&$logger
  exec 2>&$logger_err
  exec {DEBUGLOG}>&$logger_debug
fi


#############################################################################################################
#
# DATA GATHERING FUNCTIONS
#
# These functions are called periodically and gather data for OID trees.
# The resulting data is handed over to the cache by calling 'set_oid' or 'set_oid_list' and pipe
# their output to 'submit_oids'.
# 


# Strips declarations generated by 'declare -p' and writes only the value to stdout.
# This is done to avoid security issues by using 'eval'. We manually declare the variables again at the
# receiving end.
# E.g.  declare -- var="string"    => "string"
#       declare -a var=("string")  => ("string")
#
# It also works around a bug in bash prior to version 4.4, generates wrong declarations for
# arrays and associative arrays.
# E.g.  declare -a var='("string")'        => ("string")
#       declare -A var='(["0"]="string")'  =>  (["0"]="string")
#
function strip_declaration() {
  local decl=$1
  [ -z $decl ] && read -r decl
  decl=${decl#declare -}
  local is_list=false
  [[ $decl =~ ^(a|A ).* ]] && is_list=true
  decl=${decl#*=}
  if $is_list && (( BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4 )); then
    decl=${decl#\'}
    decl=${decl%\'}
  fi
  echo "$decl"
  return 0
}

# Sets type and value for a single OID. Arguments are OID, type and value.
# Its output should be piped to 'submit_oids'.
#
set_oid() {
  echo $1
  echo $2
  echo ${3//[$'\n'$'\r']/}
  return 0
}

# DATA is a two-dimensional array (list of lists) or table. Because this is not supported by the shell, columns are
# represented by declarations of list variables generated by 'declare -p'.
# The names of these variables used during generation do not matter as they get stripped away.
declare -a DATA

# COL_TYPES is a list of column types. It is essential that the number of types in COL_TYPES is equal to
# the number of columns in rows in DATA.
declare -a COL_TYPES

# Sets OID types and values based on base_oid, DATA and COL_TYPES.
# Row and column start indexes are optional arguments and default to 1.
# Its output should be piped to 'submit_oids'.
#
function set_oid_list {
  local base_oid=$1
  local -i row_id=${2:-1}
  local -i col_start_idx=${3:-1}
  local -i col_id type_id
  local row_decl value
  if (( ${#COL_TYPES[@]} == 1 )); then
    for row_decl in "${DATA[@]}"; do
      declare -a row=$(strip_declaration <<<"$row_decl")
      echo $base_oid.$row_id
      echo ${COL_TYPES[0]}
      echo ${row[0]//[$'\n'$'\r']/}
      ((row_id++))
    done
  else
    for row_decl in "${DATA[@]}"; do
      local -a row=$(strip_declaration <<<"$row_decl")
      col_id=$col_start_idx
      type_id=0
      for value in "${row[@]}"; do
        echo $base_oid.$col_id.$row_id
        echo ${COL_TYPES[$type_id]}
        echo ${value//[$'\n'$'\r']/}
        ((col_id++))
        ((type_id++))
      done
      ((row_id++))
    done
  fi
  return 0
}

# Optionally clears provided base OID, reads passed OIDs from stdin, combines them
# in an associative array and writes its declaration to stdout.
#
function submit_oids() {
  local clear_base_oid=${1:-}
  local oid oid_type value
  local -A oids
  local -a type_value
  test -n "$clear_base_oid" && echo CLEAR $clear_base_oid
  while read -r oid; do
    read -r oid_type
    read -r value
    type_value=("$oid_type" "$value")
    oids[$oid]=$(declare -p type_value | strip_declaration)
  done
  if (( ${#oids[@]} > 0 )); then
    echo -n "UPDATE "
    declare -p oids | strip_declaration
  fi
  echo ENDOFDATA
  return 0
}

function gather_multipath_data() {
  DATA=()
  local mp uuid dev_model dev_vendor slave_state_f slave_state
  local -i slave_failed slave_count
  local -a row
  for mp in /sys/devices/virtual/block/dm-*; do
    read -r uuid <$mp/dm/uuid
    [[ $uuid != mpath-* ]] && continue
    slave_failed=0
    slave_count=0
    dev_model=
    dev_vendor=
    for slave_state_f in $mp/slaves/*/device/state; do 
      ((slave_count++))
      read -r slave_state <$slave_state_f
      if [[ $slave_state != "running" ]]; then
        ((slave_failed++))
      else
        read -r dev_vendor <${slave_state_f%state}vendor
        read -r dev_model  <${slave_state_f%state}model
      fi
    done
    row=("${mp##*/}" "${uuid#mpath-}" "$dev_vendor,$dev_model" $slave_count $slave_failed)
    DATA+=("$(declare -p row)")
  done

  submit_oids .2 < <(
    set_oid .2.1.0 gauge "$(date +%s)"
    set_oid .2.2.0 gauge "${#DATA[@]}"
    COL_TYPES=(string string string gauge gauge)
    set_oid_list .2.3.1
  )
  return 0
}

function gather_meminfo_data() {
  local memfree meminactive
  local memfree=0
  if [ -r /proc/meminfo ]; then
    memfree=$(grep MemAvailable: /proc/meminfo)
    if (( $? == 0 )); then
      memfree=${memfree//[^0-9]/}
    else
      memfree=$(grep MemFree: /proc/meminfo)
      meminactive=$(grep Inactive: /proc/meminfo)
      memfree=$((${memfree//[^0-9]/} + ${meminactive//[^0-9]/}))
    fi
  fi
  submit_oids < <(
    set_oid .3.1.0 gauge "$(date +%s)"
    set_oid .3.2.0 string "$memfree"
  )
  return 0
}

function gather_zombies_data() {
  local zombies=$(grep zombie /proc/*/status 2>/dev/null | wc -l)
  submit_oids < <(
    set_oid .4.1.0 gauge "$(date +%s)"
    set_oid .4.2.0 gauge "$zombies"
  )
  return 0
}

function gather_bonding_data() {
  local bond master_state slaves slave slave_state
  local -a row
  DATA=()
  for bond in /sys/devices/virtual/net/bond*; do
    read -r master_state <$bond/bonding/mii_status
    read -r slaves < $bond/bonding/slaves
    for slave in $slaves; do 
      read -r slave_state <$bond/lower_$slave/bonding_slave/mii_status
      row=("${bond##*/}" "$master_state" "$slave" "$slave_state")
      DATA+=("$(declare -p row)")
    done
  done
  submit_oids .5 < <(
    set_oid .5.1.0 gauge "$(date +%s)"
    set_oid .5.2.0 gauge ""${#DATA[@]}
    COL_TYPES=(string string string string)
    set_oid_list .5.3.1
  )
  return 0
}

function gather_filesum_data() {
  DATA=()
  local sum path row
  while read -r sum path; do
    row=("$path" "$sum")
    DATA+=("$(declare -p row)")
  done < <(sha1sum /etc/passwd /etc/shadow /etc/group /root/.ssh/authorized_keys)
  submit_oids .6 < <(
    set_oid .6.1.0 gauge "$(date +%s)"
    set_oid .6.2.0 gauge "${#DATA[@]}"
    COL_TYPES=(string string)
    set_oid_list .6.3.1
  )
  return 0
}

# Data gathering functions and their refresh delay
declare -A DATA_FUNCS=(
  ["gather_multipath_data"]=60
  ["gather_meminfo_data"]=30
  ["gather_zombies_data"]=30
  ["gather_bonding_data"]=30
  ["gather_filesum_data"]=60
)

#############################################################################################################
#
# OVERLOAD SCRIPT
#
# Source the file specified in OVERLOAD_SCRIPT to overload data gathering functions.
#

if [ -f "$OVERLOAD_SCRIPT" -a -r "$OVERLOAD_SCRIPT" ]; then
  echo "source $OVERLOAD_SCRIPT" >&$LOG
  source "$OVERLOAD_SCRIPT"
else
  echo "overload script '$OVERLOAD_SCRIPT' does not exist or is not readable" >&$DEBUGLOG
fi


#############################################################################################################
#
# MAIN AND ITS HELPER FUNCTIONS
#
# The main logic of the daemon is defined here.
#

# Cache variables for OID data and types
declare -A OIDDATA
declare -A OIDTYPES

# Removes all elements from OIDDATA and OIDTYPES with an OID starting with base_oid.
#
function clear_cached_oid() {
  local base_oid=$1
  local oid
  local count=0
  for oid in ${!OIDDATA[@]}; do
    if [[ $oid == $base_oid.* ]]; then
      unset OIDDATA[$oid]
      unset OIDTYPES[$oid]
      ((count++))
    fi
  done
  echo "cache: removed $count OIDs" >&$DEBUGLOG
  return 0
}

# Reads the output of 'submit_oids' and updates the OIDDATA and OIDTYPES arrays accordingly.
# If warmup is set to true, it waits for all gathering functions to return data
# before it returns, otherwise it just waits for a single one and returns.
#
function update_oid_cache() {
  local warmup=${1:-false}
  local line base_oid oid
  while :; do
    read -r line || exit 255
    echo "cache: received: $line" >&$DEBUGLOG
    case "$line" in
      "CLEAR "?*)
        base_oid=${line#CLEAR }
        clear_cached_oid "${base_oid}"
      ;;
      "UPDATE "?*)
        local -A oids=${line#UPDATE }
        for oid in $(sort -V <<< "$(printf "%s\n" ${!oids[@]})"); do
          local -a type_value=${oids[$oid]}
          OIDTYPES[$oid]=${type_value[0]}
          OIDDATA[$oid]=${type_value[1]}
          echo "cache: update $oid = ${type_value[0]}: ${type_value[1]}" >&$DEBUGLOG
        done
      ;;
      "ENDOFDATA")
        $warmup || break
      ;;
      STARTUPDONE)
        break
      ;;
      *)
        echo "cache: received invalid line" >&$DEBUGLOG
      ;;
    esac
  done
  return 0
}

function snmp_echo() {
  local value
  for value in "$@"; do
    echo "> $value" >&$DEBUGLOG
    echo "$value"
  done
  return 0
}

function req_from_oid() {
  local oid=$1
  declare -gn var=$2
  var=${oid#$BASE_OID}
  if (( ${#var} == ${#oid} )); then
    echo "$oid is not part of our base OID" >&$DEBUGLOG
    snmp_echo NONE
    return 1
  fi
  [ -z $var ] && var=".0"
  return 0
}

function return_oid() {
  local req=$1
  snmp_echo "$BASE_OID$req" "${OIDTYPES[$req]}" "${OIDDATA[$req]}"
  return 0
}

# Main logic of the daemon.
#
function main() {
  local buf line cmd oid req next
  local -a args

  echo "waiting for all data gathering functions to return data" >&$LOG
  update_oid_cache true

  echo "daemon started (BASE_OID: $BASE_OID)" >&$LOG
  while :; do
    while read -t 0; do
      update_oid_cache
    done
    read -r -t 1 -u $STDIN buf
    rc=$?
    if (( rc > 128 )); then
      if [ -n "$buf" ]; then
        line+=$buf
        echo "< $buf (partial line: '$line')" >&$DEBUGLOG
      fi
      continue
    elif (( rc == 0 )); then
      line+=$buf
      echo "< $line" >&$DEBUGLOG
    else
      exit 255
    fi

    if [ -z $cmd ]; then
      cmd=$line
      args=()
    elif [ -z $line ]; then
      cmd=""
      args=()
      line=""
      snmp_echo NONE
      continue
    else
      args+=("$line")
    fi
    line=""
    case "${cmd,,}" in
      ping)
        cmd=""
        snmp_echo PONG 
      ;;
      set)
        # we need to args here, 'oid' and 'type_and_value'
        (( ${#args[@]} < 2 )) && continue
        cmd=""
        snmp_echo not-writable
      ;;
      get)
        (( ${#args[@]} < 1 )) && continue
        cmd=""
        oid=${args[0]}
        req_from_oid $oid req || continue
        if [[ ! -v OIDDATA[$req] ]]; then
          echo "$oid not found" >&$DEBUGLOG
          snmp_echo NONE
          continue
        fi
        return_oid "$req"
      ;;
      getnext)
        (( ${#args[@]} < 1 )) && continue
        cmd=""
        oid=${args[0]}
        req_from_oid $oid req || continue
        next=$(printf "%s\n" ${!OIDDATA[@]} $req | sort -V | grep -A1 -E "^$req\$" | tail -n 1)
        echo "evaluated next candidate: [requested: '$req', next: '$next']" >&$DEBUGLOG
        if [ -z "$next" -o "$next" == "$req" ]; then
          echo "$oid not found" >&$DEBUGLOG
          snmp_echo NONE
          continue
        fi
        return_oid "$next"
      ;;
      "")
        echo "empty command, exiting ..." >&$LOG
        break
      ;;
      *)
        echo "invalid command '$cmd'" >&2
        cmd=""
      ;;
    esac
  done
  return 0
}


#############################################################################################################
#
# STARTUP
#
# Start the daemon.
# Main is running in a sub-shell, reads commands from stdin and writes results to stdout.
# The main process gathers the data and writes it to the FD DATAIN which is read by main.
#

export PATH=/usr/bin:/bin
shopt -s nullglob

# Redirect stdin a new fd that is used in main.
# This is neccessary because data updates will be piped to main.
exec {STDIN}<&0

# Start main in a sub-shell and create a writable fd to it.
echo "daemon starting (PID: $$)" >&$LOG
exec {DATAIN}> >(main)
pid=$!

trap "echo daemon stopped >&$LOG" EXIT

declare -A timetable
first_run=true
while :; do
  # Check if main is still alive and exit otherwise.
  ps -p $pid > /dev/null || break

  [ -v EPOCHSECONDS ] && now=$EPOCHSECONDS || now=$(date +%s)
  for func in "${!DATA_FUNCS[@]}"; do
    if (( now >= ${timetable[$func]:-0} )); then
      delay=${DATA_FUNCS[$func]}
      next_update=$((now + delay))
      timetable[$func]=$next_update
      $first_run && echo "starting $func (refresh every $delay seconds)" >&$LOG
      echo "executing $func, scheduled next refresh at $(date -d @$next_update)" >&$DEBUGLOG
      # execute data gathering function and pipe its output to main
      $func >&$DATAIN
    fi
  done

  # Emit STARTUPDONE to inform main about data availibity from all gatherin functions (warmup).
  $first_run && echo STARTUPDONE >&$DATAIN && first_run=false

  sleep 1
done

exit 0
