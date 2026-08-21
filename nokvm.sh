#!/bin/bash
set -euo pipefail

display_header() {
    clear
    if command -v toilet &> /dev/null; then
        toilet -f big -F metal "JKSoft"
    elif command -v figlet &> /dev/null; then
        figlet "JKSoft"
    else
        echo "┌────────────────────────────────────────────────────────┐"
        echo "│                        JKSOFT                          │"
        echo "└────────────────────────────────────────────────────────┘"
    fi
    echo ""
    echo -e "\033[1;36m┌────────────────────────────────────────────────────────┐\033[0m"
    echo -e "\033[1;36m│\033[0m         \033[1;37mJKSoft Cloud Virtual Machine Manager\033[0m           \033[1;36m│\033[0m"
    echo -e "\033[1;36m└────────────────────────────────────────────────────────┘\033[0m"
    echo ""
}

print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "\033[1;34m[ ℹ INFO ]\033[0m $message" ;;
        "WARN") echo -e "\033[1;33m[ ⚠ WARN ]\033[0m $message" ;;
        "ERROR") echo -e "\033[1;31m[ ✖ FAIL ]\033[0m $message" ;;
        "SUCCESS") echo -e "\033[1;32m[ ✔ DONE ]\033[0m $message" ;;
        "INPUT") echo -e "\033[1;36m[ ➜ INPUT ]\033[0m $message" ;;
        *) echo -e "\033[1;37m[ $type ]\033[0m $message" ;;
    esac
}

get_host_specs() {
    HOST_TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
    HOST_AVAIL_RAM_MB=$(free -m | awk '/^Mem:/{print $7}')
    HOST_TOTAL_CPUS=$(nproc)
    HOST_AVAIL_DISK_GB=$(df -BG "$VM_DIR" 2>/dev/null | awk 'NR==2 {gsub("G","",$4); print $4}')
    if [ -z "$HOST_AVAIL_DISK_GB" ]; then
        HOST_AVAIL_DISK_GB=$(df -BG "$HOME" | awk 'NR==2 {gsub("G","",$4); print $4}')
    fi
}

