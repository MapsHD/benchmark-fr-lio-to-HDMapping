## Hint

Please change branch to [Bunker-DVI-Dataset-reg-1](https://github.com/MapsHD/benchmark-fr-lio-to-HDMapping/tree/Bunker-DVI-Dataset-reg-1) for quick experiment.

## Example Dataset:

Download the dataset from [Bunker DVI Dataset](https://charleshamesse.github.io/bunker-dvi-dataset/)

# benchmark-fr-lio-to-HDMapping

Runs the [fr-lio](https://github.com/alvgaona/fr-lio) LiDAR-inertial odometry
on a ROS 2 (or ROS 1) bag and converts the output to an
[HDMapping](https://github.com/MapsHD/HDMapping) session.

fr-lio (Flight-ready Drift-Aware LiDAR-Inertial Odometry and Mapping with
Self-correcting Maps, A. J. Gaona et al.) builds on FAST-LIO2 and adds
real-time loop closure (iSAM2 pose graph) with map correction. It is developed
for a Livox Mid-360.

## Prerequisites

- Docker
- A ROS 2 bag directory (or a ROS 1 bag, converted to ROS 2 automatically)
  with a Livox `livox_ros_driver2/CustomMsg` LiDAR topic and a
  `sensor_msgs/Imu` topic.

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-fr-lio-to-HDMapping.git --recursive
cd benchmark-fr-lio-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t fr-lio_humble .
```

This installs:
- Ubuntu 22.04 + ROS 2 Humble, GTSAM, glog, TBB, PCL
- the author's forks of ikd-tree, Livox-SDK2 and livox_ros_driver2 (fr-lio's
  `deps.repos`), pinned as submodules
- colcon workspace with `fr_lio` and `fr_lio_to_hdmapping`

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros2-fr-lio.sh
./docker_session_run-ros2-fr-lio.sh /path/to/ros2_bag_dir /path/to/output/dir
```

A ROS 1 `.bag` file works as input too; its LiDAR and IMU topics are converted
to ROS 2 first. Or run with no arguments to use a GUI file selector (requires
`zenity`).

| Variable | Default | Meaning |
|----------|---------|---------|
| `CONFIG_FILE` | `indoors.yaml` | fr-lio parameter file. A file on the host, or the name of one in fr-lio's [config/](https://github.com/alvgaona/fr-lio/tree/main/config) folder (`indoors.yaml`, `outdoors.yaml`, ...) |
| `LIDAR_TOPIC` | `/livox/lidar` | Livox CustomMsg topic in the bag |
| `ACCUMULATE_COUNT` | derived from the bag | Livox messages fr-lio's `lidar_accumulator` merges into one scan |
| `USE_RVIZ` | `1` | RViz live view |
| `PLAY_RATE` | `1.0` | ros2 bag play rate (lower it if fr-lio cannot keep up) |

fr-lio feeds its estimator through `lidar_accumulator`, which merges a number
of consecutive Livox messages into one scan. Upstream merges 10, for a Livox
driver publishing 10 ms packets at 100 Hz. The script derives the number from
the bag, LiDAR message rate divided by the config's `preprocess/scan_rate`, so
a bag that already holds full 100 ms scans gets 1. Before anything starts, the
script also checks that the LiDAR and IMU topics are in the bag.

**What happens:**

The script opens a Docker container with a tmux session containing five panes on
window 0 and a `control` window (window 1, the attach target):

| Pane | Role |
|------|------|
| 0 | `ros2 launch fr_lio fr_lio_bench.launch.py` — `lidar_accumulator` + `frlio` |
| 1 | `ros2 bag record /odom_unfiltered /cloud_registered` |
| 2 | `ros2 bag play` of the LiDAR and IMU topics |
| 3 | RViz live view |
| 4 | diagnostics — shows active topics and publishing rates |

When playback finishes, the control window stops the recorder, kills all nodes
and RViz, and exits tmux. A second Docker run then converts the recorded bag
into the HDMapping session format. Logs are written to `<output_dir>/logs/`.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-fr-lio/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
...
session.json
trajectory_lio_0.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on fr-lio

fr-lio publishes its pose only at IMU rate, forward-propagated from the state
of the last scan update:

| Topic | Type | Meaning |
|-------|------|---------|
| `/odom` | `nav_msgs/Odometry` | pose in the `odom` frame, orientation smoothed for flight control |
| `/odom_unfiltered` | `nav_msgs/Odometry` | the same pose without the smoothing (the raw estimator state) |
| `/odom_map` | `nav_msgs/Odometry` | pose in the `map` frame, with loop-closure corrections |
| `/cloud_registered` | `sensor_msgs/PointCloud2` | the scan in the `odom` frame, one per scan |

The converter records `/odom_unfiltered` + `/cloud_registered`: both are in the
`odom` frame, so poses and points of the session match.

**Timestamps:** the benchmark does not change fr-lio's clock (no
`use_sim_time`, its own default). fr-lio stamps the odometry with the IMU
message's stamp and the scan with its end time, so the result is in bag time.

## Contact

januszbedkowski@gmail.com
