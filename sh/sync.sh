#!/usr/bin/env sh
# Sync a FOLDER to google drive forever using labbots/google-drive-upload
# shellcheck source=/dev/null

_usage() {
    printf "%b" "
The script can be used to sync your local folder to google drive.

Utilizes google-drive-upload bash scripts.\n
Usage: ${0##*/} [options.. ]\n
Options:\n
  -d | --directory - Gdrive foldername.\n
  -k | --kill - to kill the background job using pid number ( -p flags ) or used with input, can be used multiple times.\n
  -j | --jobs - See all background jobs that were started and still running.\n
     Use --jobs v/verbose to more information for jobs.\n
  -p | --pid - Specify a pid number, used for --jobs or --kill or --info flags, can be used multiple times.\n
  -i | --info - See information about a specific sync using pid_number ( use -p flag ) or use with input, can be used multiple times.\n
  -t | --time <time_in_seconds> - Amount of time to wait before try to sync again in background.\n
     To set wait time by default, use ${0##*/} -t default='3'. Replace 3 with any positive integer.\n
  -l | --logs - To show the logs after starting a job or show log of existing job. Can be used with pid number ( -p flag ).
     Note: If multiple pid numbers or inputs are used, then will only show log of first input as it goes on forever.
  -a | --arguments - Additional arguments for gupload commands. e.g: ${0##*/} -a '-q -o -p 4 -d'.\n
     To set some arguments by default, use ${0##*/} -a default='-q -o -p 4 -d'.\n
  -fg | --foreground - This will run the job in foreground and show the logs.\n
  -in | --include 'pattern' - Only include the files with the given pattern to upload.\n
       e.g: ${0##*/} local_folder --include "*1*", will only include with files with pattern '1' in the name.\n
  -ex | --exclude 'pattern' - Exclude the files with the given pattern from uploading.\n
       e.g: ${0##*/} local_folder --exclude "*1*", will exclude all files with pattern '1' in the name.\n
  -c | --command 'command name'- Incase if gupload command installed with any other name or to use in systemd service.\n
  --sync-detail-dir 'dirname' - Directory where a job information will be stored.
     Default: ${HOME}/.google-drive-upload\n
  -s | --service 'service name' - To generate systemd service file to setup background jobs on boot.\n
  -D | --debug - Display script command trace, use before all the flags to see maximum script trace.\n
  -h | --help - Display usage instructions.\n"
    exit 0
}

_short_help() {
    printf "No valid arguments provided, use -h/--help flag to see usage.\n"
    exit 0
}

###################################################
# Check if a pid exists by using ps
# Globals: None
# Arguments: 1
#   ${1}" = pid number of a sync job
# Result: return 0 or 1
###################################################
_check_pid() {
    { ps -p "${1}" 2>| /dev/null 1>&2 && return 0; } || return 1
}

###################################################
# Show information about a specific sync job
# Globals: 1 variable, 1 function
#   Variable - SYNC_LIST
#   Functions - _setup_loop_variables
# Arguments: 1
#   ${1}" = pid number of a sync job
#   ${2}" = anything: Prints extra information ( optional )
#   ${3}" = all information about a job ( optional )
# Result: read description
###################################################
_get_job_info() {
    unset local_folder_get_job_info times_get_job_info extra_get_job_info
    pid_get_job_info="${1}" && input_get_job_info="${3:-$(grep "${pid_get_job_info}" "${SYNC_LIST}" || :)}"

    if [ -n "${input_get_job_info}" ]; then
        if times_get_job_info="$(ps -p "${pid_get_job_info}" -o etimes --no-headers)"; then
            printf "\n%s\n" "PID: ${pid_get_job_info}"
            _tmp="${input_get_job_info#*"|:_//_:|"}" && local_folder_get_job_info="${_tmp%%"|:_//_:|"*}"

            printf "Local Folder: %s\n" "${local_folder_get_job_info}"
            printf "Drive Folder: %s\n" "${input_get_job_info##*"|:_//_:|"}"
            printf "Running Since: %s\n" "$(_display_time "${times_get_job_info}")"

            [ -n "${2}" ] && {
                extra_get_job_info="$(ps -p "${pid_get_job_info}" -o %cpu,%mem --no-headers || :)"
                printf "CPU usage:%s\n" "${extra_get_job_info% *}"
                printf "Memory usage: %s\n" "${extra_get_job_info##* }"
                _setup_loop_variables "${local_folder_get_job_info}" "${input_get_job_info##*"|:_//_:|"}"
                printf "Success: %s\n" "$(($(wc -l < "${SUCCESS_LOG}")))"
                printf "Failed: %s\n" "$(($(wc -l < "${ERROR_LOG}")))"
            }
            RETURN_STATUS=0
        else
            RETURN_STATUS=1
        fi
    else
        RETURN_STATUS=11
    fi
    return 0
}

###################################################
# Remove a sync job information from database
# Globals: 2 variables
#   SYNC_LIST, SYNC_DETAIL_DIR
# Arguments: 1
#   ${1} = pid number of a sync job
# Result: read description
###################################################
_remove_job() {
    unset input_remove_job local_folder_remove_job drive_folder_remove_job new_list_remove_job
    pid_remove_job="${1}"

    if [ -n "${pid_remove_job}" ]; then
        input_remove_job="$(grep "${pid_remove_job}" "${SYNC_LIST}" || :)"
        _tmp="${input_remove_job#*"|:_//_:|"}" && local_folder_remove_job="${_tmp%%"|:_//_:|"*}"
        drive_folder_remove_job="${input_remove_job##*"|:_//_:|"}"
        new_list_remove_job="$(grep -v "${pid_remove_job}" "${SYNC_LIST}" || :)"
        printf "%s\n" "${new_list_remove_job}" >| "${SYNC_LIST}"
    fi

    rm -rf "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}${local_folder_remove_job:-${3}}"
    # Cleanup dir if empty
    { [ -z "$(find "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}" -type f)" ] && rm -rf "${SYNC_DETAIL_DIR:?}/${drive_folder_remove_job:-${2}}"; } 2>| /dev/null 1>&2
    return 0
}

###################################################
# Kill a sync job and do _remove_job
# Globals: 1 function
#   _remove_job
# Arguments: 1
#   ${1}" = pid number of a sync job
# Result: read description
###################################################
_kill_job() {
    pid_kill_job="${1}"
    kill -9 "${pid_kill_job}" 2>| /dev/null 1>&2 || :
    _remove_job "${pid_kill_job}"
    printf "Killed.\n"
}

###################################################
# Show total no of sync jobs running
# Globals: 1 variable, 2 functions
#   Variable - SYNC_LIST
#   Functions - _get_job_info, _remove_job
# Arguments: 1
#   ${1}" = v/verbose: Prints extra information ( optional )
# Result: read description
###################################################
_show_jobs() {
    unset list_show_job pid_show_job no_task_show_job
    total_show_job=0 list_show_job="$(grep -v '^$' "${SYNC_LIST}" || :)"
    printf "%s\n" "${list_show_job}" >| "${SYNC_LIST}"

    while read -r line <&4; do
        if [ -n "${line}" ]; then
            _tmp="${line%%"|:_//_:|"*}" && pid_show_job="${_tmp##*: }"
            _get_job_info "${pid_show_job}" "${1}" "${line}"
            { [ "${RETURN_STATUS}" = 1 ] && _remove_job "${pid_show_job}"; } || { total_show_job="$((total_show_job + 1))" && no_task_show_job="printf"; }
        fi
    done 4< "${SYNC_LIST}"

    printf "\nTotal Jobs Running: %s\n" "${total_show_job}"
    [ -z "${1}" ] && "${no_task_show_job:-:}" "For more info: %s -j/--jobs v/verbose\n" "${0##*/}"
    return 0
}

###################################################
# Setup required variables for a sync job
# Globals: 1 Variable
#   SYNC_DETAIL_DIR
# Arguments: 1
#   ${1}" = Local folder name which will be synced
# Result: read description
###################################################
_setup_loop_variables() {
    folder_setup_loop_variables="${1}" drive_folder_setup_loop_variables="${2}"
    DIRECTORY="${SYNC_DETAIL_DIR}/${drive_folder_setup_loop_variables}${folder_setup_loop_variables}"
    PID_FILE="${DIRECTORY}/pid"
    SUCCESS_LOG="${DIRECTORY}/success_list"
    ERROR_LOG="${DIRECTORY}/failed_list"
    LOGS="${DIRECTORY}/logs"
}

###################################################
# Create folder and files for a sync job
# Globals: 4 variables
#   DIRECTORY, PID_FILE, SUCCESS_LOG, ERROR_LOG
# Arguments: None
# Result: read description
###################################################
_setup_loop_files() {
    mkdir -p "${DIRECTORY}"
    for file in PID_FILE SUCCESS_LOG ERROR_LOG; do
        printf "" >> "$(eval printf "%s" \"\$"${file}"\")"
    done
    PID="$(cat "${PID_FILE}")"
}

###################################################
# Check for new files in the sync folder and upload it
# A list is generated everytime, success and error.
# Globals: 4 variables, 1 function
#   Variables - SUCCESS_LOG, ERROR_LOG, COMMAND_NAME, ARGS, GDRIVE_FOLDER
#   Function  - _remove_array_duplicates
# Arguments: None
# Result: read description
###################################################
_check_and_upload() {
    unset all_check_and_upload initial_check_and_upload new_files_check_and_upload new_file_check_and_upload aseen_check_and_upload

    initial_check_and_upload="$(cat "${SUCCESS_LOG}")"
    all_check_and_upload="$(cat "${SUCCESS_LOG}" "${ERROR_LOG}")"

    # check if folder is empty
    [ "$(printf "%b\n" ./*)" = "./*" ] && return 0

    # shellcheck disable=SC2086
    all_check_and_upload="${all_check_and_upload}
$(_tmp='printf -- "%b\n" * '${INCLUDE_FILES:+| grep -E ${INCLUDE_FILES}}'' && eval "${_tmp}")"

    # Open file discriptors for grep
    exec 5<< EOF
$(printf "%s\n" "${initial_check_and_upload}")
EOF
    exec 6<< EOF
$(printf "%s\n" "${all_check_and_upload}")
EOF
    # shellcheck disable=SC2086
    new_files_check_and_upload="$(eval grep -vExf /dev/fd/5 /dev/fd/6 -e '^$' ${EXCLUDE_FILES} || :)"
    # close file discriptos
    exec 5<&- && exec 6<&-

    [ -n "${new_files_check_and_upload}" ] && printf "" >| "${ERROR_LOG}" && {
        while read -r new_file_check_and_upload <&4 &&
            case "${aseen_check_and_upload}" in
                *"|:_//_:|${new_file_check_and_upload}|:_//_:|"*) continue ;;
                *) aseen_check_and_upload="${aseen_check_and_upload}|:_//_:|${new_file_check_and_upload}|:_//_:|" ;;
            esac do
            if eval "\"${COMMAND_PATH}\"" "\"${new_file_check_and_upload}\"" "${ARGS}"; then
                printf "%s\n" "${new_file_check_and_upload}" >> "${SUCCESS_LOG}"
            else
                printf "%s\n" "${new_file_check_and_upload}" >> "${ERROR_LOG}"
                printf "%s\n" "Error: Input - ${new_file_check_and_upload}"
            fi
            printf "\n"
        done 4<< EOF
$(printf "%s\n" "${new_files_check_and_upload}")
EOF
    }
    return 0
}

###################################################
# Loop _check_and_upload function, sleep for sometime in between
# Globals: 1 variable, 1 function
#   Variable - SYNC_TIME_TO_SLEEP
#   Function - _check_and_upload
# Arguments: None
# Result: read description
###################################################
_loop() {
    while :; do
        _check_and_upload
        sleep "${SYNC_TIME_TO_SLEEP}"
    done
}

###################################################
# Check if a loop exists with given input
# Globals: 3 variables, 3 function
#   Variable - FOLDER, PID, GDRIVE_FOLDER
#   Function - _setup_loop_variables, _setup_loop_files, _check_pid
# Arguments: None
# Result: return 0 - No existing loop, 1 - loop exists, 2 - loop only in database
#   if return 2 - then remove entry from database
###################################################
_check_existing_loop() {
    _setup_loop_variables "${FOLDER}" "${GDRIVE_FOLDER}"
    _setup_loop_files
    if [ -z "${PID}" ]; then
        RETURN_STATUS=0
    elif _check_pid "${PID}"; then
        RETURN_STATUS=1
    else
        _remove_job "${PID}"
        _setup_loop_variables "${FOLDER}" "${GDRIVE_FOLDER}"
        _setup_loop_files
        RETURN_STATUS=2
    fi
    return 0
}

###################################################
# Start a new sync job by _loop function
# Print sync job information
# Globals: 7 variables, 1 function
#   Variable - LOGS, PID_FILE, INPUT, GDRIVE_FOLDER, FOLDER, SYNC_LIST, FOREGROUND
#   Function - _loop
# Arguments: None
# Result: read description
#   Show logs at last and don't hangup if SHOW_LOGS is set
###################################################
_start_new_loop() {
    if [ -n "${FOREGROUND}" ]; then
        printf "%b\n" "Local Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}\n"
        trap '_clear_line 1 && printf "\n" && _remove_job "" "${GDRIVE_FOLDER}" "${FOLDER}"; exit' INT TERM
        trap 'printf "Job stopped.\n" ; exit' EXIT
        _loop
    else
        (_loop 2>| "${LOGS}" 1>&2) & # A double fork doesn't get killed if script exits
        PID="${!}"
        printf "%s\n" "${PID}" >| "${PID_FILE}"
        printf "%b\n" "Local Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}\nPID: ${PID}"
        printf "%b\n" "PID: ${PID}|:_//_:|${FOLDER}|:_//_:|${GDRIVE_FOLDER}" >> "${SYNC_LIST}"
        [ -n "${SHOW_LOGS}" ] && printf "\n" && tail -f "${LOGS}"
    fi
    return 0
}

###################################################
# Triggers in case either -j & -k or -l flag ( both -k|-j if with positive integer as argument )
# Priority: -j > -i > -l > -k
# Globals: 5 variables, 6 functions
#   Variables - JOB, SHOW_JOBS_VERBOSE, INFO_PID, LOG_PID, KILL_PID ( all array )
#   Functions - _check_pid, _setup_loop_variables
#               _kill_job, _show_jobs, _get_job_info, _remove_job
# Arguments: None
# Result: show either job info, individual info or kill job(s) according to set global variables.
#   Script exits after -j and -k if kill all is triggered )
###################################################
_do_job() {
    case "${JOB}" in
        *SHOW_JOBS*)
            _show_jobs "${SHOW_JOBS_VERBOSE:-}"
            exit
            ;;
        *KILL_ALL*)
            PIDS="$(_show_jobs | grep -o 'PID:.*[0-9]' | sed "s/PID: //g" || :)" && total=0
            [ -n "${PIDS}" ] && {
                for _pid in ${PIDS}; do
                    printf "PID: %s - " "${_pid##* }"
                    _kill_job "${_pid##* }"
                    total="$((total + 1))"
                done
            }
            printf "\nTotal Jobs Killed: %s\n" "${total}"
            exit
            ;;
        *PIDS*)
            unset Aseen && while read -r pid <&4 && { [ -n "${pid}" ] || continue; } &&
                case "${Aseen}" in
                    *"|:_//_:|${pid}|:_//_:|"*) continue ;;
                    *) Aseen="${Aseen}|:_//_:|${pid}|:_//_:|" ;;
                esac do
                case "${JOB_TYPE}" in
                    *INFO*)
                        _get_job_info "${pid}" more
                        [ "${RETURN_STATUS}" -gt 0 ] && {
                            [ "${RETURN_STATUS}" = 1 ] && _remove_job "${pid}"
                            printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                        }
                        ;;
                esac
                case "${JOB_TYPE}" in
                    *SHOW_LOGS*)
                        input="$(grep "${pid}" "${SYNC_LIST}" || :)"
                        if [ -n "${input}" ]; then
                            _check_pid "${pid}" && {
                                _tmp="${input#*"|:_//_:|"}" && local_folder="${_tmp%%"|:_//_:|"*/}"
                                _setup_loop_variables "${local_folder}" "${input##*"|:_//_:|"/}"
                                tail -f "${LOGS}"
                            }
                        else
                            printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                        fi
                        ;;
                esac
                case "${JOB_TYPE}" in
                    *KILL*)
                        _get_job_info "${pid}"
                        if [ "${RETURN_STATUS}" = 0 ]; then
                            _kill_job "${pid}"
                        else
                            [ "${RETURN_STATUS}" = 1 ] && _remove_job "${pid}"
                            printf "No job running with given PID ( %s ).\n" "${pid}" 1>&2
                        fi
                        ;;
                esac
            done 4<< EOF