validate_input() {
    local type=$1
    local value=$2
    
    case $type in
        "number")
            if ! [[ "$value" =~ ^[0-9]+$ ]]; then
                print_status "ERROR" "Input must be a valid number."
                return 1
            fi
            ;;
        "size")
            if ! [[ "$value" =~ ^[0-9]+[GgMm]$ ]]; then
                print_status "ERROR" "Input must include units (e.g., 20G, 512M)."
                return 1
            fi
            ;;
        "port")
            if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt 23 ] || [ "$value" -gt 65535 ]; then
                print_status "ERROR" "Port must be in valid range (23-65535)."
                return 1
            fi
            ;;
        "name")
            if ! [[ "$value" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                print_status "ERROR" "Allowed characters: letters, numbers, hyphens, and underscores."
                return 1
            fi
            ;;
        "username")
            if ! [[ "$value" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                print_status "ERROR" "Username must start with letter/underscore and be lowercase alphanumeric."
                return 1
            fi
            ;;
    esac
    return 0
}

check_dependencies() {
    local missing_pkgs=()
    
    if ! command -v qemu-system-x86_64 &> /dev/null; then missing_pkgs+=("qemu-system-x86"); fi
    if ! command -v qemu-img &> /dev/null; then missing_pkgs+=("qemu-utils"); fi
    if ! command -v cloud-localds &> /dev/null; then missing_pkgs+=("cloud-image-utils"); fi
    if ! command -v wget &> /dev/null; then missing_pkgs+=("wget"); fi
    if ! command -v toilet &> /dev/null; then missing_pkgs+=("toilet"); fi
    if ! command -v figlet &> /dev/null; then missing_pkgs+=("figlet"); fi
    if ! command -v curl &> /dev/null; then missing_pkgs+=("curl"); fi

    if [ ${#missing_pkgs[@]} -ne 0 ]; then
        print_status "WARN" "Missing packages: ${missing_pkgs[*]}"
        read -p "$(print_status "INPUT" "Install missing dependencies automatically? (y/n): ")" auto_install
        if [[ "$auto_install" =~ ^[Yy]$ ]]; then
            print_status "INFO" "Installing packages..."
            if command -v apt-get &> /dev/null; then
                sudo apt-get update -y
                sudo apt-get install -y "${missing_pkgs[@]}"
            elif command -v dnf &> /dev/null; then
                sudo dnf install -y "${missing_pkgs[@]}"
            elif command -v pacman &> /dev/null; then
                sudo pacman -Sy --noconfirm "${missing_pkgs[@]}"
            else
                print_status "ERROR" "Package manager not detected. Install manually: ${missing_pkgs[*]}"
                exit 1
            fi
        else
            print_status "ERROR" "Dependencies required to proceed."
            exit 1
        fi
    fi
}

cleanup() {
    if [ -f "user-data" ]; then rm -f "user-data"; fi
    if [ -f "meta-data" ]; then rm -f "meta-data"; fi
}

get_vm_list() {
    find "$VM_DIR" -name "*.conf" -exec basename {} .conf \; 2>/dev/null | sort
}

load_vm_config() {
    local vm_name=$1
    local config_file="$VM_DIR/$vm_name.conf"
    
    if [[ -f "$config_file" ]]; then
        unset VM_NAME OS_TYPE CODENAME IMG_URL HOSTNAME USERNAME PASSWORD
        unset DISK_SIZE MEMORY CPUS SSH_PORT GUI_MODE PORT_FORWARDS IMG_FILE SEED_FILE CREATED
        
        source "$config_file"
        return 0
    else
        print_status "ERROR" "Config '$vm_name' not found."
        return 1
    fi
}

save_vm_config() {
    local config_file="$VM_DIR/$VM_NAME.conf"
    
    cat > "$config_file" <<EOF
VM_NAME="$VM_NAME"
OS_TYPE="$OS_TYPE"
CODENAME="$CODENAME"
IMG_URL="$IMG_URL"
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
PASSWORD="$PASSWORD"
DISK_SIZE="$DISK_SIZE"
MEMORY="$MEMORY"
CPUS="$CPUS"
SSH_PORT="$SSH_PORT"
GUI_MODE="$GUI_MODE"
PORT_FORWARDS="$PORT_FORWARDS"
IMG_FILE="$IMG_FILE"
SEED_FILE="$SEED_FILE"
CREATED="$CREATED"
EOF
    
    print_status "SUCCESS" "Configuration saved."
}

create_new_vm() {
    print_status "INFO" "Initializing new VM configuration"
    get_host_specs
    
    local os_options=()
    local i=1
    echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
    for os in "${!OS_OPTIONS[@]}"; do
        echo -e "  \033[1;36m$i)\033[0m \033[1;37m$os\033[0m"
        os_options[$i]="$os"
        ((i++))
    done
    echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
    
    while true; do
        read -p "$(print_status "INPUT" "Select OS image (1-${#OS_OPTIONS[@]}): ")" choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#OS_OPTIONS[@]} ]; then
            local os="${os_options[$choice]}"
            IFS='|' read -r OS_TYPE CODENAME IMG_URL DEFAULT_HOSTNAME DEFAULT_USERNAME DEFAULT_PASSWORD <<< "${OS_OPTIONS[$os]}"
            break
        else
            print_status "ERROR" "Invalid option. Try again."
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "VM Name (default: $DEFAULT_HOSTNAME): ")" VM_NAME
        VM_NAME="${VM_NAME:-$DEFAULT_HOSTNAME}"
        if validate_input "name" "$VM_NAME"; then
            if [[ -f "$VM_DIR/$VM_NAME.conf" ]]; then
                print_status "ERROR" "VM '$VM_NAME' already exists."
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Hostname (default: $VM_NAME): ")" HOSTNAME
        HOSTNAME="${HOSTNAME:-$VM_NAME}"
        if validate_input "name" "$HOSTNAME"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Username (default: $DEFAULT_USERNAME): ")" USERNAME
        USERNAME="${USERNAME:-$DEFAULT_USERNAME}"
        if validate_input "username" "$USERNAME"; then
            break
        fi
    done

    while true; do
        read -s -p "$(print_status "INPUT" "Password (default: $DEFAULT_PASSWORD): ")" PASSWORD
        PASSWORD="${PASSWORD:-$DEFAULT_PASSWORD}"
        echo
        if [ -n "$PASSWORD" ]; then
            break
        else
            print_status "ERROR" "Password cannot be empty."
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Disk size (Host free: ${HOST_AVAIL_DISK_GB}G | default: 20G): ")" DISK_SIZE
        DISK_SIZE="${DISK_SIZE:-20G}"
        if validate_input "size" "$DISK_SIZE"; then
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "RAM in MB (Host available: ${HOST_AVAIL_RAM_MB}MB | default: 2048): ")" MEMORY
        MEMORY="${MEMORY:-2048}"
        if validate_input "number" "$MEMORY"; then
            if [ "$MEMORY" -gt "$HOST_TOTAL_RAM_MB" ]; then
                print_status "WARN" "Allocated RAM exceeds physical host RAM ($HOST_TOTAL_RAM_MB MB)."
            fi
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "vCPUs (Host cores: ${HOST_TOTAL_CPUS} | default: 2): ")" CPUS
        CPUS="${CPUS:-2}"
        if validate_input "number" "$CPUS"; then
            if [ "$CPUS" -gt "$HOST_TOTAL_CPUS" ]; then
                print_status "WARN" "Allocated cores exceed physical host cores ($HOST_TOTAL_CPUS)."
            fi
            break
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "SSH Port Forward (default: 2222): ")" SSH_PORT
        SSH_PORT="${SSH_PORT:-2222}"
        if validate_input "port" "$SSH_PORT"; then
            if ss -tln 2>/dev/null | grep -q ":$SSH_PORT "; then
                print_status "ERROR" "Port $SSH_PORT is in use."
            else
                break
            fi
        fi
    done

    while true; do
        read -p "$(print_status "INPUT" "Enable GUI / VNC Mode? (y/n, default: n): ")" gui_input
        GUI_MODE=false
        gui_input="${gui_input:-n}"
        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
            GUI_MODE=true
            break
        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
            break
        else
            print_status "ERROR" "Please enter 'y' or 'n'."
        fi
    done

    read -p "$(print_status "INPUT" "Additional Ports (e.g., 8080:80,8443:443 | Enter to skip): ")" PORT_FORWARDS

    IMG_FILE="$VM_DIR/$VM_NAME.img"
    SEED_FILE="$VM_DIR/$VM_NAME-seed.iso"
    CREATED="$(date '+%Y-%m-%d %H:%M:%S')"

    setup_vm_image
    save_vm_config
}

setup_vm_image() {
    print_status "INFO" "Preparing disk image..."
    
    mkdir -p "$VM_DIR"
    
    if [[ -f "$IMG_FILE" ]]; then
        print_status "INFO" "Base image already present. Skipping download."
    else
        print_status "INFO" "Downloading image from repository..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$IMG_FILE.tmp"; then
            print_status "ERROR" "Download failed."
            exit 1
        fi
        mv "$IMG_FILE.tmp" "$IMG_FILE"
    fi
    
    if ! qemu-img resize "$IMG_FILE" "$DISK_SIZE" &>/dev/null; then
        print_status "WARN" "Direct resize unsupported, rebuilding disk..."
        rm -f "$IMG_FILE"
        qemu-img create -f qcow2 -F qcow2 -b "$IMG_FILE" "$IMG_FILE.tmp" "$DISK_SIZE" &>/dev/null || \
        qemu-img create -f qcow2 "$IMG_FILE" "$DISK_SIZE"
        if [ -f "$IMG_FILE.tmp" ]; then
            mv "$IMG_FILE.tmp" "$IMG_FILE"
        fi
    fi

    cat > user-data <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
users:
  - name: $USERNAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    password: $(openssl passwd -6 "$PASSWORD" | tr -d '\n')
chpasswd:
  list: |
    root:$PASSWORD
    $USERNAME:$PASSWORD
  expire: false
runcmd:
  - sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
EOF

    cat > meta-data <<EOF
instance-id: iid-$VM_NAME
local-hostname: $HOSTNAME
EOF

    if ! cloud-localds "$SEED_FILE" user-data meta-data; then
        print_status "ERROR" "Failed generating cloud-init ISO."
        exit 1
    fi
    
    print_status "SUCCESS" "VM '$VM_NAME' created."
}

start_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "WARN" "VM '$vm_name' is already running."
            return 0
        fi

        local server_ip
        server_ip=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

        print_status "INFO" "Booting VM '$vm_name' in daemon mode..."
        
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "Image missing: $IMG_FILE"
            return 1
        fi
        
        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Regenerating seed image..."
            setup_vm_image
        fi
        
        local qemu_cmd=(
            qemu-system-x86_64
            -name "$vm_name,process=$vm_name"
            -m "$MEMORY"
            -smp "$CPUS"
            -cpu EPYC
            -drive "file=$IMG_FILE,format=qcow2,if=virtio,cache=none,aio=native"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=n0
            -netdev "user,id=n0,hostfwd=tcp::$SSH_PORT-:22"
            -pidfile "$VM_DIR/$vm_name.pid"
            -daemonize
        )

        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            qemu_cmd+=(-enable-kvm -cpu host)
        fi

        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                qemu_cmd+=(-device "virtio-net-pci,netdev=n${#qemu_cmd[@]}")
                qemu_cmd+=(-netdev "user,id=n${#qemu_cmd[@]},hostfwd=tcp::$host_port-:$guest_port")
            done
        fi

        if [[ "$GUI_MODE" == true ]]; then
            qemu_cmd+=(-vga std -display vnc=:1)
            print_status "WARN" "VNC display enabled on port 5901 (:1)."
        else
            qemu_cmd+=(-display none)
        fi

        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        "${qemu_cmd[@]}"
        
        sleep 1
        if is_vm_running "$vm_name"; then
            echo ""
            echo -e "\033[1;32m┌────────────────────────────────────────────────────────┐\033[0m"
            echo -e "\033[1;32m│\033[0m \033[1;37mINSTANCE STATUS: ONLINE (Background Process)\033[0m           \033[1;32m│\033[0m"
            echo -e "\033[1;32m├────────────────────────────────────────────────────────┤\033[0m"
            printf "\033[1;32m│\033[0m  \033[1;34mSSH (Root)\033[0m : ssh -p %-5s root@%-22s \033[1;32m│\033[0m\n" "$SSH_PORT" "$server_ip"
            printf "\033[1;32m│\033[0m  \033[1;34mSSH (User)\033[0m : ssh -p %-5s %s@%-22s \033[1;32m│\033[0m\n" "$SSH_PORT" "$USERNAME" "$server_ip"
            printf "\033[1;32m│\033[0m  \033[1;34mPassword\033[0m   : %-39s \033[1;32m│\033[0m\n" "$PASSWORD"
            echo -e "\033[1;32m└────────────────────────────────────────────────────────┘\033[0m"
            echo ""
        else
            print_status "ERROR" "Failed to start VM. Check system logs."
        fi
    fi
}

delete_vm() {
    local vm_name=$1
    
    print_status "WARN" "Permanent deletion requested for: '$vm_name'"
    read -p "$(print_status "INPUT" "Confirm delete operation? (y/N): ")" -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            if is_vm_running "$vm_name"; then
                stop_vm "$vm_name"
            fi
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name.pid"
            print_status "SUCCESS" "VM '$vm_name' deleted."
        fi
    else
        print_status "INFO" "Action cancelled."
    fi
}

show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local current_status="\033[1;31mStopped\033[0m"
        if is_vm_running "$vm_name"; then
            current_status="\033[1;32mRunning\033[0m"
        fi

        local server_ip
        server_ip=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')

        echo ""
        echo -e "\033[1;36m┌────────────────────────────────────────────────────────┐\033[0m"
        echo -e "\033[1;36m│\033[0m \033[1;37mCONFIGURATION PROFILE: $vm_name\033[0m"
        echo -e "\033[1;36m├────────────────────────────────────────────────────────┤\033[0m"
        echo -e "\033[1;36m│\033[0m  \033[1;34mStatus\033[0m        : $current_status"
        echo -e "\033[1;36m│\033[0m  \033[1;34mOS Platform\033[0m   : $OS_TYPE ($CODENAME)"
        echo -e "\033[1;36m│\033[0m  \033[1;34mHostname\033[0m      : $HOSTNAME"
        echo -e "\033[1;36m│\033[0m  \033[1;34mSSH Root\033[0m      : ssh -p $SSH_PORT root@$server_ip"
        echo -e "\033[1;36m│\033[0m  \033[1;34mSSH User\033[0m      : ssh -p $SSH_PORT $USERNAME@$server_ip"
        echo -e "\033[1;36m│\033[0m  \033[1;34mPassword\033[0m      : $PASSWORD"
        echo -e "\033[1;36m│\033[0m  \033[1;34mMemory\033[0m        : $MEMORY MB"
        echo -e "\033[1;36m│\033[0m  \033[1;34mProcessors\033[0m    : $CPUS Core(s) (AMD EPYC)"
        echo -e "\033[1;36m│\033[0m  \033[1;34mStorage\033[0m       : $DISK_SIZE"
        echo -e "\033[1;36m│\033[0m  \033[1;34mGUI Mode\033[0m      : $GUI_MODE"
        echo -e "\033[1;36m│\033[0m  \033[1;34mPort Forwards\033[0m : ${PORT_FORWARDS:-None}"
        echo -e "\033[1;36m│\033[0m  \033[1;34mCreated Date\033[0m  : $CREATED"
        echo -e "\033[1;36m│\033[0m  \033[1;34mDisk Image\033[0m    : $IMG_FILE"
        echo -e "\033[1;36m└────────────────────────────────────────────────────────┘\033[0m"
        echo ""
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

is_vm_running() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
    fi
    
    if pgrep -f "qemu-system-x86_64.*$vm_name" >/dev/null; then
        return 0
    fi
    
    return 1
}

