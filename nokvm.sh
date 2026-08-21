#!/bin/bash
set -euo pipefail

display_header() {
    clear
    if command -v toilet &> /dev/null; then
        toilet -f big -F metal "JKSoft"
    elif command -v figlet &> /dev/null; then
        figlet "JKSoft"
    else
        echo -e "\033[1;36mJKSoft Cloud Manager\033[0m"
    fi
    echo ""
    echo -e "  \033[1;30m⚡\033[0m \033[1;37mVirtual Machine & Cloud Compute Console\033[0m"
    echo ""
}

print_status() {
    local type=$1
    local message=$2
    
    case $type in
        "INFO") echo -e "  \033[1;34mℹ INFO\033[0m     $message" ;;
        "WARN") echo -e "  \033[1;33m⚠ WARN\033[0m     $message" ;;
        "ERROR") echo -e "  \033[1;31m✖ FAIL\033[0m     $message" ;;
        "SUCCESS") echo -e "  \033[1;32m✔ DONE\033[0m     $message" ;;
        "INPUT") echo -e "  \033[1;36m➜ INPUT\033[0m    $message" ;;
        *) echo -e "  \033[1;37m$type\033[0m      $message" ;;
    esac
}

get_best_epyc_model() {
    local candidate_models=("EPYC-Genoa" "EPYC-Milan" "EPYC-Rome" "EPYC-v4" "EPYC-v3" "EPYC-v2" "EPYC")
    local supported_models
    supported_models=$(qemu-system-x86_64 -cpu help 2>/dev/null | awk '{print $2}' || true)
    
    for model in "${candidate_models[@]}"; do
        if echo "$supported_models" | grep -qx "$model"; then
            echo "$model"
            return 0
        fi
    done
    echo "EPYC"
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
    local tmp_ud="/tmp/user-data-$$"
    local tmp_md="/tmp/meta-data-$$"
    rm -f "$tmp_ud" "$tmp_md"
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
    echo ""
    
    local os_options=()
    local i=1
    for os in "${!OS_OPTIONS[@]}"; do
        echo -e "    \033[1;36m$i\033[0m  $os"
        os_options[$i]="$os"
        ((i++))
    done
    echo ""
    
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
                print_status "ERROR" "Port $SSH_PORT is already in use by host or another VM."
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
    print_status "INFO" "Preparing disk and isolated cloud-init for '$VM_NAME'..."
    
    mkdir -p "$VM_DIR"
    
    local base_raw="$VM_DIR/base-${CODENAME}.img"
    if [[ ! -f "$base_raw" ]]; then
        print_status "INFO" "Downloading official cloud base image..."
        if ! wget --progress=bar:force "$IMG_URL" -O "$base_raw.tmp"; then
            print_status "ERROR" "Download failed."
            exit 1
        fi
        mv "$base_raw.tmp" "$base_raw"
    fi

    if [[ ! -f "$IMG_FILE" ]]; then
        cp --sparse=always "$base_raw" "$IMG_FILE"
        qemu-img resize "$IMG_FILE" "$DISK_SIZE" &>/dev/null || true
    fi

    local tmp_ud="/tmp/user-data-${VM_NAME}-$$"
    local tmp_md="/tmp/meta-data-${VM_NAME}-$$"

    cat > "$tmp_ud" <<EOF
#cloud-config
hostname: $HOSTNAME
ssh_pwauth: true
disable_root: false
packages:
  - toilet
  - figlet
  - bc
  - curl
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
write_files:
  - path: /etc/update-motd.d/01-jksoft-motd
    permissions: '0755'
    content: |
      #!/bin/bash
      clear
      if command -v toilet &> /dev/null; then
          toilet -f big -F metal "JKSoft"
      elif command -v figlet &> /dev/null; then
          figlet "JKSoft"
      else
          echo -e "\033[1;36mJKSoft\033[0m"
      fi
      echo ""
      echo -e "  \033[1;30m⚡\033[0m \033[1;37mWelcome to JKSoft Cloud Virtual Machine\033[0m"
      echo ""
      
      OS_NAME=\$(grep -oP '(?<=^PRETTY_NAME=).+' /etc/os-release 2>/dev/null | tr -d '"' || uname -sr)
      KERNEL_VER=\$(uname -r)
      UPTIME_VAL=\$(uptime -p 2>/dev/null | sed 's/up //')
      PACKAGES_COUNT=\$(dpkg-query -f '\${binary:Package}\n' -W 2>/dev/null | wc -l || echo "N/A")
      
      CPU_MODEL=\$(lscpu 2>/dev/null | awk -F: '/Model name/ {print \$2}' | sed 's/^[ \t]*//' | head -n 1)
      CPU_CORES=\$(nproc)
      
      MEM_TOTAL=\$(free -m | awk '/^Mem:/{print \$2}')
      MEM_USED=\$(free -m | awk '/^Mem:/{print \$3}')
      
      DISK_TOTAL=\$(df -h / | awk 'NR==2 {print \$2}')
      DISK_USED=\$(df -h / | awk 'NR==2 {print \$3}')
      DISK_PERCENT=\$(df -h / | awk 'NR==2 {print \$5}')
      
      IP_ADDR=\$(hostname -I 2>/dev/null | awk '{print \$1}')
      PUB_IP=\$(curl -s -m 2 -4 ifconfig.me 2>/dev/null || curl -s -m 2 -4 icanhazip.com 2>/dev/null || echo "N/A")
      
      printf "    \033[1;35m%-12s\033[0m : %s\n" "OS" "\$OS_NAME"
      printf "    \033[1;35m%-12s\033[0m : %s\n" "Host" "KVM/QEMU Cloud VM"
      printf "    \033[1;35m%-12s\033[0m : %s\n" "Kernel" "\$KERNEL_VER"
      printf "    \033[1;35m%-12s\033[0m : %s\n" "Uptime" "\$UPTIME_VAL"
      printf "    \033[1;35m%-12s\033[0m : %s (dpkg)\n" "Packages" "\$PACKAGES_COUNT"
      printf "    \033[1;35m%-12s\033[0m : %s (%s Cores)\n" "CPU" "\${CPU_MODEL:-AMD EPYC}" "\$CPU_CORES"
      printf "    \033[1;35m%-12s\033[0m : %sMB / %sMB\n" "Memory" "\$MEM_USED" "\$MEM_TOTAL"
      printf "    \033[1;35m%-12s\033[0m : %s / %s (%s)\n" "Disk" "\$DISK_USED" "\$DISK_TOTAL" "\$DISK_PERCENT"
      printf "    \033[1;35m%-12s\033[0m : %s\n" "Local IP" "\$IP_ADDR"
      printf "    \033[1;35m%-12s\033[0m : %s\n" "Public IP" "\$PUB_IP"
      echo ""
      echo -e "    \033[40m   \033[41m   \033[42m   \033[43m   \033[44m   \033[45m   \033[46m   \033[47m   \033[0m"
      echo -e "    \033[100m   \033[101m   \033[102m   \033[103m   \033[104m   \033[105m   \033[106m   \033[107m   \033[0m"
      echo ""
runcmd:
  - chmod -x /etc/update-motd.d/* 2>/dev/null || true
  - chmod +x /etc/update-motd.d/01-jksoft-motd
  - rm -f /etc/legal /etc/motd
  - touch /etc/motd
  - sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  - sed -i 's/^#\?ClientAliveInterval .*/ClientAliveInterval 30/' /etc/ssh/sshd_config
  - sed -i 's/^#\?ClientAliveCountMax .*/ClientAliveCountMax 5/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PrintMotd .*/PrintMotd no/' /etc/ssh/sshd_config
  - sed -i 's/^#\?PrintLastLog .*/PrintLastLog no/' /etc/ssh/sshd_config
  - echo "UseDNS no" >> /etc/ssh/sshd_config
  - echo "GSSAPIAuthentication no" >> /etc/ssh/sshd_config
  - systemctl restart ssh || systemctl restart sshd
EOF

    cat > "$tmp_md" <<EOF
instance-id: iid-$VM_NAME-$(date +%s)
local-hostname: $HOSTNAME
EOF

    rm -f "$SEED_FILE"
    if ! cloud-localds "$SEED_FILE" "$tmp_ud" "$tmp_md"; then
        print_status "ERROR" "Failed generating cloud-init ISO for '$VM_NAME'."
        rm -f "$tmp_ud" "$tmp_md"
        exit 1
    fi
    rm -f "$tmp_ud" "$tmp_md"
    
    print_status "SUCCESS" "Isolated configuration for '$VM_NAME' generated."
}