$(printf "%s\n" "${ALL_PIDS}")
EOF
            case "${JOB_TYPE}" in
                *INFO* | *SHOW_LOGS* | *KILL*) exit 0 ;;
            esac
            ;;
    esac
    return 0
}

###################################################
# Process all arguments given to the script
# Globals: 1 variable, 4 functions
#   Variable - HOME
#   Functions - _kill_jobs, _show_jobs, _get_job_info, _remove_array_duplicates
# Arguments: Many
#   ${@} = Flags with arguments
# Result: On
#   Success - Set all the variables
#   Error   - Print error message and exit
###################################################
_setup_arguments() {
    [ $# = 0 ] && printf "Missing arguments\n" && return 1
    unset SYNC_TIME_TO_SLEEP ARGS COMMAND_NAME DEBUG GDRIVE_FOLDER KILL SHOW_LOGS
    COMMAND_NAME="gupload"

    _check_longoptions() {
        [ -z "${2}" ] &&
            printf '%s: %s: option requires an argument\nTry '"%s -h/--help"' for more information.\n' "${0##*/}" "${1}" "${0##*/}" &&
            exit 1
        return 0
    }

    while [ $# -gt 0 ]; do
        case "${1}" in
            -h | --help) _usage ;;
            -D | --debug) DEBUG="true" && export DEBUG && _check_debug ;;
            -d | --directory)
                _check_longoptions "${1}" "${2}"
                GDRIVE_FOLDER="${2}" && shift
                ARGS=" ${ARGS} -C \"${GDRIVE_FOLDER}\" "
                ;;
            -j | --jobs)
                case "${2}" in
                    v*) SHOW_JOBS_VERBOSE="true" && shift ;;
                esac
                JOB="SHOW_JOBS"
                ;;
            -p | --pid)
                _check_longoptions "${1}" "${2}"
                if [ "${2}" -gt 0 ] 2>| /dev/null 1>&2; then
                    ALL_PIDS="${ALL_PIDS}
                              ${2}" && shift
                    JOB=" ${JOBS} PIDS "
                else
                    printf "%s\n" "-p/--pid only takes postive integer as arguments."
                    exit 1
                fi
                ;;
            -i | --info) JOB_TYPE=" ${JOB_TYPE} INFO " && INFO="true" ;;
            -k | --kill)
                JOB_TYPE=" ${JOB_TYPE} KILL " && KILL="true"
                [ "${2}" = all ] && JOB="KILL_ALL" && shift
                ;;
            -l | --logs) JOB_TYPE=" ${JOB_TYPE} SHOW_LOGS " && SHOW_LOGS="true" ;;
            -t | --time)
                _check_longoptions "${1}" "${2}"
                if [ "${2}" -gt 0 ] 2>| /dev/null 1>&2; then
                    case "${2}" in
                        default*) UPDATE_DEFAULT_TIME_TO_SLEEP="_update_config" ;;
                    esac
                    TO_SLEEP="${2##default=/}" && shift
                else
                    printf "%s\n" "-t/--time only takes positive integers as arguments, min = 1, max = infinity."
                    exit 1
                fi
                ;;
            -a | --arguments)
                _check_longoptions "${1}" "${2}"
                case "${2}" in
                    default*) UPDATE_DEFAULT_ARGS="_update_config" ;;
                esac
                ARGS=" ${ARGS} ${2##default=} " && shift
                ;;
            -fg | --foreground) FOREGROUND="true" && SHOW_LOGS="true" ;;
            -in | --include)
                _check_longoptions "${1}" "${2}"
                INCLUDE_FILES="${INCLUDE_FILES} -e '${2}' " && shift
                ;;
            -ex | --exclude)
                _check_longoptions "${1}" "${2}"
                EXCLUDE_FILES="${EXCLUDE_FILES} -e '${2}' " && shift
                ;;
            -c | --command)
                _check_longoptions "${1}" "${2}"
                CUSTOM_COMMAND_NAME="${2}" && shift
                ;;
            --sync-detail-dir)
                _check_longoptions "${1}" "${2}"
                SYNC_DETAIL_DIR="${2}" && shift
                ;;
            -s | --service)
                _check_longoptions "${1}" "${2}"
                SERVICE_NAME="${2}" && shift
                CREATE_SERVICE="true"
                ;;
            *)
                # Check if user meant it to be a flag
                case "${1}" in
                    -*) printf '%s: %s: Unknown option\nTry '"%s -h/--help"' for more information.\n' "${0##*/}" "${1}" "${0##*/}" && exit 1 ;;
                    *) # If no "-" is detected in 1st arg, it adds to input
                        FINAL_INPUT_ARRAY="${FINAL_INPUT_ARRAY}
                                           ${1}"
                        ;;
                esac
                ;;
        esac
        shift
    done

    INFO_PATH="${HOME}/.google-drive-upload"
    CONFIG_INFO="${INFO_PATH}/google-drive-upload.configpath"
    [ -f "${CONFIG_INFO}" ] && . "${CONFIG_INFO}"
    CONFIG="${CONFIG:-${HOME}/.googledrive.conf}"
    SYNC_DETAIL_DIR="${SYNC_DETAIL_DIR:-${INFO_PATH}/sync}"
    SYNC_LIST="${SYNC_DETAIL_DIR}/sync_list"
    mkdir -p "${SYNC_DETAIL_DIR}" && printf "" >> "${SYNC_LIST}"

    _do_job

    [ -z "${FINAL_INPUT_ARRAY}" ] && _short_help

    return 0
}

