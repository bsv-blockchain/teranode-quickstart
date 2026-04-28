#!/bin/bash
# Shell colour codes + echo_* helpers. Sourced by every script in this repo.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

echo_red()     { echo -e "${RED}$1${NC}"; }
echo_green()   { echo -e "${GREEN}$1${NC}"; }
echo_yellow()  { echo -e "${YELLOW}$1${NC}"; }
echo_blue()    { echo -e "${BLUE}$1${NC}"; }
echo_magenta() { echo -e "${MAGENTA}$1${NC}"; }
echo_cyan()    { echo -e "${CYAN}$1${NC}"; }
echo_white()   { echo -e "${WHITE}$1${NC}"; }

echo_error()   { echo -e "${RED}[ERROR] $1${NC}" >&2; }
echo_success() { echo -e "${GREEN}[SUCCESS] $1${NC}"; }
echo_warning() { echo -e "${YELLOW}[WARNING] $1${NC}"; }
echo_info()    { echo -e "${CYAN}[INFO] $1${NC}"; }
echo_debug()   { [[ "${DEBUG:-0}" == "1" ]] && echo -e "${MAGENTA}[DEBUG] $1${NC}"; }
