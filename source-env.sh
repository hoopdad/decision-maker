#!/usr/bin/env bash

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'Source this file instead of executing it: source ./source-env.sh\n' >&2
    exit 1
fi

load_example_env() {
    local script_dir env_file restore_allexport=false

    script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    env_file="$script_dir/.env"
    if [[ ! -f "$env_file" ]]; then
        printf 'Error: Environment file not found: %s\n' "$env_file" >&2
        return 1
    fi

    case $- in
        *a*) ;;
        *)
            set -a
            restore_allexport=true
            ;;
    esac

    if ! source "$env_file"; then
        if [[ "$restore_allexport" == true ]]; then
            set +a
        fi
        printf 'Error: Could not source environment file: %s\n' "$env_file" >&2
        return 1
    fi

    if [[ "$restore_allexport" == true ]]; then
        set +a
    fi
}

load_example_env
unset -f load_example_env