###################################################
# Grab config variables and modify defaults if necessary
# Globals: 5 variables, 2 functions
#   Variables - INFO_PATH, UPDATE_DEFAULT_CONFIG, DEFAULT_ARGS
#               UPDATE_DEFAULT_ARGS, UPDATE_DEFAULT_TIME_TO_SLEEP, TIME_TO_SLEEP
#   Functions - _print_center, _update_config
# Arguments: None
# Result: grab COMMAND_NAME, INSTALL_PATH, and CONFIG
#   source CONFIG, update default values if required
###################################################
_config_variables() {
    COMMAND_NAME="${CUSTOM_COMMAND_NAME:-${COMMAND_NAME}}"
    VALUES_LIST="REPO COMMAND_NAME SYNC_COMMAND_NAME INSTALL_PATH TYPE TYPE_VALUE"
    VALUES_REGEX="" && for i in ${VALUES_LIST}; do
        VALUES_REGEX="${VALUES_REGEX:+${VALUES_REGEX}|}^${i}=\".*\".* # added values"
    done

    # Check if command exist, not necessary but just in case.
    {
        COMMAND_PATH="$(command -v "${COMMAND_NAME}")" 1> /dev/null &&
            SCRIPT_VALUES="$(grep -E "${VALUES_REGEX}|^SELF_SOURCE=\".*\"" "${COMMAND_PATH}" || :)" && eval "${SCRIPT_VALUES}" &&
            [ -n "${REPO:+${COMMAND_NAME:+${INSTALL_PATH:+${TYPE:+${TYPE_VALUE}}}}}" ] && unset SOURCED_GUPLOAD
    } || { printf "Error: %s is not installed, use -c/--command to specify.\n" "${COMMAND_NAME}" 1>&2 && exit 1; }

    ARGS=" ${ARGS} -q "
    SYNC_TIME_TO_SLEEP="3"
    # Config file is created automatically after first run
    # shellcheck source=/dev/null
    [ -r "${CONFIG}" ] && . "${CONFIG}"

    SYNC_TIME_TO_SLEEP="${TO_SLEEP:-${SYNC_TIME_TO_SLEEP}}"
    ARGS=" ${ARGS} ${SYNC_DEFAULT_ARGS:-} "
    "${UPDATE_DEFAULT_ARGS:-:}" SYNC_DEFAULT_ARGS " ${ARGS} " "${CONFIG}"
    "${UPDATE_DEFAULT_TIME_TO_SLEEP:-:}" SYNC_TIME_TO_SLEEP "${SYNC_TIME_TO_SLEEP}" "${CONFIG}"
    return 0
}

