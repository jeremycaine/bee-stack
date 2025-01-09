#!/bin/bash

# shellcheck disable=SC2059
# disable "no variables in printf" due to color codes

REQUIRED_COMPOSE_VERSION=2.26
ORANGE='\e[1;33m'
BLUE='\e[1;34m'
NC='\e[0m' # No Color
TMP_ENV_FILE=.env.tmp

set -e

print_error() {
    printf "${ORANGE}❗ERROR: %s${NC}\n" "$1"
    shift
    [ -n "$1" ] && printf "${ORANGE}❗       %s${NC}\n" "$@"
    printf "❗\n${ORANGE}❗Visit the troubleshooting guide:\n"
    printf "❗${BLUE}https://github.com/i-am-bee/bee-stack/blob/main/docs/troubleshooting.md${NC}\n"
}

print_header() {
  printf "${BLUE}%s${NC}\n" "$1"
}

MISSING_COMPOSE_MSG=$(cat << EOF
For installation instructions, see:
- ${BLUE}Podman desktop:${NC} https://podman.io
  ⚠️ install using the official installer (not through package manager like brew, apt, etc.)
  ⚠️ use rootful machine (default)
  ⚠️ use docker compatibility mode
- ${BLUE}Rancher desktop:${NC} https://rancherdesktop.io
- ${BLUE}Docker desktop:${NC} https://www.docker.com/
EOF
)

