"""One command for the Argus stack.

    ros2 launch argus_bringup argus.launch.py
    ros2 launch argus_bringup argus.launch.py program:=true
    ros2 launch argus_bringup argus.launch.py decode:=false console:=false

Starts, in one terminal with one prefix per process:

    preflight   route / VPN / files / console-port checks (informational)
    console     the board's UART as a process; released on Ctrl-C
    relay       argus_sim dataset_relay_node on the replay .bin
    receiver    argus_sensors neural_udp_receiver, UDP :5005 -> bridge topic
    bridge      argus_sensors neural_telemetry_receiver -> /argus/sensors/neural_telemetry
    decoder     argus_inference inference_node -> /cmd_vel
    program     (program:=true) the Vitis Run sequence via XSDB, 2 s after
                the relay is up so the firmware's first fetch finds it

Ctrl-C ends all of it. The board keeps running whatever it was programmed
with; only the host side stops.
"""

import os

from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, TimerAction
from launch.conditions import IfCondition, UnlessCondition
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution, PythonExpression
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare

HOME = os.path.expanduser('~')


def generate_launch_description():
    share = FindPackageShare('argus_bringup')
    config = PathJoinSubstitution([share, 'config', 'argus.yaml'])
    scripts = PathJoinSubstitution([share, 'scripts'])

    dataset = LaunchConfiguration('dataset')
    mat = LaunchConfiguration('mat')
    model = LaunchConfiguration('model')
    has_model = PythonExpression(["'", model, "' != ''"])
    console_dev = LaunchConfiguration('console_dev')
    firmware = LaunchConfiguration('firmware')

    args = [
        DeclareLaunchArgument(
            'dataset',
            default_value=os.path.join(HOME, 'argus_data', 'indy_20161005_06_s120_10s.bin'),
            description='Replay .bin the relay serves (RHD2132 codes at 30012 Hz)'),
        DeclareLaunchArgument(
            'mat',
            default_value=os.path.join(HOME, 'argus_data', 'indy_20161005_06.mat'),
            description='Training set for the decoder (ARGUS_DATASET_PATH)'),
        DeclareLaunchArgument(
            'model', default_value='',
            description='Saved decoder pipeline (decode_test.py --save-model); empty = train on the .mat at startup'),
        DeclareLaunchArgument('relay', default_value='true',
                              description='Run the dataset relay'),
        DeclareLaunchArgument('receiver', default_value='true',
                              description='Run the UDP receiver and telemetry bridge'),
        DeclareLaunchArgument('decode', default_value='true',
                              description='Run the decoder'),
        DeclareLaunchArgument('console', default_value='true',
                              description='Stream the board console into the launch output'),
        DeclareLaunchArgument('console_dev', default_value='/dev/ttyUSB1',
                              description='Board UART device'),
        DeclareLaunchArgument('program', default_value='false',
                              description='Program the FPGA and run the ELF via XSDB'),
        DeclareLaunchArgument(
            'firmware',
            default_value=os.path.join(HOME, 'Documents', 'argus_safety_controller'),
            description='argus_safety_controller checkout (for tools/program.sh)'),
    ]

    preflight = ExecuteProcess(
        cmd=['bash', PathJoinSubstitution([scripts, 'preflight.sh']),
             dataset, mat, console_dev],
        name='preflight',
        output='screen',
    )

    console = ExecuteProcess(
        cmd=['bash', PathJoinSubstitution([scripts, 'console.sh']), console_dev],
        name='console',
        output='screen',
        condition=IfCondition(LaunchConfiguration('console')),
    )

    relay = Node(
        package='argus_sim',
        executable='dataset_relay_node',
        name='dataset_relay',
        output='screen',
        parameters=[config, {'dataset_path': dataset}],
        condition=IfCondition(LaunchConfiguration('relay')),
    )

    receiver = Node(
        package='argus_sensors',
        executable='neural_udp_receiver',
        name='neural_udp_receiver',
        output='screen',
        parameters=[config],
        condition=IfCondition(LaunchConfiguration('receiver')),
    )

    bridge = Node(
        package='argus_sensors',
        executable='neural_telemetry_receiver_node',
        name='neural_telemetry_receiver',
        output='screen',
        parameters=[config],
        condition=IfCondition(LaunchConfiguration('receiver')),
    )

    # Two declarations of one node: with a saved model the decoder loads it
    # (ARGUS_MODEL_PATH); without one it trains on the .mat at startup. An
    # empty ARGUS_MODEL_PATH would read as "set", so it is only exported
    # when model:= is non-empty.
    decoder = Node(
        package='argus_inference',
        executable='inference_node',
        name='argus_inference',
        output='screen',
        parameters=[config],
        additional_env={'ARGUS_DATASET_PATH': mat},
        condition=IfCondition(PythonExpression([LaunchConfiguration('decode'), " and not ", has_model])),
    )
    decoder_with_model = Node(
        package='argus_inference',
        executable='inference_node',
        name='argus_inference',
        output='screen',
        parameters=[config],
        additional_env={'ARGUS_DATASET_PATH': mat, 'ARGUS_MODEL_PATH': model},
        condition=IfCondition(PythonExpression([LaunchConfiguration('decode'), " and ", has_model])),
    )

    # After the relay is listening: the firmware's first fetch goes out
    # within milliseconds of the ELF starting, and with no relay it prints
    # "replay FAILED" and never streams.
    program = TimerAction(
        period=2.0,
        actions=[ExecuteProcess(
            cmd=['bash', PathJoinSubstitution([firmware, 'tools', 'program.sh'])],
            name='program',
            output='screen',
        )],
        condition=IfCondition(LaunchConfiguration('program')),
    )

    return LaunchDescription(args + [
        preflight,
        console,
        relay,
        receiver,
        bridge,
        decoder,
        decoder_with_model,
        program,
    ])