get_exact_vm_pid() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            if grep -qa "vm_${vm_name}" "/proc/$pid/cmdline" 2>/dev/null; then
                echo "$pid"
                return 0
            fi
        fi
    fi

    local matched_pids
    matched_pids=$(pgrep -f "qemu-system-x86_64.*-name vm_${vm_name}," 2>/dev/null || true)
    if [[ -n "$matched_pids" ]]; then
        echo "$matched_pids" | head -n 1
        return 0
    fi

    echo ""
}

get_vm_status() {
    local vm_name=$1
    local log_file="$VM_DIR/$vm_name.log"
    local pid
    pid=$(get_exact_vm_pid "$vm_name")
    
    if [[ -z "$pid" ]]; then
        echo "STOPPED"
        return 0
    fi
    
    if [[ -f "$log_file" ]] && grep -qE "cloud-init.*finished at|JKSoft Cloud Instance Ready" "$log_file" 2>/dev/null; then
        echo "ONLINE"
    else
        echo "PROVISIONING"
    fi
}

start_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local current_status
        current_status=$(get_vm_status "$vm_name")
        if [ "$current_status" != "STOPPED" ]; then
            print_status "WARN" "VM '$vm_name' is already $current_status."
            return 0
        fi

        local vms=($(get_vm_list))
        for other_vm in "${vms[@]}"; do
            if [ "$other_vm" != "$vm_name" ]; then
                local other_status
                other_status=$(get_vm_status "$other_vm")
                if [ "$other_status" == "PROVISIONING" ]; then
                    print_status "WARN" "Instance '$other_vm' is currently in Provisioning status. Launching '$vm_name' simultaneously..."
                fi
            fi
        done

        local server_ip
        server_ip=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')
        local log_file="$VM_DIR/$vm_name.log"
        local epyc_cpu
        epyc_cpu=$(get_best_epyc_model)

        print_status "INFO" "Booting VM '$vm_name' with CPU: AMD $epyc_cpu..."
        
        if [[ ! -f "$IMG_FILE" ]]; then
            print_status "ERROR" "Image missing: $IMG_FILE"
            return 1
        fi
        
        if [[ ! -f "$SEED_FILE" ]]; then
            print_status "WARN" "Regenerating seed image..."
            setup_vm_image
        fi

        if [[ ! -f "$log_file" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] Initializing isolated QEMU runtime for $vm_name ($epyc_cpu)" > "$log_file"
        fi
        
        local qemu_cmd=(
            qemu-system-x86_64
            -name "vm_${vm_name},process=vm_${vm_name}"
            -m "$MEMORY"
            -smp "$CPUS,sockets=1,cores=$CPUS,threads=1"
            -cpu "$epyc_cpu"
            -drive "file=$IMG_FILE,format=qcow2,if=virtio,cache=writeback,discard=unmap"
            -drive "file=$SEED_FILE,format=raw,if=virtio"
            -boot order=c
            -device virtio-net-pci,netdev=net0
            -netdev "user,id=net0,hostfwd=tcp::$SSH_PORT-:22"
            -serial "file:$log_file"
            -pidfile "$VM_DIR/$vm_name.pid"
            -daemonize
        )

        if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
            qemu_cmd+=(-enable-kvm)
        else
            qemu_cmd+=(-accel tcg,thread=multi)
        fi

        if [[ -n "$PORT_FORWARDS" ]]; then
            IFS=',' read -ra forwards <<< "$PORT_FORWARDS"
            local p_idx=1
            for forward in "${forwards[@]}"; do
                IFS=':' read -r host_port guest_port <<< "$forward"
                qemu_cmd+=(-device "virtio-net-pci,netdev=net${p_idx}")
                qemu_cmd+=(-netdev "user,id=net${p_idx},hostfwd=tcp::$host_port-:$guest_port")
                ((p_idx++))
            done
        fi

        if [[ "$GUI_MODE" == true ]]; then
            local vnc_display_port=$((SSH_PORT % 100))
            qemu_cmd+=(-vga std -display "vnc=:${vnc_display_port}")
            local vnc_real_port=$((5900 + vnc_display_port))
            print_status "WARN" "VNC display enabled on port ${vnc_real_port} (:${vnc_display_port})."
        else
            qemu_cmd+=(-display none)
        fi

        qemu_cmd+=(
            -device virtio-balloon-pci
            -object rng-random,filename=/dev/urandom,id=rng0
            -device virtio-rng-pci,rng=rng0
        )

        "${qemu_cmd[@]}" 2>> "$log_file" || {
            print_status "ERROR" "QEMU execution crashed for '$vm_name'. Check logs via Menu 11."
            return 1
        }
        
        sleep 1
        print_status "SUCCESS" "Instance '$vm_name' launched. Live status tracking in Main Menu."
    fi
}

