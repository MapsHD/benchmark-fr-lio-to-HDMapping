FROM ubuntu:22.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    ca-certificates \
    wget \
    libeigen3-dev \
    libpcl-dev \
    libtbb-dev \
    libgoogle-glog-dev \
    python3-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 2 Humble ─────────────────────────────────────────────────────────────
# fr-lio's own environment (pixi.toml, default "humble") pulls the same
# packages from RoboStack; here they come from the ROS apt repository.
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros2.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-humble-desktop \
    ros-humble-pcl-ros \
    ros-humble-pcl-conversions \
    ros-humble-gtsam \
    ros-humble-mocap4r2-msgs \
    ros-humble-rosbag2-cpp \
    ros-humble-rosbag2-storage-default-plugins \
    python3-colcon-common-extensions \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (used to convert ROS 1 bags to ROS 2, if needed) ─────────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── ikd-tree ─────────────────────────────────────────────────────────────────
# fr-lio finds it with find_package(ikd_tree); upstream gets it from a conda
# channel. Built from the author's ikd-tree fork (src/ikd-tree) and installed
# into /usr/local, outside the colcon workspace.
COPY ./src/ikd-tree /tmp/ikd-tree
RUN cmake -S /tmp/ikd-tree -B /tmp/ikd-tree/build -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF && \
    cmake --build /tmp/ikd-tree/build -j$(nproc) && \
    cmake --install /tmp/ikd-tree/build && \
    rm -rf /tmp/ikd-tree

# ── Build colcon workspace (Livox SDK + driver, fr-lio, converter) ───────────
WORKDIR /ros2_ws

# Livox-SDK2 and livox_ros_driver2 are the author's forks (deps.repos upstream),
# pinned as submodules; livox_ros_driver2 provides the CustomMsg fr-lio reads.
COPY ./src/Livox-SDK2            ./src/Livox-SDK2
COPY ./src/livox_ros_driver2     ./src/livox_ros_driver2
COPY ./src/fr-lio                ./src/fr-lio
COPY ./src/fr-lio-to-hdmapping   ./src/fr-lio-to-hdmapping

# Benchmark launch (accumulator count and input topic as launch args) added
# into the fr_lio package; preflight check used by the run script.
COPY ./overlay/launch/  ./src/fr-lio/launch/
COPY ./overlay/scripts/ /ros2_ws/scripts/

# The final guard fails the image build loudly if an executable is missing.
RUN source /opt/ros/humble/setup.bash && \
    colcon build --cmake-args -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF -DROS_EDITION=ROS2 && \
    test -f /ros2_ws/install/fr_lio/lib/fr_lio/frlio && \
    test -f /ros2_ws/install/fr_lio/lib/fr_lio/lidar_accumulator && \
    test -f /ros2_ws/install/fr_lio/share/fr_lio/launch/fr_lio_bench.launch.py && \
    test -f /ros2_ws/install/fr_lio_to_hdmapping/lib/fr_lio_to_hdmapping/listener && \
    echo "[build] frlio, lidar_accumulator, bench launch and converter present"

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros2_ws

RUN echo "source /opt/ros/humble/setup.bash"   >> /root/.bashrc && \
    echo "source /ros2_ws/install/setup.bash"  >> /root/.bashrc && \
    echo "source /opt/ros/humble/setup.bash"   >> /home/ros/.bashrc && \
    echo "source /ros2_ws/install/setup.bash"  >> /home/ros/.bashrc

CMD ["bash"]
