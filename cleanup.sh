#!/bin/bash

# Load configuration
if [ -f "$(dirname "$0")/pi_config.sh" ]; then
    source "$(dirname "$0")/pi_config.sh"
else
    # Fallback configuration if config file is missing
    PI_EMAIL="your-email@example.com"
    PI_USER="$(whoami)"
    PI_HOME="/home/${PI_USER}"
    PI_HOSTNAME="$(hostname)"
fi

# Colors for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to confirm actions
confirm() {
    read -p "$(echo -e "${YELLOW}$1 [y/N]:${NC} ")" response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to show docker disk usage
show_docker_usage() {
    echo -e "\n${BLUE}=== Docker Disk Usage ===${NC}"
    docker system df
}

# Function to clean Docker resources
clean_docker() {
    echo -e "\n${GREEN}=== Docker Cleanup ===${NC}"
    
    # Show initial disk usage
    show_docker_usage
    
    # List ALL containers (including running ones)
    echo -e "\n${YELLOW}All containers:${NC}"
    docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Size}}\t{{.CreatedAt}}"
    
    # List running containers
    echo -e "\n${YELLOW}Currently running containers:${NC}"
    docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"
    
    # List stopped containers
    echo -e "\n${YELLOW}Stopped containers:${NC}"
    docker ps -a --filter "status=exited" --filter "status=created" --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Size}}"
    
    if confirm "Would you like to stop any running containers?"; then
        echo -e "Enter container IDs or names to stop (space-separated), or press Enter to skip:"
        read -r containers_to_stop
        if [ ! -z "$containers_to_stop" ]; then
            docker stop $containers_to_stop
            echo -e "${GREEN}Specified containers stopped${NC}"
        fi
    fi
    
    if confirm "Remove all stopped containers?"; then
        docker container prune -f
        echo -e "${GREEN}Stopped containers removed${NC}"
    fi
    
    # List all images with size
    echo -e "\n${YELLOW}All Docker images:${NC}"

docker images --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
    
    # List unused images
    echo -e "\n${YELLOW}Unused images:${NC}"
    docker images -f "dangling=true" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}"
    
    if confirm "Remove unused images?"; then
        docker image prune -f
        echo -e "${GREEN}Unused images removed${NC}"
    fi
    
    if confirm "Remove all unused images (including tagged ones)?"; then
        docker image prune -a -f
        echo -e "${GREEN}All unused images removed${NC}"
    fi
    
    # List all volumes with details
    echo -e "\n${YELLOW}All volumes:${NC}"
    docker volume ls --format "table {{.Name}}\t{{.Driver}}\t{{.Scope}}"
    
    # List unused volumes
    echo -e "\n${YELLOW}Unused volumes:${NC}"
    docker volume ls -f "dangling=true"
    
    if confirm "Remove unused volumes?"; then
        docker volume prune -f
        echo -e "${GREEN}Unused volumes removed${NC}"
    fi
    
    # Show final disk usage
    echo -e "\n${BLUE}=== Final Docker Disk Usage ===${NC}"
    docker system df
    
    # Option for complete cleanup
    if confirm "Would you like to perform a complete system prune (removes all unused containers, networks, images, and volumes)?"; then
        docker system prune -a --volumes -f
        echo -e "${GREEN}Complete system prune completed${NC}"
    fi
}

# Function to clean files and folders
clean_files() {
    echo -e "\n${GREEN}=== Files and Folders Cleanup ===${NC}"
    
    # Clean temporary files
    if confirm "Clean temporary files in /tmp older than 7 days?"; then
        sudo find /tmp -type f -atime +7 -delete
        echo -e "${GREEN}Old temporary files removed${NC}"
    fi
    
    # Clean package manager cache
    if [ -f /etc/debian_version ]; then
        if confirm "Clean apt cache?"; then
            sudo apt-get clean
            sudo apt-get autoremove
            echo -e "${GREEN}APT cache cleaned${NC}"
        fi
    elif [ -f /etc/redhat-release ]; then
        if confirm "Clean yum cache?"; then
            sudo yum clean all
            echo -e "${GREEN}YUM cache cleaned${NC}"
        fi
    fi
    
    # Custom directory cleanup
    echo -e "\n${YELLOW}To remove specific directories or files, please enter their paths (one per line)."
    echo -e "Press Ctrl+D when finished:${NC}"
    
    while IFS= read -r path; do
        if [ -e "$path" ]; then
            if confirm "Remove $path?"; then
                rm -rf "$path"
                echo -e "${GREEN}Removed: $path${NC}"
            fi
        else
            echo -e "${RED}Path not found: $path${NC}"
        fi
    done
}

# Main menu
echo -e "${GREEN}=== System Cleanup Script ===${NC}"
echo "1. Clean Docker resources"
echo "2. Clean files and folders"
echo "3. Clean both"
echo "4. Exit"
read -p "Select an option (1-4): " option

case $option in
    1) clean_docker ;;
    2) clean_files ;;
    3) 
        clean_docker
        clean_files
        ;;
    4) echo "Exiting..." ;;
    *) echo -e "${RED}Invalid option${NC}" ;;
esac
