#!/bin/bash
# Run fr-lio on a rosbag (ROS 2 bag directory or ROS 1 .bag), record output
# topics, then convert the recorded bag to an HDMapping session.
#
# fr-lio reads Livox CustomMsg scans (livox_ros_driver2) through its
# lidar_accumulator, which merges a number of consecutive messages into one
# scan; the preflight check derives that number from the bag (1 for a bag that
# already holds full 100 ms scans, 10 for a driver publishing 10 ms packets).
#
# fr-lio publishes its pose only at IMU rate, forward-propagated from the last
# scan update: /odom (orientation smoothed for flight control),
# /odom_unfiltered (the raw estimator state) and /odom_map (with loop-closure
# corrections, map frame). We record /odom_unfiltered and /cloud_registered,
# both in the odom frame and stamped with times taken from the input messages,
# i.e. bag time. fr-lio's clock is left untouched (no use_sim_time).

IMAGE_NAME='fr-lio_humble'
TMUX_SESSION='ros2_fr_lio'

DATASET_CONTAINER_PATH='/ros2_ws/dataset/input.bag'
DATASET_ROS2_PATH='/tmp/dataset_ros2'
BAG_OUTPUT_CONTAINER='/ros2_ws/recordings'
CONFIG_MOUNT_CONTAINER='/ros2_ws/config/fr_lio.yaml'
CONFIG_DIR_CONTAINER='/ros2_ws/install/fr_lio/share/fr_lio/config'
COUNT_FILE_CONTAINER='/tmp/fr_lio_accumulate_count'

RECORDED_BAG_NAME="recorded-fr-lio"
HDMAPPING_OUT_NAME="output_hdmapping"

# Recorded topics (used by the converter).
ODOM_TOPIC="${ODOM_TOPIC:-/odom_unfiltered}"
CLOUD_TOPIC="${CLOUD_TOPIC:-/cloud_registered}"

# Livox CustomMsg topic in the bag (input of fr-lio's lidar_accumulator).
LIDAR_TOPIC="${LIDAR_TOPIC:-/livox/lidar}"

# Messages lidar_accumulator merges into one scan. Empty = derived from the bag.
ACCUMULATE_COUNT="${ACCUMULATE_COUNT:-}"

# fr-lio parameter file: a file on the host, or the name of one shipped with
# fr-lio in its config/ folder. Default: fr-lio's own indoors.yaml.
CONFIG_FILE="${CONFIG_FILE:-indoors.yaml}"

# RViz on by default — the live view of how fr-lio tracks the dataset.
USE_RVIZ="${USE_RVIZ:-1}"

# Force Mesa software rendering by default so RViz renders even when the host
# GPU driver is not exposed to the container (the libGL "nvidia-drm" / amdgpu case).
LIBGL_SW="${LIBGL_SW:-1}"
if [[ "$LIBGL_SW" == "1" ]]; then LIBGL_ENV="1"; else LIBGL_ENV=""; fi

usage() {
  echo "Usage:"
  echo "  $0 <ros2_bag_dir | input.bag> <output_dir>"
  echo
  echo "  ros2_bag_dir : ROS 2 bag directory — played directly, no conversion"
  echo "                 (this is what the HDMapping orchestration passes)"
  echo "  input.bag    : ROS 1 bag file — its LiDAR and IMU topics are converted to ROS 2 first"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  CONFIG_FILE      - fr-lio parameter file: a host *.yaml, or the name of one in"
  echo "                     fr-lio's config/ folder         (default: indoors.yaml)"
  echo "  LIDAR_TOPIC      - Livox CustomMsg topic in the bag  (default: /livox/lidar)"
  echo "  ACCUMULATE_COUNT - messages merged into one scan     (default: derived from the bag)"
  echo "  ODOM_TOPIC       - recorded odometry topic           (default: /odom_unfiltered)"
  echo "  CLOUD_TOPIC      - recorded scan topic               (default: /cloud_registered)"
  echo "  USE_RVIZ         - 1/0, launch RViz live view        (default: 1)"
  echo "  PLAY_RATE        - ros2 bag play rate                (default: 1.0)"
  exit 1
}

echo "=== fr-lio rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -e "$DATASET_HOST_PATH" ]]; then
  echo "Error: input does not exist: $DATASET_HOST_PATH"
  exit 1
fi