stop_vm() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            print_status "INFO" "Halting VM '$vm_name'..."
            if [[ -f "$pid_file" ]]; then
                local pid
                pid=$(cat "$pid_file" 2>/dev/null || true)
                if [[ -n "$pid" ]]; then
                    kill "$pid" 2>/dev/null || true
                fi
            fi
            pkill -f "qemu-system-x86_64.*$vm_name" 2>/dev/null || true
            sleep 2
            if is_vm_running "$vm_name"; then
                print_status "WARN" "Graceful shutdown timeout. Sending SIGKILL..."
                pkill -9 -f "qemu-system-x86_64.*$vm_name" 2>/dev/null || true
            fi
            rm -f "$pid_file"
            print_status "SUCCESS" "VM '$vm_name' stopped."
        else
            print_status "INFO" "VM '$vm_name' is not active."
        fi
    fi
}

edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        get_host_specs
        print_status "INFO" "Modifying parameters for: $vm_name"
        
        while true; do
            echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
            echo -e "  \033[1;36m1)\033[0m Hostname"
            echo -e "  \033[1;36m2)\033[0m Username"
            echo -e "  \033[1;36m3)\033[0m Password"
            echo -e "  \033[1;36m4)\033[0m SSH Port Forward"
            echo -e "  \033[1;36m5)\033[0m GUI Mode"
            echo -e "  \033[1;36m6)\033[0m Extra Port Forwards"
            echo -e "  \033[1;36m7)\033[0m Memory (RAM) \033[0;33m[Avail: ${HOST_AVAIL_RAM_MB}MB / Max: ${HOST_TOTAL_RAM_MB}MB]\033[0m"
            echo -e "  \033[1;36m8)\033[0m CPU Count \033[0;33m[Host: ${HOST_TOTAL_CPUS} Cores]\033[0m"
            echo -e "  \033[1;36m9)\033[0m Disk Allocation \033[0;33m[Free: ${HOST_AVAIL_DISK_GB}G]\033[0m"
            echo -e "  \033[1;36m0)\033[0m Return to Main Menu"
            echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
            
            read -p "$(print_status "INPUT" "Select parameter: ")" edit_choice
            
            case $edit_choice in
                1)
                    while true; do
                        read -p "$(print_status "INPUT" "New hostname (current: $HOSTNAME): ")" new_hostname
                        new_hostname="${new_hostname:-$HOSTNAME}"
                        if validate_input "name" "$new_hostname"; then
                            HOSTNAME="$new_hostname"
                            break
                        fi
                    done
                    ;;
                2)
                    while true; do
                        read -p "$(print_status "INPUT" "New username (current: $USERNAME): ")" new_username
                        new_username="${new_username:-$USERNAME}"
                        if validate_input "username" "$new_username"; then
                            USERNAME="$new_username"
                            break
                        fi
                    done
                    ;;
                3)
                    while true; do
                        read -s -p "$(print_status "INPUT" "New password (current: ****): ")" new_password
                        new_password="${new_password:-$PASSWORD}"
                        echo
                        if [ -n "$new_password" ]; then
                            PASSWORD="$new_password"
                            break
                        else
                            print_status "ERROR" "Password cannot be empty."
                        fi
                    done
                    ;;
                4)
                    while true; do
                        read -p "$(print_status "INPUT" "New SSH port (current: $SSH_PORT): ")" new_ssh_port
                        new_ssh_port="${new_ssh_port:-$SSH_PORT}"
                        if validate_input "port" "$new_ssh_port"; then
                            if [ "$new_ssh_port" != "$SSH_PORT" ] && ss -tln 2>/dev/null | grep -q ":$new_ssh_port "; then
                                print_status "ERROR" "Port $new_ssh_port is occupied."
                            else
                                SSH_PORT="$new_ssh_port"
                                break
                            fi
                        fi
                    done
                    ;;
                5)
                    while true; do
                        read -p "$(print_status "INPUT" "Enable GUI mode? (y/n, current: $GUI_MODE): ")" gui_input
                        gui_input="${gui_input:-}"
                        if [[ "$gui_input" =~ ^[Yy]$ ]]; then 
                            GUI_MODE=true
                            break
                        elif [[ "$gui_input" =~ ^[Nn]$ ]]; then
                            GUI_MODE=false
                            break
                        elif [ -z "$gui_input" ]; then
                            break
                        else
                            print_status "ERROR" "Enter 'y' or 'n'."
                        fi
                    done
                    ;;
                6)
                    read -p "$(print_status "INPUT" "Extra port forwards (current: ${PORT_FORWARDS:-None}): ")" new_port_forwards
                    PORT_FORWARDS="${new_port_forwards:-$PORT_FORWARDS}"
                    ;;
                7)
                    while true; do
                        read -p "$(print_status "INPUT" "Memory in MB (current: $MEMORY | Host Max: $HOST_TOTAL_RAM_MB): ")" new_memory
                        new_memory="${new_memory:-$MEMORY}"
                        if validate_input "number" "$new_memory"; then
                            MEMORY="$new_memory"
                            break
                        fi
                    done
                    ;;
                8)
                    while true; do
                        read -p "$(print_status "INPUT" "CPU Count (current: $CPUS | Host Max: $HOST_TOTAL_CPUS): ")" new_cpus
                        new_cpus="${new_cpus:-$CPUS}"
                        if validate_input "number" "$new_cpus"; then
                            CPUS="$new_cpus"
                            break
                        fi
                    done
                    ;;
                9)
                    while true; do
                        read -p "$(print_status "INPUT" "Disk Size (current: $DISK_SIZE | Host Free: ${HOST_AVAIL_DISK_GB}G): ")" new_disk_size
                        new_disk_size="${new_disk_size:-$DISK_SIZE}"
                        if validate_input "size" "$new_disk_size"; then
                            DISK_SIZE="$new_disk_size"
                            break
                        fi
                    done
                    ;;
                0)
                    return 0
                    ;;
                *)
                    print_status "ERROR" "Invalid option."
                    continue
                    ;;
            esac
            
            if [[ "$edit_choice" -eq 1 || "$edit_choice" -eq 2 || "$edit_choice" -eq 3 ]]; then
                print_status "INFO" "Updating cloud-init definitions..."
                setup_vm_image
            fi
            
            save_vm_config
            
            read -p "$(print_status "INPUT" "Modify other parameters? (y/N): ")" continue_editing
            if [[ ! "$continue_editing" =~ ^[Yy]$ ]]; then
                break
            fi
        done
    fi
}