###################################################
# Print systemd service file contents
# Globals: 5 variables
# Variables - LOGNAME, INSTALL_PATH, COMMAND_NAME, SYNC_COMMAND_NAME, ALL_ARGUMNETS
# Arguments: None
###################################################
_systemd_service_contents() {
    username_systemd_service_contents="${LOGNAME:?Give username}" install_path_systemd_service_contents="${INSTALL_PATH:?Missing install path}"
    cmd_systemd_service_contents="${COMMAND_NAME:?Missing command name}" sync_cmd_systemd_service_contents="${SYNC_COMMAND_NAME:?Missing gsync cmd name}"
    all_argumnets_systemd_service_contents="${ALL_ARGUMNETS:-}"

    printf "%s\n" '# Systemd service file - start
[Unit]
Description=google-drive-upload synchronisation service
After=network.target

[Service]
Type=simple
User='"${username_systemd_service_contents}"'
Restart=on-abort
RestartSec=3
ExecStart="'"${install_path_systemd_service_contents}/${sync_cmd_systemd_service_contents}"'" --foreground --command "'"${install_path_systemd_service_contents}/${cmd_systemd_service_contents}"'" --sync-detail-dir "/tmp/sync" '"${all_argumnets_systemd_service_contents}"'

# Security
PrivateTmp=true
ProtectSystem=full
NoNewPrivileges=true
ProtectControlGroups=true
ProtectKernelModules=true
ProtectKernelTunables=true
PrivateDevices=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
RestrictNamespaces=true
RestrictRealtime=true
SystemCallArchitectures=native

[Install]
WantedBy=multi-user.target
# Systemd service file - end'
}

