#!/usr/bin/env bash
set -euo pipefail
shopt -s extglob
readonly PROGRAM="${0##*/}"
readonly LC_ALL=C
declare IFS=$'\t\n'

REGISTRY=${REGISTRY:-"https://index.docker.io/v2"}
REGISTRY_AUTH=${REGISTRY_AUTH:-"https://auth.docker.io"}
REGISTRY_SERVICE=${REGISTRY_SERVICE:-"registry.docker.io"}
IMAGE_NAME=${IMAGE_NAME:-""}
IMAGE_TAG=${IMAGE_TAG:-"latest"}
IMAGE_ID_TARGET=""
IMAGE_ID_LONG=${IMAGE_ID_LONG:-""}
DOCKER_BIN=docker
TAGS_FILTER=${TAGS_FILTER:-""}
VERBOSE=0
TAGS_LIMIT=25
ignore_404=0

trace() { echo -e "$PROGRAM: $*" >&2; }
die() {	trace "Error: $*" ; exit 1 ; }
is_verbosity() { [ $VERBOSE -ge $1 ]; }
info() { ! is_verbosity 1 || trace "[info] $*" ; }
debug() { ! is_verbosity 3 || trace "[debug] $*" ; }

usage () {
	local DS='$'
	(cat <<-EOT
	Usage:
	  $DS $PROGRAM [options...]

	Options:
	  -n [text]    Image name (Required). Example: org/image:tag
	  -r [text]    Registry URL to use. Example: -r $REGISTRY (Default) (Optional)
	  -a [text]    Registry AUTH to use. Example: -a $REGISTRY_AUTH (Default) (Optional)
	  -l [number]  Tag limit. Defaults to $TAGS_LIMIT. (Optional)
	  -f [text]    Filter tag to contain this value (Optional)
	  -v           Verbose output (Optional)

	Examples:
	  $DS $PROGRAM -n traefik -f 1.7
	  $DS $PROGRAM -n node -l 40
	  $DS $PROGRAM -n jenkins/jenkins:latest-jdk11

	EOT
	) >&2
}

# From: https://stackoverflow.com/questions/192249/how-do-i-parse-command-line-arguments-in-bash
# A POSIX variable
OPTIND=1 # Reset in case getopts has been used previously in the shell.
while getopts ":h?n:r:a:l:f:v" OPTION; do
	case "$OPTION" in
		h)
			usage
			exit 0
			;;
		n)  IMAGE_NAME="$OPTARG"
			;;
		r)  REGISTRY="$OPTARG"
			;;
		a)  REGISTRY_AUTH="$OPTARG"
			;;
		l)  TAGS_LIMIT="$OPTARG"
			;;
		f)  TAGS_FILTER="$OPTARG"
			;;
		v)  (( VERBOSE+=1 ))
			;;
		:)  die "The '-$OPTARG' option is missing a required argument"
			;;
		\?)
			usage
			die "The '-$OPTARG' option is invalid"
			;;
	esac
done
shift $((OPTIND-1))
[ "${1:-}" != "--" ] || shift
debug "VERBOSE=$VERBOSE, IMAGE_NAME='$IMAGE_NAME', Leftovers: $@"

[ -n "$IMAGE_NAME" ] || { usage; die "Error: Missing required Image Name (-n) option"; }
info "Using IMAGE_NAME: $IMAGE_NAME"
info "Using REGISTRY: $REGISTRY"

# add library/ if no /. (Which is _ aka official image like hub.docker.com/_/traefik)
# Official images are in "library/"
ACTUAL_IMAGE_NAME="$IMAGE_NAME"
if [ "$IMAGE_NAME" != *"/"* ]; then
	ACTUAL_IMAGE_NAME="library/$IMAGE_NAME"
fi

if [ "$ACTUAL_IMAGE_NAME" == *":"* ]; then
	IMAGE_TAG="${ACTUAL_IMAGE_NAME##*:}"
	ACTUAL_IMAGE_NAME="${ACTUAL_IMAGE_NAME%:*}"
fi

debug "ACTUAL_IMAGE_NAME:$ACTUAL_IMAGE_NAME, IMAGE_TAG:$IMAGE_TAG"

[[ $TAGS_LIMIT =~ ^[0-9]+$ ]] || die "Error: Tag limit (-l) must be an integer > 0"

