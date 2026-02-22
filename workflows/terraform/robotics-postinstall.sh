#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root via sudo: sudo /usr/local/bin/robotics-postinstall.sh"
  exit 1
fi

exec > >(tee -a /var/log/robotics-postinstall.log) 2>&1

ADMIN_USER="__ADMIN_USER__"

ENABLE_CUDA_TOOLKIT="${ENABLE_CUDA_TOOLKIT:-true}"
CUDA_KEYRING_URL="${CUDA_KEYRING_URL:-https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/x86_64/cuda-keyring_1.1-1_all.deb}"
CUDA_APT_PKG="${CUDA_APT_PKG:-cuda-toolkit}"

INSTALL_ROS2="${INSTALL_ROS2:-true}"
ROS_DISTRO="${ROS_DISTRO:-humble}"

INSTALL_GAZEBO="${INSTALL_GAZEBO:-true}"
INSTALL_ISAAC_HELPERS="${INSTALL_ISAAC_HELPERS:-true}"
ISAAC_IMAGE="${ISAAC_IMAGE:-nvcr.io/nvidia/isaac-sim:latest}"

apt_update() {
  apt-get update
}

apt_install() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

echo "=== [1/6] Docker ==="
apt_update
apt_install docker.io
systemctl enable --now docker
if id "${ADMIN_USER}" >/dev/null 2>&1; then
  usermod -aG docker "${ADMIN_USER}" || true
fi

echo "=== [2/6] NVIDIA Container Toolkit ==="
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor --yes -o /usr/share/keyrings/nvidia-container-toolkit.gpg
cat >/etc/apt/sources.list.d/nvidia-container-toolkit.list <<EOF
deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit.gpg] https://nvidia.github.io/libnvidia-container/stable/deb/amd64 /
EOF
apt_update
apt_install nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker || true
systemctl restart docker

echo "=== [3/6] CUDA toolkit (optional) ==="
if [[ "${ENABLE_CUDA_TOOLKIT}" == "true" ]]; then
  wget -qO /tmp/cuda-keyring.deb "${CUDA_KEYRING_URL}"
  dpkg -i /tmp/cuda-keyring.deb
  apt_update
  apt_install "${CUDA_APT_PKG}" || true
fi

echo "=== [4/6] ROS 2 (optional) ==="
if [[ "${INSTALL_ROS2}" == "true" ]]; then
  curl -fsSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/ros-archive-keyring.gpg
  echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu jammy main" \
    >/etc/apt/sources.list.d/ros2.list
  apt_update
  apt_install "ros-${ROS_DISTRO}-desktop" python3-colcon-common-extensions
  echo "source /opt/ros/${ROS_DISTRO}/setup.bash" >/etc/profile.d/ros2.sh
fi

echo "=== [5/6] Gazebo (optional) ==="
if [[ "${INSTALL_GAZEBO}" == "true" ]]; then
  apt_install gazebo
  if [[ "${INSTALL_ROS2}" == "true" ]]; then
    apt_install "ros-${ROS_DISTRO}-gazebo-ros-pkgs" || true
  fi
fi

echo "=== [6/6] Helper scripts ==="
cat >/usr/local/bin/gpu-check <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "== nvidia-smi =="
nvidia-smi || true
EOF
chmod +x /usr/local/bin/gpu-check

if [[ "${INSTALL_ISAAC_HELPERS}" == "true" ]]; then
  cat >/usr/local/bin/isaac-sim-run <<EOF
#!/usr/bin/env bash
set -euo pipefail
docker run --rm --gpus all --network host ${ISAAC_IMAGE}
EOF
  chmod +x /usr/local/bin/isaac-sim-run
fi

echo
echo "Robotics stack setup completed."
echo "Log: /var/log/robotics-postinstall.log"
echo "You may need to re-login for docker group membership to apply."
