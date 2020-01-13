#!/usr/bin/env bash
set -euo pipefail

IFS=$'\n\t'

#####
# TODO
#   + For the CF template, only apply the SG whitelist if the option to secure Jenkins (should be another option) is set to true. Do this on my own dime.
## 
# To lint:
#   docker run \
#     --rm \
#     --mount \
#       type=bind,source="$(pwd)",target=$(pwd),readonly \
#     -w $(pwd) \
#     koalaman/shellcheck:stable \
#     run.sh
###
# Tested against:
#   $ aws --version
#   aws-cli/1.16.303 Python/3.6.9 Linux/4.15.0-72-generic botocore/1.13.46
#####

# Better debugging output.
# See: http://wiki.bash-hackers.org/scripting/debuggingtips#making_xtrace_more_useful
# shellcheck disable=SC2016
export PS5='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

# Absolute path to current dir.
declare DIR
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

declare AWS_PROFILE=${AWS_PROFILE:-}

_print_usage() {
    echo
    echo "USAGE:"
    printf "\tAWS_PROFILE=AWS_PROFILE_NAME %s %s %s %s\n" "$0" STACK_NAME_PREFIX STACK_TO_DEPLOY "[OPTIONS]"
    echo "DESCRIPTION:"
    echo -e "\tAWS_PROFILE_NAME"
    echo -e "\t\tName of the AWS profile to use."
    echo -e "\tSTACK_NAME_PREFIX"
    echo -e "\t\tThe prefix of your stack name."
    echo -e "\tSTACK_TO_DEPLOY"
    echo -e "\t\tThe stack you want to deploy. Allowed values are 'vpc' or 'jenkins'."
    echo -e "\tOPTIONS"
    echo -e "\t\tAny options you pass in here are appended or they override the sensible defaults. This is very useful for '--parameter-overrides'."
    echo
}

# Ensure that an AWS profile has been set.
_ensure_aws_profile_set() {
    if [[ -z $AWS_PROFILE ]]; then
        echo "ERROR: You must specify your AWS profile name."
        echo "See: https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-envvars.html"
        _print_usage
        exit 1
    fi
    echo "Using AWS profile ${AWS_PROFILE}"
}

# Gets AWS Account ID for $AWS_PROFILE.
_get_account_id() {
    aws sts \
        get-caller-identity \
            --output text \
            --query Account
}

# Create S3 bucket if it doesn't exist.
# This bucket will hold our templates so that CloudFormation can execute them.
# You can't omit the bucket using CLI because the template size exceeds the limit set by AWS CLI (51,200 bytes), so uploading works best if you want to do this via CLI.
_ensure_s3_bucket_exists() {
    local bucket_name
    bucket_name=${1?"Missing argument 'bucket_name'." $(_print_usage)}
    aws s3 ls s3://"${bucket_name}" > /dev/null 2>&1 || aws s3 mb s3://"${bucket_name}" > /dev/null 2>&1
}

# Gets your current public IP.
_get_my_ip() {
    dig +short myip.opendns.com @resolver1.opendns.com
}

main() {
    local stack
    local -A stacks
    local stack_name_prefix
    local -A defaults
    local -A options
    local -a arguments

    _ensure_aws_profile_set

    # I'm asking for this to be deliberate so that we don't confuse stacks while experimenting.
    stack_name_prefix=${1?"Missing argument 'stack_name_prefix'." $(_print_usage)}
    stack=${2?"Missing argument 'stack'." $(_print_usage)}
    shift 2

    # The stacks to be deployed.
    stacks=(
        ["jenkins"]="${DIR}/jenkins2-ha-agents.yaml"
        ["vpc"]="${DIR}/../vpc/vpc-2azs.yaml"
    )

    pattern="--([^[:space:]]{2,})"

    # Sensible defaults.
    defaults=(
        ["capabilities"]="CAPABILITY_IAM"
        ["s3-prefix"]="${stack}"
        ["s3-bucket"]="unmanaged-${stack_name_prefix}-$(_get_account_id)"
        ["template-file"]="${stacks[${stack}]}"
        ["stack-name"]="${stack_name_prefix}-${stack}"
    )

    # If $options contains a value that already exists in $defaults, add them to $defaults and unset them in $options.
    for default in "${!defaults[@]}"; do
        if [[ "${options[$default]+not_empty}" ]]; then
            defaults["$default"]="${options["$default"]}"
            unset options["$default"]
        fi
    done

    # Add all remaining $options values to $defaults.
    for option in "${!options[@]}"; do
        defaults["$option"]="${options[$option]}"
    done

    case "${stack}" in
        jenkins|vpc)
            echo "Deploying ${stack^^} stack '${defaults["stack-name"]}'"
            ;;

        *)
            echo "ERROR: Unsupported stack."
            _print_usage
            exit 1
    esac

    for opt in "${!defaults[@]}"; do
        arguments=( ${arguments[@]} "--${opt}" "${defaults[$opt]}" )
    done

    echo "Creating S3 bucket if it doesnt exist..."
    _ensure_s3_bucket_exists "${defaults["s3-bucket"]}"
    set -x
    aws cloudformation validate-template --template-body "file://${defaults["template-file"]}"
    set +x

    # Credits for watching events as they occur: https://advancedweb.hu/cloudformation-cli-workflows/#deploy-and-watch-the-events
    (
        # shellcheck disable=SC2206
        aws cloudformation deploy ${arguments[@]} > /dev/null & \
    ) && watch \
        "aws cloudformation describe-stack-events \
            --stack-name \"${defaults["stack-name"]}\" | \
                jq -r '.StackEvents[] |
                        \"\\(.Timestamp | sub(\"\\\\.[0-9]+Z$\"; \"Z\") | fromdate | strftime(\"%H:%M:%S\") ) \\(.LogicalResourceId) \\(.ResourceType) \\(.ResourceStatus)\"
                ' | column -t"
}

main "$@"
exit $?
