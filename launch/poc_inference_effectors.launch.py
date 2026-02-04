from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import Node


def generate_launch_description():
    use_sim_time = LaunchConfiguration('use_sim_time')

    inference_node = Node(
        package='argus_inference',
        executable='inference_node',
        name='argus_inference',
        output='screen',
        parameters=[{'use_sim_time': use_sim_time}],
    )

    effectors_node = Node(
        package='argus_effectors',
        executable='effectors_node',
        name='argus_effectors',
        output='screen',
        parameters=[{'use_sim_time': use_sim_time}],
    )

    return LaunchDescription([
        DeclareLaunchArgument(
            'use_sim_time',
            default_value='false',
            description='Use simulation time if true',
        ),
        inference_node,
        effectors_node,
    ])