resize_vm_disk() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        get_host_specs
        print_status "INFO" "Current disk allocation: $DISK_SIZE (Free: ${HOST_AVAIL_DISK_GB}G)"
        
        while true; do
            read -p "$(print_status "INPUT" "Target disk size (e.g., 50G): ")" new_disk_size
            if validate_input "size" "$new_disk_size"; then
                if [[ "$new_disk_size" == "$DISK_SIZE" ]]; then
                    print_status "INFO" "Target identical to current size. No changes made."
                    return 0
                fi
                
                local current_size_num=${DISK_SIZE%[GgMm]}
                local new_size_num=${new_disk_size%[GgMm]}
                local current_unit=${DISK_SIZE: -1}
                local new_unit=${new_disk_size: -1}
                
                if [[ "$current_unit" =~ [Gg] ]]; then
                    current_size_num=$((current_size_num * 1024))
                fi
                if [[ "$new_unit" =~ [Gg] ]]; then
                    new_size_num=$((new_size_num * 1024))
                fi
                
                if [[ $new_size_num -lt $current_size_num ]]; then
                    print_status "WARN" "Shrinking disk images carries risk of filesystem corruption!"
                    read -p "$(print_status "INPUT" "Proceed anyway? (y/N): ")" confirm_shrink
                    if [[ ! "$confirm_shrink" =~ ^[Yy]$ ]]; then
                        print_status "INFO" "Resize operation aborted."
                        return 0
                    fi
                fi
                
                print_status "INFO" "Resizing virtual drive..."
                if qemu-img resize "$IMG_FILE" "$new_disk_size"; then
                    DISK_SIZE="$new_disk_size"
                    save_vm_config
                    print_status "SUCCESS" "Disk extended to $new_disk_size."
                else
                    print_status "ERROR" "qemu-img failed to resize."
                    return 1
                fi
                break
            fi
        done
    fi
}