###################################################
# Create systemd service wrapper script for managing the service
# Globals: None
# Arguments: 3
#   ${1} = Service name
#   ${1} = Service file contents
#   ${1} = Script name
# Result: print the script contents to script file
###################################################
_systemd_service_script() {
    name_systemd_service_script="${1:?Missing service name}" script_systemd_service_script=""
    service_file_contents_systemd_service_script="${2:?Missing service file contents}" script_name_systemd_service_script="${3:?Missing script name}"

    # shellcheck disable=SC2016
    script_systemd_service_script='#!/usr/bin/env sh
set -e

_usage() {
    printf "%b" "# Service name: '"'${name_systemd_service_script}'"'

# Print the systemd service file contents
sh \"${0##*/}\" print\n
# Add service to systemd files ( this must be run before doing any of the below )
sh \"${0##*/}\" add\n
# Start or Stop the service
sh \"${0##*/}\" start / stop\n
# Enable or Disable as a boot service:
sh \"${0##*/}\" enable / disable\n
# See logs
sh \"${0##*/}\" logs\n
# Remove the service from system
sh \"${0##*/}\" remove\n\n"

    _status
    exit 0
}

_status() {
    status_status="" current_status_status=""
    status_status="$(systemctl status '"'${name_systemd_service_script}'"' 2>&1 || :)"
    current_status_status="$(printf "%s\n" "${status_status}" | env grep -E "●.*|(Loaded|Active|Main PID|Tasks|Memory|CPU): .*" || :)"

    printf "%s\n" "Current status of service: ${current_status_status:-${status_status}}"
    return 0
}

unset TMPFILE

[ $# = 0 ] && _usage

CONTENTS='"'${service_file_contents_systemd_service_script}'"'

_add_service() {
    service_file_path_add_service="/etc/systemd/system/'"${name_systemd_service_script}"'.service"
    printf "%s\n" "Service file path: ${service_file_path_add_service}"
    if [ -f "${service_file_path_add_service}" ]; then
        printf "%s\n" "Service file already exists. Overwriting"
        sudo mv "${service_file_path_add_service}" "${service_file_path_add_service}.bak" || exit 1
        printf "%s\n" "Existing service file was backed up."
        printf "%s\n" "Old service file: ${service_file_path_add_service}.bak"
    else
        [ -z "${TMPFILE}" ] && {
        { { command -v mktemp 1>| /dev/null && TMPFILE="$(mktemp -u)"; } ||
                TMPFILE="$(pwd)/.$(_t="$(date +"%s")" && printf "%s\n" "$((_t * _t))").LOG"; } || exit 1
        }
        export TMPFILE
        trap "exit" INT TERM
        _rm_tmpfile() { rm -f "${TMPFILE:?}" ; }
        trap "_rm_tmpfile" EXIT
        trap "" TSTP # ignore ctrl + z

        { printf "%s\n" "${CONTENTS}" >|"${TMPFILE}" && sudo cp "${TMPFILE}" /etc/systemd/system/'"${name_systemd_service_script}"'.service; } ||
            { printf "%s\n" "Error: Failed to add service file to system." && exit 1 ;}
    fi
    sudo systemctl daemon-reload || printf "%s\n" "Could not reload the systemd daemon."
    printf "%s\n" "Service file was successfully added."
    return 0
}

_service() {
    service_name_service='"'${name_systemd_service_script}'"' action_service="${1:?}" service_file_path_service=""
    service_file_path_service="/etc/systemd/system/${service_name_service}.service"
    printf "%s\n" "Service file path: ${service_file_path_service}"
    [ -f "${service_file_path_service}" ] || { printf "%s\n" "Service file does not exist." && exit 1; }
    sudo systemctl daemon-reload || exit 1
    case "${action_service}" in
        log*) sudo journalctl -u "${service_name_service}" -f ;;
        rm | remove)
            sudo systemctl stop "${service_name_service}" || :
            if  sudo rm -f /etc/systemd/system/"${service_name_service}".service; then
                sudo systemctl daemon-reload || :
                printf "%s\n" "Service removed." && return 0
            else
                printf "%s\n" "Error: Cannot remove." && exit 1
            fi
            ;;
        *)
            success_service="${2:?}" error_service="${3:-}"
            if sudo systemctl "${action_service}" "${service_name_service}"; then
                printf "%s\n" "Success: ${service_name_service} ${success_service}." && return 0
            else
                printf "%s\n" "Error: Cannot ${action_service} ${service_name_service} ${error_service}." && exit 1
            fi
            ;;
    esac
    return 0
}