# Parameter file: a host file is mounted into the container; a plain name is
# a file shipped with fr-lio (checked inside the container).
CONFIG_MOUNT=()
if [[ -f "$CONFIG_FILE" ]]; then
  CONFIG_FILE=$(realpath "$CONFIG_FILE")
  CONFIG_MOUNT=(-v "$CONFIG_FILE":"$CONFIG_MOUNT_CONTAINER":ro)
  CONFIG_CONTAINER="$CONFIG_MOUNT_CONTAINER"
  CONFIG_DESC="$CONFIG_FILE (host)"
elif [[ "$CONFIG_FILE" != */* ]]; then
  CONFIG_CONTAINER="$CONFIG_DIR_CONTAINER/$CONFIG_FILE"
  CONFIG_DESC="$CONFIG_FILE (fr-lio config/)"
else
  echo "Error: CONFIG_FILE does not exist: $CONFIG_FILE"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# Orchestration convention: a directory input is an already-converted ROS 2 bag
# (played directly); a file input is a ROS 1 .bag (converted first).
if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

echo "Input           : $DATASET_HOST_PATH ($([[ $INPUT_IS_DIR == 1 ]] && echo 'ROS 2 bag directory' || echo 'ROS 1 bag file, converted to ROS 2'))"
echo "Output dir      : $BAG_OUTPUT_HOST"
echo "Parameter file  : $CONFIG_DESC"
echo "LiDAR topic     : $LIDAR_TOPIC"
echo "Odom topic      : $ODOM_TOPIC"
echo "Cloud topic     : $CLOUD_TOPIC"

xhost +local:docker >/dev/null

# ── Phase 1: run fr-lio + record output topics ───────────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ENV" \
  -e USE_RVIZ="$USE_RVIZ" \
  -e CONFIG_CONTAINER="$CONFIG_CONTAINER" \
  -e LIDAR_TOPIC="$LIDAR_TOPIC" \
  -e ACCUMULATE_COUNT="$ACCUMULATE_COUNT" \
  -e ODOM_TOPIC="$ODOM_TOPIC" \
  -e CLOUD_TOPIC="$CLOUD_TOPIC" \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -e PLAY_RATE="${PLAY_RATE:-1.0}" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "${CONFIG_MOUNT[@]}" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/humble/setup.bash
    source /ros2_ws/install/setup.bash

    IMU_TOPIC=$(python3 /ros2_ws/scripts/fr_lio_preflight.py --imu-topic "$CONFIG_CONTAINER") || {
      echo "[preflight] ERROR: cannot read common/imu_topic from $CONFIG_CONTAINER"; exit 42; }
    export IMU_TOPIC

    # ── Convert ROS 1 bag to ROS 2 format if needed (LiDAR and IMU only) ─────
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Input is already a ROS 2 bag directory — skipping conversion."
      ROS2_BAG="'"$DATASET_CONTAINER_PATH"'"
    else
      echo "[convert] Converting $LIDAR_TOPIC and $IMU_TOPIC of the ROS 1 bag to ROS 2 format..."
      rm -rf "'"$DATASET_ROS2_PATH"'"
      rosbags-convert "'"$DATASET_CONTAINER_PATH"'" --dst "'"$DATASET_ROS2_PATH"'" \
        --include-topic "$LIDAR_TOPIC" --include-topic "$IMU_TOPIC" || {
        echo "[convert] ERROR: rosbags-convert failed"; exit 1; }
      ROS2_BAG="'"$DATASET_ROS2_PATH"'"
    fi

    export ROS2_BAG
    echo "[convert] ROS 2 bag ready at: $ROS2_BAG"
    ls -la $ROS2_BAG/

    # ── Preflight: the LiDAR and IMU topics must be in the bag, otherwise ────
    # fr-lio processes nothing and the run records no output. Derives how many
    # Livox messages lidar_accumulator merges into one scan.
    rm -f '"$COUNT_FILE_CONTAINER"'
    if ! python3 /ros2_ws/scripts/fr_lio_preflight.py "$CONFIG_CONTAINER" "$ROS2_BAG" "$LIDAR_TOPIC" '"$COUNT_FILE_CONTAINER"'; then
      echo "[preflight] input check failed, nothing is run"
      exit 42
    fi
    if [[ -z "$ACCUMULATE_COUNT" ]]; then
      read -r ACCUMULATE_COUNT < '"$COUNT_FILE_CONTAINER"'
    else
      echo "[preflight] ACCUMULATE_COUNT=$ACCUMULATE_COUNT set by the user"
    fi
    export ACCUMULATE_COUNT

    # Diagnostic logs, next to the recording. Exported so the shells of the
    # tmux panes inherit it.
    export LOG_DIR='"$BAG_OUTPUT_CONTAINER"'/logs
    mkdir -p "$LOG_DIR"
    rm -f "$LOG_DIR"/*.log
    echo "[setup] diagnostic logs -> $LOG_DIR"

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: fr-lio (lidar_accumulator + frlio) ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "[fr-lio] launching fr_lio_bench.launch.py (config=$CONFIG_CONTAINER, accumulate_count=$ACCUMULATE_COUNT) ..."
stdbuf -oL -eL ros2 launch fr_lio fr_lio_bench.launch.py config_file:=$CONFIG_CONTAINER accumulate_count:=$ACCUMULATE_COUNT lidar_input_topic:=$LIDAR_TOPIC 2>&1 | tee "$LOG_DIR"/fr_lio.log
'\'' C-m

    # ---------- PANE 1: ros2 bag record ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 2
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
rm -rf '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
ros2 bag record $ODOM_TOPIC $CLOUD_TOPIC -o '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 2: ros2 bag play (LiDAR and IMU only) ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 6
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "[play] start: $LIDAR_TOPIC $IMU_TOPIC"
ros2 bag play $ROS2_BAG --topics $LIDAR_TOPIC $IMU_TOPIC --rate ${PLAY_RATE:-1.0}; tmux wait-for -S BAG_DONE;
echo "[play] done"
'\'' C-m

    # ---------- PANE 3: RViz ----------
    # Horizontal from here on: the detached session is 80x24, which has room
    # for at most three vertical splits.
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 2
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
if [[ "$USE_RVIZ" == "1" ]]; then
  echo "[rviz] launching RViz2..."
  rviz2 -d /ros2_ws/install/fr_lio/share/fr_lio/rviz/fr_lio.rviz
else
  echo "[rviz] disabled (USE_RVIZ=0)"
fi
'\'' C-m

    # ---------- PANE 4: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 12
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
(
echo "=== ROS 2 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
ros2 topic list
echo ""
for t in $LIDAR_TOPIC /livox/lidar_accumulated $IMU_TOPIC $ODOM_TOPIC $CLOUD_TOPIC; do
  echo "--- hz $t ---"
  timeout 5 ros2 topic hz $t 2>&1 | tail -2
done
) 2>&1 | tee "$LOG_DIR"/diag.log
echo ""
echo "[diag] done — you can type ROS 2 commands here, e.g.:"
echo "  ros2 topic echo $ODOM_TOPIC --once"
'\'' C-m

    # ---------- Control window (window 1) ----------
    # This is the window the user attaches to; the noisy panes are on window 0.
    # It waits for the play pane to signal end of playback, then tears the whole
    # session down.
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/humble/setup.bash
source /ros2_ws/install/setup.bash
echo "[control] waiting for bag playback to finish..."
echo "(logs -> $LOG_DIR/{fr_lio,diag}.log)"
tmux wait-for BAG_DONE
echo "[control] bag playback finished — shutting down"

# Give fr-lio a moment to process remaining queued scans
sleep 3

echo ""
echo "--- fr_lio.log: last 5 WARN / ERROR lines ---"
grep -E "\[WARN\]|\[ERROR\]" "$LOG_DIR"/fr_lio.log 2>/dev/null | tail -5
echo ""

# Graceful stop: Ctrl+C to each pane, the recorder first so its bag is closed cleanly
# Pane layout: 0=fr-lio, 1=recorder, 2=play, 3=rviz, 4=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 3
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
tmux send-keys -t '"$TMUX_SESSION"':0.3 C-c
sleep 3

# Force-kill by process name
echo "[control] force-killing remaining processes..."
pkill -9 frlio            2>/dev/null || true
pkill -9 lidar_accum      2>/dev/null || true
pkill -9 rviz2            2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# The preflight check failed: nothing was recorded, and converting would pick
# up a stale recording from an earlier run.
if [[ $? -eq 42 ]]; then
  echo "=== ABORTED: input check failed, no conversion ==="
  exit 1
fi

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/humble/setup.bash
    source /ros2_ws/install/setup.bash
    ros2 run fr_lio_to_hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-fr-lio\" \
      \"$ODOM_TOPIC\" \
      \"$CLOUD_TOPIC\"
  "

echo "=== DONE ==="
