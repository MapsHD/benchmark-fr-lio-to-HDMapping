# Benchmark launch for fr-lio: upstream lio.launch.py (lidar_accumulator +
# frlio) without the mocap converter and RViz (the benchmark script starts
# RViz in its own pane), with the accumulator's message count and input topic
# as launch arguments.
#
# lidar_accumulator merges `accumulate_count` consecutive Livox CustomMsg into
# one scan for frlio (upstream: 10, for a driver publishing 10 ms packets at
# 100 Hz). The benchmark script derives the count from the bag so that frlio
# gets scans at the config's scan_rate (e.g. 1 for a bag with full 100 ms scans).
#
# The ROS clock is left as is (use_sim_time false, as upstream defaults):
# frlio stamps its outputs with times taken from the input messages.

import os

from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, OpaqueFunction
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    default_config_file = os.path.join(
        get_package_share_directory('fr_lio'), 'config', 'indoors.yaml')

    def launch_nodes(context):
        config_file = os.path.abspath(LaunchConfiguration('config_file').perform(context))
        accumulate_count = int(LaunchConfiguration('accumulate_count').perform(context))
        lidar_input_topic = LaunchConfiguration('lidar_input_topic').perform(context)
        return [
            Node(
                package='fr_lio',
                executable='lidar_accumulator',
                parameters=[{
                    'accumulate_count': accumulate_count,
                    'input_topic': lidar_input_topic,
                    'output_topic': '/livox/lidar_accumulated',
                }],
                output='screen',
            ),
            Node(
                package='fr_lio',
                executable='frlio',
                parameters=[config_file, {'use_sim_time': False}],
                output='screen',
            ),
        ]

    return LaunchDescription([
        DeclareLaunchArgument('config_file', default_value=default_config_file,
                              description='frlio parameter file'),
        DeclareLaunchArgument('accumulate_count', default_value='10',
                              description='Livox messages merged into one scan'),
        DeclareLaunchArgument('lidar_input_topic', default_value='/livox/lidar',
                              description='Livox CustomMsg topic in the bag'),
        OpaqueFunction(function=launch_nodes),
    ])