stop_vm() {
    local vm_name=$1
    local pid_file="$VM_DIR/$vm_name.pid"
    
    if load_vm_config "$vm_name"; then
        local pid
        pid=$(get_exact_vm_pid "$vm_name")
        
        if [[ -n "$pid" ]]; then
            print_status "INFO" "Halting instance '$vm_name' (PID: $pid)..."
            kill "$pid" 2>/dev/null || true
            
            local count=0
            while kill -0 "$pid" 2>/dev/null && [ $count -lt 5 ]; do
                sleep 1
                ((count++))
            done
            
            if kill -0 "$pid" 2>/dev/null; then
                print_status "WARN" "Instance '$vm_name' did not terminate gracefully. Sending SIGKILL..."
                kill -9 "$pid" 2>/dev/null || true
            fi
            
            rm -f "$pid_file"
            print_status "SUCCESS" "VM '$vm_name' stopped safely without affecting other instances."
        else
            rm -f "$pid_file"
            print_status "INFO" "VM '$vm_name' is not active."
        fi
    fi
}

restart_vm() {
    local vm_name=$1
    print_status "INFO" "Restarting VM '$vm_name'..."
    local current_status
    current_status=$(get_vm_status "$vm_name")
    if [ "$current_status" != "STOPPED" ]; then
        stop_vm "$vm_name"
        sleep 1
    fi
    start_vm "$vm_name"
}

