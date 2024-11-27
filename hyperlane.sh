#!/bin/bash

LOG_FILE="/var/log/hyperlane_setup.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() {
    echo -e "$1"
    echo -e "$(date '+%Y-%m-%d %H:%M:%S') $1" >> $LOG_FILE
}

error_exit() {
    log "${RED}Error: $1${NC}"
    exit 1
}

if [ "$EUID" -ne 0 ]; then
    log "${RED}Please run this script with root privileges!${NC}"
    exit 1
fi

# Check if the log path is writable
if [ ! -w "$(dirname "$LOG_FILE")" ]; then
    error_exit "Log path is not writable. Please check permissions or adjust the path: $(dirname "$LOG_FILE")"
fi

# Install Required Dependencies
install_dependencies() {
    log "${YELLOW}Installing required dependencies...${NC}"
    sudo apt-get update || error_exit "Failed to update package list"
    sudo apt-get install -y wget curl || error_exit "Failed to install wget and curl"
    sudo apt-get install -y toilet || error_exit "Failed to install toilet"
    log "${GREEN}All required dependencies are installed!${NC}"
}

# Set global variables
DB_DIR="/opt/hyperlane_db_base"

# Ensure the directory exists and has appropriate permissions
if [ ! -d "$DB_DIR" ]; then
    mkdir -p "$DB_DIR" && chmod -R 777 "$DB_DIR" || error_exit "Failed to create database directory: $DB_DIR"
    log "${GREEN}Database directory created: $DB_DIR${NC}"
else
    log "${GREEN}Database directory already exists: $DB_DIR${NC}"
fi

# Install Docker
install_docker() {
    if ! command -v docker &> /dev/null; then
        log "${YELLOW}Installing Docker...${NC}"
        sudo apt-get update
        sudo apt-get install -y docker.io || error_exit "Failed to install Docker"
        sudo systemctl start docker || error_exit "Failed to start Docker service"
        sudo systemctl enable docker || error_exit "Failed to enable Docker at startup"
        log "${GREEN}Docker successfully installed and started!${NC}"
    else
        log "${GREEN}Docker is already installed. Skipping this step.${NC}"
    fi
}

# Install Node.js and NVM
install_nvm_and_node() {
    if ! command -v nvm &> /dev/null; then
        log "${YELLOW}Installing NVM...${NC}"
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.0/install.sh | bash || error_exit "Failed to install NVM"
        export NVM_DIR="$HOME/.nvm"
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        log "${GREEN}NVM successfully installed!${NC}"
    else
        log "${GREEN}NVM is already installed. Skipping this step.${NC}"
    fi

    if ! command -v node &> /dev/null; then
        log "${YELLOW}Installing Node.js v20...${NC}"
        nvm install 20 || error_exit "Failed to install Node.js"
        log "${GREEN}Node.js successfully installed!${NC}"
    else
        log "${GREEN}Node.js is already installed. Skipping this step.${NC}"
    fi
}

# Install Foundry
install_foundry() {
    if ! command -v foundryup &> /dev/null; then
        log "${YELLOW}Installing Foundry...${NC}"
        curl -L https://foundry.paradigm.xyz | bash || error_exit "Failed to install Foundry"
        export PATH="$HOME/.foundry/bin:$PATH"
        source ~/.bashrc || error_exit "Failed to source ~/.bashrc"
        foundryup || error_exit "Failed to initialize Foundry"
        log "${GREEN}Foundry successfully installed!${NC}"
    else
        log "${GREEN}Foundry is already installed. Skipping this step.${NC}"
    fi
}

# Install Hyperlane
install_hyperlane() {
    if ! command -v hyperlane &> /dev/null; then
        log "${YELLOW}Installing Hyperlane CLI...${NC}"
        npm install -g @hyperlane-xyz/cli || error_exit "Failed to install Hyperlane CLI"
        log "${GREEN}Hyperlane CLI successfully installed!${NC}"
    else
        log "${GREEN}Hyperlane CLI is already installed. Skipping this step.${NC}"
    fi

    if ! docker images | grep -q 'gcr.io/abacus-labs-dev/hyperlane-agent'; then
        log "${YELLOW}Pulling Hyperlane image...${NC}"
        docker pull --platform linux/amd64 gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 || error_exit "Failed to pull Hyperlane image"
        log "${GREEN}Hyperlane image successfully pulled!${NC}"
    else
        log "${GREEN}Hyperlane image already exists. Skipping this step.${NC}"
    fi
}