while [ "${#}" -gt 0 ]; do
    case "${1}" in
        print) printf "%s\n" "${CONTENTS}" ;;
        add) _add_service ;;
        start) _service start started ;;
        stop) _service stop stopped ;;
        enable) _service enable "boot service enabled" "boot service" ;;
        disable) _service disable "boot service disabled" "boot service" ;;
        logs) _service logs ;;
        remove) _service rm ;;
        *) printf "%s\n" "Error: No valid options provided." && _usage ;;
    esac
    shift
done'
    printf "%s\n" "${script_systemd_service_script}" >| "${script_name_systemd_service_script}"
    return 0
}

###################################################
# Process all the values in "${FINAL_INPUT_ARRAY[@]}"
# Globals: 20 variables, 15 functions
#   Variables - FINAL_INPUT_ARRAY ( array ), DEFAULT_ACCOUNT, ROOT_FOLDER_NAME, GDRIVE_FOLDER
#               PID_FILE, SHOW_LOGS, LOGS, KILL, INFO, CREATE_SERVICE, ARGS, SERVICE_NAME
# Functions - _set_value, _systemd_service_script, _systemd_service_contents, _print_center, _check_existing_loop, _start_new_loop
# Arguments: None
# Result: Start the sync jobs for given folders, if running already, don't start new.
#   If a pid is detected but not running, remove that job.
#   If service script is going to be created then don,t touch the jobs
###################################################
_process_arguments() {
    unset status_process_arguments_process_arguments current_folder_process_arguments_process_arguments Aseen
    while read -r INPUT <&4 && { [ -n "${INPUT}" ] || continue; } &&
        case "${Aseen}" in
            *"|:_//_:|${INPUT}|:_//_:|"*) continue ;;
            *) Aseen="${Aseen}|:_//_:|${INPUT}|:_//_:|" ;;
        esac do
        ! [ -d "${INPUT}" ] && printf "\nError: Invalid Input ( %s ), no such directory.\n" "${INPUT}" && continue
        current_folder_process_arguments="$(pwd)"
        FOLDER="$(cd "${INPUT}" && pwd)" || exit 1
        [ -n "${DEFAULT_ACCOUNT}" ] && _set_value indirect ROOT_FOLDER_NAME "ACCOUNT_${DEFAULT_ACCOUNT}_ROOT_FOLDER_NAME"
        GDRIVE_FOLDER="${GDRIVE_FOLDER:-${ROOT_FOLDER_NAME:-Unknown}}"

        [ -n "${CREATE_SERVICE}" ] && {
            ALL_ARGUMNETS="\"${FOLDER}\" ${TO_SLEEP:+-t \"${TO_SLEEP}\"} -a \"${ARGS}\""
            num_process_arguments="${num_process_arguments+$(printf "%s\n" $((num_process_arguments + 1)))}"
            service_name_process_arguments="gsync-${SERVICE_NAME}${num_process_arguments:+_${num_process_arguments}}"
            script_name_process_arguments="${service_name_process_arguments}.service.sh"
            _systemd_service_script "${service_name_process_arguments}" "$(_systemd_service_contents)" "${script_name_process_arguments}"

            _print_center "normal" "=" "="
            sh "${script_name_process_arguments}"
            _print_center "normal" "=" "="
            continue
        }

        cd "${FOLDER}" || exit 1
        _check_existing_loop
        case "${RETURN_STATUS}" in
            0 | 2) _start_new_loop ;;
            1)
                printf "%b\n" "Job is already running.."
                if [ -n "${INFO}" ]; then
                    _get_job_info "${PID}" more "PID: ${PID}|:_//_:|${FOLDER}|:_//_:|${GDRIVE_FOLDER}"
                else
                    printf "%b\n" "Local Folder: ${INPUT}\nDrive Folder: ${GDRIVE_FOLDER}"
                    printf "%s\n" "PID: ${PID}"
                fi

                [ -n "${KILL}" ] && _kill_job "${PID}" && exit
                [ -n "${SHOW_LOGS}" ] && tail -f "${LOGS}"
                ;;
        esac
        cd "${current_folder_process_arguments}" || exit 1
    done 4<< EOF
$(printf "%s\n" "${FINAL_INPUT_ARRAY}")
EOF
    return 0
}

main() {
    [ $# = 0 ] && _short_help

    set -o errexit -o noclobber

    if [ -z "${SELF_SOURCE}" ]; then
        UTILS_FOLDER="${UTILS_FOLDER:-${PWD}}" && SOURCE_UTILS=". '${UTILS_FOLDER}/common-utils.sh'"
        eval "${SOURCE_UTILS}" || { printf "Error: Unable to source util files.\n" && exit 1; }
    fi

    trap '' TSTP # ignore ctrl + z

    _setup_arguments "${@}"
    _check_debug
    _config_variables
    _process_arguments
}

main "${@}"