rebuild_vm() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        print_status "WARN" "Rebuild will wipe OS disk and apply latest cloud-init/MOTD scripts!"
        print_status "INFO" "Retained parameters: SSH Port ($SSH_PORT), Username ($USERNAME), Password ($PASSWORD), RAM ($MEMORY MB), CPUs ($CPUS)."
        read -p "$(print_status "INPUT" "Confirm rebuild operation for '$vm_name'? (y/N): ")" -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "INFO" "Rebuild operation cancelled."
            return 0
        fi

        local current_status
        current_status=$(get_vm_status "$vm_name")
        if [ "$current_status" != "STOPPED" ]; then
            stop_vm "$vm_name"
            sleep 1
        fi

        print_status "INFO" "Cleaning storage and logs for '$vm_name'..."
        rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.pid" "$VM_DIR/$vm_name.log"

        print_status "INFO" "Rebuilding isolated disk and seed image..."
        setup_vm_image

        CREATED="$(date '+%Y-%m-%d %H:%M:%S') (Rebuilt)"
        save_vm_config

        print_status "SUCCESS" "VM '$vm_name' successfully rebuilt."
        start_vm "$vm_name"
    fi
}

view_vm_logs() {
    local vm_name=$1
    local log_file="$VM_DIR/$vm_name.log"
    
    if [[ ! -f "$log_file" ]]; then
        print_status "WARN" "Log file not found ($log_file). Start the VM first."
        return 0
    fi
    
    echo ""
    echo -e "  \033[1;36mLive System & Console Log for $vm_name\033[0m"
    echo -e "  \033[0;33m(Press Ctrl+C to exit log view)\033[0m"
    echo ""
    trap 'echo ""' INT
    tail -n 40 -f "$log_file"
    trap cleanup EXIT
}

