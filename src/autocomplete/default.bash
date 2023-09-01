#!/usr/bin/env bash

# Basic bash completion script. Con4m should start generating these.
# Until then, maintain it manually.
#
# :Author: John Viega (john@crashoverride.com)
# :Copyright: 2023, Crash Override, Inc.


function _chalk_setup_either {
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --store-password --no-store-password --key-file" -- ${_CHALK_CUR_WORD}))
}

function _chalk_setup_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        gen)
            _chalk_setup_either
            ;;
        load)
            _chalk_setup_either
            ;;
        *)
            COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --store-password --key-file gen load" -- ${_CHALK_CUR_WORD}))
            ;;
        esac
}

function _chalk_delete_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults--use-report-cache --no-use-report-cache --dry-run --no-dry-run --no-dry-run --debug --no-debug --skip-command-report --no-skip-command-report --recursive --no-recursive --artifact-profile --host-profile" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
    fi
}

function _chalk_load_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --debug --no-debug --validation --no-validation --validation-warning --no-validation-warning" -- ${_CHALK_CUR_WORD}))
    fi

    if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
        if [ ${COMP_WORDS[${_CHALK_CUR_IX}]::1}  = "-" ] ; then
            _chalk_shift_one
            _chalk_load_completions
        fi
        # Else, already got a file name so nothing to complete.
    else
        _filedir
    fi
}

function _chalk_exec_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
        COMPREPLY=($(compgen -W "-- --color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --exec-command-name --chalk-as-parent --no-chalk-as-parent --heartbeat --no-heartbeat --artifact-profile -host-profile" -- ${_CHALK_CUR_WORD}))
    else
        if [ ${_CHALK_PREV} = "--exec-command-name" ] ; then
            _command
        fi
    fi
}

function _chalk_help_completions {
    COMPREPLY=($(compgen -W "builtins key keyspec profile tool plugin sink outconf custom_report sbom sast" -- ${_CHALK_CUR_WORD}))
}

function _chalk_extract_completions {
    if [[ ${_CHALK_CUR_WORD::1} = "-" ]] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --debug --no-debug --skip-command-report --no-skip-command-report --recursive --no-recursive --artifact-profile --host-profile --search-layers --no-search-layers" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
        EXTRA=($(compgen -W "images containers all" -- ${_CHALK_CUR_WORD}))
        COMPREPLY+=(${EXTRA[@]})
    fi
}

function _chalk_insert_completions {
    if [ ${_CHALK_CUR_WORD::1} = "-" ] ; then
    COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --run-sbom-tools --no-run-sbom-tools --run-sast-tools --no-run-sast-tools --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --recursive --no-recursive --artifact-profile --host-profile --chalk-profile" -- ${_CHALK_CUR_WORD}))
    else
        _filedir
    fi
}

function _chalk_toplevel_completions {
    case ${COMP_WORDS[${_CHALK_CUR_IX}]} in
        insert)
            _chalk_shift_one
            _chalk_insert_completions
            ;;
        extract)
            _chalk_shift_one
            _chalk_extract_completions
            ;;
        delete)
            _chalk_shift_one
            _chalk_delete_completions
            ;;
        env)
            _chalk_shift_one
            _chalk_env_completions
            ;;
        exec)
            _chalk_shift_one
            _chalk_exec_completions
            ;;
        defaults)
            _chalk_shift_one
            _chalk_defaults_completions
            ;;
        profile)
            _chalk_shift_one
            _chalk_profile_completions
            ;;
        dump)
            _chalk_shift_one
            _chalk_dump_completions
            ;;
        load)
            _chalk_shift_one
            _chalk_load_completions
            ;;
        version)
            _chalk_shift_one
            _chalk_version_completions
            ;;
        docker)
            _chalk_shift_one
            _chalk_docker_completions
            ;;
        setup)
            _chalk_shift_one
            _chalk_setup_completions
            ;;
        help)
            _chalk_shift_one
            _chalk_help_completions
            ;;
        *)
            if [[ $_CHALK_CUR_IX -le $COMP_CWORD ]] ; then
                _chalk_shift_one
                _chalk_toplevel_completions
            else
                COMPREPLY=($(compgen -W "--color --no-color --help --log-level --config-file --enable-profile --disable-profile --enable-report --disable-report --report-cache-file --time --no-time --use-embedded-config --no-use-embedded-config --use-external-config --no-use-external-config --publish-defaults --no-publish-defaults --use-report-cache --no-use-report-cache --virtual --no-virtual --debug --no-debug --skip-command-report --no-skip-command-report --wrap --no-wrap extract insert delete env exec defaults profile dump load version docker setup help" -- ${_CHALK_CUR_WORD}))
            fi
            ;;
    esac
}

function _chalk_shift_one {
    let "_CHALK_CUR_IX++"
}

function _chalk_completions {

    _get_comp_words_by_ref cur prev words cword

    _CHALK_CUR_IX=0
    _CHALK_CUR_WORD=${2}
    _CHALK_PREV=${3}

    _chalk_toplevel_completions
}

complete -F _chalk_completions chalk