# Configure and Start Validator
configure_and_start_validator() {
    log "${YELLOW}Configuring and starting the Validator...${NC}"
    
    read -p "Enter Validator Name: " VALIDATOR_NAME
    
    while true; do
        read -s -p "Enter Private Key (format: 0x followed by 64 hex characters): " PRIVATE_KEY
        echo ""
        if [[ ! $PRIVATE_KEY =~ ^0x[0-9a-fA-F]{64}$ ]]; then
            log "${RED}Invalid Private Key format! Ensure it starts with '0x' and is followed by 64 hex characters.${NC}"
        else
            break
        fi
    done
    
    read -p "Enter RPC URL: " RPC_URL

    CONTAINER_NAME="hyperlane"

    if docker ps -a --format '{{.Names}}' | grep -q "^hyperlane$"; then
        log "${YELLOW}An existing container named 'hyperlane' was found.${NC}"
        read -p "Do you want to remove the old container and continue? (y/n): " choice
        if [[ "$choice" == "y" ]]; then
            docker rm -f hyperlane || error_exit "Failed to remove the old container."
            log "${GREEN}Old container removed. Proceeding to start a new container.${NC}"
        else
            read -p "Enter a new container name: " NEW_CONTAINER_NAME
            if [[ -z "$NEW_CONTAINER_NAME" ]]; then
                error_exit "Container name cannot be empty!"
            fi
            CONTAINER_NAME=$NEW_CONTAINER_NAME
        fi
    fi

    docker run -d \
        -it \
        --name "$CONTAINER_NAME" \
        --mount type=bind,source="$DB_DIR",target=/hyperlane_db_base \
        gcr.io/abacus-labs-dev/hyperlane-agent:agents-v1.0.0 \
        ./validator \
        --db /hyperlane_db_base \
        --originChainName base \
        --reorgPeriod 1 \
        --validator.id "$VALIDATOR_NAME" \
        --checkpointSyncer.type localStorage \
        --checkpointSyncer.folder base \
        --checkpointSyncer.path /hyperlane_db_base/base_checkpoints \
        --validator.key "$PRIVATE_KEY" \
        --chains.base.signer.key "$PRIVATE_KEY" \
        --chains.base.customRpcUrls "$RPC_URL" || error_exit "Failed to start the Validator"

    log "${GREEN}Validator configured and started! Container name: $CONTAINER_NAME${NC}"
}

# Complete All Steps
install_all() {
    log "${YELLOW}Starting full installation process...${NC}"
    install_dependencies
    install_docker
    install_nvm_and_node
    install_foundry
    install_hyperlane
    configure_and_start_validator
    log "${GREEN}All steps completed successfully!${NC}"
}

# View Logs
view_logs() {
    log "${YELLOW}Viewing runtime logs...${NC}"
    if docker ps -a --format '{{.Names}}' | grep -q "^hyperlane$"; then
        docker logs -f hyperlane || error_exit "Failed to view logs"
    else
        error_exit "The 'hyperlane' container does not exist. Ensure it has been started!"
    fi
}

# Main Menu
main_menu() {
    while true; do
        clear
        toilet -f smblock "WibuCrypto"
        echo
        echo "Welcome to WibuCrypto Validator Setup!"
        echo "Find us in telegram channel: https://t.me/wibuairdrop142"
        echo
        echo "Please Select an Option:"
        echo "1) Complete All Steps Automatically"
        echo "2) View Runtime Logs"
        echo "0) Exit"
        echo
        read -p "Enter your choice: " choice
        case $choice in
            1) install_all ;;
            2) view_logs ;;
            0) exit 0 ;;
            *) log "${RED}Invalid option, please try again!${NC}" ;;
        esac
    done
}

main_menu