choose() {
  print_header "${1}:"
  local range="[1-$(($# - 1))]"

  for ((i=1; i < $#; i++)); do
    choice=$((i+1))
    echo "[${i}]: ${!choice}"
  done

  while true; do
    read -rp "Select ${range}: " SELECTED_NUM
    if ! [[ "$SELECTED_NUM" =~ ^[0-9]+$ ]]; then print_error "Please enter a valid number"; continue; fi
    if [ "$SELECTED_NUM" -lt 1 ] || [ "$SELECTED_NUM" -ge "$#" ]; then
      print_error "Number is not in ${range}"; continue;
    fi
    break
  done

  local idx=$((SELECTED_NUM + 1))
  SELECTED_OPT="${!idx}"
}

ask_yes_no() {
  local answer
  read -rp "${1} (Y/n): " answer
  answer=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
  [ "$answer" = "y" ] && echo "yes" || echo "no"
}

check_docker() {
    # Check if RUNTIME is set in the .env file
    if [ -z "$RUNTIME" ] && [ -f ".env" ]; then
        RUNTIME=$(grep -E '^RUNTIME=' .env | cut -d'=' -f2 | xargs)
    fi

    # If RUNTIME is now set, return early
    if [ -n "$RUNTIME" ]; then
        return
    fi

    # Check if docker or podman is installed
    local runtime compose_version major minor req_major req_minor
    req_major=$(cut -d'.' -f1 <<< ${REQUIRED_COMPOSE_VERSION})
    req_minor=$(cut -d'.' -f2 <<< ${REQUIRED_COMPOSE_VERSION})
       
    local existing_runtimes=()
    for runtime in docker podman; do
       command -v "$runtime" &>/dev/null && existing_runtimes+=("$runtime")
    done

    if [ ${#existing_runtimes[@]} -eq 0 ]; then
      print_error "None of the supported container runtimes are installed (docker, rancher, or podman)"
      printf "\n${MISSING_COMPOSE_MSG}"
      exit 1
    fi
    
    # find docker-compose if it is installed
    local os_type
    os_type=$(uname -s)
    local compose_command
    if [[ "$os_type" == "Linux" || "$os_type" == "Darwin" ]]; then
        compose_command="command -v docker-compose"
    elif [[ "$os_type" == "CYGWIN"* || "$os_type" == "MINGW"* || "$os_type" == "MSYS"* ]]; then
        compose_command="where docker-compose"
    else
        print_error "Unsupported platform: $os_type"
        exit 1
    fi

    # Check docker-compose executable runs
    local compose_path
    compose_path=$($compose_command 2>/dev/null || echo "not_found")
    if [[ "$compose_path" == "not_found" ]]; then
        print_error "Compose extension is not installed."
        printf "\n${MISSING_COMPOSE_MSG}"
        exit 2
    fi

    # Check version
    compose_version=$(docker-compose version --short 2>/dev/null || echo "not_found")
    if [[ "$compose_version" == "not_found" ]]; then
        print_error "Failed to retrieve compose version. Ensure docker-compose is correctly installed."
        exit 2
    else
        major=$(cut -d'.' -f1 <<< "$compose_version")
        minor=$(cut -d'.' -f2 <<< "$compose_version")

        if [ "$major" -lt "$req_major" ] || { [ "$major" -eq "$req_major" ] && [ "$minor" -lt "$req_minor" ]; }; then
          print_error "The compose version ($compose_version) does not meet the required version ${REQUIRED_COMPOSE_VERSION}."
          exit 2
        fi
    fi

    # detect if multiple runtime and ask user to choose
    if [ ${#existing_runtimes[@]} -gt 1 ]; then
        choose "Multiple runtimes detected. Select the runtime to use" "${existing_runtimes[@]}"
        runtime="$SELECTED_OPT"
    else
        runtime="${existing_runtimes[0]}"
    fi
    RUNTIME="$runtime"
}

trim() {
    local var="${1#"${1%%[![:space:]]*}"}"
    echo "${var%"${var##*[![:space:]]}"}"
}

write_env() {
  local default_prompt default_provided value
  default_provided=$([ $# -gt 1 ] && echo 1 || echo 0)
  default_prompt="$([ "$default_provided" -eq 1 ] && echo " (leave empty for default '${2}')" || echo "")"
  while true; do
    read -rp "Provide ${1}${default_prompt}: " value
    if [ -z "$value" ] && [ "$default_provided" -eq 0 ]; then
      print_error "Value is required"
      continue
    fi
    break
  done
  value="$([ -z "$value" ] && echo "$2" || echo "$value")"
  value="$(trim "$value")"
  echo "$1=$value" >> "$TMP_ENV_FILE"
  export "${1}=${value}"
}

write_backend() {
  echo LLM_BACKEND="$1" >> "$TMP_ENV_FILE"
  echo EMBEDDING_BACKEND="$1" >> "$TMP_ENV_FILE"
}

configure_bam() {
  write_backend bam
  write_env BAM_API_KEY
}

configure_watsonx() {
  write_backend watsonx
  write_env WATSONX_PROJECT_ID
  write_env WATSONX_API_KEY
  write_env WATSONX_REGION "us-south"
}

configure_ollama() {
  write_backend ollama
  write_env OLLAMA_URL "http://host.docker.internal:11434"
  print_header "Checking Ollama connection"
  if ! ${RUNTIME} run --rm -it curlimages/curl "$OLLAMA_URL"; then
    print_error "Ollama is not running or accessible from containers."
    printf "  Make sure you configured OLLAMA_HOST=0.0.0.0\n"
    printf "  see https://github.com/ollama/ollama/blob/main/docs/faq.md#how-do-i-configure-ollama-server\n"
    printf "  or run ollama from command line ${BLUE}OLLAMA_HOST=0.0.0.0 ollama serve${NC}\n"
    printf "  Do not forget to pull the required LLMs ${BLUE}ollama pull llama3.1${NC}\n"
    exit 2
  fi
}

configure_openai() {
  write_backend openai
  write_env OPENAI_API_KEY
}

setup() {
  printf "🐝 Welcome to the bee-stack! You're just a few questions away from building agents!\n(Press ^C to exit)\n\n"
  rm -f "$TMP_ENV_FILE"
  choose "Choose LLM provider" "watsonx" "ollama" "bam" "openai"
  [[ $SELECTED_OPT == 'bam' ]] && configure_bam
  [[ $SELECTED_OPT == 'ollama' ]] && configure_ollama
  [[ $SELECTED_OPT == 'watsonx' ]] && configure_watsonx
  [[ $SELECTED_OPT == 'openai' ]] && configure_openai

  if [ -f ".env" ]; then
    printf "\n\n"
    [ "$(ask_yes_no ".env file already exists. Do you want to override it?")" = 'no' ] && exit 1
    if [ -n "$(${RUNTIME} compose ps -aq)" ]; then
      [ "$(ask_yes_no "bee-stack data must be removed when changing configuration, are you sure?")" = 'no' ] && exit 1
      clean_stack
    fi
  fi

  echo RUNTIME="$RUNTIME" >> "$TMP_ENV_FILE"

  cp "$TMP_ENV_FILE" .env
  [ "$(ask_yes_no "Do you want to start bee-stack now?")" = 'yes' ] && start_stack
}

start_stack() {
  if ! [ -f ".env" ]; then
    [ "$(ask_yes_no "bee-stack is not yet configured, do you want to configure it now?")" = 'yes' ] && setup || exit 3
  fi

  ${RUNTIME} compose --profile all up -d
  printf "Done. You can visit the UI at ${BLUE}http://localhost:3000${NC}\n"
}

stop_stack() {
  ${RUNTIME} compose --profile all down
  ${RUNTIME} compose --profile infra down
}

clean_stack() {
  ${RUNTIME} compose --profile all down --volumes
  ${RUNTIME} compose --profile infra down --volumes
  rm -rf tmp
  mkdir -p ./tmp/code-interpreter-storage
}

start_infra() {
  mkdir -p ./tmp/code-interpreter-storage
  ${RUNTIME} compose --profile infra up -d
}

dump_logs() {
  timestamp=$(date +"%Y-%m-%d_%H%MS")
  folder="./logs/${timestamp}"
  mkdir -p "${folder}"

  for component in $(${RUNTIME} compose --profile all config --services); do
    ${RUNTIME} compose logs "${component}" > "${folder}/${component}.log"
  done

  ${RUNTIME} version > "${folder}/${RUNTIME}.log"
  ${RUNTIME} compose version > "${folder}/${RUNTIME}.log"

  zip -r "${folder}.zip" "${folder}/"|| echo "Zip is not installed, please upload individual logs"

  printf "${ORANGE}Logs were created in ${folder}${NC}.\n"
  printf "If you have issues running bee-stack, please create an issue "
  printf "and attach the file ${ORANGE}${folder}.zip${NC} at:\n"
  printf "${BLUE}https://github.com/i-am-bee/bee-stack/issues/new?template=run_stack_issue.md${NC}\n"
}

# Main
check_docker
command=$(trim "$1" | tr '[:upper:]' '[:lower:]')
command=$([ -z "$command" ] && echo "setup" || echo "$command")
if [ "$command" = 'setup' ]; then setup
elif [ "$command" = 'start' ]; then start_stack
elif [ "$command" = 'start:infra' ]; then start_infra
elif [ "$command" = 'stop' ]; then stop_stack
elif [ "$command" = 'clean' ]; then clean_stack
elif [ "$command" = 'check' ]; then check_docker
elif [ "$command" = 'logs' ]; then dump_logs
else print_error "Unknown command $1"
fi