# https://unix.stackexchange.com/questions/459367/using-shell-variables-for-command-options/459369#459369
# https://unix.stackexchange.com/questions/444946/how-can-we-run-a-command-stored-in-a-variable/444949#444949
# https://askubuntu.com/questions/674333/how-to-pass-an-array-as-function-argument/995110#995110
# Maybe this? https://stackoverflow.com/questions/45948172/executing-a-curl-request-through-bash-script/45948289#45948289
# http://mywiki.wooledge.org/BashFAQ/050#I_only_want_to_pass_options_if_the_runtime_data_needs_them
function do_curl_get () {
	local URL="$1"
	shift
	local array=("$@")
	# debug "URL: $URL, {array[@]}:\n${array[@]}"
	HTTP_RESPONSE="$(curl -sSL --write-out "HTTPSTATUS:%{http_code}" \
		-H "Content-Type: application/json;charset=UTF-8" \
		"${array[@]}" \
		-X GET "$URL")"
	# debug "HTTP_RESPONSE: $HTTP_RESPONSE"
	HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed -E 's/HTTPSTATUS\:[0-9]{3}$//')
	HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tr -d '\n' | sed -E 's/.*HTTPSTATUS:([0-9]{3})$/\1/')
	# Check that the http status is 200
	if [ "$HTTP_STATUS" -ne 200 ]; then
		if [ "$HTTP_STATUS" -ne 404 ] || [ "$ignore_404" -eq 0 ]; then
			debug "Error $HTTP_STATUS from: $URL\nHTTP_BODY: $HTTP_BODY"
			die "Error $HTTP_STATUS from: $URL"
		fi
	fi
}

# Get AUTH token
# This cannot be: ("")
CURL_AUTH=()
CURL_URL="$REGISTRY_AUTH/token?service=${REGISTRY_SERVICE##*(//)}&scope=repository:$ACTUAL_IMAGE_NAME:pull"

do_curl_get "$CURL_URL" "${CURL_AUTH[@]}"
AUTH=$(echo "$HTTP_BODY" | jq --raw-output .token)

# Get Tags
CURL_AUTH=( -H "Authorization: Bearer $AUTH" )
# debug "CURL_AUTH[@]: ${CURL_AUTH[@]}"
CURL_URL="$REGISTRY/$ACTUAL_IMAGE_NAME/tags/list"
do_curl_get "$CURL_URL" "${CURL_AUTH[@]}"
TAGS_CURL=$(echo "$HTTP_BODY")
TAGS_COUNT=$(echo "$TAGS_CURL"|jq -r '.tags[]'|grep -vi windows|wc -l)
# n doesn't limit.. wtf
# TAGS=$(curl -sLH "Authorization: Bearer $AUTH" "$REGISTRY/$ACTUAL_IMAGE_NAME/tags/list?n=100"|jq -r '.tags[]'|sort -r --version-sort|head -100)
# This breaks at 'head' when large tag list. wtf. example: bitnami/mariadb has >4500 tags
# Solved, don't use head with -o pipefail. Replaced head with sed.
# https://stackoverflow.com/questions/19120263/why-exit-code-141-with-grep-q/19120674#19120674
# TAGS=$(echo "$TAGS_CURL"|jq --arg TAGS_FILTER "$TAGS_FILTER" -r '.tags[]|select(.|contains($TAGS_FILTER))'|grep -vi windows|sort -r --version-sort|head -"$TAGS_LIMIT")
TAGS_temp=$(echo "$TAGS_CURL"|jq --arg TAGS_FILTER "$TAGS_FILTER" -r '.tags[]|select(.|contains($TAGS_FILTER))'|grep -vi windows|sort -r --version-sort)
TAGS_FILTER_COUNT=$(echo "$TAGS_temp"|wc -l)
TAGS=$(echo "$TAGS_temp"|sed -n 1,"$TAGS_LIMIT"p)
info "Found Total Tags: $TAGS_COUNT, filtered: $TAGS_FILTER_COUNT."
info "Limiting Tags to: $TAGS_LIMIT"
info "Found Tags:\n$TAGS"

get_image_digest() {
	local tag=$1 digest
	CURL_AUTH=( -H "Authorization: Bearer $AUTH" -H "Accept:application/vnd.docker.distribution.manifest.v2+json" )
	CURL_URL="$REGISTRY/$ACTUAL_IMAGE_NAME/manifests/${tag}"
	do_curl_get "$CURL_URL" "${CURL_AUTH[@]}"
	digest="$(echo "$HTTP_BODY" |jq -r .config.digest)"
	echo "$digest"
}

IMAGE_ID_LONG=$(get_image_digest $IMAGE_TAG)
[ -n "${IMAGE_ID_LONG}" ] || die "Image digest not found"

# Loop through tags and look for sha Id match
# Some "manifests/tag" endpoints do not exist (http404 error)? Seems to be windows images. Ignore any 404 error
ignore_404=1
counter=0
info "Checking for image match.."
for tag in $TAGS; do
	if [[ "$counter" =~ ^($(echo {50..1000..50}|sed 's/ /|/g'))$ ]]; then
		info "Still working, currently on tag number: $counter"
	fi
	IMAGE_ID_TARGET=$(get_image_digest $tag)
	if [[ "$IMAGE_ID_TARGET" == "$IMAGE_ID_LONG" ]]; then
		info "Found match. tag:"
		echo $tag
		info "Image ID Target: $IMAGE_ID_TARGET"
		info "Image ID Source: $IMAGE_ID_LONG"
	fi
	sleep .5
	counter=$((counter+1))
done;
