#!/usr/bin/env python3
"""Preflight check for the fr-lio benchmark run.

fr-lio reads Livox CustomMsg scans (livox_ros_driver2) and an IMU topic.
Its lidar_accumulator merges `accumulate_count` consecutive CustomMsg into one
scan for frlio. Upstream uses 10, for a driver publishing 10 ms packets at
100 Hz; the count is derived here from the bag instead, as
    round(LiDAR message rate / preprocess/scan_rate), at least 1,
so frlio gets scans at the config's scan rate whatever the driver's publish
rate was (1 for a bag that already holds full 100 ms scans).

If the LiDAR or the IMU topic is missing, fr-lio processes nothing and the run
records no output, so the run is stopped (exit code 42, the run script then
skips the conversion). On success the accumulate count is written to
<count_file>.

Usage: fr_lio_preflight.py <parameter_file.yaml> <ros2_bag_dir> <lidar_input_topic> <count_file>
       fr_lio_preflight.py --imu-topic <parameter_file.yaml>   (prints common/imu_topic)
"""

import os
import sys

import yaml

CUSTOM_MSG = "livox_ros_driver2/msg/CustomMsg"
IMU = "sensor_msgs/msg/Imu"


def ros_parameters(config):
    """fr-lio parameter files keep everything under <node or /**>: ros__parameters:."""
    for value in config.values():
        if isinstance(value, dict) and "ros__parameters" in value:
            return value["ros__parameters"]
    raise KeyError("ros__parameters")


def main():
    if sys.argv[1] == "--imu-topic":
        with open(sys.argv[2]) as f:
            print(ros_parameters(yaml.safe_load(f))["common"]["imu_topic"])
        return
    config_path, bag_dir, lidar_topic, count_file = sys.argv[1:5]
    try:
        with open(config_path) as f:
            params = ros_parameters(yaml.safe_load(f))
        imu_topic = params["common"]["imu_topic"]
        scan_rate = float(params["preprocess"]["scan_rate"])
    except (OSError, KeyError, TypeError, ValueError, AttributeError, yaml.YAMLError) as e:
        print(f"[preflight] ERROR: cannot read common/imu_topic and preprocess/scan_rate from {config_path}: {e}")
        sys.exit(42)
    print(f"[preflight] parameter file: {config_path}")
    print(f"[preflight] LiDAR topic: {lidar_topic}  IMU topic: {imu_topic}  scan_rate: {scan_rate:g} Hz")

    try:
        with open(os.path.join(bag_dir, "metadata.yaml")) as f:
            info = yaml.safe_load(f)["rosbag2_bagfile_information"]
        topics = {t["topic_metadata"]["name"]: (t["topic_metadata"]["type"], t["message_count"])
                  for t in info["topics_with_message_count"]}
        duration_s = info["duration"]["nanoseconds"] * 1e-9
    except (OSError, KeyError, TypeError, yaml.YAMLError) as e:
        print(f"[preflight] ERROR: cannot read the ROS 2 bag metadata in {bag_dir}: {e}")
        sys.exit(42)

    ok = True
    for name, msg_type in ((lidar_topic, CUSTOM_MSG), (imu_topic, IMU)):
        found = topics.get(name)
        if found is None or found[0] != msg_type:
            print(f"[preflight] ERROR: {name} must be {msg_type} ({found[0] if found else 'not in the bag'}).")
            ok = False
        else:
            print(f"[preflight] {name}: {found[1]} msgs ({msg_type})")
    if not ok:
        for msg_type in (CUSTOM_MSG, IMU):
            names = [t for t, (ty, _) in topics.items() if ty == msg_type]
            print(f"[preflight] {msg_type} topics in this bag: {', '.join(names) or '(none)'}")
        print("[preflight] Set LIDAR_TOPIC, or common/imu_topic in the parameter file (CONFIG_FILE).")
        sys.exit(42)

    rate = topics[lidar_topic][1] / duration_s if duration_s > 0 else scan_rate
    count = max(1, round(rate / scan_rate))
    print(f"[preflight] {lidar_topic} at {rate:.1f} Hz -> lidar_accumulator merges {count} message(s) per scan")
    with open(count_file, "w") as f:
        f.write(f"{count}\n")


if __name__ == "__main__":
    main()