delete_vm() {
    local vm_name=$1
    
    print_status "WARN" "Permanent deletion requested for: '$vm_name'"
    read -p "$(print_status "INPUT" "Confirm delete operation? (y/N): ")" -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if load_vm_config "$vm_name"; then
            local current_status
            current_status=$(get_vm_status "$vm_name")
            if [ "$current_status" != "STOPPED" ]; then
                stop_vm "$vm_name"
            fi
            rm -f "$IMG_FILE" "$SEED_FILE" "$VM_DIR/$vm_name.conf" "$VM_DIR/$vm_name.pid" "$VM_DIR/$vm_name.log"
            print_status "SUCCESS" "VM '$vm_name' deleted."
        fi
    else
        print_status "INFO" "Action cancelled."
    fi
}

show_vm_info() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        local raw_status
        raw_status=$(get_vm_status "$vm_name")
        local current_status="\033[1;31mStopped\033[0m"
        if [ "$raw_status" == "ONLINE" ]; then
            current_status="\033[1;32mOnline\033[0m"
        elif [ "$raw_status" == "PROVISIONING" ]; then
            current_status="\033[1;33mProvisioning\033[0m"
        fi

        local server_ip
        server_ip=$(curl -s -4 ifconfig.me || hostname -I | awk '{print $1}')
        local epyc_cpu
        epyc_cpu=$(get_best_epyc_model)

        echo ""
        echo -e "  \033[1;36m$vm_name Details\033[0m"
        echo ""
        printf "    \033[0;34m%-16s\033[0m : %b\n" "Status" "$current_status"
        printf "    \033[0;34m%-16s\033[0m : %s (%s)\n" "OS Platform" "$OS_TYPE" "$CODENAME"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Hostname" "$HOSTNAME"
        printf "    \033[0;34m%-16s\033[0m : ssh -p %s root@%s\n" "SSH Root" "$SSH_PORT" "$server_ip"
        printf "    \033[0;34m%-16s\033[0m : ssh -p %s %s@%s\n" "SSH User" "$SSH_PORT" "$USERNAME" "$server_ip"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Password" "$PASSWORD"
        printf "    \033[0;34m%-16s\033[0m : %s MB\n" "Memory" "$MEMORY"
        printf "    \033[0;34m%-16s\033[0m : %s Core(s) (AMD %s)\n" "Processors" "$CPUS" "$epyc_cpu"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Storage" "$DISK_SIZE"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "GUI Mode" "$GUI_MODE"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Port Forwards" "${PORT_FORWARDS:-None}"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Created Date" "$CREATED"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Disk Image" "$IMG_FILE"
        printf "    \033[0;34m%-16s\033[0m : %s\n" "Log File" "$VM_DIR/$vm_name.log"
        echo ""
        read -p "$(print_status "INPUT" "Press Enter to continue...")"
    fi
}