show_vm_performance() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        if is_vm_running "$vm_name"; then
            local qemu_pid
            if [[ -f "$VM_DIR/$vm_name.pid" ]]; then
                qemu_pid=$(cat "$VM_DIR/$vm_name.pid" 2>/dev/null || true)
            fi
            if [[ -z "$qemu_pid" ]] || ! kill -0 "$qemu_pid" 2>/dev/null; then
                qemu_pid=$(pgrep -f "qemu-system-x86_64.*$vm_name" | head -n 1)
            fi

            echo ""
            echo -e "\033[1;36m┌────────────────────────────────────────────────────────┐\033[0m"
            echo -e "\033[1;36m│\033[0m \033[1;37mMETRICS & TELEMETRY: $vm_name\033[0m"
            echo -e "\033[1;36m├────────────────────────────────────────────────────────┤\033[0m"
            
            if [[ -n "$qemu_pid" ]]; then
                echo -e "\033[1;34m Process Statistics:\033[0m"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,rss,vsz,cmd --no-headers
                echo ""
                echo -e "\033[1;34m Host Memory Consumption:\033[0m"
                free -h
                echo ""
                echo -e "\033[1;34m Storage Footprint:\033[0m"
                df -h "$IMG_FILE" 2>/dev/null || du -h "$IMG_FILE"
            else
                print_status "ERROR" "PID reference unavailable."
            fi
            echo -e "\033[1;36m└────────────────────────────────────────────────────────┘\033[0m"
            echo ""
        else
            print_status "INFO" "VM '$vm_name' is not active."
        fi
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

