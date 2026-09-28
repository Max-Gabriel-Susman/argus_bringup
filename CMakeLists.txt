cmake_minimum_required(VERSION 3.8)
project(argus_bringup)

find_package(ament_cmake REQUIRED)

install(DIRECTORY launch config
  DESTINATION share/${PROJECT_NAME})

install(PROGRAMS
  scripts/console.sh
  scripts/preflight.sh
  DESTINATION share/${PROJECT_NAME}/scripts)

ament_package()