edit_vm_config() {
    local vm_name=$1
    
    if load_vm_config "$vm_name"; then
        get_host_specs
        print_status "INFO" "Modifying parameters for: $vm_name"
        echo ""
        
        while true; do
            echo -e "    \033[1;36m1\033[0m  Hostname"
            echo -e "    \033[1;36m2\033[0m  Username"
            echo -e "    \033[1;36m3\033[0m  Password"
            echo -e "    \033[1;36m4\033[0m  SSH Port Forward"
            echo -e "    \033[1;36m5\033[0m  GUI Mode"
            echo -e "    \033[1;36m6\033[0m  Extra Port Forwards"
            echo -e "    \033[1;36m7\033[0m  Memory (RAM) \033[0;33m[Avail: ${HOST_AVAIL_RAM_MB}MB / Max: ${HOST_TOTAL_RAM_MB}MB]\033[0m"
            echo -e "    \033[1;36m8\033[0m  CPU Count \033[0;33m[Host: ${HOST_TOTAL_CPUS} Cores]\033[0m"
            echo -e "    \033[1;36m9\033[0m  Disk Allocation \033[0;33m[Free: ${HOST_AVAIL_DISK_GB}G]\033[0m"
            echo -e "    \033[1;36m0\033[0m  Return to Main Menu"
            echo ""
            
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
        echo ""
        
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
        local raw_status
        raw_status=$(get_vm_status "$vm_name")
        if [ "$raw_status" != "STOPPED" ]; then
            local qemu_pid
            qemu_pid=$(get_exact_vm_pid "$vm_name")

            echo ""
            echo -e "  \033[1;36m$vm_name Performance\033[0m"
            echo ""
            
            if [[ -n "$qemu_pid" ]]; then
                echo -e "    \033[0;34mProcess Info\033[0m"
                echo -e "    PID   %CPU  %MEM  RSS     VSZ"
                ps -p "$qemu_pid" -o pid,%cpu,%mem,rss,vsz --no-headers | awk '{printf "    %-5s %-5s %-5s %-7s %-7s\n", $1, $2, $3, $4, $5}'
                echo ""
                echo -e "    \033[0;34mHost Memory\033[0m"
                free -h | awk 'NR<=2 {print "    " $0}'
                echo ""
                echo -e "    \033[0;34mDisk Footprint\033[0m"
                local disk_usage
                disk_usage=$(du -h "$IMG_FILE" 2>/dev/null | awk '{print $1}')
                echo -e "    Size on disk: $disk_usage"
            else
                print_status "ERROR" "PID reference unavailable."
            fi
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
        local has_provisioning=0
        
        if [ $vm_count -gt 0 ]; then
            echo -e "  \033[1;37mVirtual Instances\033[0m"
            echo ""
            for i in "${!vms[@]}"; do
                local raw_status
                raw_status=$(get_vm_status "${vms[$i]}")
                local status="\033[1;31mStopped\033[0m"
                local dot="\033[1;31m○\033[0m"
                
                if [ "$raw_status" == "ONLINE" ]; then
                    status="\033[1;32mOnline\033[0m"
                    dot="\033[1;32m●\033[0m"
                elif [ "$raw_status" == "PROVISIONING" ]; then
                    status="\033[1;33mProvisioning (Penyediaan)\033[0m"
                    dot="\033[1;33m⏳\033[0m"
                    has_provisioning=1
                fi
                printf "    \033[1;36m%d\033[0m  %b  %-22s \033[0;30m|\033[0m %b\n" $((i+1)) "$dot" "${vms[$i]}" "$status"
            done
            echo ""
        fi
        
        echo -e "  \033[1;37mActions\033[0m"
        echo ""
        echo -e "    \033[1;36m1\033[0m   Deploy New Instance"
        if [ $vm_count -gt 0 ]; then
            echo -e "    \033[1;36m2\033[0m   Start Instance"
            echo -e "    \033[1;36m3\033[0m   Stop Instance"
            echo -e "    \033[1;36m4\033[0m   Restart Instance"
            echo -e "    \033[1;36m5\033[0m   Rebuild Instance (Clean Install)"
            echo -e "    \033[1;36m6\033[0m   Show Instance Info"
            echo -e "    \033[1;36m7\033[0m   Edit Configuration"
            echo -e "    \033[1;36m8\033[0m   Delete Instance"
            echo -e "    \033[1;36m9\033[0m   Resize Storage"
            echo -e "    \033[1;36m10\033[0m  Performance Telemetry"
            echo -e "    \033[1;36m11\033[0m  Live Boot / Console Logs"
        fi
        echo -e "    \033[1;36m0\033[0m   Exit"
        echo ""

        local choice=""
        if [ "$has_provisioning" -eq 1 ]; then
            if ! read -t 3 -p "$(print_status "INPUT" "Option (Auto-refresh 3s): ")" choice; then
                continue
            fi
        else
            read -p "$(print_status "INPUT" "Option: ")" choice
        fi

        if [[ -z "$choice" ]]; then
            continue
        fi
        
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
                        restart_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            5)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index to rebuild: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        rebuild_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            6)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_info "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            7)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        edit_vm_config "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            8)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        delete_vm "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            9)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        resize_vm_disk "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            10)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        show_vm_performance "${vms[$((vm_num-1))]}"
                    else
                        print_status "ERROR" "Invalid target."
                    fi
                fi
                ;;
            11)
                if [ $vm_count -gt 0 ]; then
                    read -p "$(print_status "INPUT" "Target index to inspect logs: ")" vm_num
                    if [[ "$vm_num" =~ ^[0-9]+$ ]] && [ "$vm_num" -ge 1 ] && [ "$vm_num" -le $vm_count ]; then
                        view_vm_logs "${vms[$((vm_num-1))]}"
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