main_menu() {
    while true; do
        display_header
        
        local vms=($(get_vm_list))
        local vm_count=${#vms[@]}
        
        if [ $vm_count -gt 0 ]; then
            echo -e "\033[1;37mActive Instances:\033[0m"
            echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
            for i in "${!vms[@]}"; do
                local status="\033[1;31mStopped\033[0m"
                if is_vm_running "${vms[$i]}"; then
                    status="\033[1;32mOnline\033[0m"
                fi
                printf "  \033[1;36m%2d)\033[0m %-25s [%b]\n" $((i+1)) "${vms[$i]}" "$status"
            done
            echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
            echo ""
        fi
        
        echo -e "\033[1;37mControl Panel:\033[0m"
        echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
        echo -e "  \033[1;36m1)\033[0m Deploy New VM"
        if [ $vm_count -gt 0 ]; then
            echo -e "  \033[1;36m2)\033[0m Power On (Start)"
            echo -e "  \033[1;36m3)\033[0m Power Off (Stop)"
            echo -e "  \033[1;36m4)\033[0m View Detailed Info"
            echo -e "  \033[1;36m5)\033[0m Edit Configuration"
            echo -e "  \033[1;36m6)\033[0m Destroy Instance (Delete)"
            echo -e "  \033[1;36m7)\033[0m Expand Disk Storage"
            echo -e "  \033[1;36m8)\033[0m System Telemetry"
        fi
        echo -e "  \033[1;36m0)\033[0m Exit Console"
        echo -e "\033[1;30m────────────────────────────────────────────────────────\033[0m"
        echo ""
        
        read -p "$(print_status "INPUT" "Selection: ")" choice
        
        case $choice in
            1)
                create_new_vm
                ;;
            2)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        start_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            3)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        stop_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            4)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            0)
                print_status "INFO" "Session terminated."
                exit 0
                ;;
            *)
                print_status "ERROR" "Option unrecognized."
                ;;
        esac
        
        read -p "$(print_status "INPUT" "Press Enter to return to menu...")"
    done
}

trap cleanup EXIT

check_dependencies

VM_DIR="${VM_DIR:-$HOME/vms}"
mkdir -p "$VM_DIR"

declare -A OS_OPTIONS=(
    ["Ubuntu 24.04"]="ubuntu|noble|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img|ubuntu24|ubuntu|ubuntu"
)

main_menu
